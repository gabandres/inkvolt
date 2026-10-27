import Foundation

/// Demo mode's made-up network (the Windows app's `Demo`): printers that answer from the scrubbed test fixtures and never
/// reach the network, so the app can be tried (and reviewed) without a printer.
/// - The HP laser at `FixtureTransport.demoHost`: LEDM and eSCL (`m234dw`, with `hp-demo`'s additions).
/// - An inkjet that isn't HP's, at `inkjetHost`: IPP and eSCL (`inkjet-demo`).
/// - An office laser remembered at `officeOldHost`, where nothing answers; it answers at `officeNewHost` (the offline fixer's
///   case).
/// - A newer HP colour laser at `cdmHost` that answers CDM only (`cdm-laser`).
/// - A laser at `snmpHost` that answers SNMP only (`snmp-demo/workgroup-laser.txt`), and an unlisted one at `unlistedHost`.
public enum Demo {
    /// The fixtures' (fake) UUID.
    public static let uuid = "12345678-1234-4abc-8def-123456789abc"
    public static let inkjetUuid = "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"
    public static let officeUuid = "3c9a7e51-8d2b-4f60-a1e4-5b7c9d0e2f13"
    public static let cdmUuid = "4d1e2c3b-0a9f-4e8d-b7c6-5a4b3c2d1e0f"

    public static let inkjetHost = "192.0.2.11"
    public static let officeOldHost = "192.0.2.12", officeNewHost = "192.0.2.23"
    public static let cdmHost = "192.0.2.13"
    public static let snmpHost = "192.0.2.14", snmpQueueHost = "192.0.2.15"
    public static let unlistedHost = "192.0.2.16"

