import Foundation

/// A template from `limactl info` (`templates[]`), e.g. `ubuntu-24.04` or `experimental/gentoo`.
///
/// Lima ships its templates by name only. HanaLima derives a readable name ("Ubuntu 24.04 LTS")
/// and a group from the name, so new versions in a Lima update show up without changes here.
/// Templates that follow the latest release (`ubuntu`, `ubuntu-lts`, `debian`, `default`) are
/// resolved to the versioned image they currently use, by reading their YAML.
public struct LimaTemplate: Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var location: URL?
    /// For a "latest" template: the versioned image it uses now, e.g. "ubuntu-26.04".
    public var resolvedImage: String?

    public init(name: String, location: URL? = nil, resolvedImage: String? = nil) {
        self.name = name
        self.location = location
        self.resolvedImage = resolvedImage
    }

    public var isExperimental: Bool { name.hasPrefix("experimental/") }

    /// The name without the `experimental/` directory.
    var baseName: String { name.split(separator: "/").last.map(String.init) ?? name }

    /// True for templates that track the newest release of their family.
    var isLatestAlias: Bool {
        guard !isExperimental else { return false }
        if name == "default" || name == "ubuntu-lts" { return true }
        return TemplateCatalog.family(of: name)?.version == nil
            && TemplateCatalog.families.contains { $0.id == name }
    }

    // MARK: Display name

    public var displayName: String {
        if name == "default" {
            if let image = resolvedImage {
                return String(localized: "標準（\(TemplateCatalog.displayName(ofImage: image))）")
            }
            return String(localized: "標準")
        }
        if name == "ubuntu-lts" {
            if let version = resolvedVersion?.replacing(" LTS", with: "") {
                return String(localized: "Ubuntu LTS（最新: \(version)）")
            }
            return String(localized: "Ubuntu LTS（最新）")
        }
        if let special = TemplateCatalog.specialName(baseName) { return special }
        if isLatestAlias, let family = TemplateCatalog.families.first(where: { $0.id == name }) {
            if let version = resolvedVersion { return String(localized: "\(family.name)（最新: \(version)）") }
            return String(localized: "\(family.name)（最新）")
        }
        return TemplateCatalog.displayName(ofImage: baseName)
    }

    /// "26.04 LTS" for `ubuntu` → `ubuntu-26.04`; "Leap 16" for `opensuse` → `opensuse-leap-16`.
    private var resolvedVersion: String? {
        guard let image = resolvedImage else { return nil }
        let full = TemplateCatalog.displayName(ofImage: image)
        let familyName = TemplateCatalog.families.first { $0.id == name }?.name
            ?? (name == "ubuntu-lts" ? "Ubuntu" : nil)
        if let familyName, full.hasPrefix(familyName + " ") {
            return String(full.dropFirst(familyName.count + 1))
        }
        return full
    }
}

/// A section of the template menu.
public struct TemplateGroup: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var templates: [LimaTemplate]
}

public enum TemplateCatalog {
    struct Family {
        var id: String
        var name: String
        /// The menu section (openSUSE and openSUSE Leap share one).
        var group: String
    }

    /// Distribution families in menu order. Longer ids first where one is a prefix of another.
    static let families: [Family] = [
        Family(id: "ubuntu", name: "Ubuntu", group: "ubuntu"),
        Family(id: "debian", name: "Debian", group: "debian"),
        Family(id: "fedora", name: "Fedora", group: "fedora"),
        Family(id: "alpine", name: "Alpine", group: "alpine"),
        Family(id: "archlinux", name: "Arch Linux", group: "archlinux"),
        Family(id: "almalinux", name: "AlmaLinux", group: "almalinux"),
        Family(id: "rocky", name: "Rocky Linux", group: "rocky"),
        Family(id: "centos-stream", name: "CentOS Stream", group: "centos-stream"),
        Family(id: "oraclelinux", name: "Oracle Linux", group: "oraclelinux"),
        Family(id: "opensuse-leap", name: "openSUSE Leap", group: "opensuse"),
        Family(id: "opensuse", name: "openSUSE", group: "opensuse"),
        Family(id: "macos", name: "macOS", group: "macos"),
        Family(id: "freebsd", name: "FreeBSD", group: "freebsd"),
        Family(id: "windows", name: "Windows", group: "windows"),
    ]

