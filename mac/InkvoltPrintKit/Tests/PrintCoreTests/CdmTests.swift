import Testing
@testable import PrintCore

/// HP CDM (newer HP printers without LEDM), read only: identity, supplies and status from fixtures written from the public
/// sources, and the JSON reader. Ported from CdmTests.cs; the connection tests come with P4.
struct CdmTests {
    private static func json(_ printer: String, _ name: String) throws -> String { try Fixtures.text("\(printer)/\(name)") }

    @Test func identityGivesModelSerialFirmwareAndUuid() throws {
        let p = try #require(CdmParsers.parseIdentity(try Self.json("cdm-laser", "cdm_system_v1_identity.json")))
        #expect(p.makeAndModel == "HP Color LaserJet Pro MFP 3302")
        #expect(p.family == "HP Color LaserJet Pro MFP 3301-3304 3388")
        #expect(p.serialNumber == "CNC0X00000")
        #expect(p.productNumber == "499Q7A")
        #expect(p.uuid == "4d1e2c3b-0a9f-4e8d-b7c6-5a4b3c2d1e0f")
        #expect(p.firmwareRevision == "6.28.3.30-202606111700")
        #expect(p.firmwareDate == "2026-07-24")
        #expect(p.adminPasswordSet == nil)
    }

    @Test func identityToleratesAPlainModelStringAndMissingFields() throws {
        #expect(CdmParsers.parseIdentity(#"{"makeAndModel":"HP OfficeJet Pro 9130"}"#)?.makeAndModel == "HP OfficeJet Pro 9130")
        #expect(CdmParsers.parseIdentity(try Self.json("cdm-tank", "cdm_system_v1_identity.json"))?.firmwareDate == "2025-09-18")
        #expect(CdmParsers.parseIdentity(#"{"version":"1.0.0"}"#) == nil) // no model: not an identity
        #expect(CdmParsers.parseIdentity("<html>not json</html>") == nil)
        #expect(CdmParsers.parseIdentity("[1,2]") == nil)
    }

    @Test func tonerSuppliesWithLevelsPartsAndPages() throws {
        let s = CdmParsers.parseSupplies(try Self.json("cdm-laser", "cdm_supply_v1_suppliesPublic.json"))
        #expect(s.map(\.name) == ["Black toner", "Cyan toner", "Magenta toner", "Yellow toner"])
        #expect(s.allSatisfy { $0.kind == "toner" })
        #expect(s.map(\.colorCode) == ["K", "C", "M", "Y"])
        #expect(s.map(\.percentRemaining) == [72, 9, 55, 61])
        #expect(s[1].productNumber == "W2121X")
        #expect(s[1].estimatedPagesRemaining == 200)
        #expect(s[1].state == "low")
        #expect(s[1].isLow)
        #expect(!s[0].isLow)
    }

    @Test func inkTanksAndTheirPrintheads() throws {
        let s = CdmParsers.parseSupplies(try Self.json("cdm-tank", "cdm_supply_v1_suppliesPublic.json"))
        // Tanks first (what runs out), then the printheads, which report no level on tank printers.
        #expect(s.map(\.name) == ["Cyan ink tank", "Magenta ink tank", "Yellow ink tank", "Black ink tank", "Tri-color printhead", "Black printhead"])
        #expect(s.map(\.percentRemaining) == [80, 60, 10, 100, nil, nil])
        #expect(s[2].state == "low")
        #expect(s[4].state == "ok") // "inform" (a used printhead): nothing to do
        #expect(s[4].productNumber == "M0H50A")
        #expect(s[4].colorCode == "CMY")
    }

    @Test func supplyStatesAndOddValues() {
        let s = CdmParsers.parseSupplies("""
            {"suppliesList":[
              {"supplyType":"inkCartridge","supplyColorCode":"K","supplyState":"out","percentLifeDisplay":"0"},
              {"supplyType":"inkCartridge","supplyColorCode":"CMY","supplyState":"ok","levelState":"veryLow","percentLifeDisplay":4},
              {"supplyType":"inkCartridge","supplyColorCode":"pK","supplyState":"missing"},
              {"supplyType":"imageDrum","supplyState":"ok","percentLifeDisplay":250},
              {"supplyType":"somethingNew","supplyState":"weird","percentLifeDisplay":-1},
              {"no":"type"}
            ]}
            """)
        #expect(s.map(\.name) == ["Black ink cartridge", "Tri-color ink cartridge", "Photo black ink cartridge", "Drum", "Something new", "Supply"])
        #expect(s.map(\.state) == ["out", "veryLow", "missing", "ok", "unknown", "unknown"])
        #expect(s.map(\.percentRemaining) == [0, 4, nil, 100, nil, nil])
        #expect(s[2].colorCode == "K") // photo black shows as black
        #expect(CdmParsers.parseSupplies("{}").isEmpty)
        #expect(CdmParsers.parseSupplies("garbage").isEmpty)
    }

