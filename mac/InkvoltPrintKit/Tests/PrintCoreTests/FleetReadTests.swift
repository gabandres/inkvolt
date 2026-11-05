import Foundation
import Testing
@testable import PrintCore

/// Reading every printer at once (`FleetReader`) and Fix all (`FleetFixAll`), on the demo Mac's list (the same printers, queues
/// and scanners the app's `--demo` has, over the same fixtures) and on printers that misbehave. Ported from FleetReadTests.cs
/// with the same names (its `status --all` tests are FleetCommandTests). Adapted to the Mac: cupsd lists every queue with its
/// state in one call, so a queue that hangs or vanishes on its own (A_read_that_hangs_holds_up_only_its_own_row's queues,
/// A_queue_windows_lost_mid_read_says_so) has no Mac counterpart and the hung, throwing and fine rows are network printers;
/// "the spooler" is cupsd, which starts on demand: not answering stops Fix all before any question, as a stopped spooler
/// does; the sandbox has no permission prompt, so A_copy_that_may_elevate_asks_windows_only_after_the_user_was_refused is
/// left out (a refusal is the steps, One_refusal_doesnt_stop_the_rest_and_says_what_to_do).
extension ProGated {
@Suite final class FleetReadTests {
    init() {
        Pro.store = MemoryProStore()
        Pro.enforced = false
    }

    deinit {
        Pro.store = MemoryProStore()
        Pro.enforced = false
    }

    private static let now = FleetTests.now
    private static let me = FleetTests.me

    private static func demoMac(forgotten: [String] = [], history: SupplyHistoryStore? = nil) -> DemoFleetMac {
        DemoFleetMac(fixtures: Fixtures.root, forgotten: forgotten, history: history)
    }

    // The demo Mac's nine entries, as the Fleet page and status --all list them: those that need attention (low ink or toner),
    // by name; then the two that can't be reached (the office laser's old address, the Mac sharing Front desk); then the
    // fine ones. Connected printers go by the name they report, as on the sidebar. Mac: the office colour MFP's queue has no
    // levels in cupsd (the Windows app reads them over SNMP through its port), so it's fine, not low.
    private static let nineInOrder = [
        "Demo inkjet", "Demo Laser 5200 Series", "Demo USB laser", "HP Color LaserJet Pro MFP 3302",
        "Demo office laser", "Front desk @ demo-mac",
        "Demo Photo Scanner 40", "HP LaserJet MFP M234dw", "Office color MFP",
    ]

    private static let nineTroubles: [FleetTrouble] = [.warning, .warning, .warning, .warning, .offline, .offline, .ok, .ok, .ok]

    @Test func The_demo_pcs_nine_entries_render_most_trouble_first() async throws {
        let read = try await FleetReader.readAll(Self.demoMac(), now: Self.now)

        #expect(read.notes.isEmpty)
        let rows = FleetPage.rows(read.printers, Self.now, timeZone: FleetTests.utc)
        #expect(rows.map(\.printer.name) == Self.nineInOrder)
        #expect(rows.map(\.printer.trouble) == Self.nineTroubles)
    }

    @Test func The_demo_pcs_rows_say_what_each_printer_gave() async throws {
        let read = try await FleetReader.readAll(Self.demoMac(), now: Self.now)
        let rows = Dictionary(FleetPage.rows(read.printers, Self.now, timeZone: FleetTests.utc).map { ($0.printer.name, $0) }, uniquingKeysWith: { a, _ in a })

        let laser = try #require(rows["HP LaserJet MFP M234dw"])
        #expect(laser.printer.trouble == .ok)
        #expect(laser.supplies.contains { $0.level != nil })
        #expect(laser.pagesText.contains("pages printed")) // LEDM gives a count
        #expect(laser.firmwareText.hasPrefix("Firmware 20"))
        #expect(laser.lastReadText == "Read just now")

        let office = try #require(rows["Demo office laser"])
        #expect(office.printer.trouble == .offline)
        #expect(office.lastReadText == "Not read yet")

        let usb = try #require(rows["Demo USB laser"])
        #expect(usb.printer.kind == .queue)
        #expect(usb.printer.connection == "USB")
        #expect(usb.pagesText == "Pages not reported")
        #expect(usb.supplies.contains { $0.isLow }) // cupsd's marker levels

        let inkjet = try #require(rows["Demo inkjet"])
        #expect(inkjet.supplies.contains { $0.text.lowercased().hasPrefix("yellow") && $0.isLow })
        #expect(inkjet.firmwareText.contains("Firmware"))

        let shared = try #require(rows["Front desk @ demo-mac"])
        #expect(shared.printer.connection == FleetConnection.shared)

        let scanner = try #require(rows["Demo Photo Scanner 40"])
        #expect(scanner.printer.kind == .scanner)
        #expect(scanner.printer.status == "Ready to scan")
    }