    /// Container runtimes, Kubernetes and package managers.
    static let tools: [String] = [
        "docker", "docker-rootful", "podman", "podman-rootful", "k3s", "k0s", "k8s",
        "buildkit", "apptainer", "apptainer-rootful", "faasd",
        "homebrew-linux", "homebrew-macos", "linuxbrew",
    ]

    /// The "latest" templates of the most used distributions, shown first.
    static let featured: [String] = ["default", "ubuntu-lts", "debian", "fedora", "alpine"]

    /// Splits `ubuntu-24.04` into the family and "24.04". Returns the family alone for `ubuntu`.
    static func family(of name: String) -> (family: Family, version: String?)? {
        let candidates = families.sorted { $0.id.count > $1.id.count }
        for family in candidates {
            if name == family.id { return (family, nil) }
            if name.hasPrefix(family.id + "-") {
                let rest = String(name.dropFirst(family.id.count + 1))
                if rest.wholeMatch(of: /\d+(\.\d+)*/) != nil { return (family, rest) }
            }
        }
        return nil
    }

    /// The family section a template belongs to, by name prefix (`alpine-iso` → "alpine").
    static func familyGroup(of name: String) -> String? {
        families.sorted { $0.id.count > $1.id.count }
            .first { name == $0.id || name.hasPrefix($0.id + "-") }?.group
    }

    /// Ubuntu LTS releases are the .04 of even years (20.04, 22.04, 24.04, 26.04 …).
    static func isUbuntuLTS(_ version: String) -> Bool {
        let parts = version.split(separator: ".")
        guard parts.count == 2, let year = Int(parts[0]) else { return false }
        return parts[1] == "04" && year % 2 == 0
    }

    /// Readable name of a versioned template or image name: "ubuntu-24.04" → "Ubuntu 24.04 LTS".
    static func displayName(ofImage name: String) -> String {
        if let special = specialName(name) { return special }
        guard let (family, version) = family(of: name) else { return name }
        guard let version else { return family.name }
        if family.id == "ubuntu", isUbuntuLTS(version) { return "Ubuntu \(version) LTS" }
        if family.id == "windows", version.count == 4 { return "Windows Server \(version)" }
        return "\(family.name) \(version)"
    }

    static func specialName(_ name: String) -> String? {
        switch name {
        case "archlinux": "Arch Linux"
        case "alpine-iso": String(localized: "Alpine（ISO 起動）")
        case "windows": "Windows"
        case "docker": "Docker"
        case "docker-rootful": String(localized: "Docker（rootful）")
        case "podman": "Podman"
        case "podman-rootful": String(localized: "Podman（rootful）")
        case "k3s": "k3s"
        case "k0s": "k0s"
        case "k8s": String(localized: "Kubernetes（kubeadm）")
        case "buildkit": "BuildKit"
        case "apptainer": "Apptainer"
        case "apptainer-rootful": String(localized: "Apptainer（rootful）")
        case "faasd": "faasd"
        case "homebrew-linux": String(localized: "Homebrew（Linux）")
        case "homebrew-macos": String(localized: "Homebrew（macOS）")
        case "linuxbrew": "Linuxbrew"
        case "gentoo": "Gentoo"
        case "almalinux-kitten": "AlmaLinux Kitten"
        case "almalinux-kitten-10": "AlmaLinux Kitten 10"
        case "debian-sid": "Debian sid"
        case "fedora-rawhide": "Fedora Rawhide"
        case "opensuse-tumbleweed": "openSUSE Tumbleweed"
        case "freebsd-current": "FreeBSD CURRENT"
        case "ubuntu-next": String(localized: "Ubuntu（開発版）")
        default: nil
        }
    }

    // MARK: Grouping

