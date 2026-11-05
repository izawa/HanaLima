import Foundation
import Darwin

private func fdError(_ operation: String, errno code: Int32 = errno) -> NSError {
    NSError(domain: "FDPassing", code: Int(code), userInfo: [
        NSLocalizedDescriptionKey: "\(operation): \(String(cString: strerror(code))) (errno \(code))"
    ])
}

private func fdAddress(_ path: String) throws -> sockaddr_un {
    var address = sockaddr_un()
    let bytes = Array(path.utf8) + [0]
    guard !path.utf8.contains(0), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
        throw fdError("Invalid Unix socket path", errno: ENAMETOOLONG)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    return address
}

func makeDatagramSocketPair() throws -> (local: FileHandle, remote: FileHandle) {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
        throw fdError("socketpair")
    }
    for descriptor in descriptors {
        var size: Int32 = 1 << 20
        for option in [SO_SNDBUF, SO_RCVBUF] {
            _ = setsockopt(descriptor, SOL_SOCKET, option, &size, socklen_t(MemoryLayout.size(ofValue: size)))
        }
    }
    return (FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true),
            FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true))
}

func sendFileDescriptor(_ fd: Int32, toUnixSocketAt path: String) throws {
    var address = try fdAddress(path)
    let stream = socket(AF_UNIX, SOCK_STREAM, 0)
    guard stream >= 0 else { throw fdError("socket") }
    defer { close(stream) }
    var enabled: Int32 = 1
    guard setsockopt(stream, SOL_SOCKET, SO_NOSIGPIPE, &enabled, 4) == 0 else {
        throw fdError("setsockopt(SO_NOSIGPIPE)")
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(stream, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { throw fdError("connect to \(path)") }

    // Darwin aligns ancillary data to four bytes: 12-byte header + 4-byte fd.
    let controlSize = (MemoryLayout<cmsghdr>.size + MemoryLayout<Int32>.size + 3) & ~3
    let control = UnsafeMutableRawPointer.allocate(byteCount: controlSize, alignment: 4)
    defer { control.deallocate() }
    control.initializeMemory(as: UInt8.self, repeating: 0, count: controlSize)
    var header = cmsghdr()
    header.cmsg_len = socklen_t(controlSize)
    header.cmsg_level = SOL_SOCKET
    header.cmsg_type = SCM_RIGHTS
    control.storeBytes(of: header, as: cmsghdr.self)
    control.storeBytes(of: fd, toByteOffset: 12, as: Int32.self)
    var payload: UInt8 = 0
    let sent = withUnsafeMutablePointer(to: &payload) { payloadPointer in
        var vector = iovec(iov_base: UnsafeMutableRawPointer(payloadPointer), iov_len: 1)
        return withUnsafeMutablePointer(to: &vector) { vectorPointer in
            var message = msghdr()
            message.msg_iov = vectorPointer
            message.msg_iovlen = 1
            message.msg_control = control
            message.msg_controllen = socklen_t(controlSize)
            var result: Int
            repeat { result = sendmsg(stream, &message, 0) } while result < 0 && errno == EINTR
            return result
        }
    }
    guard sent == 1 else { throw fdError("sendmsg(SCM_RIGHTS)", errno: sent < 0 ? errno : EIO) }
}

func fdPassingSelfTest() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fd-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("s").path
    var address = try fdAddress(path)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw fdError("self-test socket") }
    defer { close(listener) }
    let bound = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0 else { throw fdError("self-test bind") }
    guard listen(listener, 1) == 0 else { throw fdError("self-test listen") }
    let pair = try makeDatagramSocketPair()
    defer { try? pair.local.close(); try? pair.remote.close() }
    try sendFileDescriptor(pair.remote.fileDescriptor, toUnixSocketAt: path)
    let stream = accept(listener, nil, nil)
    guard stream >= 0 else { throw fdError("self-test accept") }
    defer { close(stream) }
    let control = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 4)
    defer { control.deallocate() }
    control.initializeMemory(as: UInt8.self, repeating: 0, count: 16)
    var payload: UInt8 = 0
    var receivedFD: Int32 = -1
    try withUnsafeMutablePointer(to: &payload) { pointer in
        var vector = iovec(iov_base: UnsafeMutableRawPointer(pointer), iov_len: 1)
        try withUnsafeMutablePointer(to: &vector) { vectorPointer in
            var message = msghdr()
            message.msg_iov = vectorPointer
            message.msg_iovlen = 1
            message.msg_control = control
            message.msg_controllen = 16
            guard recvmsg(stream, &message, 0) == 1 else { throw fdError("self-test recvmsg") }
            let header = control.load(as: cmsghdr.self)
            guard message.msg_flags & MSG_CTRUNC == 0, message.msg_controllen >= 16,
                  header.cmsg_len == 16, header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_RIGHTS else {
                throw fdError("self-test invalid SCM_RIGHTS message", errno: EPROTO)
            }
            receivedFD = control.load(fromByteOffset: 12, as: Int32.self)
        }
    }
    defer { close(receivedFD) }
    // Verify the received descriptor independently owns the remote endpoint.
    try pair.remote.close()
    let expected = Data("datagram via SCM_RIGHTS".utf8)
    try pair.local.write(contentsOf: expected)
    var buffer = [UInt8](repeating: 0, count: 128)
    let count = recv(receivedFD, &buffer, buffer.count, 0)
    guard count >= 0 else { throw fdError("self-test recv datagram") }
    guard Data(buffer.prefix(count)) == expected else { throw fdError("self-test datagram mismatch", errno: EIO) }
}
