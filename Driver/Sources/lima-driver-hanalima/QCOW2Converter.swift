import Foundation

struct QCOW2Error: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

enum QCOW2 {
    private static let offsetMask: UInt64 = 0x00ff_ffff_ffff_fe00

    static func isQCOW2(_ url: URL) throws -> Bool {
        let fd = try openFile(url, flags: O_RDONLY)
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: 4)
        let count = try readBytes(fd, into: &bytes, at: 0)
        return count == 4 && bytes == [0x51, 0x46, 0x49, 0xfb]
    }

    static func convertToRaw(_ source: URL, to destination: URL) throws {
        let input = try openFile(source, flags: O_RDONLY)
        defer { close(input) }
        var inputInfo = stat()
        guard fstat(input, &inputInfo) == 0 else { throw systemError("Stat source") }
        guard inputInfo.st_size >= 72 else { throw QCOW2Error("Truncated QCOW2 header") }
        let sourceLength = UInt64(inputInfo.st_size)

        func read(_ offset: UInt64, _ count: Int) throws -> [UInt8] {
            guard offset <= sourceLength, UInt64(count) <= sourceLength - offset else {
                throw QCOW2Error("Read outside source at offset \(offset) (\(count) bytes)")
            }
            var bytes = [UInt8](repeating: 0, count: count)
            guard try readBytes(input, into: &bytes, at: offset) == count else {
                throw QCOW2Error("Unexpected end of source at offset \(offset)")
            }
            return bytes
        }

        let header = try read(0, 72)
        guard be(header, 0, 4) == 0x5146_49fb else { throw QCOW2Error("Invalid QCOW2 magic") }
        let version = be(header, 4, 4)
        guard version == 2 || version == 3 else {
            throw QCOW2Error("Unsupported QCOW2 version \(version)")
        }
        guard be(header, 8, 8) == 0 && be(header, 16, 4) == 0 else {
            throw QCOW2Error("Backing files are unsupported")
        }
        let clusterBits = be(header, 20, 4)
        guard (9...21).contains(clusterBits) else {
            throw QCOW2Error("Invalid cluster_bits \(clusterBits); expected 9...21")
        }
        let clusterSize = UInt64(1) << clusterBits
        let size = be(header, 24, 8)
        guard size <= UInt64(Int64.max) else { throw QCOW2Error("Virtual size exceeds file offset range") }
        guard be(header, 32, 4) == 0 else { throw QCOW2Error("Encrypted images are unsupported") }
        let l1Count = be(header, 36, 4)
        let l1Offset = be(header, 40, 8)
        if version == 3 {
            let extra = try read(72, 32)
            let incompatible = be(extra, 0, 8)
            guard incompatible & 1 == 0 else { throw QCOW2Error("Dirty QCOW2 images are unsupported") }
            guard incompatible & (1 << 4) == 0 else {
                throw QCOW2Error("Extended L2 entries are unsupported")
            }
            guard incompatible == 0 else {
                throw QCOW2Error("Unsupported incompatible features: 0x\(String(incompatible, radix: 16))")
            }
            let headerLength = be(extra, 28, 4)
            guard headerLength >= 104 && headerLength <= clusterSize && headerLength <= sourceLength else {
                throw QCOW2Error("Invalid v3 header_length \(headerLength)")
            }
        }
        let entriesPerL2 = clusterSize / 8
        let guestClusters = size / clusterSize + (size % clusterSize == 0 ? 0 : 1)
        let neededL1 = guestClusters / entriesPerL2 + (guestClusters % entriesPerL2 == 0 ? 0 : 1)
        guard l1Count >= neededL1 else { throw QCOW2Error("L1 table does not cover virtual size") }
        guard l1Offset % clusterSize == 0,
              l1Offset <= sourceLength, l1Count * 8 <= sourceLength - l1Offset,
              l1Count == 0 || l1Offset != 0 else {
            throw QCOW2Error("Invalid L1 table offset or length")
        }

        let output = try openFile(destination, flags: O_WRONLY | O_CREAT)
        defer { close(output) }
        var outputInfo = stat()
        guard fstat(output, &outputInfo) == 0 else { throw systemError("Stat destination") }
        guard inputInfo.st_dev != outputInfo.st_dev || inputInfo.st_ino != outputInfo.st_ino else {
            throw QCOW2Error("Source and destination refer to the same file")
        }
        // Clear existing contents so skipped clusters remain holes containing zeros.
        guard ftruncate(output, 0) == 0, ftruncate(output, off_t(size)) == 0 else {
            throw systemError("Resize destination")
        }
        var filesystem = statfs()
        guard fstatfs(output, &filesystem) == 0, filesystem.f_bsize > 0 else {
            throw systemError("Get destination filesystem block size")
        }
        let blockSize = UInt64(filesystem.f_bsize)
        func punchHole(from start: UInt64, to end: UInt64) throws {
            let alignedStart = start + (blockSize - start % blockSize) % blockSize
            let alignedEnd = end - end % blockSize
            guard alignedEnd > alignedStart else { return }
            var hole = fpunchhole_t(fp_flags: 0, reserved: 0,
                                   fp_offset: off_t(alignedStart), fp_length: off_t(alignedEnd - alignedStart))
            guard fcntl(output, F_PUNCHHOLE, &hole) == 0 else {
                throw systemError("Make destination sparse at offset \(alignedStart)")
            }
        }
        var allocatedEnd: UInt64 = 0
        for l1Index in 0..<neededL1 {
            let entry = be(try read(l1Offset + l1Index * 8, 8), 0, 8)
            let l2Offset = entry & offsetMask
            if l2Offset == 0 { continue }
            guard l2Offset % clusterSize == 0 else { throw QCOW2Error("Unaligned L2 table offset") }
            let l2 = try read(l2Offset, Int(clusterSize))
            for l2Index in 0..<min(entriesPerL2, guestClusters - l1Index * entriesPerL2) {
                let dataEntry = be(l2, Int(l2Index * 8), 8)
                if dataEntry == 0 { continue }
                guard dataEntry & (UInt64(1) << 62) == 0 else {
                    throw QCOW2Error("Compressed cluster at L1 \(l1Index), L2 \(l2Index) is unsupported")
                }
                if dataEntry & 1 != 0 {
                    guard version == 3 else { throw QCOW2Error("Zero flag is invalid in QCOW2 v2") }
                    continue
                }
                let hostOffset = dataEntry & offsetMask
                guard hostOffset != 0 && hostOffset % clusterSize == 0 else {
                    throw QCOW2Error("Invalid data cluster offset \(hostOffset)")
                }
                let guestOffset = (l1Index * entriesPerL2 + l2Index) * clusterSize
                let data = try read(hostOffset, Int(clusterSize))
                // The final guest cluster may extend past the virtual disk size.
                try writeBytes(output, data, count: Int(min(clusterSize, size - guestOffset)), at: guestOffset)
                // APFS may allocate gaps during writes; explicitly deallocate them afterward.
                try punchHole(from: allocatedEnd, to: guestOffset)
                allocatedEnd = guestOffset + min(clusterSize, size - guestOffset)
            }
        }
        try punchHole(from: allocatedEnd, to: size)
    }

    private static func be(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> UInt64 {
        bytes[offset..<(offset + count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func openFile(_ url: URL, flags: Int32) throws -> Int32 {
        guard url.isFileURL else { throw QCOW2Error("Expected a local file URL: \(url)") }
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, flags | O_CLOEXEC, mode_t(0o666)) } ?? -1
        }
        guard fd >= 0 else { throw systemError("Open \(url.path)") }
        return fd
    }

    private static func readBytes(_ fd: Int32, into bytes: inout [UInt8], at offset: UInt64) throws -> Int {
        try bytes.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < buffer.count {
                let count = pread(fd, buffer.baseAddress!.advanced(by: done), buffer.count - done, off_t(offset + UInt64(done)))
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemError("Read at offset \(offset + UInt64(done))")
                }
                if count == 0 { break }
                done += count
            }
            return done
        }
    }

    private static func writeBytes(_ fd: Int32, _ bytes: [UInt8], count: Int, at offset: UInt64) throws {
        try bytes.withUnsafeBytes { buffer in
            var done = 0
            while done < count {
                let written = pwrite(fd, buffer.baseAddress!.advanced(by: done), count - done, off_t(offset + UInt64(done)))
                if written < 0 {
                    if errno == EINTR { continue }
                    throw systemError("Write at offset \(offset + UInt64(done))")
                }
                guard written > 0 else { throw QCOW2Error("Write made no progress at offset \(offset + UInt64(done))") }
                done += written
            }
        }
    }

    private static func systemError(_ operation: String) -> QCOW2Error {
        QCOW2Error("\(operation): \(String(cString: strerror(errno)))")
    }
}
