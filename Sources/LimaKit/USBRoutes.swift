import Foundation

/// Which HanaLima VM receives each USB accessory the user assigns to HanaLima's driver in
/// macOS's "Virtual Machine Accessories" menu (docs/19, routing). Every driver of a running VM
/// is told of every such accessory; each one attaches only those this table sends to its VM.
/// Written by the app only; read by the drivers, which watch the folder for changes.
public struct USBRoutes: Codable, Equatable, Sendable {
    public static let fileName = "usb-routes.json"
    public static let currentVersion = 1

    /// The format.
    public var version: Int
    /// A new UUID at each save; a driver reports the one it read, so the app sees it applied.
    public var revision: String
    /// Where an accessory no rule matches goes; nil holds it.
    public var defaultRoute: USBTarget?
    public var rules: [Rule]

    public init(defaultRoute: USBTarget? = nil, rules: [Rule] = [], revision: String = "") {
        self.version = Self.currentVersion
        self.revision = revision
        self.defaultRoute = defaultRoute
        self.rules = rules
    }

    /// A device by its serial number, or by the port it is plugged into (for devices without
    /// one, or with one their maker gives every unit).
    public struct Match: Codable, Hashable, Sendable {
        public var vendor: UInt16
        public var product: UInt16
        public var serial: String?
        /// The port, as `USBDeviceIdentity.port` gives it.
        public var locationID: UInt32?

        public init(vendor: UInt16, product: UInt16, serial: String? = nil, locationID: UInt32? = nil) {
            self.vendor = vendor
            self.product = product
            self.serial = serial
            self.locationID = locationID
        }

        public var isSerial: Bool { serial != nil }
    }

    public struct Rule: Codable, Equatable, Sendable {
        public var match: Match
        public var destination: USBTarget

        public init(match: Match, destination: USBTarget) {
            self.match = match
            self.destination = destination
        }
    }

    public enum LoadError: Error, Equatable, CustomStringConvertible {
        case unreadable(String)
        case unknownVersion(Int)
        case invalid(String)

        public var description: String {
            switch self {
            case .unreadable(let reason): "the USB routes can't be read: \(reason)"
            case .unknownVersion(let version): "the USB routes are of a newer format (\(version))"
            case .invalid(let reason): "the USB routes are invalid: \(reason)"
            }
        }
    }

    /// Exactly one of `serial` (not empty) and `locationID`, and no two rules alike.
    public func validate() throws(LoadError) {
        var seen = Set<Match>()
        for rule in rules {
            let match = rule.match
            switch (match.serial, match.locationID) {
            case (let serial?, nil) where !serial.isEmpty: break
            case (nil, _?): break
            default: throw .invalid("a rule needs a serial number or a port")
            }
            guard seen.insert(match).inserted else { throw .invalid("two rules for the same device") }
        }
    }

    /// The table in `support` (the app's Application Support folder). Without one, v0.19's
    /// single USB target (`usb-target.json`) is the default route, so a VM started before the
    /// app has migrated still receives as before; without either, nothing goes anywhere. A
    /// table that can't be read never falls back to the old file.
    public static func load(support: URL) -> Result<USBRoutes, LoadError> {
        let file = support.appending(path: fileName)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch CocoaError.fileReadNoSuchFile {
            return .success(USBRoutes(defaultRoute: USBTarget.load(from: support.appending(path: USBTarget.fileName))))
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
        struct Header: Decodable { var version: Int }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            return .failure(.unreadable("not a routes file"))
        }
        guard header.version == currentVersion else { return .failure(.unknownVersion(header.version)) }
        do {
            let routes = try JSONDecoder().decode(USBRoutes.self, from: data)
            try routes.validate()
            return .success(routes)
        } catch let error as LoadError {
            return .failure(error)
        } catch {
            return .failure(.unreadable(error.localizedDescription))
        }
    }

    /// Writes the table with a new revision (atomically, after validating it) and retires
    /// v0.19's `usb-target.json`. Returns what was written.
    @discardableResult
    public func save(support: URL) throws -> USBRoutes {
        try validate()
        var routes = self
        routes.version = Self.currentVersion
        routes.revision = UUID().uuidString
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(routes).write(to: support.appending(path: Self.fileName), options: .atomic)
        try USBTarget.save(nil, to: support.appending(path: USBTarget.fileName))
        return routes
    }
}

/// What identifies an accessory, read from IORegistry by its registry ID without opening it.
public struct USBDeviceIdentity: Codable, Hashable, Sendable {
    public var vendor: UInt16
    public var product: UInt16
    /// Nil when the device has none, or when IORegistry couldn't be read (`readable`).
    public var serial: String?
    /// IORegistry's `locationID`, as it is (shown to the user).
    public var locationID: UInt32?
    /// The port a rule names (`port(locationID:oneSocket:)`); set where IORegistry is read.
    public var port: UInt32?
    public var name: String?
    public var manufacturer: String?
    /// IORegistry answered. From the device descriptor alone only vendor and product are known.
    public var readable: Bool

    public init(vendor: UInt16, product: UInt16, serial: String? = nil, locationID: UInt32? = nil, port: UInt32? = nil,
                name: String? = nil, manufacturer: String? = nil, readable: Bool = true) {
        self.vendor = vendor
        self.product = product
        self.serial = serial
        self.locationID = locationID
        self.port = port ?? locationID
        self.name = name
        self.manufacturer = manufacturer
        self.readable = readable
    }

