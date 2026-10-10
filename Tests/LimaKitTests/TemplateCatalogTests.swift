import Foundation
import Testing
@testable import LimaKit

// Strings are compared in Japanese, the source language (tests run without the app's catalog).
@Suite struct TemplateCatalogTests {
    @Test func displayNames() {
        func name(_ n: String, _ resolved: String? = nil) -> String {
            LimaTemplate(name: n, resolvedImage: resolved).displayName
        }
        #expect(name("ubuntu-24.04") == "Ubuntu 24.04 LTS")
        #expect(name("ubuntu-26.04") == "Ubuntu 26.04 LTS")
        #expect(name("ubuntu-25.10") == "Ubuntu 25.10")
        #expect(name("ubuntu-25.04") == "Ubuntu 25.04")
        #expect(name("ubuntu-lts", "ubuntu-26.04") == "Ubuntu LTS（最新: 26.04）")
        #expect(name("ubuntu", "ubuntu-26.04") == "Ubuntu（最新: 26.04 LTS）")
        #expect(name("ubuntu") == "Ubuntu（最新）")
        #expect(name("default", "ubuntu-26.04") == "標準（Ubuntu 26.04 LTS）")
        #expect(name("debian-13") == "Debian 13")
        #expect(name("alpine-3.23") == "Alpine 3.23")
        #expect(name("alpine-iso") == "Alpine（ISO 起動）")
        #expect(name("opensuse-leap-16") == "openSUSE Leap 16")
        #expect(name("opensuse", "opensuse-leap-16") == "openSUSE（最新: Leap 16）")
        #expect(name("centos-stream", "centos-stream-9") == "CentOS Stream（最新: 9）")
        #expect(name("windows-2025") == "Windows Server 2025")
        #expect(name("windows-11") == "Windows 11")
        #expect(name("archlinux") == "Arch Linux")
        #expect(name("k8s") == "Kubernetes（kubeadm）")
        #expect(name("experimental/ubuntu-26.10") == "Ubuntu 26.10")
        #expect(name("experimental/debian-sid") == "Debian sid")
        #expect(name("experimental/gentoo") == "Gentoo")
        #expect(name("experimental/vnc") == "vnc")
        #expect(name("someday-new") == "someday-new")
    }

    @Test func groupsAndOrder() {
        let names = [
            "almalinux", "almalinux-9", "almalinux-10", "alpine", "alpine-3.22", "alpine-3.23", "alpine-iso",
            "debian", "debian-12", "debian-13", "default", "docker", "experimental/gentoo", "fedora",
            "k3s", "macos", "macos-26", "opensuse", "opensuse-leap-15", "opensuse-leap-16", "ubuntu",
            "ubuntu-20.04", "ubuntu-24.04", "ubuntu-25.10", "ubuntu-26.04", "ubuntu-lts", "someday-new",
        ]
        let groups = TemplateCatalog.groups(names.map { LimaTemplate(name: $0) })
        func members(_ id: String) -> [String]? {
            groups.first { $0.id == id }?.templates.map(\.name)
        }
        #expect(groups.map(\.id) == ["featured", "ubuntu", "debian", "alpine", "almalinux", "opensuse",
                                     "macos", "tools", "other", "experimental"])
        #expect(members("featured") == ["default", "ubuntu-lts", "debian", "fedora", "alpine"])
        #expect(members("ubuntu") == ["ubuntu", "ubuntu-26.04", "ubuntu-25.10", "ubuntu-24.04", "ubuntu-20.04"])
        #expect(members("debian") == ["debian-13", "debian-12"])
        #expect(members("alpine") == ["alpine-3.23", "alpine-3.22", "alpine-iso"])
        #expect(members("almalinux") == ["almalinux", "almalinux-10", "almalinux-9"])
        #expect(members("opensuse") == ["opensuse", "opensuse-leap-16", "opensuse-leap-15"])
        #expect(groups.first { $0.id == "opensuse" }?.title == "openSUSE")
        #expect(members("tools") == ["docker", "k3s"])
        #expect(members("other") == ["someday-new"])
        #expect(members("experimental") == ["experimental/gentoo"])
        #expect(groups.flatMap(\.templates).count == names.count)
    }

    @Test func resolvesLatestTemplates() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hanalima-templates-\(UUID())")
        let images = dir.appending(path: "_images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ path: String, _ text: String) throws {
            try text.write(to: dir.appending(path: path), atomically: true, encoding: .utf8)
        }
        // Lima 2.2.1's layout: `default` → unversioned `_images/ubuntu`, a copy of the newest one.
        try write("default.yaml", "base:\n- template:_images/ubuntu\n- template:_default/mounts\n")
        try write("ubuntu-lts.yaml", "base:\n- template:_images/ubuntu-26.04\n")
        try write("archlinux.yaml", "base:\n- template:_images/archlinux\n")
        try write("ubuntu-24.04.yaml", "base:\n- template:_images/ubuntu-24.04\n")
        try write("_images/ubuntu.yaml", "images: [26.04]\n")
        try write("_images/ubuntu-26.04.yaml", "images: [26.04]\n")
        try write("_images/ubuntu-24.04.yaml", "images: [24.04]\n")
        try write("_images/archlinux.yaml", "images: [rolling]\n")

        func resolve(_ name: String) -> String? {
            TemplateCatalog.resolveImage(of: LimaTemplate(name: name, location: dir.appending(path: "\(name).yaml")))
        }
        #expect(resolve("default") == "ubuntu-26.04")
        #expect(resolve("ubuntu-lts") == "ubuntu-26.04")
        #expect(resolve("archlinux") == nil)
        #expect(resolve("ubuntu-24.04") == nil)  // already versioned
    }
}
