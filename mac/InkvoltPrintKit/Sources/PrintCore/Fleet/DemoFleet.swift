import Foundation

/// Demo mode's made-up Mac as the fleet reads it (the Windows app's `DemoFleetPc`): `Demo.state()`'s five remembered printers on
/// `Demo.network`, `DemoOffline`'s print queues (the USB laser, Front desk shared from another Mac, the office colour MFP;
/// the PDF writer, the HP laser's own queue and the office laser's stay out) and `Demo.scanners` (the USB laser's scanner part
/// goes with its queue, the photo flatbed stands alone). The app's `--demo` and the tests read the same nine entries.
public struct DemoFleetMac: FleetMac {
    private let state: PrintState
    private let http: any HttpTransport
    private let snmp: any SnmpTransport
    private let queues: any PrintQueues
    public let forgotten: [String]
    public let history: SupplyHistoryStore?

    /// `fixtures`: as `Demo.network`'s. `queues`: the made-up queues (demo mode's `DemoOffline`, so a Fix all shows).
    public init(fixtures: URL, queues: (any PrintQueues)? = nil, forgotten: [String] = [], history: SupplyHistoryStore? = nil) {
        let network = Demo.network(fixtures: fixtures)
        state = Demo.state()
        http = network.http
        snmp = network.snmp
        self.queues = queues ?? DemoOffline(delay: .zero)
        self.forgotten = forgotten
        self.history = history
    }

    public var remembered: [KnownPrinter] { state.printers }

    public func accepted(_ id: String) -> [String] { state.acceptedUuids.first { PrinterId.same($0.key, id) }?.value ?? [] }

    public func firmware(_ id: String) -> String? { state.firmware.first { $0.key.caseInsensitiveCompare(id) == .orderedSame }?.value.version }

    public func recipe(_ printer: KnownPrinter) -> PrinterRecipe {
        let http = http
        return PrinterRecipe(transport: { _, _ in http }, snmp: snmp)
    }

    public func destinations() async throws -> [CupsDestination]? { await queues.destinations() }

    public func scanners() async throws -> [SystemScanner]? { Demo.scanners }
}

extension Demo {
    /// The made-up Mac's USB scanners macOS would have drivers for: the USB laser's scanner part, and a photo flatbed that
    /// belongs to no printer (PrintMac's `DemoScanDevice` scans with them).
    public static let laserScanner = SystemScanner(id: "demo-usb-laser-scanner", name: "Demo Laser 2100", usb: true)
    public static let flatbed = SystemScanner(id: "demo-photo-scanner", name: "Demo Photo Scanner 40", usb: true)
    public static let scanners = [laserScanner, flatbed]
}