    /// The made-up network's HTTP and SNMP. `fixtures`: the folder holding `m234dw`, `hp-demo`, `inkjet-demo`, `cdm-laser` and
    /// `snmp-demo` (the app bundle's `Demo` folder; the tests' Fixtures folder). `scanPage`: the made-up scanners' pages, a JPEG
    /// for (page, width, height in 1/300 inch), one of `DemoScan`'s. The glass gives a letter at the area asked for (photos
    /// when `scanSetup` says so); the feeder holds three pages, letter size, or a batch with a separator sheet. Nil: the demo
    /// printers can't scan.
    public static func network(fixtures: URL, scanPage: (@Sendable (Int, Int, Int) -> [UInt8])? = nil)
        -> (http: any HttpTransport, snmp: any SnmpTransport) {
        @Sendable func read(_ folder: String, _ name: String) -> [UInt8]? {
            (try? Data(contentsOf: fixtures.appendingPathComponent(folder).appendingPathComponent(name))).map(Array.init)
        }
        @Sendable func laser(_ name: String) -> [UInt8]? { read("m234dw", name) ?? read("hp-demo", name) }
        var area: (@Sendable (Int, Int) -> [UInt8])?
        var feeder: (@Sendable () -> [[UInt8]]?)?
        if let scanPage {
            area = { w, h in scanPage(scanSetup.photosOnGlass ? DemoScan.photos : DemoScan.letter, w, h) }
            feeder = { (scanSetup.feederBatch ? DemoScan.batch : DemoScan.feeder).map { scanPage($0, 2550, 3300) } }
        }
        let http = HostRouter([
            FixtureTransport.demoHost: FixtureTransport(document: laser, scanArea: area, feederBatch: feeder),
            inkjetHost: FixtureTransport(document: { read("inkjet-demo", $0) }, scanArea: area, feederBatch: feeder),
            // The office laser answers only at its new address: the HP fixtures under its own name and UUID.
            officeNewHost: FixtureTransport(document: { name in
                guard let bytes = laser(name) else { return nil }
                guard name.hasSuffix("ProductConfigDyn.xml") || name.hasSuffix("ScannerCapabilities.xml") else { return bytes }
                return Array(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "HP LaserJet MFP M234dw", with: "Demo office laser")
                    .replacingOccurrences(of: uuid, with: officeUuid).utf8)
            }),
            cdmHost: FixtureTransport(document: { read("cdm-laser", $0) }),
        ])
        func agent(_ name: String, _ change: (String) -> String = { $0 }) -> any SnmpTransport {
            let text = change(String(decoding: read("snmp-demo", name) ?? [], as: UTF8.self))
            return SnmpAgent((try? SnmpAgent.parseWalk(text)) ?? [])
        }
        let snmp = SnmpRouter([
            snmpHost: agent("workgroup-laser.txt"),
            snmpQueueHost: agent("color-mfp.txt"),
            unlistedHost: agent("workgroup-laser.txt") {
                $0.replacingOccurrences(of: "Demo Laser 5200 Series", with: "Demo Laser 3100").replacingOccurrences(of: "Demo Laser 5200", with: "Demo Laser 3100")
                    .replacingOccurrences(of: "DEMO0005200", with: "DEMO0003100").replacingOccurrences(of: "demo-laser", with: "basement-laser")
                    .replacingOccurrences(of: "Office, 2nd floor", with: "Basement")
            },
        ])
        return (http, snmp)
    }

    /// Search my network on the made-up network: 253 addresses over about three seconds, finding the HP laser and the
    /// SNMP-only laser (both listed already) and `unlistedHost`. Nothing reaches the network.
    public static func searchNetwork(found: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (SearchProgress) -> Void) async throws {
        let total = 253
        let printers = [10: FixtureTransport.demoHost, 14: snmpHost, 16: unlistedHost]
        for i in 1...total {
            if i % 16 == 0 { try await Task.sleep(for: .milliseconds(180)) }
            if let host = printers[i] { found(host) }
            progress(SearchProgress(checked: i, total: total))
        }
    }

    /// The made-up Mac's print queues: a USB laser discovery can't see (toner low as its queue says), a printer shared from
    /// another Mac that is off, a colour MFP on a raw socket at `snmpQueueHost` with a job waiting, and two that stay out of
    /// the list: a PDF writer (virtual) and the demo HP laser's own queue (its device URI carries the printer's UUID).
    public static let destinations: [CupsDestination] = [
        CupsDestination(name: "Demo_USB_laser", options: [
            "printer-info": "Demo USB laser", "device-uri": "usb://Demo/Laser%202100?serial=DEMO0002100", "printer-make-and-model": "Demo Laser 2100",
            "printer-type": "4", "printer-state": "3", "printer-state-reasons": "toner-low-warning", "printer-is-accepting-jobs": "true",
            "marker-names": "Black Toner", "marker-levels": "12", "marker-low-levels": "15", "marker-types": "toner", "marker-colors": "#000000",
        ], jobs: 0),
        CupsDestination(name: "Front_desk_demo_mac", options: [
            "printer-info": "Front desk @ demo-mac", "device-uri": "dnssd://Front%20desk%20%40%20demo-mac._ipp._tcp.local./cups?uuid=5e6f7a8b-9c0d-4e1f-a2b3-c4d5e6f7a8b9",
            "printer-make-and-model": "Demo Inkjet 3700 Series", "printer-type": "\(4 | CupsDestination.TypeBit.remote)", "printer-state": "3",
            "printer-state-reasons": "offline-report", "printer-is-accepting-jobs": "true",
        ], jobs: 0),
        CupsDestination(name: "Office_color_MFP", options: [
            "printer-info": "Office color MFP", "device-uri": "socket://\(snmpQueueHost)", "printer-make-and-model": "Demo Color MFP 4400",
            "printer-location": "Copy room", "printer-type": "8", "printer-state": "4", "printer-state-reasons": "none", "printer-is-accepting-jobs": "true",
        ], jobs: 1),
        CupsDestination(name: "PDFwriter", options: ["printer-info": "PDFwriter", "device-uri": "pdfwriter:/", "printer-type": "4", "printer-state": "3"]),
        CupsDestination(name: "HP_LaserJet_MFP_M234dw_demo", options: [
            "printer-info": "HP LaserJet MFP M234dw (demo)", "device-uri": "dnssd://Demo%20printer._ipp._tcp.local./?uuid=\(uuid)",
            "printer-make-and-model": "HP LaserJet MFP M234dw - IPP Everywhere", "printer-type": "4", "printer-state": "3",
        ]),
    ]

    /// Demo mode's print queues: `destinations`, with made-up jobs (yours, and one from someone else) in the office MFP's
    /// queue and the demo HP laser's own, which can be cancelled; nothing prints.
    public static func queues(now: Date = Date()) -> FixedQueues {
        FixedQueues(destinations, jobs: [
            "Office_color_MFP": [
                QueueJob(id: 41, name: "Quarterly report.pdf", pages: 12, pagesPrinted: 3, state: .processing, submitted: now.addingTimeInterval(-240), owner: "you"),
                QueueJob(id: 42, name: "Team photo.jpg", pages: 1, state: .pending, submitted: now.addingTimeInterval(-60), owner: "alex"),
            ],
            "HP_LaserJet_MFP_M234dw_demo": [
                QueueJob(id: 17, name: "Boarding pass.pdf", pages: 2, state: .pending, submitted: now.addingTimeInterval(-30), owner: "you"),
            ],
        ], user: "you")
    }

    /// The made-up state: the demo printers remembered, the HP laser selected. Kept in memory only.
    public static func state() -> PrintState {
        var s = PrintState()
        let demo = FixtureTransport.demoHost
        s.printers = [
            KnownPrinter(uuid: uuid, name: "Demo printer", host: demo, esclRoot: "http://\(demo)/eSCL/"),
            KnownPrinter(uuid: inkjetUuid, name: "Demo inkjet", host: inkjetHost, esclRoot: "http://\(inkjetHost)/eSCL/",
                         ippUri: "http://\(inkjetHost):631/ipp/print"),
            KnownPrinter(uuid: officeUuid, name: "Demo office laser", host: officeOldHost, esclRoot: "http://\(officeOldHost)/eSCL/"),
            KnownPrinter(uuid: cdmUuid, name: "Demo color laser (CDM)", host: cdmHost),
            // Added by address, as an SNMP-only printer is (no UUID: its id comes from the address).
            KnownPrinter(uuid: PrinterId.normalize(nil, host: snmpHost), name: "Demo Laser 5200 Series", host: snmpHost,
                         snmp: SnmpDevice(serialNumber: "DEMO0005200", model: "Demo Laser 5200 Series", systemName: "demo-laser")),
        ]
        s.selectedUuid = uuid
        return s
    }
}