    @Test func The_scanner_that_belongs_to_a_printer_and_the_queues_that_stand_for_none_stay_out() async throws {
        let names = try await FleetReader.readAll(Self.demoMac(), now: Self.now).printers.map(\.name)
        #expect(!names.contains("PDFwriter"))
        #expect(!names.contains { $0.contains("(demo)") }) // the HP laser's own queue
        #expect(!names.contains("Demo Laser 2100")) // the USB laser's scanner part
        #expect(names.filter { $0 == "Demo office laser" }.count == 1) // its queue is the remembered printer's
    }

    @Test func A_hidden_entry_stays_hidden() async throws {
        let mac = Self.demoMac(forgotten: [CupsQueues.id(for: "Demo_USB_laser"), Demo.cdmUuid])
        let names = try await FleetReader.readAll(mac, now: Self.now).printers.map(\.name)
        #expect(!names.contains("Demo USB laser"))
        #expect(names.contains("HP Color LaserJet Pro MFP 3302")) // remembered: hidden is only for what macOS lists
    }

    @Test func The_demo_pcs_json_validates_against_the_schema_and_carries_no_identifiers() async throws {
        let read = try await FleetReader.readAll(Self.demoMac(), now: Self.now)
        let json = FleetExport.json(read.printers, read.notes, Self.now, Self.me, timeZone: FleetTests.utc)

        #expect(try FleetTests.validate(json).isEmpty)
        for secret in [Demo.uuid, Demo.inkjetUuid, Demo.officeUuid, Demo.cdmUuid, "CNB0A00000", "DEMO0005200", "192.0.2.", "demo-laser", "demo-mac"] {
            #expect(json.range(of: secret, options: .caseInsensitive) == nil, "\(secret) in the JSON")
        }
    }

    /// The scrubber's test (RecordingTests): a printer whose replies carry its serial number, UUID, MAC, addresses, host names
    /// and people's names, over LEDM and eSCL, IPP and SNMP. None of it may reach the JSON or the CSV.
    @Test func What_the_scrubbers_test_plants_in_a_printers_replies_never_reaches_the_export() async throws {
        let host = "10.20.30.40"
        let m234dw = Fixtures.root.appendingPathComponent("m234dw", isDirectory: true)
        let ledm = FixtureTransport(document: { name in
            FileManager.default.contents(atPath: m234dw.appendingPathComponent(name).path)
                .map { Array(RecordingTests.plant(name, String(decoding: $0, as: UTF8.self)).utf8) }
        })
        let ipp = FixtureTransport(document: { $0 == "ipp_print.ipp.txt" ? Array(RecordingTests.plantedIpp.utf8) : nil })
        let agent = SnmpAgent(try SnmpAgent.parseWalk(try RecordingTests.plantedWalk()))
        let planted = "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f" // the UUID the replies report: the printer is known by it, and it stays out too

        var printers: [FleetPrinter] = []
        let cases: [(String, String, any HttpTransport, any SnmpTransport, SnmpDevice?)] = [
            (planted, "LEDM printer", ledm, SnmpRouter([:]), nil),
            (planted, "IPP printer", ipp, SnmpRouter([:]), nil),
            (PrinterId.normalize(nil, host: host), "SNMP printer", HostRouter([:]), SnmpRouter([host: agent]),
             SnmpDevice(serialNumber: nil, model: nil, systemName: nil)),
        ]
        for (id, name, http, snmp, device) in cases {
            let known = KnownPrinter(uuid: id, name: name, host: host, snmp: device)
            let read = try await FleetReader.readAll(OnePrinterMac(printer: known, http: http, snmp: snmp), now: Self.now)
            #expect(read.printers.count == 1)
            let printer = try #require(read.printers.first)
            #expect(printer.trouble != .offline, "\(name) should have been read")
            printers.append(printer)
        }

        for text in [FleetExport.json(printers, [], Self.now, Self.me), FleetExport.csv(printers, Self.now, Self.me)] {
            for word in RecordingTests.planted {
                #expect(text.range(of: word, options: .caseInsensitive) == nil, "\(word) left in \(text)")
            }
        }
    }

