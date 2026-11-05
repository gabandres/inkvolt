import Foundation
import Testing
@testable import PrintCore

/// What Inkvolt PDF uses of Inkvolt Print when printing: the health summary (ported from SuiteTests.cs, its PrinterHealth
/// tests with their names), the printers Inkvolt Print hands over on the Mac (`SuitePrinters`: Windows reads Print's
/// state file instead, `ReadsInkvoltPrintState`), the queue behind a printer, and the bounded check.
struct SuiteTests {
    private static let uuid = "12345678-1234-4abc-8def-123456789abc"

    private static func toner(_ pct: Int?, _ state: String = "ok") -> Consumable {
        Consumable(name: "Black toner", kind: "toner", colorCode: "K", percentRemaining: pct, state: state, lowThreshold: 10)
    }

    // MARK: PrinterHealth (SuiteTests.cs)

    @Test func SleepingPrinterIsFineToPrintTo() {
        let h = PrinterHealth.from(PrinterStatus(code: "inPowerSave", message: "Ready", severity: .info, alerts: []), [Self.toner(45)])
        #expect(h.state == .sleeping)
        #expect(!h.shouldWarn)
        #expect(h.tonerPercent == 45)
        #expect(h.summary == "Sleeping · toner 45%")
    }

    @Test func PaperProblemIsAnErrorWorthAWarning() {
        let status = PrinterStatus(code: "trayEmptyOrOpen", message: "Tray empty or open", severity: .error, alerts: [
            PrinterAlert(id: "trayEmptyOrOpen", severity: .error, message: "Tray empty or open"),
            PrinterAlert(id: "cartridgeLow", severity: .warning, message: "Toner low"),
        ])
        let h = PrinterHealth.from(status, [Self.toner(8, "low")])
        #expect(h.state == .error)
        #expect(h.shouldWarn)
        #expect(h.paperProblems == ["Tray empty or open"])
        #expect(h.problems == ["Toner low"])
        #expect(h.supplies.contains("Black toner: 8% (low)"))
    }

    @Test func IppReasonsCountAsPaperProblems() {
        let status = PrinterStatus(code: "stopped", message: "Stopped", severity: .error,
                                   alerts: [PrinterAlert(id: "media-jam", severity: .error, message: "Media jam")])
        let h = PrinterHealth.from(status, [])
        #expect(h.shouldWarn)
        #expect(h.paperProblems == ["Media jam"])
        #expect(h.tonerPercent == nil)
    }

