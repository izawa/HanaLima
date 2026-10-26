import Foundation

/// The one-time fix-up for an OS installed from an ISO (docs/07): makes Lima's `cidata.iso`
/// (cloud-init, NoCloud) take over at the next boot, so Lima sets up its user, key, guest agent,
/// shares and provisioning as for any VM. Shipped to the guest on a small ISO labeled
/// `HANALIMA` with Lima's public key and the user name, and run as root from the installed OS.
public enum InstallerFixup {
    public static let volumeLabel = "HANALIMA"
    public static let scriptName = "limaify.sh"

    /// What the user types in the installed OS (no clipboard reaches the installer's screen).
    public static let command = "sudo mount -L \(volumeLabel) /mnt && sudo sh /mnt/\(scriptName)"

    /// What makes cloud-init take Lima's `cidata.iso` at the next boot (installers such as
    /// Ubuntu's subiquity pin the datasource or switch cloud-init off). Run as root in the
    /// installed OS, or in the installer's target (`curtin in-target`), so paths are absolute.
    public static let cloudInitSteps: [String] = [
        "rm -f /etc/cloud/cloud-init.disabled /etc/cloud/cloud.cfg.d/99-installer.cfg /etc/cloud/cloud.cfg.d/90-installer-network.cfg",
        "rm -rf /var/lib/cloud/seed",
        "printf 'datasource_list: [ NoCloud, None ]\\n' > /etc/cloud/cloud.cfg.d/95-hanalima.cfg",
        "cloud-init clean --logs",
    ]

    /// The script, with `cloudInitSteps` spliced in (the template's placeholder sits at the
    /// indentation the raw literal keeps: two spaces).
    public static var script: String {
        scriptTemplate.replacingOccurrences(of: "  CLOUD_INIT_STEPS", with: cloudInitSteps.map { "  " + $0 }.joined(separator: "\n"))
    }

    static let scriptTemplate = #"""
    #!/bin/sh
    # HanaLima: prepares an OS installed from an ISO for Lima. Installs cloud-init and sshd and
    # lets NoCloud run, so at the next boot Lima's cidata.iso sets up its user, key, guest agent,
    # shares and provisioning, as for any Lima VM. Run once, as root, from the installed OS.
    set -eu
    [ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
    D=$(cd "$(dirname "$0")" && pwd)
    if command -v apt-get >/dev/null 2>&1; then
      export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y cloud-init openssh-server
    elif command -v dnf >/dev/null 2>&1; then dnf install -y cloud-init openssh-server
    elif command -v apk >/dev/null 2>&1; then apk add cloud-init openssh
    elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm cloud-init openssh
    fi
    if command -v cloud-init >/dev/null 2>&1; then
      # Installers (Ubuntu's subiquity) may pin the datasource or switch cloud-init off.
      CLOUD_INIT_STEPS
      echo "cloud-init is ready: Lima configures this VM at the next boot."
    else
      # No cloud-init available: Lima's user and key, so limactl can ssh in (no guest agent, so
      # shares and port forwards won't work).
      U=$(cat "$D/user")
      id "$U" >/dev/null 2>&1 || useradd -m -u 501 -s /bin/sh "$U" 2>/dev/null || adduser -D -u 501 "$U"
      mkdir -p "/home/$U/.ssh"; cat "$D/user.pub" >> "/home/$U/.ssh/authorized_keys"
      chown -R "$U" "/home/$U/.ssh"; chmod 700 "/home/$U/.ssh"; chmod 600 "/home/$U/.ssh/authorized_keys"
      mkdir -p /etc/sudoers.d; echo "$U ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$U"; chmod 440 "/etc/sudoers.d/$U"
      (systemctl enable ssh || systemctl enable sshd || rc-update add sshd) >/dev/null 2>&1 || true
      echo "sshd and Lima's user are ready (no cloud-init on this system)."
    fi
    sync
    echo "Done. Shut the VM down now: sudo poweroff"
    """#

    /// Builds the helper ISO at `output` with `hdiutil makehybrid`: the script, Lima's public key
    /// (`<limaHome>/_config/user.pub`) and the user name.
    public static func makeISO(at output: URL, limaHome: URL, userName: String) throws {
        let fm = FileManager.default
        let staging = output.deletingLastPathComponent().appending(path: "helper-root", directoryHint: .isDirectory)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try script.write(to: staging.appending(path: scriptName), atomically: true, encoding: .utf8)
        try fm.copyItem(at: limaHome.appending(path: "_config/user.pub"), to: staging.appending(path: "user.pub"))
        try (userName + "\n").write(to: staging.appending(path: "user"), atomically: true, encoding: .utf8)
        try? fm.removeItem(at: output)
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/hdiutil")
        p.arguments = ["makehybrid", "-iso", "-joliet", "-default-volume-name", volumeLabel, "-o", output.path, staging.path]
        p.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        try? fm.removeItem(at: staging)
        guard p.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ExternalDisk.Failure(message: String(localized: "仕上げ用の ISO を作れませんでした: \(message)"))
        }
    }
}