    private struct OnePrinterMac: FleetMac {
        let printer: KnownPrinter
        let http: any HttpTransport
        let snmp: any SnmpTransport

        var remembered: [KnownPrinter] { [printer] }
        var forgotten: [String] { [] }
        func accepted(_ id: String) -> [String] { [] }
        func firmware(_ id: String) -> String? { nil }
        func recipe(_ p: KnownPrinter) -> PrinterRecipe {
            let http = http
            return PrinterRecipe(transport: { _, _ in http }, snmp: snmp)
        }
        func destinations() async throws -> [CupsDestination]? { [] }
        func scanners() async throws -> [SystemScanner]? { [] }
        var history: SupplyHistoryStore? { nil }
    }

    // MARK: Printers that misbehave

    private struct Script: FleetMac {
        var printers: [KnownPrinter] = []
        var transport: @Sendable (String) -> any HttpTransport = { _ in HostRouter([:]) }
        var queues: [CupsDestination] = []
        var queuesFail = false, queuesHang = false, scannersHang = false
        var store: SupplyHistoryStore?
        var firmwares: [String: String] = [:]

        var remembered: [KnownPrinter] { printers }
        var forgotten: [String] { [] }
        func accepted(_ id: String) -> [String] { [] }
        func firmware(_ id: String) -> String? { firmwares[id] }
        func recipe(_ p: KnownPrinter) -> PrinterRecipe {
            let http = transport(p.host)
            return PrinterRecipe(transport: { _, _ in http }, snmp: SnmpRouter([:]))
        }
        func destinations() async throws -> [CupsDestination]? {
            if queuesHang { await Hung.forever() }
            if queuesFail { throw DeviceNetworkError.failed("cupsd") }
            return queues
        }
        func scanners() async throws -> [SystemScanner]? {
            if scannersHang { await Hung.forever() }
            return []
        }
        var history: SupplyHistoryStore? { store }
    }

    /// A transport whose every request never answers, whatever cancellation says.
    private struct Hung: HttpTransport {
        /// Kept, never resumed: the task waits for good (a dropped continuation would be reported as leaked).
        private static let kept = Shared<[CheckedContinuation<Void, Never>]>([])

