import Foundation

/// Ready-made provisioning entries offered in the Settings tab ("Add from Examples…").
///
/// Lima runs provisioning at every boot, so each script checks whether its work is done and
/// exits early. Scripts use /bin/sh (Alpine has no bash) and pick the package manager they find.
/// Titles and descriptions live in the app (they are localized); this holds what goes into
/// lima.yaml.
public struct ProvisionExample: Identifiable, Sendable {
    public enum ID: String, CaseIterable, Sendable {
        case basicTools, dotfiles, containerEngine, xdp, japan, noAutoUpdates, swap, devLanguages, fullUpgrade, consoleLogin, gateway
    }

    public let id: ID
    /// Distributions the scripts were tested on.
    public let distributions: [String]
    public let entries: [ProvisionConfig]
}

public enum ProvisionExamples {
    public static let all: [ProvisionExample] = [basicTools, dotfiles, containerEngine, xdp, japan, noAutoUpdates, swap, devLanguages, fullUpgrade, consoleLogin, gateway]

    public static func example(_ id: ProvisionExample.ID) -> ProvisionExample {
        all.first { $0.id == id }!
    }

    static let basicTools = ProvisionExample(id: .basicTools, distributions: ["Ubuntu", "Debian", "Fedora", "Alpine"], entries: [
        ProvisionConfig(mode: .system, script: #"""
        #!/bin/sh
        # HanaLima example: everyday command-line tools.
        set -eu
        command -v jq >/dev/null 2>&1 && command -v htop >/dev/null 2>&1 && exit 0
        if command -v apt-get >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update
          apt-get install -y git curl wget jq vim htop tmux unzip ca-certificates
        elif command -v dnf >/dev/null 2>&1; then
          # Fedora's cloud image has curl-minimal, which provides curl.
          dnf install -y git wget jq vim-enhanced htop tmux unzip
        elif command -v apk >/dev/null 2>&1; then
          apk add --no-cache git curl wget jq vim htop tmux unzip
        else
          echo "HanaLima example: no apt, dnf or apk found" >&2
          exit 1
        fi
        """#),
    ])

    static let dotfiles = ProvisionExample(id: .dotfiles, distributions: ["Ubuntu", "Debian", "Fedora", "Alpine"], entries: [
        ProvisionConfig(mode: .data, path: "{{.Home}}/.config/hanalima/shell.sh", content: #"""
        # HanaLima example: your shell settings, read by ~/.profile and ~/.bashrc.
        # Edit to taste.
        alias ll='ls -alF'
        export EDITOR=vim
        """#, owner: "{{.User}}"),
        ProvisionConfig(mode: .user, script: #"""
        #!/bin/sh
        # HanaLima example: read ~/.config/hanalima/shell.sh from your shell startup files,
        # add your public key, and clone your dotfiles.
        set -eu
        line='[ -f "$HOME/.config/hanalima/shell.sh" ] && . "$HOME/.config/hanalima/shell.sh"'
        for rc in "$HOME/.profile" "$HOME/.bashrc"; do
          touch "$rc"
          grep -qxF "$line" "$rc" || echo "$line" >> "$rc"
        done

        # Your public key, to ssh in from elsewhere (on the Mac: cat ~/.ssh/id_ed25519.pub).
        # Added to authorized_keys, never replacing it: Lima's own key is there too.
        KEY=''
        if [ -n "$KEY" ]; then
          mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
          touch "$HOME/.ssh/authorized_keys" && chmod 600 "$HOME/.ssh/authorized_keys"
          grep -qxF "$KEY" "$HOME/.ssh/authorized_keys" || echo "$KEY" >> "$HOME/.ssh/authorized_keys"
        fi

        # Your dotfiles repository (needs git), cloned once; its install.sh runs once.
        REPO=''
        if [ -n "$REPO" ] && [ ! -d "$HOME/dotfiles" ]; then
          git clone --depth 1 "$REPO" "$HOME/dotfiles"
          if [ -x "$HOME/dotfiles/install.sh" ]; then "$HOME/dotfiles/install.sh"; fi
        fi
        """#),
    ])

    static let containerEngine = ProvisionExample(id: .containerEngine, distributions: ["Ubuntu", "Debian", "Fedora"], entries: [
        ProvisionConfig(mode: .system, script: #"""
        #!/bin/sh
        # HanaLima example: Docker Engine (run by root, as on a server), with the VM's user in
        # the docker group. Lima's "docker" template is the rootless alternative.
        set -eu
        if ! command -v docker >/dev/null 2>&1; then
          if command -v apt-get >/dev/null 2>&1 || command -v dnf >/dev/null 2>&1; then
            curl -fsSL https://get.docker.com | sh
          else
            echo "HanaLima example: Ubuntu, Debian or Fedora only" >&2
            exit 1
          fi
        fi
        systemctl enable --now docker
        usermod -aG docker "$LIMA_CIDATA_USER"
        """#),
    ])

    static let xdp = ProvisionExample(id: .xdp, distributions: ["Ubuntu", "Debian", "Fedora"], entries: [
        ProvisionConfig(mode: .system, script: #"""
        #!/bin/sh
        # HanaLima example: build and load XDP programs. The distribution's kernel already
        # supports XDP and BPF; this adds the compiler, libraries, headers and tools.
        set -eu
        command -v clang >/dev/null 2>&1 && command -v bpftool >/dev/null 2>&1 && command -v xdp-loader >/dev/null 2>&1 && exit 0
        if command -v apt-get >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update
          apt-get install -y clang llvm make pkg-config libbpf-dev libxdp-dev xdp-tools \
            libelf-dev zlib1g-dev linux-headers-"$(uname -r)" bpftool \
            || apt-get install -y clang llvm make pkg-config libbpf-dev libxdp-dev xdp-tools \
                 libelf-dev zlib1g-dev linux-headers-"$(uname -r)" linux-tools-common linux-tools-"$(uname -r)"
        elif command -v dnf >/dev/null 2>&1; then
          dnf install -y clang llvm make pkgconf libbpf-devel libxdp-devel xdp-tools bpftool \
            elfutils-libelf-devel zlib-devel kernel-headers kernel-devel-"$(uname -r)"
        else
          echo "HanaLima example: Ubuntu, Debian or Fedora only" >&2
          exit 1
        fi
        """#),
    ])

    static let japan = ProvisionExample(id: .japan, distributions: ["Ubuntu", "Fedora", "Alpine"], entries: [
        ProvisionConfig(mode: .system, script: #"""
        #!/bin/sh
        # HanaLima example: Japan: the Asia/Tokyo time zone and the ja_JP.UTF-8 locale (LANG stays as it is).
        set -eu
        ZONE=Asia/Tokyo
        case "$(readlink -f /etc/localtime 2>/dev/null || true)" in
          */"$ZONE") ;;
          *)
            # timedatectl needs D-Bus, which may not be up yet; fall back to the plain symlink.
            if ! { command -v timedatectl >/dev/null 2>&1 && [ -d /run/systemd/system ] && timedatectl set-timezone "$ZONE"; }; then
              if [ ! -e "/usr/share/zoneinfo/$ZONE" ] && command -v apk >/dev/null 2>&1; then apk add --no-cache tzdata; fi
              ln -sfn "/usr/share/zoneinfo/$ZONE" /etc/localtime
              if command -v apt-get >/dev/null 2>&1; then echo "$ZONE" > /etc/timezone; fi
            fi ;;
        esac

        # The locale, so that ja_JP.UTF-8 can be chosen in a shell (LANG=ja_JP.UTF-8). Alpine's musl
        # has no locale files; the time zone alone applies there.
        has_locale() { locale -a 2>/dev/null | grep -qi '^ja_JP\.utf-\?8$'; }
        if command -v apt-get >/dev/null 2>&1; then
          if ! has_locale; then
            export DEBIAN_FRONTEND=noninteractive
            dpkg -s locales >/dev/null 2>&1 || { apt-get update; apt-get install -y locales; }
            sed -i 's/^# *ja_JP\.UTF-8 UTF-8/ja_JP.UTF-8 UTF-8/' /etc/locale.gen
            grep -q '^ja_JP\.UTF-8 UTF-8' /etc/locale.gen || echo 'ja_JP.UTF-8 UTF-8' >> /etc/locale.gen
            locale-gen
            has_locale || { echo "HanaLima example: ja_JP.UTF-8 was not generated" >&2; exit 1; }
          fi
        elif command -v dnf >/dev/null 2>&1; then
          has_locale || dnf install -y glibc-langpack-ja
        elif command -v apk >/dev/null 2>&1; then
          :
        else
          echo "HanaLima example: no apt, dnf or apk found" >&2
          exit 1
        fi
        """#),
    ])

    static let noAutoUpdates = ProvisionExample(id: .noAutoUpdates, distributions: ["Ubuntu", "Fedora"], entries: [
        ProvisionConfig(mode: .system, script: #"""
        #!/bin/sh
        # HanaLima example: no automatic package updates, so they never compete with your work after a boot.
        set -eu
        if command -v apt-get >/dev/null 2>&1; then
          patterns='apt-daily* unattended-upgrades*'
        elif command -v dnf >/dev/null 2>&1; then
          # dnf 4 names them dnf-…, dnf 5 names them dnf5-….
          patterns='dnf*automatic* dnf*makecache*'
        else
          echo "HanaLima example: Ubuntu, Debian or Fedora only" >&2
          exit 1
        fi
        # shellcheck disable=SC2086
        units="$(systemctl list-unit-files --no-legend $patterns 2>/dev/null | awk '{print $1}' || true)"
        for u in $units; do
          case "$(systemctl is-enabled "$u" 2>/dev/null || true)" in masked*) continue ;; esac
          systemctl stop "$u" >/dev/null 2>&1 || true
          systemctl mask --now "$u"
        done
        """#),
    ])

    static let swap = ProvisionExample(id: .swap, distributions: ["Ubuntu", "Fedora", "Alpine"], entries: [
        ProvisionConfig(mode: .system, script: #"""
        #!/bin/sh
        # HanaLima example: a 2 GiB swap file (/swapfile), active from every boot.
        set -eu
        SIZE_MIB=2048
        if [ ! -f /swapfile ]; then
          rm -f /swapfile.tmp
          # Fedora's root is btrfs: a swap file there must not be copy-on-write (elsewhere +C just fails).
          : > /swapfile.tmp
          chattr +C /swapfile.tmp 2>/dev/null || true
          chmod 600 /swapfile.tmp
          fallocate -l "${SIZE_MIB}M" /swapfile.tmp 2>/dev/null \
            || dd if=/dev/zero of=/swapfile.tmp bs=1M count="$SIZE_MIB" 2>/dev/null
          mkswap /swapfile.tmp >/dev/null
          mv /swapfile.tmp /swapfile
          if command -v restorecon >/dev/null 2>&1; then restorecon /swapfile || true; fi
        fi
        grep -q '^/swapfile[[:space:]]' /etc/fstab 2>/dev/null || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        grep -q '^/swapfile[[:space:]]' /proc/swaps || swapon /swapfile
        # Alpine turns on the swap in fstab from the "swap" service.
        if command -v rc-update >/dev/null 2>&1 && ! rc-update show boot | grep -qw swap; then rc-update add swap boot; fi
        """#),
    ])

    /// A one-shot example: wrapped with `ProvisionOnce` (the sheet gives it a fresh stamp id when added).
    static let fullUpgrade = ProvisionExample(id: .fullUpgrade, distributions: ["Ubuntu", "Debian", "Fedora", "Alpine"], entries: [
        ProvisionConfig(mode: .system, script: ProvisionOnce.wrap(body: #"""
        # HanaLima example: upgrade every installed package once (run again from the editor when you want).
        set -eu
        if command -v apt-get >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          apt-get update
          apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
          apt-get -y autoremove
        elif command -v dnf >/dev/null 2>&1; then
          dnf -y upgrade --refresh
        elif command -v apk >/dev/null 2>&1; then
          apk update
          apk upgrade
        else
          echo "HanaLima example: no apt, dnf or apk found" >&2
          exit 1
        fi
        """#, mode: .system, id: "example")),
    ])

    static let devLanguages = ProvisionExample(id: .devLanguages, distributions: ["Ubuntu", "Fedora", "Alpine"], entries: [
        ProvisionConfig(mode: .system, script: #"""
        #!/bin/sh
        # HanaLima example: Go (the official build, in /usr/local/go) and Node.js with npm (the distribution's packages).
        set -eu
        if command -v apt-get >/dev/null 2>&1; then
          export DEBIAN_FRONTEND=noninteractive
          if ! { command -v curl && command -v node && command -v npm; } >/dev/null 2>&1; then
            apt-get update
            apt-get install -y curl ca-certificates nodejs npm
          fi
        elif command -v dnf >/dev/null 2>&1; then
          # Fedora's cloud image has curl-minimal, which provides curl.
          if ! { command -v node && command -v npm; } >/dev/null 2>&1; then dnf install -y nodejs npm; fi
        elif command -v apk >/dev/null 2>&1; then
          if ! { command -v curl && command -v node && command -v npm; } >/dev/null 2>&1; then
            apk add --no-cache curl ca-certificates nodejs npm
          fi
        else
          echo "HanaLima example: no apt, dnf or apk found" >&2
          exit 1
        fi