/// The demo scanners' pages, by number (`Demo.network`'s `scanPage`).
public enum DemoScan {
    public static let letter = 0, crooked = 1, blank = 2, separatorSheet = 3, crookedLeft = 4, photos = 5
    /// The feeder's three pages.
    public static let feeder = [letter, crooked, blank]
    /// The feeder's batch (the Windows demo's): two pages, a Patch T sheet, then three more (one blank, one crooked).
    public static let batch = [letter, crooked, separatorSheet, letter, blank, crookedLeft]
}

/// What the demo scanners hold next, set by the Scan tab (the Windows demo's `FeederBatch`, `PhotosOnGlass`): a batch in the
/// feeder when the scan splits into files, photos on the glass when it looks for them.
public final class DemoScanSetup: Sendable {
    private let state = Shared((batch: false, photos: false))

    public init() {}

    public var feederBatch: Bool { state.withLock { $0.batch } }
    public var photosOnGlass: Bool { state.withLock { $0.photos } }

    public func prepare(feederBatch: Bool, photosOnGlass: Bool) { state.withLock { $0 = (feederBatch, photosOnGlass) } }
}

extension Demo {
    public static let scanSetup = DemoScanSetup()

    /// The demo inkjet's paper sizes for Print Photos (the Windows demo's): photo paper, borderless except on Legal.
    public static let photoMedia: [QueueMedia] = {
        func m(_ name: String, _ w: Double, _ h: Double, _ margin: Double) -> QueueMedia {
            QueueMedia(name: name, width: w, height: h, left: margin, top: margin, right: margin, bottom: margin)
        }
        return [
            m("na_letter_8.5x11in", 8.5, 11, 0.12), m("na_letter_8.5x11in.borderless", 8.5, 11, 0),
            m("na_index-4x6_4x6in", 4, 6, 0.12), m("na_index-4x6_4x6in.borderless", 4, 6, 0),
            m("na_5x7_5x7in", 5, 7, 0.12), m("na_5x7_5x7in.borderless", 5, 7, 0),
            m("iso_a4_210x297mm", 210 / 25.4, 297 / 25.4, 0.12), m("iso_a4_210x297mm.borderless", 210 / 25.4, 297 / 25.4, 0),
            m("na_legal_8.5x14in", 8.5, 14, 0.12),
        ]
    }()

    /// The demo inkjet's paper types, qualities and colors (the Windows demo's, as IPP keywords).
    public static let photoJobOptions = QueueJobOptions(
        mediaTypes: ["stationery", "photographic", "photographic-glossy", "photographic-semi-gloss", "photographic-matte"],
        defaultMediaType: "stationery", qualities: [3, 4, 5], defaultQuality: 4, colorModes: ["color", "monochrome"],
        defaultColorMode: "color")
}
