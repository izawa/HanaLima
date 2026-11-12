import Foundation

/// Parameters for `limactl create`. Nil values fall back to the template's defaults.
public struct CreateOptions: Sendable, Hashable {
    public enum VMType: String, Sendable, CaseIterable, Identifiable {
        /// `hanalima` is HanaLima's own driver for Lima's external-driver interface (Driver/, docs/09).
        case vz, qemu, hanalima
        public var id: String { rawValue }
    }

    /// The guest's CPU (`--arch`). Only QEMU runs a guest unlike the Mac's CPU, by emulating it;
    /// VZ and HanaLima's driver run the Mac's own (aarch64 on Apple Silicon).
    public enum Arch: String, Sendable, CaseIterable, Identifiable {
        case aarch64, x86_64
        public var id: String { rawValue }
        /// The Mac's own CPU.
        public static var host: Arch {
            #if arch(arm64)
            .aarch64
            #else
            .x86_64
            #endif
        }
    }

    /// Instance name (`--name`).
    public var name: String
    /// Template name as listed by `limactl create --list-templates`, e.g. "default", "ubuntu-24.04".
    public var template: String
    public var cpus: Int?
    public var memoryGiB: Double?
    public var diskGiB: Double?
    public var vmType: VMType?
    /// nil: the template's default, the Mac's own CPU.
    public var arch: Arch?
    /// Values for `--network`, e.g. "vzNAT", "lima:shared".
    public var networks: [String]
    public var rosetta: Bool
    public var video: Bool
    /// Drop every mount from the template (`--mount-none`), so the guest can't see the host's home.
    public var mountNone: Bool
    /// Replace the template's mounts with these (`--mount-only`, `<path>` or `<path>:w`); the
    /// guest sees each at the same path. Takes precedence over `mountNone`.
    public var mountOnly: [String]
    /// Extra yq expressions for `--set`, e.g. to attach `socket:` networks.
    public var setExpressions: [String]

    public init(name: String, template: String = "default", cpus: Int? = nil,
                memoryGiB: Double? = nil, diskGiB: Double? = nil, vmType: VMType? = nil,
                networks: [String] = [], rosetta: Bool = false, video: Bool = false,
                mountNone: Bool = false, mountOnly: [String] = [], setExpressions: [String] = [], arch: Arch? = nil) {
        self.arch = arch
        self.name = name
        self.template = template
        self.cpus = cpus
        self.memoryGiB = memoryGiB
        self.diskGiB = diskGiB
        self.vmType = vmType
        self.networks = networks
        self.rosetta = rosetta
        self.video = video
        self.mountNone = mountNone
        self.mountOnly = mountOnly
        self.setExpressions = setExpressions
    }

    /// Arguments after `limactl` (without global flags).
    public var arguments: [String] {
        var args = ["create", "--name=\(name)"]
        if let cpus { args.append("--cpus=\(cpus)") }
        if let memoryGiB { args.append("--memory=\(Self.format(memoryGiB))") }
        if let diskGiB { args.append("--disk=\(Self.format(diskGiB))") }
        if let vmType { args.append("--vm-type=\(vmType.rawValue)") }
        if let arch { args.append("--arch=\(arch.rawValue)") }
        for net in networks { args.append("--network=\(net)") }
        if rosetta { args.append("--rosetta") }
        if video { args.append("--video") }
        if !mountOnly.isEmpty {
            for m in mountOnly { args.append("--mount-only=\(m)") }
        } else if mountNone {
            args.append("--mount-none")
        }
        for expr in setExpressions { args += ["--set", expr] }
        args.append("template:\(template)")
        return args
    }

    /// Mirrors Lima's `dirnames.ValidateInstName`: alphanumeric runs joined by single
    /// `.`, `_` or `-`, at most 76 characters, and no `.yml`/`.yaml` suffix.
    public static func isValidName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return name.wholeMatch(of: /[A-Za-z0-9]+([._-][A-Za-z0-9]+)*/) != nil
            && name.count <= 76
            && !lower.hasSuffix(".yml") && !lower.hasSuffix(".yaml")
    }

    private static func format(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(v)
    }
}
