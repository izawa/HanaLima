import Foundation
import LimaKit

/// Which bundled provisioning examples a declaration may name (`provision`, docs/14 §2.2), and
/// the entries a planned VM gets from them and from its gateway.
public enum DeclaredProvisioning {
    /// Why `id` can't be named in a declaration, or nil when it can.
    public static func refusal(_ id: ProvisionExample.ID) -> String? {
        switch id {
        case .gateway: "use the gateway field (gateway: {allow: [...]})"
        case .dotfiles: "it needs your repository and keys: run your own script with exec instead"
        default: nil
        }
    }

    /// Whether `id` downloads on its first boot (an isolated VM needs bootstrapUsernet for it).
    public static func needsNetwork(_ id: ProvisionExample.ID, distribution: String?) -> Bool {
        switch id {
        case .swap, .noAutoUpdates: false
        case .consoleLogin: distribution == "Alpine"  // installs agetty there
        default: true
        }
    }

    /// What a person approves before a VM is made with `id`, or nil.
    public static func approval(_ id: ProvisionExample.ID) -> String? {
        id == .consoleLogin ? "passwordless shell with sudo for anyone with the screen or the serial console" : nil
    }

    /// The gateway's entries (its allow list in gateway.conf), then each example's, in order.
    public static func entries(_ examples: [ProvisionExample.ID], gatewayAllow: [String]?) -> [ProvisionConfig] {
        let gateway: [ProvisionConfig] = gatewayAllow.map { allow in
            ProvisionExamples.example(.gateway).entries.map { original -> ProvisionConfig in
                var entry = original
                if entry.mode == .data && entry.path == "/etc/hanalima/gateway.conf" { entry.content = allow.joined(separator: "\n") + "\n" }
                return entry
            }
        } ?? []
        return gateway + examples.flatMap { ProvisionExamples.example($0).entries }
    }
}