        static func forever() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in kept.withLock { $0.append(c) } }
        }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            await Self.forever()
            throw DeviceNetworkError.timedOut
        }
    }

    private struct Throws: HttpTransport {
        func send(_ request: HttpRequest) async throws -> HttpResponse { throw Wire() }
        struct Wire: Error, CustomStringConvertible { var description: String { "the wire came out" } }
    }

    private static func laserFixtures() -> FixtureTransport {
        let root = Fixtures.root
        return FixtureTransport(document: { name in
            for folder in ["m234dw", "hp-demo"] {
                if let d = FileManager.default.contents(atPath: root.appendingPathComponent(folder).appendingPathComponent(name).path) { return Array(d) }
            }
            return nil
        })
    }

    private static func usbQueue(_ name: String) -> CupsDestination {
        CupsDestination(name: name, options: ["printer-info": name, "device-uri": "usb://Demo/\(name)", "printer-type": "4", "printer-state": "3",
                                              "printer-is-accepting-jobs": "true"])
    }

    @Test func A_read_that_hangs_holds_up_only_its_own_row() async throws {
        let mac = Script(printers: [
            KnownPrinter(uuid: Demo.uuid, name: "Fine", host: FixtureTransport.demoHost),
            KnownPrinter(uuid: "aaaaaaaa-1234-4abc-8def-123456789abc", name: "Hangs", host: "192.0.2.50"),
            KnownPrinter(uuid: "bbbbbbbb-1234-4abc-8def-123456789abc", name: "Throws", host: "192.0.2.51"),
        ], transport: { host in
            switch host {
            case "192.0.2.50": Hung() as any HttpTransport
            case "192.0.2.51": Throws() as any HttpTransport
            default: FleetReadTests.laserFixtures()
            }
        })

        let read = try await FleetReader.readAll(mac, now: Self.now, limit: .milliseconds(1500))

        let rows = Dictionary(read.printers.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(rows[Demo.uuid]?.trouble == .ok)
        let hung = try #require(rows["aaaaaaaa-1234-4abc-8def-123456789abc"])
        #expect(hung.trouble == .offline)
        #expect(hung.status.contains("didn't answer"))
        let threw = try #require(rows["bbbbbbbb-1234-4abc-8def-123456789abc"])
        #expect(threw.trouble == .offline)
        #expect(!threw.status.contains("wire")) // not the error's words
    }

    @Test func A_network_printer_that_hangs_mid_read_is_contained_too() async throws {
        // It answers who it is, then hangs on its status: the read is given up on all the same.
        let fixtures = Self.laserFixtures()
        let midRead = MidRead(fixtures)
        let mac = Script(printers: [KnownPrinter(uuid: Demo.uuid, name: "Hung", host: FixtureTransport.demoHost),
                                    KnownPrinter(uuid: Demo.cdmUuid, name: "Other", host: "192.0.2.51")],
                         transport: { $0 == FixtureTransport.demoHost ? midRead as any HttpTransport : HostRouter([:]) })

        let read = try await FleetReader.readAll(mac, now: Self.now, limit: .milliseconds(400))

        #expect(read.printers.count == 2)
        #expect(read.printers.allSatisfy { $0.trouble == .offline })
    }

    /// Answers the probe, then never answers a status document.
    private struct MidRead: HttpTransport {
        let inner: FixtureTransport
        init(_ inner: FixtureTransport) { self.inner = inner }
        func send(_ request: HttpRequest) async throws -> HttpResponse {
            if request.url.path.contains("Status") || request.url.path.lowercased().contains("consumable") { await Hung.forever() }
            return try await inner.send(request)
        }
    }

    @Test func A_lot_of_printers_that_hang_dont_add_up() async throws {
        let printers = (0..<40).map { i in
            KnownPrinter(uuid: String(format: "%08x-1234-4abc-8def-123456789abc", i), name: "Printer \(i)", host: "192.0.2.\(100 + i)")
        }
        let mac = Script(printers: printers, transport: { _ in Hung() })

        let start = ContinuousClock.now
        let read = try await FleetReader.readAll(mac, now: Self.now, limit: .milliseconds(200))

        #expect(read.printers.count == 40)
        #expect(ContinuousClock.now - start < .seconds(15), "took \(ContinuousClock.now - start)")
    }

    @Test func A_spooler_that_hangs_or_fails_leaves_a_note_and_the_network_printers() async throws {
        let hung = Script(printers: [KnownPrinter(uuid: Demo.uuid, name: "Net", host: "192.0.2.50")], queuesHang: true)
        let read = try await FleetReader.readAll(hung, now: Self.now, limit: .milliseconds(200))
        #expect(read.printers.count == 1)
        #expect(read.notes.contains { $0.contains("macOS's printers") })

        let failed = Script(queuesFail: true)
        #expect(try await FleetReader.readAll(failed, now: Self.now).notes.contains { $0.contains("macOS's printers") })

        let scanners = Script(scannersHang: true)
        #expect(try await FleetReader.readAll(scanners, now: Self.now, limit: .milliseconds(200)).notes.contains { $0.contains("scanners") })
    }

    @Test func Another_device_at_the_address_is_never_read_under_the_printers_name() async throws {
        // The address answers as the demo laser, with its own UUID; this printer remembers another one.
        let mac = Script(printers: [KnownPrinter(uuid: "87654321-4321-4cba-8fed-cba987654321", name: "My printer", host: FixtureTransport.demoHost)],
                         transport: { _ in FleetReadTests.laserFixtures() })

        let read = try await FleetReader.readAll(mac, now: Self.now)
        #expect(read.printers.count == 1)
        let printer = try #require(read.printers.first)

        #expect(printer.name == "My printer")
        #expect(printer.trouble == .offline)
        #expect(printer.status.contains("different device"))
        #expect(printer.supplies.isEmpty)
        #expect(printer.firmware == nil)
        #expect(printer.pages == nil)
    }

    @Test func A_printer_that_doesnt_answer_shows_what_the_supply_history_and_state_last_knew() async throws {
        let store = SupplyHistoryStore(nil)
        _ = store.record("p", [FleetTests.supply("Black", 33)], 4242, Day(2026, 10, 29))
        let mac = Script(printers: [KnownPrinter(uuid: "p", name: "Asleep", host: "192.0.2.50")], store: store, firmwares: ["p": "2024-08-13"])

        let read = try await FleetReader.readAll(mac, now: Self.now)
        let printer = try #require(read.printers.first)

        #expect(printer.trouble == .offline)
        #expect(printer.lastKnown)
        #expect(printer.lastReadingDay == Day(2026, 10, 29))
        #expect(printer.lastReading == nil)
        #expect(printer.pages == 4242)
        #expect(printer.firmware == "2024-08-13")
        #expect(printer.supplies.map(\.level) == [33])
    }

    @Test func A_printer_that_answers_without_supplies_says_the_historys_are_last_known_and_old_trouble_isnt_now() async throws {
        let store = SupplyHistoryStore(nil)
        _ = store.record(Demo.uuid, [FleetTests.supply("Black", 0, "out")], 4242, Day(2026, 10, 29))
        let failing = SuppliesFail(Self.laserFixtures())
        let mac = Script(printers: [KnownPrinter(uuid: Demo.uuid, name: "Laser", host: FixtureTransport.demoHost)],
                         transport: { _ in failing }, store: store)

        let read = try await FleetReader.readAll(mac, now: Self.now)
        let printer = try #require(read.printers.first)

        #expect(printer.supplies.map(\.level) == [0]) // the history's, since this read gave none
        #expect(printer.lastKnown)
        #expect(printer.trouble != .error) // the printer says it's ready now; that toner may have been changed since
    }

    /// A printer whose supplies documents answer with an error: the read has none this time.
    private struct SuppliesFail: HttpTransport {
        let inner: FixtureTransport
        init(_ inner: FixtureTransport) { self.inner = inner }
        func send(_ request: HttpRequest) async throws -> HttpResponse {
            let path = request.url.path.lowercased()
            if path.contains("consumable") || path.contains("suppl") { return HttpResponse(status: 500) }
            return try await inner.send(request)
        }
    }

    @Test func Reading_writes_nothing_to_the_supply_history() async throws {
        let store = SupplyHistoryStore(nil)
        _ = try await FleetReader.readAll(Self.demoMac(history: store), now: Self.now)
        for id in [Demo.uuid, Demo.inkjetUuid, Demo.cdmUuid] { #expect(store.rows(id).isEmpty) }
    }

    /// Mac: the page's rows come from what the app shows (no read); one still connecting is not known yet, not unreachable,
    /// and one that stopped answering keeps its last levels, marked last known.
    @Test func The_page_takes_what_the_app_shows_and_marks_what_is_last_known() {
        var connecting = PrinterView.connecting
        connecting.model = "Demo"
        let waiting = FleetPrinter.of(.shown("a", "A", .network, view: connecting, connection: nil, firmware: nil, lastReading: nil, known: nil))
        #expect(waiting.trouble == .unknown)

        var off = PrinterView.connecting
        off.phase = .offline
        off.statusMessage = "Can't reach the printer"
        off.supplies = [FleetTests.supply("Black", 40)]
        let silent = FleetPrinter.of(.shown("b", "B", .network, view: off, connection: "LEDM", firmware: "2024-08-13", lastReading: Self.now, known: nil))
        #expect(silent.trouble == .offline)
        #expect(silent.lastKnown)
        #expect(silent.supplies.map(\.level) == [40])
        #expect(silent.lastReading == Self.now)

        let known = FleetLastKnown(day: Day(2026, 10, 29), pages: 7, supplies: [FleetTests.supply("Black", 12)])
        off.supplies = []
        let fromHistory = FleetPrinter.of(.shown("c", "C", .network, view: off, connection: nil, firmware: nil, lastReading: nil, known: known))
        #expect(fromHistory.lastReadingDay == Day(2026, 10, 29))
        #expect(fromHistory.pages == 7)
        #expect(fromHistory.supplies.map(\.level) == [12])
    }

    // MARK: Fix all

    /// cupsd's queues as Fix all sees them, and what it was asked to do.
    private final class FakeFixMac: PrintQueues, QueueControl {
        let state: Shared<(queues: [CupsDestination], done: [String])>
        let jobsIn: [String: [QueueJob]]
        let refuse: Bool, fails: String?, hangs: Bool, absent: Bool
        let user = "you"

        init(_ queues: [CupsDestination], jobs: [String: [QueueJob]] = [:], refuse: Bool = false, fails: String? = nil, hangs: Bool = false,
             absent: Bool = false) {
            state = Shared((queues, []))
            jobsIn = jobs
            self.refuse = refuse
            self.fails = fails
            self.hangs = hangs
            self.absent = absent
        }

        var queues: [CupsDestination] { state.withLock { $0.queues } }
        var done: [String] { state.withLock { $0.done } }
        func set(_ queues: [CupsDestination]) { state.withLock { $0.queues = queues } }

        func destinations() async -> [CupsDestination]? {
            if hangs { await Hung.forever() }
            return absent ? nil : queues
        }
        func jobs(_ queue: String) async -> [QueueJob]? { jobsIn[queue] ?? [] }
        func cancel(_ queue: String, job: Int) async throws { state.withLock { $0.done.append("cancel \(job)") } }

        func resume(_ queue: String) async throws { try change("resume", queue) { $0.options["printer-state"] = "3" } }
        func acceptJobs(_ queue: String) async throws { try change("accept", queue) { $0.options["printer-is-accepting-jobs"] = "true" } }
        func setDeviceUri(_ queue: String, _ uri: String) async throws { try change("point", queue) { $0.options["device-uri"] = uri } }

        private func change(_ what: String, _ queue: String, _ body: @Sendable (inout CupsDestination) -> Void) throws {
            if refuse { throw QueueControlError.refused }
            if let fails { throw QueueControlError.failed(fails) }
            state.withLock { s in
                s.done.append("\(what) \(queue)")
                if let i = s.queues.firstIndex(where: { $0.name == queue }) { body(&s.queues[i]) }
            }
        }
    }

    private static func facts(_ name: String, paused: Bool = false, rejecting: Bool = false, uri: String? = nil) -> CupsDestination {
        CupsDestination(name: name, options: ["printer-info": name, "device-uri": uri ?? "usb://Demo/\(name)", "printer-type": "4",
                                              "printer-state": paused ? "5" : "3", "printer-is-accepting-jobs": rejecting ? "false" : "true"])
    }

    private final class Asked: Sendable {
        private let list = Shared<[Repair]>([])
        var all: [Repair] { list.withLock { $0 } }
        func add(_ r: Repair) { list.withLock { $0.append(r) } }
    }

    private static func answer(_ yes: Bool, _ asked: Asked? = nil) -> @Sendable (Repair) async -> Bool {
        { r in
            asked?.add(r)
            return yes
        }
    }

    private static func fixAll(_ mac: FakeFixMac, _ confirm: @escaping @Sendable (Repair) async -> Bool, _ queues: String...,
                               limit: Duration = FleetFixAll.readLimit) async -> FixAllReport {
        await FleetFixAll.run(queues.map { .queue($0) }, queues: mac, control: mac, confirm: confirm, limit: limit)
    }

    @Test func Fix_all_asks_for_each_repair_and_does_only_what_was_confirmed() async {
        let mac = FakeFixMac([Self.facts("A", paused: true, rejecting: true), Self.facts("B", paused: true), Self.facts("C")])
        let asked = Asked()

        let report = await Self.fixAll(mac, { r in
            asked.add(r)
            return r.queue != "B"
        }, "A", "B", "C")

        #expect(asked.all.count == 3)
        #expect(asked.all.allSatisfy { $0.question?.contains("?") == true })
        #expect(mac.done == ["resume A", "accept A"])
        #expect(report.steps.map(\.kind) == [.fixed, .fixed, .declined])
        #expect(mac.queues.first { $0.name == "B" }?.state == 5)
    }

    @Test func Saying_no_to_everything_changes_nothing() async {
        let mac = FakeFixMac([Self.facts("A", paused: true, rejecting: true)])
        let report = await Self.fixAll(mac, Self.answer(false), "A")
        #expect(mac.done.isEmpty)
        #expect(!report.steps.isEmpty)
        #expect(report.steps.allSatisfy { $0.kind == .declined })
    }

    @Test func Stuck_jobs_are_never_touched_only_named_for_the_printers_own_fixer() async {
        let mine = QueueJob(id: 7, name: "Report.pdf", pages: 2, state: .stopped, submitted: Self.now.addingTimeInterval(-600), owner: "you")
        let theirs = QueueJob(id: 8, name: "Old.pdf", pages: 2, state: .aborted, submitted: Self.now.addingTimeInterval(-3600), owner: "someone")
        let mac = FakeFixMac([Self.facts("A")], jobs: ["A": [mine, theirs]])
        let asked = Asked()

        let report = await Self.fixAll(mac, Self.answer(true, asked), "A")

        #expect(asked.all.isEmpty)
        #expect(mac.done.isEmpty)
        #expect(report.steps.isEmpty)
        #expect(report.left.contains { $0.contains("stuck job") })
        #expect(report.left.contains { $0.contains("other people's") })
        #expect(!report.left.contains { $0.hasPrefix("Or ") }) // an alternative isn't one more thing to do
    }

    @Test func A_queue_renamed_while_the_question_was_open_isnt_touched() async {
        let mac = FakeFixMac([Self.facts("A", paused: true)])
        let report = await Self.fixAll(mac, { _ in
            mac.set([Self.facts("A renamed", paused: true)])
            return true
        }, "A")
        #expect(mac.done.isEmpty)
        #expect(report.steps.map(\.kind) == [.gone])
    }

    @Test func A_queue_someone_resumed_while_the_question_was_open_is_left_alone() async {
        let mac = FakeFixMac([Self.facts("A", paused: true)])
        let report = await Self.fixAll(mac, { _ in
            mac.set([Self.facts("A")])
            return true
        }, "A")
        #expect(mac.done.isEmpty)
        #expect(report.steps.map(\.kind) == [.alreadyFine])
    }

    @Test func One_refusal_doesnt_stop_the_rest_and_says_what_to_do() async {
        let mac = FakeFixMac([Self.facts("A", paused: true), Self.facts("B", paused: true)], refuse: true)

        let report = await Self.fixAll(mac, Self.answer(true), "A", "B")

        #expect(report.steps.count == 2)
        #expect(report.steps.allSatisfy { $0.kind == .manual && !$0.steps.isEmpty })
    }

    @Test func A_repair_that_throws_is_that_queues_failure_only() async {
        let mac = FakeFixMac([Self.facts("A", paused: true), Self.facts("B", paused: true)], fails: "cupsd said no")
        let report = await Self.fixAll(mac, Self.answer(true), "A", "B")
        #expect(report.steps.map(\.kind) == [.failed, .failed])
        #expect(report.steps.first?.message.contains("cupsd said no") == true)
    }

    @Test func A_stopped_spooler_stops_it_before_any_question() async {
        let mac = FakeFixMac([Self.facts("A", paused: true)], absent: true)
        let asked = Asked()
        let report = await Self.fixAll(mac, Self.answer(true, asked), "A")
        #expect(asked.all.isEmpty)
        #expect(report.stopped?.contains("printing system") == true)
        #expect(report.summary == report.stopped)
    }

    @Test func Windows_not_answering_ends_it_with_a_message_instead_of_holding_it() async {
        let mac = FakeFixMac([Self.facts("A", paused: true)], hangs: true)
        let asked = Asked()
        let start = ContinuousClock.now
        let report = await Self.fixAll(mac, Self.answer(true, asked), "A", limit: .milliseconds(100))
        #expect(ContinuousClock.now - start < .seconds(20))
        #expect(mac.done.isEmpty)
        #expect(asked.all.isEmpty)
        #expect(report.stopped?.contains("didn't answer") == true)
    }

    @Test func A_cancel_stops_before_the_next_queue() async {
        let mac = FakeFixMac([Self.facts("A", paused: true), Self.facts("B", paused: true)])
        let asked = Asked()

        let task = Task {
            await FleetFixAll.run([.queue("A"), .queue("B")], queues: mac, control: mac, confirm: { r in
                asked.add(r)
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            })
        }
        let report = await task.value

        #expect(asked.all.map(\.queue) == ["A"])
        #expect(mac.done.isEmpty) // cancelled while the question was open: not run
        #expect(report.stopped != nil)
    }

    @Test func A_network_printer_counts_only_queues_known_to_be_its_own() async {
        let mac = FakeFixMac([
            Self.facts("Paired", paused: true, uri: "dnssd://Example%20Laser._ipp._tcp.local./?uuid=\(Demo.uuid)"),
            Self.facts("By_address", rejecting: true, uri: "socket://192.0.2.10"),
            Self.facts("Example_Laser_copy", paused: true, uri: "socket://192.0.2.99"), // only its name matches
            Self.facts("Unrelated", paused: true),
        ])
        let device = OfflineDevice(uuid: Demo.uuid, name: "Example Laser", model: "Example Laser", host: "192.0.2.10")
        let asked = Asked()

        _ = await FleetFixAll.run([.network(device)], queues: mac, control: mac, confirm: Self.answer(true, asked))

        #expect(asked.all.map(\.queue) == ["Paired", "By_address"])
    }

    @Test func A_queue_two_printers_share_is_asked_about_once() async {
        let mac = FakeFixMac([Self.facts("A", paused: true)])
        let asked = Asked()
        _ = await Self.fixAll(mac, Self.answer(true, asked), "A", "a")
        #expect(asked.all.count == 1)
    }

    @Test func Without_a_licence_fix_all_asks_nothing_and_changes_nothing() async {
        Pro.enforced = true
        let mac = FakeFixMac([Self.facts("A", paused: true)])
        let asked = Asked()

        let report = await Self.fixAll(mac, Self.answer(true, asked), "A")

        #expect(report.locked)
        #expect(asked.all.isEmpty)
        #expect(mac.done.isEmpty)
    }

    /// Mac: a queue's name is `printer-info`, which a driverless printer fills itself: cleaned and bounded in the question and
    /// the lines, as on the page.
    @Test func A_queue_name_a_printer_wrote_is_cleaned_in_the_question() async {
        var hostile = Self.facts("Evil", paused: true)
        hostile.options["printer-info"] = "Laser\u{202E}gnp.exe\nPaid: yes" + String(repeating: "x", count: 5000)
        let mac = FakeFixMac([hostile])
        let asked = Asked()
        let report = await Self.fixAll(mac, Self.answer(false, asked), "Evil")
        let question = asked.all.first?.question ?? ""
        #expect(!question.isEmpty)
        #expect(!question.contains("\u{202E}") && !question.contains("\n"))
        #expect(question.utf16.count < FleetPrinter.maxText + 100)
        #expect(report.steps.allSatisfy { $0.title.utf16.count <= FleetPrinter.maxText && !$0.title.contains("\n") })
    }

    /// Mac: the demo's Fix all (the app's `--report --fleet fix`) resumes the office laser's made-up queue and leaves its
    /// stuck job to the printer's own fixer; nothing real is touched.
    @Test func The_demo_macs_fix_all_resumes_the_office_laser_and_leaves_its_stuck_job() async {
        let demo = DemoOffline(delay: .zero)
        let device = OfflineDevice(uuid: Demo.officeUuid, name: "Demo office laser", host: Demo.officeOldHost)
        let report = await FleetFixAll.run([.network(device), .queue("Demo_USB_laser")], queues: demo, control: demo, confirm: Self.answer(true))
        #expect(report.steps.map(\.kind) == [.fixed])
        #expect(report.left.contains { $0.contains("stuck job") })
        #expect(await demo.destinations()?.first { $0.name == DemoOffline.officeQueue }?.state == 3)
    }
}
}
