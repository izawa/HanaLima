import Foundation

/// Boot scripts the driver adds to Lima's cidata (`BootScripts` RPC; Lima runs `boot.Linux/*.sh`
/// in name order at every boot, after its own 25-guestagent and 30-install-packages).
enum BootScripts {
    static let all: [String: String] = [
        "boot.Linux/35-hanalima-vsock-ssh.sh": dedent(vsockSSH),
        "boot.Linux/05-rosetta-volume.sh": dedent(rosettaVolume),
    ]

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

    /// Lima's own `05-rosetta-volume.sh` (pkg/driver/vz/boot.Linux, Apache-2.0, copied as is):
    /// mounts the `vz-rosetta` share, registers binfmt_misc, and runs rosettad for the AOT cache.
    /// Does nothing unless cidata says Rosetta is on (`LIMA_CIDATA_ROSETTA_ENABLED`, from Info).
    static let rosettaVolume = #"""
    #!/bin/bash

    # SPDX-FileCopyrightText: Copyright The Lima Authors
    # SPDX-License-Identifier: Apache-2.0

    set -eux -o pipefail

    if [ "$LIMA_CIDATA_ROSETTA_ENABLED" != "true" ]; then
    	exit 0
    fi

    if [ -f /etc/alpine-release ]; then
    	rc-service procfs start --ifnotstarted
    	rc-service qemu-binfmt stop --ifexists --ifstarted
    fi

    binfmt_entry=/proc/sys/fs/binfmt_misc/rosetta
    binfmtd_conf=/usr/lib/binfmt.d/rosetta.conf
    if [ "$LIMA_CIDATA_ROSETTA_BINFMT" = "true" ]; then
    	rosetta_binfmt=":rosetta:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00:\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:/mnt/lima-rosetta/rosetta:OCF"

    	# If rosetta is not registered in binfmt_misc, register it.
    	[ -f "$binfmt_entry" ] || echo "$rosetta_binfmt" >/proc/sys/fs/binfmt_misc/register

    	# Create binfmt.d(5) configuration to prioritize rosetta even if qemu-user-static is installed on systemd based systems.
    	# If the binfmt.d directory exists, consider systemd-binfmt.service(8) to be enabled and create the configuration file.
    	[ ! -d "$(dirname "$binfmtd_conf")" ] || [ -f "$binfmtd_conf" ] || echo "$rosetta_binfmt" >"$binfmtd_conf"
    else
    	# unregister rosetta from binfmt_misc if it exists
    	[ ! -f "$binfmt_entry" ] || echo -1 >"$binfmt_entry"
    	# remove binfmt.d(5) configuration if it exists
    	[ ! -f "$binfmtd_conf" ] || rm "$binfmtd_conf"
    fi

    if [ -x /mnt/lima-rosetta/rosettad ]; then
    	CACHE_DIRECTORY=/var/cache/rosettad
    	DEFAULT_SOCKET=${CACHE_DIRECTORY}/uds/rosetta.sock
    	EXPECTED_SOCKET=/run/rosettad/rosetta.sock

    	# Create rosettad service
    	if [ -f /sbin/openrc-run ]; then
    		cat >/etc/init.d/rosettad <<EOF
    #!/sbin/openrc-run
    name="rosettad"
    description="Rosetta AOT Caching Daemon"
    required_dirs=/mnt/lima-rosetta
    required_files=/mnt/lima-rosetta/rosettad
    command=/mnt/lima-rosetta/rosettad
    command_args="daemon ${CACHE_DIRECTORY}"
    command_background=true
    pidfile="/run/rosettad.pid"
    start_pre() {
    	# To detect creation of the socket by rosettad, remove the old socket before starting
    	test ! -e "${DEFAULT_SOCKET}" || rm -f "${DEFAULT_SOCKET}"
    }
    start_post() {
    	# Set the socket permission to world-writable
    	while ! chmod -f go+w "${DEFAULT_SOCKET}"; do sleep 1; done
    	# Create the symlink as expected by the configuration to enable Rosetta AOT caching
    	mkdir -p "$(dirname "${EXPECTED_SOCKET}")"
    	ln -sf "${DEFAULT_SOCKET}" "${EXPECTED_SOCKET}"
    }
    EOF
    		chmod 755 /etc/init.d/rosettad
    		rc-update add rosettad default
    		rc-service rosettad start
    	else
    		cat >/etc/systemd/system/rosettad.service <<EOF
    [Unit]
    Description=Rosetta AOT Caching Daemon
    RequiresMountsFor=/mnt/lima-rosetta
    [Service]
    RuntimeDirectory=rosettad
    CacheDirectory=rosettad
    # To detect creation of the socket by rosettad, remove the old socket
    ExecStartPre=sh -c "test ! -e \"${DEFAULT_SOCKET}\" || rm -f \"${DEFAULT_SOCKET}\""
    ExecStart=/mnt/lima-rosetta/rosettad daemon "${CACHE_DIRECTORY}"
    # Set the socket permission to world-writable and create the symlink as expected by the configuration to enable Rosetta AOT caching.
    ExecStartPost=sh -c "while ! chmod -f go+w \"${DEFAULT_SOCKET}\"; do sleep 1; done; ln -sf \"${DEFAULT_SOCKET}\" \"${EXPECTED_SOCKET}\""
    OOMPolicy=continue
    OOMScoreAdjust=-500
    [Install]
    WantedBy=default.target
    EOF
    		systemctl is-enabled rosettad || systemctl enable --now rosettad
    	fi

    	# Create CDI configuration for Rosetta
    	mkdir -p /etc/cdi /var/run/cdi /etc/buildkit/cdi
    	cat >/etc/cdi/rosetta.yaml <<EOF
    cdiVersion: "0.6.0"
    kind: "lima-vm.io/rosetta"
    devices:
    - name: cached
      containerEdits:
        mounts:
        - hostPath: /var/cache/rosettad/uds/rosetta.sock
          containerPath: /run/rosettad/rosetta.sock
          options: [bind]
    annotations:
      org.mobyproject.buildkit.device.autoallow: true
    EOF
    	# nerdctl requires user-specific CDI configuration directories
    	mkdir -p "${LIMA_CIDATA_HOME}/.config/cdi"
    	ln -sf /etc/cdi/rosetta.yaml "${LIMA_CIDATA_HOME}/.config/cdi/"
    	chown -R "${LIMA_CIDATA_USER}" "${LIMA_CIDATA_HOME}/.config"
    else
    	# Remove CDI configuration for Rosetta AOT Caching
    	[ ! -f /etc/cdi/rosetta.yaml ] || rm /etc/cdi/rosetta.yaml
    	[ ! -d "${LIMA_CIDATA_HOME}/.config/cdi/rosetta.yaml" ] || rm "${LIMA_CIDATA_HOME}/.config/cdi/rosetta.yaml"
    fi
    """#
}