        # Go: the newest stable release, as go.dev lists it. Nothing is downloaded once it is there.
        if [ ! -x /usr/local/go/bin/go ]; then
          case "$(uname -m)" in
            aarch64|arm64) arch=arm64 ;;
            x86_64) arch=amd64 ;;
            *) echo "HanaLima example: unsupported architecture $(uname -m)" >&2; exit 1 ;;
          esac
          version="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n 1)"
          curl -fsSL "https://go.dev/dl/${version}.linux-${arch}.tar.gz" -o /tmp/go.tar.gz
          rm -rf /usr/local/go
          tar -C /usr/local -xzf /tmp/go.tar.gz
          rm -f /tmp/go.tar.gz
        fi
        for tool in go gofmt; do ln -sfn "/usr/local/go/bin/$tool" "/usr/local/bin/$tool"; done
        """#),
        ProvisionConfig(mode: .user, script: #"""
        #!/bin/sh
        # HanaLima example: uv (Python) and rustup (Rust) in your home, from their official installers.
        set -eu
        fetch() {
          if command -v curl >/dev/null 2>&1; then curl -fsSL --proto '=https' --tlsv1.2 "$1"
          else wget -qO- "$1"; fi
        }
        # Both installers add their bin directory to your shell's PATH (takes effect at the next login).
        if [ ! -x "$HOME/.local/bin/uv" ]; then
          fetch https://astral.sh/uv/install.sh | sh
        fi
        if [ ! -x "$HOME/.cargo/bin/cargo" ]; then
          fetch https://sh.rustup.rs | sh -s -- -y --profile minimal
        fi
        """#),
    ])

    /// For HanaLima's rescue boot (the VM's screen, see docs/04): Lima locks the user's password
    /// (`lock_passwd: true`), so without this nobody can log in at the screen's console.
    static let consoleLogin = ProvisionExample(id: .consoleLogin, distributions: ["Ubuntu", "Debian", "Fedora", "Alpine"], entries: [
        ProvisionConfig(mode: .system, script: #"""
        #!/bin/sh
        # HanaLima example: log the user in without a password on the screen console (tty1: the
        # rescue boot's window, or the VM's screen) and on the serial console (hvc0: the console
        # tab's "serial" with HanaLima's driver). Anyone who can open the screen or the serial
        # gets the user's shell (with passwordless sudo), as anyone with Lima's SSH key does.
        set -eu
        USER_NAME='{{.User}}'
        if command -v systemctl >/dev/null 2>&1; then
          changed=0
          for unit in getty@tty1 serial-getty@hvc0; do
            d=/etc/systemd/system/$unit.service.d
            f=$d/hanalima-autologin.conf
            grep -qs -- "--autologin $USER_NAME " "$f" && continue
            mkdir -p "$d"
            case $unit in
              getty@*) start="ExecStart=-/sbin/agetty --autologin $USER_NAME --noclear %I \$TERM" ;;
              *) start="ExecStart=-/sbin/agetty --autologin $USER_NAME --keep-baud 115200,57600,38400,9600 %I \$TERM" ;;
            esac
            printf '[Service]\nExecStart=\n%s\n' "$start" > "$f"
            changed=1
          done
          [ "$changed" = 1 ] || exit 0
          systemctl daemon-reload
          systemctl enable serial-getty@hvc0.service >/dev/null 2>&1 || true
          systemctl restart getty@tty1.service serial-getty@hvc0.service || true
        elif [ -f /etc/inittab ] && command -v apk >/dev/null 2>&1; then
          # Alpine: busybox getty can't log a user in by itself; util-linux's agetty can.
          changed=0
          for tty in tty1 hvc0; do
            line="$tty::respawn:/sbin/agetty --autologin $USER_NAME --noclear $tty linux"
            grep -qxF "$line" /etc/inittab && continue
            command -v agetty >/dev/null 2>&1 || apk add --no-cache agetty
            if grep -q "^$tty::" /etc/inittab; then
              sed -i "s|^$tty::.*|$line|" /etc/inittab
            else
              echo "$line" >> /etc/inittab
            fi
            changed=1
          done
          [ "$changed" = 1 ] && kill -HUP 1
          exit 0
        else
          echo "HanaLima example: no systemd or Alpine inittab found" >&2
          exit 1
        fi
        """#),
    ])

    /// A gateway for a guest-only network: name this VM's address as the network's router, and
    /// the VMs behind it get NAT and DNS through it, limited to an allow list.
    static let gateway = ProvisionExample(id: .gateway, distributions: ["Ubuntu", "Alpine"], entries: [
        ProvisionConfig(mode: .data, path: "/etc/hanalima/gateway.conf", content: #"""
        # HanaLima gateway: what the VMs behind this one may reach. One entry per line.
        #   a host name  - allowed once a VM resolves it through this gateway (every address it has)
        #   an address or CIDR, e.g. 10.9.8.7 or 203.0.113.0/24
        #   *            - everything
        # The VMs can always reach this gateway itself and each other. Save, then run this
        # example's script again ("Run now"), or just reboot the gateway.
        dl-cdn.alpinelinux.org
        archive.ubuntu.com
        security.ubuntu.com
        ports.ubuntu.com
        deb.debian.org
        api.anthropic.com

        """#),   // the blank line keeps a trailing newline, so appending a line works
        ProvisionConfig(mode: .system, script: #"""
        #!/bin/sh
        # HanaLima example: make this VM the gateway of a guest-only network. Name this VM's
        # address on that network as the network's "router": the VMs behind it then route
        # through it (NAT to this VM's own way out) and use it as their DNS, and reach only what
        # /etc/hanalima/gateway.conf allows. Host names are learned as the VMs resolve them here
        # (dnsmasq's nftset), addresses and CIDRs go straight in, "*" allows everything. Dropped
        # packets are logged with the prefix "hanalima-gateway". Runs at every boot: it installs
        # once, then rewrites the rules only when the allow list or the interfaces changed.
        set -eu
        CONF=/etc/hanalima/gateway.conf
        [ -f "$CONF" ] || { echo "HanaLima example: $CONF is missing (the data entry of this example)" >&2; exit 1; }

        # The way out: the interface of the default route (Lima's NIC 0, or a bridged NIC).
        WAN=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')
        # Where the VMs are: every other interface with an IPv4 address.
        LANS=$(ip -4 -o addr show scope global | awk -v wan="$WAN" '$2 != wan { print $2 }' | sort -u)
        # Upstream DNS for the VMs' queries: the resolvers this VM uses itself.
        UPSTREAM=$(awk '/^nameserver/ && $2 !~ /^127\./ && $2 !~ /:/ { print $2 }' /etc/resolv.conf 2>/dev/null || true)
        if [ -z "$UPSTREAM" ] && [ -n "$WAN" ] && command -v resolvectl >/dev/null 2>&1; then
          UPSTREAM=$(resolvectl dns "$WAN" 2>/dev/null | sed 's/^[^:]*: *//' | tr ' ' '\n' | grep -v ':' | grep . || true)
        fi
        [ -n "$UPSTREAM" ] || UPSTREAM=192.168.5.2

        # dnsmasq listens on the VMs' side only (not on lo, where systemd-resolved may be, nor on
        # the way out). Written before the packages are installed so the first start is right.
        mkdir -p /etc/dnsmasq.d
        DNSCONF=/etc/dnsmasq.d/hanalima-gateway.conf
        {
          echo "# Written by HanaLima's gateway example at every boot; edit $CONF instead."
          echo "bind-dynamic"
          echo "except-interface=lo"
          [ -n "$WAN" ] && echo "except-interface=$WAN"
          echo "no-resolv"
          for s in $UPSTREAM; do echo "server=$s"; done
          grep -v '^[[:space:]]*#' "$CONF" | awk 'NF { print $1 }' | while read -r entry; do
            case $entry in
              '*' | *[!A-Za-z0-9.-]* | [0-9]*.[0-9]*.[0-9]*.[0-9]*) ;;
              *) echo "nftset=/$entry/4#inet#hanalima#allowed" ;;
            esac
          done
        } > "$DNSCONF.new"

        if ! command -v nft >/dev/null 2>&1 || ! command -v dnsmasq >/dev/null 2>&1; then
          mv "$DNSCONF.new" "$DNSCONF"
          if command -v apt-get >/dev/null 2>&1; then
            export DEBIAN_FRONTEND=noninteractive
            apt-get update
            apt-get install -y nftables dnsmasq
          elif command -v dnf >/dev/null 2>&1; then
            dnf install -y nftables dnsmasq
          elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache nftables dnsmasq-dnssec-nftset dnsmasq-openrc
          else
            echo "HanaLima example: no apt, dnf or apk found" >&2
            exit 1
          fi
          dns_changed=1
        elif cmp -s "$DNSCONF.new" "$DNSCONF"; then
          rm -f "$DNSCONF.new"
          dns_changed=0
        else
          mv "$DNSCONF.new" "$DNSCONF"
          dns_changed=1
        fi
        grep -q '^conf-dir=/etc/dnsmasq.d' /etc/dnsmasq.conf 2>/dev/null || echo 'conf-dir=/etc/dnsmasq.d,*.conf' >> /etc/dnsmasq.conf

        # Forwarding, now and after reboots.
        sysctl -w net.ipv4.ip_forward=1 >/dev/null
        echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/90-hanalima-gateway.conf

        # The rules: one table, replaced as a whole when something changed (the learned
        # addresses start over then; the VMs re-learn them with their next lookup).
        NFT=/etc/hanalima/gateway.nft
        all=0; nets=""
        set -f   # "*" in the list must not become file names
        for entry in $(grep -v '^[[:space:]]*#' "$CONF" | awk 'NF { print $1 }'); do
          case $entry in
            '*') all=1 ;;
            [0-9]*.[0-9]*.[0-9]*.[0-9]*) nets="$nets${nets:+, }$entry" ;;
          esac
        done
        set +f
        {
          echo "# Written by HanaLima's gateway example at every boot; edit $CONF instead."
          echo "table inet hanalima"
          echo "delete table inet hanalima"
          echo "table inet hanalima {"
          echo "  set allowed { type ipv4_addr; }"
          [ -n "$nets" ] && echo "  set allowed_net { type ipv4_addr; flags interval; elements = { $nets } }"
          echo "  chain forward {"
          echo "    type filter hook forward priority filter; policy drop;"
          echo "    ct state established,related accept"
          echo "    ct state invalid drop"
          if [ -n "$WAN" ]; then
            echo "    iifname \"$WAN\" drop"
            echo "    iifname != \"$WAN\" oifname != \"$WAN\" accept"
            if [ "$all" = 1 ]; then
              echo "    oifname \"$WAN\" accept"
            else
              echo "    oifname \"$WAN\" ip daddr @allowed accept"
              [ -n "$nets" ] && echo "    oifname \"$WAN\" ip daddr @allowed_net accept"
            fi
          fi
          echo "    limit rate 10/second log prefix \"hanalima-gateway drop: \""
          echo "  }"
          if [ -n "$WAN" ]; then
            echo "  chain postrouting {"
            echo "    type nat hook postrouting priority srcnat;"
            echo "    oifname \"$WAN\" masquerade"
            echo "  }"
          fi
          echo "}"
        } > "$NFT.new"
        if ! cmp -s "$NFT.new" "$NFT" || ! nft list table inet hanalima >/dev/null 2>&1; then
          mv "$NFT.new" "$NFT"
          nft -f "$NFT"
        else
          rm -f "$NFT.new"
        fi

        # dnsmasq: on at boot, restarted when its config changed or it isn't running.
        if command -v systemctl >/dev/null 2>&1; then
          systemctl enable dnsmasq >/dev/null 2>&1 || true
          if [ "$dns_changed" = 1 ] || ! systemctl is-active --quiet dnsmasq; then systemctl restart dnsmasq; fi
        elif command -v rc-service >/dev/null 2>&1; then
          rc-update -q add dnsmasq default 2>/dev/null || true
          if [ "$dns_changed" = 1 ] || ! rc-service -q dnsmasq status >/dev/null 2>&1; then rc-service dnsmasq restart; fi
        fi
        echo "HanaLima gateway: out via ${WAN:-none}, VMs on ${LANS:-no interface yet}, DNS upstream $UPSTREAM"
        """#),
    ])
}
