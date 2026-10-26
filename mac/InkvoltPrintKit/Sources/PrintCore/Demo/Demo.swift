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
    /// `snmp-demo` (the app bundle's `Demo` folder; the tests' Fixtures folder).
    public static func network(fixtures: URL) -> (http: any HttpTransport, snmp: any SnmpTransport) {
        @Sendable func read(_ folder: String, _ name: String) -> [UInt8]? {
            (try? Data(contentsOf: fixtures.appendingPathComponent(folder).appendingPathComponent(name))).map(Array.init)
        }
        @Sendable func laser(_ name: String) -> [UInt8]? { read("m234dw", name) ?? read("hp-demo", name) }
        let http = HostRouter([
            FixtureTransport.demoHost: FixtureTransport(document: laser),
            inkjetHost: FixtureTransport(document: { read("inkjet-demo", $0) }),
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