    /// The template menu: frequently used first, then each distribution (newest first), other
    /// systems, tools, anything unknown, and the experimental templates last.
    public static func groups(_ templates: [LimaTemplate]) -> [TemplateGroup] {
        var remaining = templates
        func take(_ predicate: (LimaTemplate) -> Bool) -> [LimaTemplate] {
            let taken = remaining.filter(predicate)
            remaining.removeAll(where: predicate)
            return taken
        }
        var result: [TemplateGroup] = []
        func add(_ id: String, _ title: String, _ items: [LimaTemplate]) {
            if !items.isEmpty { result.append(TemplateGroup(id: id, title: title, templates: items)) }
        }

        let featuredItems = take { featured.contains($0.name) }
            .sorted { featured.firstIndex(of: $0.name)! < featured.firstIndex(of: $1.name)! }
        add("featured", String(localized: "よく使う"), featuredItems)

        var familyGroups: [String] = []
        for family in families where !familyGroups.contains(family.group) { familyGroups.append(family.group) }
        for group in familyGroups {
            let members = families.filter { $0.group == group }
            let items = take { !$0.isExperimental && familyGroup(of: $0.name) == group }
            add(group, members.last!.name, sorted(items))
        }

        add("tools", String(localized: "コンテナと開発ツール"),
            take { tools.contains($0.name) }.sorted { tools.firstIndex(of: $0.name)! < tools.firstIndex(of: $1.name)! })
        add("other", String(localized: "その他"), take { !$0.isExperimental })
        add("experimental", String(localized: "試験的"), remaining)
        return result
    }

    /// "Latest" templates first, then versions from newest to oldest, then the rest by name.
    static func sorted(_ items: [LimaTemplate]) -> [LimaTemplate] {
        func key(_ t: LimaTemplate) -> (Int, [Int], String) {
            if t.isLatestAlias { return (0, [], t.name) }
            if let version = family(of: t.name)?.version {
                return (1, version.split(separator: ".").map { -(Int($0) ?? 0) }, t.name)
            }
            return (2, [], t.name)
        }
        return items.sorted { a, b in
            let (ka, kb) = (key(a), key(b))
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1.lexicographicallyPrecedes(kb.1) }
            return ka.2 < kb.2
        }
    }

    // MARK: Resolving "latest" templates

    /// Finds the versioned image a "latest" template uses: its `base: - template:_images/<name>`,
    /// followed through unversioned images (`_images/ubuntu`) by matching an identical
    /// versioned file next to it (`_images/ubuntu-26.04.yaml`).
    public static func resolveImage(of template: LimaTemplate) -> String? {
        guard template.isLatestAlias, let location = template.location else { return nil }
        let imagesDirectory = location.resolvingSymlinksInPath().deletingLastPathComponent()
            .appending(path: "_images", directoryHint: .isDirectory)
        // Symlinked templates (Homebrew) and their _images live in the same share directory.
        let linkedImages = location.deletingLastPathComponent().appending(path: "_images", directoryHint: .isDirectory)
        let directory = FileManager.default.fileExists(atPath: imagesDirectory.path) ? imagesDirectory : linkedImages

        var file = location
        for _ in 0..<4 {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let match = text.firstMatch(of: /template:_images\/([A-Za-z0-9._-]+)/) else { return nil }
            let image = String(match.1)
            if family(of: image)?.version != nil { return image }
            let imageFile = directory.appending(path: "\(image).yaml")
            guard let imageText = try? String(contentsOf: imageFile, encoding: .utf8) else { return nil }
            if imageText.contains("template:_images/") {
                file = imageFile
                continue
            }
            let siblings = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let versions = sorted(siblings.filter { $0.hasPrefix(image + "-") && $0.hasSuffix(".yaml") }
                .map { LimaTemplate(name: String($0.dropLast(5))) })
            return versions.first { family(of: $0.name)?.version != nil
                && (try? String(contentsOf: directory.appending(path: "\($0.name).yaml"), encoding: .utf8)) == imageText }?.name
        }
        return nil
    }
}
