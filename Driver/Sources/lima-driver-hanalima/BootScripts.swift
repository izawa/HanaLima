import Foundation

/// Boot scripts the driver adds to Lima's cidata (`BootScripts` RPC; Lima runs `boot.Linux/*.sh`
/// in name order at every boot, after its own 25-guestagent and 30-install-packages).
enum BootScripts {
    static let all: [String: String] = ["boot.Linux/35-hanalima-vsock-ssh.sh": dedent(vsockSSH)]

    /// The scripts are written indented inside this file; the guest gets them flush left.
    static func dedent(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.hasPrefix("    ") ? String($0.dropFirst(4)) : String($0) }
        if lines.first?.isEmpty == true { lines.removeFirst() }  // the shebang must be line 1
        return lines.joined(separator: "\n")
    }

    /// sshd reachable over vsock port 22 on guests whose systemd is older than 256 (no
    /// systemd-ssh-generator) or that have no systemd at all (Alpine): socat listens on the
    /// vsock and relays to sshd on 127.0.0.1:22. The driver then takes this route for SSH, and
    /// a VM without usernet (the isolation profile) can be reached at all. socat is installed
    /// with the guest's package manager, which needs the network: a VM meant to run isolated
    /// boots once with usernet first. Idempotent; a failure to install just logs.
    static let vsockSSH = #"""
    #!/bin/sh
    # HanaLima: sshd on vsock port 22 for guests without systemd-ssh-generator (systemd < 256,
    # or no systemd). Relayed by socat; the driver prefers this route over usernet.
    set -eu
    [ -e /dev/vsock ] || exit 0
    if command -v systemctl >/dev/null 2>&1; then
      if [ -e /run/systemd/generator/sshd-vsock.socket ] || systemctl is-enabled sshd-vsock.socket >/dev/null 2>&1; then
        exit 0  # systemd-ssh-generator does it already
      fi
    fi
    if ! command -v socat >/dev/null 2>&1; then
      if command -v apk >/dev/null 2>&1; then apk add --no-cache socat
      elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q && apt-get install -y -q --no-install-recommends socat
      elif command -v dnf >/dev/null 2>&1; then dnf install -y -q socat
      fi
      command -v socat >/dev/null 2>&1 || { echo "hanalima: socat not available; SSH over vsock skipped" >&2; exit 0; }
    fi
    SOCAT=$(command -v socat)
    ARGS="VSOCK-LISTEN:22,fork,reuseaddr TCP:127.0.0.1:22"
    if command -v rc-service >/dev/null 2>&1 && [ -d /etc/init.d ]; then
      f=/etc/init.d/hanalima-vsock-ssh
      new="#!/sbin/openrc-run
    description=\"sshd over vsock for HanaLima (socat)\"
    command=$SOCAT
    command_args=\"$ARGS\"
    command_background=yes
    pidfile=/run/hanalima-vsock-ssh.pid
    depend() { need net; after sshd; }
    "
      if [ "$(cat $f 2>/dev/null)" != "$new" ]; then
        printf '%s' "$new" > $f
        chmod +x $f
        rc-update add hanalima-vsock-ssh default >/dev/null 2>&1 || true
        rc-service hanalima-vsock-ssh restart
      else
        rc-service hanalima-vsock-ssh start --ifnotstarted >/dev/null 2>&1 || rc-service hanalima-vsock-ssh start
      fi
    elif command -v systemctl >/dev/null 2>&1; then
      f=/etc/systemd/system/hanalima-vsock-ssh.service
      new="[Unit]
    Description=sshd over vsock for HanaLima (socat)
    After=network.target ssh.service sshd.service
    [Service]
    ExecStart=$SOCAT $ARGS
    Restart=always
    RestartSec=1
    [Install]
    WantedBy=multi-user.target
    "
      if [ "$(cat $f 2>/dev/null)" != "$new" ]; then
        printf '%s' "$new" > $f
        systemctl daemon-reload
        systemctl enable --now hanalima-vsock-ssh.service
      else
        systemctl start hanalima-vsock-ssh.service
      fi
    fi
    """#
}