    /// Vendor and product from a USB device descriptor (bytes 8–11, little endian).
    public static func ids(descriptor d: [UInt8]) -> (vendor: UInt16, product: UInt16)? {
        guard d.count >= 12 else { return nil }
        return (UInt16(d[8]) | UInt16(d[9]) << 8, UInt16(d[10]) | UInt16(d[11]) << 8)
    }

    /// "8564:1000".
    public var ids: String { String(format: "%04x:%04x", vendor, product) }

    /// The rule that would send this device by its serial number, or by its port.
    public var serialMatch: USBRoutes.Match? {
        serial.map { USBRoutes.Match(vendor: vendor, product: product, serial: $0) }
    }
    public var portMatch: USBRoutes.Match? {
        port.map { USBRoutes.Match(vendor: vendor, product: product, locationID: $0) }
    }

    /// The port a rule names. A USB 3 device in one socket has one root port on the USB 2 path
    /// and another on the USB 3 path, and is enumerated on either (0x03114100 and 0x03214100,
    /// docs/19); the hubs below keep their numbers. So on a controller with one socket (one
    /// USB 2 and one USB 3 root port, as each USB-C controller of a Mac with Apple silicon has)
    /// the root port (bits 20–23) is left out; on others (two USB 2 and two USB 3 root ports
    /// for two sockets) it can't be told which root ports pair, and `locationID` stays whole.
    public static func port(locationID: UInt32, oneSocket: Bool) -> UInt32 {
        oneSocket ? locationID & ~0x00F0_0000 : locationID
    }
}

/// Where the routes send an accessory.
public enum USBRouteDecision: Equatable, Sendable {
    case send(USBTarget, by: Rule)
    case hold(Hold)

    public enum Rule: String, Codable, Sendable { case serial, port, defaultRoute }
    public enum Hold: String, Codable, Sendable {
        /// No rule, and the default route is none.
        case noDefault
        /// The rule that matches it matches another connected device too.
        case duplicate
        /// IORegistry couldn't be read, and a rule may be about this kind of device.
        case unreadable
    }
}

extension USBRoutes {
    /// Where `device` goes, among `connected` (every accessory the caller knows, `device`
    /// included): a serial rule, else a port rule, else the default route. A rule that matches
    /// two connected devices holds both rather than guess.
    public func decision(for device: USBDeviceIdentity, among connected: [USBDeviceIdentity]) -> USBRouteDecision {
        if !device.readable {
            let kind = rules.contains { $0.match.vendor == device.vendor && $0.match.product == device.product }
            if kind { return .hold(.unreadable) }
        } else {
            for (match, by) in [(device.serialMatch, USBRouteDecision.Rule.serial), (device.portMatch, .port)] {
                guard let match, let rule = rules.first(where: { $0.match == match }) else { continue }
                let same = connected.filter { by == .serial ? $0.serialMatch == match : $0.portMatch == match }
                return same.count > 1 ? .hold(.duplicate) : .send(rule.destination, by: by)
            }
        }
        return defaultRoute.map { .send($0, by: .defaultRoute) } ?? .hold(.noDefault)
    }
}

#if canImport(IOKit)
import IOKit

extension USBDeviceIdentity {
    /// Reads the device's serial number, port and names from IORegistry by its registry ID,
    /// without opening it (an accessory assigned to HanaLima can still be looked up, docs/19).
    /// `vendor` and `product` come from the device descriptor, so they are known even when the
    /// lookup fails (`readable` false).
    public static func read(registryID: UInt64, vendor: UInt16, product: UInt16) -> USBDeviceIdentity {
        var identity = USBDeviceIdentity(vendor: vendor, product: product, readable: false)
        guard let matching = IORegistryEntryIDMatching(registryID) else { return identity }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return identity }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        identity.readable = true
        identity.serial = (property("USB Serial Number") ?? property("kUSBSerialNumberString")) as? String
        if identity.serial?.isEmpty == true { identity.serial = nil }
        identity.locationID = (property("locationID") as? NSNumber)?.uint32Value
        identity.port = identity.locationID.map { port(locationID: $0, oneSocket: oneSocketControllers().contains(UInt8($0 >> 24))) }
        identity.name = property("USB Product Name") as? String
        identity.manufacturer = property("USB Vendor Name") as? String
        return identity
    }

    /// The controllers (`locationID`'s top byte) with exactly one USB 2 and one USB 3 root port.
    static func oneSocketControllers() -> Set<UInt8> {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleUSBXHCIPort"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var counts: [UInt8: (usb2: Int, usb3: Int)] = [:]
        while case let port = IOIteratorNext(iterator), port != 0 {
            defer { IOObjectRelease(port) }
            guard let location = (IORegistryEntryCreateCFProperty(port, "locationID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.uint32Value else { continue }
            let controller = UInt8(location >> 24)
            var count = counts[controller] ?? (0, 0)
            if IOObjectConformsTo(port, "AppleUSB30XHCIPort") != 0 { count.usb3 += 1 } else { count.usb2 += 1 }
            counts[controller] = count
        }
        return Set(counts.filter { $0.value == (1, 1) }.keys)
    }
}
#endif