    @Test func ScannerFeederJamIsNotAPaperProblem() { #expect(!PrinterHealth.isPaper("scannerAdfJam")) }

    @Test(arguments: [
        ("offline", Severity.error, Readiness.offline, true),
        ("unavailable", Severity.info, Readiness.unknown, false),
        ("ready", Severity.info, Readiness.ready, false),
        ("ready", Severity.warning, Readiness.attention, false),
        ("processing", Severity.info, Readiness.busy, false),
        ("stopped", Severity.info, Readiness.error, true),
    ])
    func ReadinessFromStatus(_ code: String, _ severity: Severity, _ expected: Readiness, _ warn: Bool) {
        let h = PrinterHealth.from(PrinterStatus(code: code, message: code, severity: severity, alerts: []), [])
        #expect(h.state == expected)
        #expect(h.shouldWarn == warn)
    }

    // MARK: The hand-off (Mac only)

    private static func state() -> PrintState {
        var s = PrintState()
        s.printers = [
            KnownPrinter(uuid: uuid, name: "HP LaserJet MFP M234dw", model: "HP LaserJet MFP M234dw", host: "192.0.2.10",
                         esclRoot: "http://192.0.2.10:8080/eSCL/", ippUri: "ipp://192.0.2.10/ipp/print"),
            KnownPrinter(uuid: "0e1f2a3b-0000-4000-8000-000000000009", name: "Old printer", host: "192.0.2.99"),
            KnownPrinter(uuid: "0e1f2a3b-0000-4000-8000-000000000005", name: "Lobby", host: "192.0.2.50",
                         snmp: SnmpDevice(serialNumber: nil, model: "Lobby laser", systemName: nil)),
        ]
        s.acceptedUuids = [uuid.uppercased(): ["0e1f2a3b-0000-4000-8000-000000000007"]]
        s.forgottenUuids = ["0E1F2A3B-0000-4000-8000-000000000009"]
        s.certificatePins = ["\(uuid):443": "ab"]
        s.proKey = "a key"
        return s
    }

    @Test func Inkvolt_Print_hands_over_its_remembered_printers_and_nothing_else() throws {
        let handed = SuitePrinters.from(Self.state(), hostNames: [Self.uuid: "NPIABCDEF.local"], queues: [Self.uuid.uppercased(): "HP_LaserJet"])
        #expect(handed.printers.map(\.name) == ["HP LaserJet MFP M234dw", "Lobby"]) // the forgotten one isn't
        let hp = handed.printers[0]
        #expect(hp.hosts == ["192.0.2.10", "NPIABCDEF.local"])
        #expect(hp.acceptedUuids == ["0e1f2a3b-0000-4000-8000-000000000007"])
        #expect(hp.queue == "HP_LaserJet")
        #expect(!hp.snmpOnly && handed.printers[1].snmpOnly)
        let text = try #require(String(data: handed.encoded(), encoding: .utf8))
        #expect(!text.contains("a key") && !text.contains(":443"), "no key, no certificate pins")
        #expect(SuitePrinters.parse(handed.encoded()) == handed)
    }

    @Test func The_hand_off_is_written_once_and_read_back() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("suite-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: root) }
        #expect(SuitePrinters.load(root: root) == .empty)
        let handed = SuitePrinters.from(Self.state())
        #expect(handed.save(root: root))
        let file = SuitePrinters.file(root: root)
        let written = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date
        #expect(handed.save(root: root))
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date == written, "unchanged: not written again")
        #expect(SuitePrinters.load(root: root) == handed)
        #expect(file.hasSuffix("Inkvolt/printers.json") || file.hasSuffix("Inkvolt\\printers.json"))
    }

    @Test func A_hostile_hand_off_reads_as_far_as_it_is_sound() {
        let long = String(repeating: "x", count: SuitePrinters.maxText + 1)
        let json = """
            { "printers": [
                { "id": "\(Self.uuid)", "host": "192.0.2.10", "esclRoot": "file:///etc/passwd", "ippUri": "javascript:alert(1)",
                  "hosts": ["192.0.2.10", 5, null, "\(long)"], "snmpOnly": "yes" },
                { "id": null, "host": "192.0.2.11" },
                { "id": "b", "host": "" },
                { "id": "\(long)", "host": "192.0.2.12" },
                "not an object",
                { "id": "c", "host": "printer.local", "name": "  ", "queue": 7 } ] }
            """
        let read = SuitePrinters.parse(Data(json.utf8))
        #expect(read.printers.map(\.id) == [Self.uuid, "c"])
        #expect(read.printers[0].esclRoot == nil && read.printers[0].ippUri == nil, "only http(s) and ipp(s) addresses")
        #expect(read.printers[0].hosts == ["192.0.2.10"])
        #expect(!read.printers[0].snmpOnly)
        #expect(read.printers[1].name == "printer.local" && read.printers[1].queue == nil)
        #expect(SuitePrinters.parse(Data("[1, 2]".utf8)) == .empty)
        #expect(SuitePrinters.parse(Data("{".utf8)) == .empty)
    }

    @Test func A_hand_off_too_big_or_too_long_is_bounded() {
        let entry = #"{ "id": "p", "host": "192.0.2.1", "hosts": [\#(Array(repeating: "\"h\"", count: 40).joined(separator: ","))] }"#
        let many = "{ \"printers\": [\(Array(repeating: entry, count: SuitePrinters.maxPrinters + 20).joined(separator: ","))] }"
        let read = SuitePrinters.parse(Data(many.utf8))
        #expect(read.printers.count == SuitePrinters.maxPrinters)
        #expect(read.printers[0].hosts.count == SuitePrinters.maxNames)
        let huge = Data("{ \"printers\": [], \"pad\": \"\(String(repeating: " ", count: SuitePrinters.maxBytes))\" }".utf8)
        #expect(SuitePrinters.parse(huge) == .empty)
    }

