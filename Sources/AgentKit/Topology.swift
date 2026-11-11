import Foundation
import LimaKit
import MCPKit
import NetworkKit

// The interface between the planner (written to this spec) and the app's `apply` runner.
// docs/14 §2.2, stage 2: guest-only networks and new VMs only.

/// A declaration as the `plan` tool receives it, decoded and checked for shape.
public struct TopologySpec: Equatable, Sendable {
    public struct Defaults: Equatable, Sendable {
        public var template: String?
        public var cpus: Int?
        public var memoryGiB: Double?
        public var diskGiB: Double?
        public var usernet: Bool?
        public init(template: String? = nil, cpus: Int? = nil, memoryGiB: Double? = nil, diskGiB: Double? = nil, usernet: Bool? = nil) {
            self.template = template; self.cpus = cpus; self.memoryGiB = memoryGiB; self.diskGiB = diskGiB; self.usernet = usernet
        }
    }
    public struct Network: Equatable, Sendable {
        public var ref: String
        /// Only "guestOnly" in stage 2.
        public var mode: String
        public var cidr: String
        /// The `ref` of the VM that routes for this network, if any.
        public var router: String?
        public init(ref: String, mode: String, cidr: String, router: String? = nil) {
            self.ref = ref; self.mode = mode; self.cidr = cidr; self.router = router
        }
    }
    public struct NIC: Equatable, Sendable {
        public var network: String
        public var ip: String?
        public init(network: String, ip: String? = nil) { self.network = network; self.ip = ip }
    }
    public struct VM: Equatable, Sendable {
        public var ref: String
        public var template: String?
        public var cpus: Int?
        public var memoryGiB: Double?
        public var diskGiB: Double?
        /// NIC 0 (Lima's user-mode network); nil = defaults.usernet, then true.
        public var usernet: Bool?
        /// With usernet false: boot once with NIC 0 first (Alpine and older systemd install
        /// socat for vsock SSH then), stop, remove NIC 0, start again.
        public var bootstrapUsernet: Bool
        public var nics: [NIC]
        /// The egress-filtering gateway example with this allow list (lines of gateway.conf).
        public var gatewayAllow: [String]?
        public init(ref: String, template: String? = nil, cpus: Int? = nil, memoryGiB: Double? = nil, diskGiB: Double? = nil,
                    usernet: Bool? = nil, bootstrapUsernet: Bool = false, nics: [NIC] = [], gatewayAllow: [String]? = nil) {
            self.ref = ref; self.template = template; self.cpus = cpus; self.memoryGiB = memoryGiB; self.diskGiB = diskGiB
            self.usernet = usernet; self.bootstrapUsernet = bootstrapUsernet; self.nics = nics; self.gatewayAllow = gatewayAllow
        }
    }
    public struct Assumption: Equatable, Sendable {
        public var path: String
        public var reason: String
        public init(path: String, reason: String) { self.path = path; self.reason = reason }
    }

    public var group: String?
    public var verifyOutside: String?
    public var defaults: Defaults
    public var networks: [Network]
    public var vms: [VM]
    public var assumptions: [Assumption]

    public init(group: String? = nil, verifyOutside: String? = nil, defaults: Defaults = .init(), networks: [Network] = [], vms: [VM] = [], assumptions: [Assumption] = []) {
        self.group = group; self.verifyOutside = verifyOutside; self.defaults = defaults; self.networks = networks; self.vms = vms; self.assumptions = assumptions
    }
}

/// One thing the planner can't do as declared, with a way that works (docs/14 §2, §4).
public struct PlanProblem: Equatable, Sendable {
    public var code: String          // "INVALID", "UNSUPPORTED", "CONFLICT"
    public var path: String          // JSON pointer, e.g. "/networks/0/cidr"
    public var message: String
    public var alternative: String?
    public init(code: String, path: String, message: String, alternative: String? = nil) {
        self.code = code; self.path = path; self.message = message; self.alternative = alternative
    }
}

/// What the planner needs to know about the Mac now.
public struct PlannerFacts: Sendable {
    public struct ExistingVM: Sendable, Equatable {
        public var name: String
        /// The VM's record id (InstanceMetadata.id), nil if it has no record yet.
        public var id: UUID?
        /// In the MCP ledger (made by an earlier apply).
        public var ownedByMCP: Bool
        public init(name: String, id: UUID?, ownedByMCP: Bool) { self.name = name; self.id = id; self.ownedByMCP = ownedByMCP }
    }
    public var vms: [ExistingVM]
    public var networks: [VirtualNetwork]
    /// Names of networks in the MCP ledger.
    public var ownedNetworks: Set<String>
    public var templates: [LimaTemplate]
    public var physicalMemory: Int64
    /// Memory of the VMs running now.
    public var runningMemory: Int64
    public var hasDriver: Bool
    public init(vms: [ExistingVM], networks: [VirtualNetwork], ownedNetworks: Set<String>, templates: [LimaTemplate],
                physicalMemory: Int64, runningMemory: Int64, hasDriver: Bool) {
        self.vms = vms; self.networks = networks; self.ownedNetworks = ownedNetworks; self.templates = templates
        self.physicalMemory = physicalMemory; self.runningMemory = runningMemory; self.hasDriver = hasDriver
    }
}

/// The planner's answer. `problems` empty = ready to apply.
public struct TopologyPlan: Equatable, Sendable {
    public enum Action: String, Sendable { case create, unchanged }

    public struct PlannedNetwork: Equatable, Sendable {
        public var action: Action
        /// To save as is (reservations and router filled in).
        public var network: VirtualNetwork
    }
    public struct PlannedVM: Equatable, Sendable {
        public var action: Action
        public var name: String
        /// For `limactl create`; NICs, NIC 0, provisioning and mounts are in `setExpressions`.
        public var options: CreateOptions
        /// The template as pinned at plan time (e.g. "alpine-3.24"), also in options.template.
        public var template: String
        public var bootstrapUsernet: Bool
        /// network name -> (mac, ip?) for this VM's NICs on planned networks.
        public var nics: [PlannedNIC]
        public var memoryBytes: Int64
    }
    public struct PlannedNIC: Equatable, Sendable {
        public var network: String
        public var mac: String
        public var ip: String?
    }

    public var networks: [PlannedNetwork]
    /// In start order: routers first, then the rest in declaration order.
    public var vms: [PlannedVM]
    public var group: String?
    public var verifyOutside: String?
    /// "key=value" notes of what HanaLima filled in (driver, DHCP server address, pinned template...).
    public var filled: [String]
    public var assumptions: [TopologySpec.Assumption]
    public var problems: [PlanProblem]
    /// Reasons a person must approve in the app (empty in the stage 2 trial).
    public var approvals: [String]
}
