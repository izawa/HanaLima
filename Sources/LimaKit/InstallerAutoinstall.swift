import Foundation

/// Unattended installation from an Ubuntu Server ISO (docs/07), used by the end-to-end test.
///
/// Subiquity runs unattended only with `autoinstall` on the kernel command line, which the ISO's
/// GRUB doesn't offer, and booting the kernel directly (no EFI) breaks the installer's bootloader
/// step. So the VM boots EFI from a small FAT image holding the ISO's own shim and GRUB with our
/// `grub.cfg`, which starts the ISO's kernel with the extra parameters. The answers come from a
/// NoCloud seed ISO (label `cidata`); its late commands do what `limaify.sh` does, so Lima's
/// `cidata.iso` takes over at the first boot under `limactl start`.
public enum InstallerAutoinstall {
    /// The kernel parameters: unattended, and the installer on the serial console (the last
    /// `console=` wins), so a log file shows its progress.
    public static let kernelParameters = "autoinstall --- console=tty0 console=hvc0"

    /// The seed's `user-data`: a minimal server (plain ext4 on the first disk, OpenSSH), the
    /// fix-up as late commands, then power off. `password` is a crypt(3) hash (`openssl passwd -6`).
    public static func userData(hostname: String, userName: String, passwordHash: String) -> String {
        let fixup = InstallerFixup.cloudInitSteps.joined(separator: " && ")
        return """
        #cloud-config
        autoinstall:
          version: 1
          locale: en_US.UTF-8
          keyboard:
            layout: us
          identity:
            hostname: \(hostname)
            username: \(userName)
            password: \(yaml(passwordHash))
          ssh:
            install-server: true
          storage:
            layout:
              name: direct
              match:
                path: /dev/vda
          late-commands:
            - \(yaml("curtin in-target --target=/target -- sh -c \(shell(fixup))"))
            - \(yaml("echo HANALIMA-LATE-DONE"))
          shutdown: poweroff

        """
    }

    public static let metaData = "instance-id: hanalima-autoinstall\nlocal-hostname: autoinstall\n"

    /// A double-quoted YAML scalar.
    static func yaml(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// A single-quoted shell word.
    static func shell(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Writes the seed ISO (`user-data`, `meta-data`) with `hdiutil makehybrid`.
    public static func makeSeedISO(at output: URL, userData: String) throws {
        let fm = FileManager.default
        let staging = output.deletingLastPathComponent().appending(path: "seed-root", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try userData.write(to: staging.appending(path: "user-data"), atomically: true, encoding: .utf8)
        try metaData.write(to: staging.appending(path: "meta-data"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: output)
        try run("/usr/bin/hdiutil", ["makehybrid", "-iso", "-joliet", "-default-volume-name", "cidata",
                                     "-o", output.path, staging.path])
        try? fm.removeItem(at: staging)
    }

    /// Builds the FAT boot image (128 MiB, MBR) at `output` from the ISO's `EFI/boot` and
    /// `.disk/info` (GRUB's embedded config looks for it) plus our `grub.cfg`. macOS can't mount
    /// these ISOs, so the files come out through `bsdtar`.
    public static func makeBootImage(at output: URL, iso: URL) throws {
        let fm = FileManager.default
        let staging = output.deletingLastPathComponent().appending(path: "boot-root", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try run("/usr/bin/bsdtar", ["-xf", iso.path, "-C", staging.path, "EFI/boot", ".disk/info"])
        let grub = staging.appending(path: "boot/grub", directoryHint: .isDirectory)
        try fm.createDirectory(at: grub, withIntermediateDirectories: true)
        try grubConfig.write(to: grub.appending(path: "grub.cfg"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: output)
        let handle = try FileHandle(forWritingTo: { fm.createFile(atPath: output.path, contents: nil); return output }())
        try handle.truncate(atOffset: 128 << 20)
        try handle.close()
        let attach = try run("/usr/bin/hdiutil", ["attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", output.path])
        guard let device = attach.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            throw ExternalDisk.Failure(message: "hdiutil attach: no device")
        }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", device]) }
        _ = try run("/usr/sbin/diskutil", ["eraseDisk", "FAT32", "HLBOOT", "MBRFormat", device])
        let info = try run("/usr/sbin/diskutil", ["info", device + "s1"])
        guard let line = info.split(separator: "\n").first(where: { $0.contains("Mount Point:") }),
              let colon = line.firstIndex(of: ":") else {
            throw ExternalDisk.Failure(message: "boot image: not mounted")
        }
        let mount = URL(filePath: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces), directoryHint: .isDirectory)
        for name in ["EFI", "boot", ".disk"] {
            try fm.copyItem(at: staging.appending(path: name), to: mount.appending(path: name))
        }
        try? fm.removeItem(at: staging)
    }

    static let grubConfig = """
    set timeout=0
    # HanaLima: start the installer on the attached Ubuntu ISO with extra kernel parameters.
    search --set=iso --file /casper/vmlinuz
    menuentry "HanaLima autoinstall" {
        linux (${iso})/casper/vmlinuz \(kernelParameters)
        initrd (${iso})/casper/initrd
    }

    """

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(filePath: executable)
        p.arguments = arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let error = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw ExternalDisk.Failure(message: "\(URL(filePath: executable).lastPathComponent) \(arguments.first ?? ""): \(error.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return output
    }
}