    @Test func statusFromSystemStatusAndAlerts() throws {
        let ready = CdmParsers.parseStatus(system: try Self.json("cdm-laser", "cdm_system_v1_status.json"),
                                           print: try Self.json("cdm-laser", "cdm_print_v2_status.json"),
                                           alerts: try Self.json("cdm-laser", "cdm_alert_v1_alerts.json"))
        #expect(ready.code == "ready")
        #expect(ready.message == "Ready")
        #expect(ready.severity == .warning)
        try #require(ready.alerts.count == 1) // the "genuine HP supply" information alert is left out
        #expect(ready.alerts[0].id == "cartridgeLow")
        #expect(ready.alerts[0].message == "Cartridge low (Cyan)")

        let tray = CdmParsers.parseStatus(system: try Self.json("cdm-tank", "cdm_system_v1_status.json"),
                                          print: try Self.json("cdm-tank", "cdm_print_v2_status.json"),
                                          alerts: try Self.json("cdm-tank", "cdm_alert_v1_alerts.json"))
        #expect(tray.severity == .error)
        #expect(tray.alerts.map(\.message) == ["Load paper"])
        #expect(tray.message == "Load paper") // an error says what's wrong rather than "Ready"
        #expect(tray.detail != nil)
    }

    @Test func statusWithoutSystemStatusFallsBackToThePrintState() {
        #expect(CdmParsers.parseStatus(system: nil, print: #"{"printerState":"processing","printerStateReasons":["none"]}"#, alerts: nil).message == "Printing")
        #expect(CdmParsers.parseStatus(system: nil, print: #"{"printerState":"idle"}"#, alerts: nil).message == "Ready")
        #expect(CdmParsers.parseStatus(system: nil, print: nil, alerts: "garbage").code == "unknown")
        #expect(CdmParsers.parseStatus(system: #"{"status":"ready"}"#, print: nil,
                                       alerts: #"{"alerts":[{"category":"doorOpen","severity":"error"},{"category":"jamInTray2","severity":"error"}]}"#)
            .alerts[0].message == "Door open")
        #expect(CdmParsers.parseStatus(system: #"{"status":"ready"}"#, print: nil, alerts: #"{"alerts":[{"category":"jamInTray2"}]}"#)
            .alerts[0].message == "Paper jam")
    }

    // MARK: The JSON reader (Mac only: .NET has System.Text.Json)

    @Test func jsonKeepsNumberTextBooleansAndEscapes() {
        let j = Json.parse(#" {"n": -1.50e3, "b": true, "s": "a\"bé😀", "a": [null, 1]} "#)
        #expect(j?["n"] == .number("-1.50e3"))
        #expect(j?["b"] == .bool(true))
        #expect(j?["s"] == .string("a\"bé😀"))
        #expect(j?["a"] == .array([.null, .number("1")]))
    }

    @Test(arguments: ["", "{", "[1,]", "{\"a\" 1}", "01x", "\"open", "{} {}", "tru"])
    func jsonRejectsWhatIsntOneValue(_ text: String) {
        #expect(Json.parse(text) == nil)
    }

    @Test func jsonNestedDeeperThanTheLimitIsRefused() {
        #expect(Json.parse(String(repeating: "[", count: 100_000)) == nil)
        #expect(Json.parse(String(repeating: "[", count: 10) + String(repeating: "]", count: 10)) != nil)
    }
}

/// The maker from what the printer says about itself. Ported from OtherBrandsTests.cs.
struct BrandTests {
    @Test(arguments: [
        (PrinterBrand.epson, "EPSON ET-0000 Series"),
        (.epson, "Seiko Epson Example"),
        (.canon, "Canon Example MF000"),
        (.brother, "Brother Example-0000"),
        (.hp, "HP LaserJet MFP M234dw"),
        (.hp, "Hewlett-Packard Example"),
        (.other, "Example Printer 9000"),
        (.other, nil),
        (.other, "SHPX 100"), // "HP" inside a word is not HP
    ] as [(PrinterBrand, String?)])
    func brandFromMakeAndModel(_ brand: PrinterBrand, _ text: String?) {
        #expect(PrinterBrand.detect(text) == brand)
    }
}
