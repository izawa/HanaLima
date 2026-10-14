import Foundation

/// Ready-made provisioning entries offered in the Settings tab ("Add from Examples…").
///
/// Lima runs provisioning at every boot, so each script checks whether its work is done and
/// exits early. Scripts use /bin/sh (Alpine has no bash) and pick the package manager they find.
/// Titles and descriptions live in the app (they are localized); this holds what goes into
/// lima.yaml.
public struct ProvisionExample: Identifiable, Sendable {
    public enum ID: String, CaseIterable, Sendable {
        case basicTools, dotfiles, containerEngine, xdp
    }

    public let id: ID
    /// Distributions the scripts were tested on.
    public let distributions: [String]
    public let entries: [ProvisionConfig]
}

public enum ProvisionExamples {
    public static let all: [ProvisionExample] = [basicTools, dotfiles, containerEngine, xdp]

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
}