    // MARK: The queue behind a printer

    private static func queue(_ name: String, _ uri: String) -> CupsDestination {
        CupsDestination(name: name, options: ["device-uri": uri, "printer-type": "4", "printer-state": "3"], jobs: nil)
    }

    @Test func The_queue_Inkvolt_Print_found_for_a_printer_names_it_first() {
        let handed = SuitePrinters.from(Self.state(), queues: [Self.uuid: "Office"])
        #expect(handed.printer(forQueue: "office", nil)?.id == Self.uuid)
        #expect(handed.printer(forQueue: "Elsewhere", nil) == nil)
    }

    @Test func Otherwise_the_queue_is_matched_by_its_device_uri() {
        let handed = SuitePrinters.from(Self.state(), hostNames: [Self.uuid: "NPIABCDEF.local"])
        #expect(handed.printer(forQueue: "Q", Self.queue("Q", "ipp://192.0.2.10/ipp/print"))?.id == Self.uuid)
        #expect(handed.printer(forQueue: "Q", Self.queue("Q", "ipps://npiabcdef.local:443/ipp/print"))?.id == Self.uuid)
        let accepted = "dnssd://HP._ipp._tcp.local./?uuid=0e1f2a3b-0000-4000-8000-000000000007"
        #expect(handed.printer(forQueue: "Q", Self.queue("Q", accepted))?.id == Self.uuid, "a UUID the user accepted")
        #expect(handed.printer(forQueue: "Q", Self.queue("Q", "usb://Other/Printer")) == nil)
        #expect(SuitePrinters.empty.printer(forQueue: "Q", Self.queue("Q", "ipp://192.0.2.10/ipp/print")) == nil)
    }

    // MARK: The check

    private static func printer(_ host: String = "192.0.2.11") -> SuitePrinter { SuitePrinter(id: uuid, name: "Demo", host: host) }

    @Test func A_printer_that_answers_gives_its_health() async throws {
        let h = try #require(await PrinterCheck.health(Self.printer(), transport: { _, _ in Printers.ippOnly() }))
        #expect(!h.shouldWarn)
        #expect(h.summary.contains("Yellow ink is low."))
    }

    @Test func A_printer_that_isnt_there_is_offline() async throws {
        let h = try #require(await PrinterCheck.health(Self.printer(), transport: { _, _ in Printers.none() }))
        #expect(h.state == .offline && h.shouldWarn)
        #expect(PrinterCheck.problem(h, "Demo") == "Demo isn't responding")
        #expect(PrinterCheck.advice(h).contains("macOS keeps the job"))
    }

    @Test func A_printer_with_an_error_says_what_to_fix() {
        let status = PrinterStatus(code: "stopped", message: "Stopped", severity: .error,
                                   alerts: [PrinterAlert(id: "media-jam", severity: .error, message: "Media jam")])
        let h = PrinterHealth.from(status, [Self.toner(45)])
        #expect(PrinterCheck.problem(h, "Demo") == "Demo has a problem")
        #expect(PrinterCheck.advice(h).hasPrefix("Stopped · Media jam · toner 45%. Fix it on the printer first"))
        let fine = PrinterHealth.from(PrinterStatus(code: "idle", message: "Idle", severity: .info, alerts: []), [Self.toner(45)])
        #expect(PrinterCheck.line(fine, "Demo") == "Demo: Ready · toner 45%")
    }

    @Test func A_printer_that_hangs_is_offline_within_the_budget() async throws {
        let hanging = Network(Printers.ippOnly(), failNow: true) { _ in Network.hang() }
        let clock = ContinuousClock()
        let start = clock.now
        let h = try #require(await PrinterCheck.health(Self.printer(), transport: { _, _ in hanging }, budget: .milliseconds(300)))
        #expect(h.state == .offline && h.text == PrinterCheck.notResponding)
        #expect(clock.now - start < .seconds(5))
    }
}
