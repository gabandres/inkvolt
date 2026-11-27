import Foundation
import Synchronization
import Testing
import TestTiming
@testable import PrintCore

/// Scan from the printer's button (print/ROADMAP.md 2.2): HP's Scan to Computer over LEDM (`LedmWalkupScan`, `ScanToComputer`),
/// a USB scanner's button (`FakeScannerButtons`, the Mac's stand-in for Windows' `FakeWiaSystem`), and what one printer's
/// `ScanButton` does with either. The M234dw doesn't list the walk-up interface; the "fixture printer" that does is the demo HP
/// laser: the M234dw's documents, the hand-written walk-up ones (`Fixtures/hp-demo`) and `FakeScanToComputer`'s list and presses.
/// Ported from ScanButtonTests.cs; all 33 tests, none left out. Adapted: the POST bodies are compared as the strings
/// `LedmWalkupScan.build` returns (Windows serializes an XDocument: the same bytes); the hostile list has 500 destinations, not
/// 5,000 (parsed from text here, as a reply is, so under `DeviceHttp.maxReplyBytes`; Windows builds it in memory); the scanner's buttons are ImageCaptureCore's
/// button names (`ScannerButtonNames`), not WIA's event GUIDs, so the test of picking them reads those names; the WIA
/// registration's `WorkClaim` is the same class, used by PrintMac's ImageCaptureCore watch.
// On the cooperative pool, not `.offThePool`: its work is short and waits on the fake printer, and the utility queue the
// CPU-heavy suites share would hold it for minutes behind them.
@Suite
struct ScanButtonTests {
    private static let host = "192.0.2.10", pc = "TEST-PC", tag = "abc123", marker = "TEST-PC-ivabc123"
    private static let page: [UInt8] = [0xFF, 0xD8, 0xFF, 0xD9]
    private static let wait = Timing.limit(Duration.seconds(10))

    private static func documents(_ folders: String...) -> FixtureTransport {
        FixtureTransport(document: { name in folders.lazy.compactMap { try? Fixtures.data("\($0)/\(name)") }.first }, scanPage: { page })
    }

    /// The demo HP laser: the M234dw with the walk-up interface listed (`inTree`).
    private static func panel(inTree: Bool = true) -> FakeScanToComputer { FakeScanToComputer(documents("m234dw", "hp-demo"), inTree: inTree) }

    private static func connect(_ printer: any HttpTransport) async throws -> PrinterConnection {
        try await PrinterConnection.open(host, transport: printer)
    }

    private static func until(_ what: String, _ done: () -> Bool) async throws {
        let clock = ContinuousClock()
        let limit = clock.now + wait
        while !done() {
            if clock.now > limit { Issue.record("Still waiting for: \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func pause(_ ms: Int = 300) async throws { try await Task.sleep(for: .milliseconds(ms)) }

    /// A scan button for the printer with its choice kept here, counting presses.
    private final class Button: Sendable {
        private final class Kept: Sendable {
            let saved: Mutex<ScanButtonChoice>
            let presses = Mutex(0)

            init(_ choice: ScanButtonChoice) { saved = Mutex(choice) }
        }

        private let kept: Kept
        let it: ScanButton

        init(_ choice: ScanButtonChoice? = nil, pressed: (@Sendable () -> Void)? = nil) {
            let start = choice ?? ScanButtonChoice(tag: ScanButtonTests.tag)
            let kept = Kept(start)
            self.kept = kept
            it = ScanButton(panelName: ScanButtonTests.pc, choice: start, save: { c in kept.saved.withLock { $0 = c } },
                            pressed: {
                                kept.presses.withLock { $0 += 1 }
                                pressed?()
                            }, detectRetry: .milliseconds(100), panelRetry: .milliseconds(100))
        }

        var saved: ScanButtonChoice { kept.saved.withLock { $0 } }
        var presses: Int { kept.presses.withLock { $0 } }
    }

    // MARK: the names

    @Test func The_M234dws_tree_lists_no_walkup_interface() throws {
        let tree = DiscoveryTree.parse(try DeviceXml.load(Fixtures.data("m234dw/DevMgmt_DiscoveryTree.xml")))

        #expect(LedmWalkupScan.manifestPath(tree) == nil)
        #expect(!tree.interfaces.keys.contains { $0.range(of: "Walkup", options: .caseInsensitive) != nil })
    }

    @Test func The_demo_manifest_names_the_list_and_the_event_document() throws {
        let manifest = try DeviceXml.load(Fixtures.data("hp-demo/WalkupScanToComp_WalkupScanToCompManifest.xml"))

        let paths = try #require(LedmWalkupScan.paths(manifest))
        #expect(paths.list == FakeScanToComputer.listPath && paths.event == FakeScanToComputer.eventPath)
    }

    @Test func The_POST_body_is_the_destination_in_the_printers_own_namespaces() throws {
        let list = try DeviceXml.load(Fixtures.data("hp-demo/WalkupScanToComp_WalkupScanToCompDestinations.xml"))

        let body = LedmWalkupScan.build(list, panelName: Self.pc, hostName: Self.marker)

        #expect(body == "<?xml version=\"1.0\" encoding=\"UTF-8\"?><wus:WalkupScanToCompDestination xmlns:wus=\"http://www.hp.com/schemas/imaging/con/ledm/walkupscan/2010/09/28\""
            + " xmlns:dd=\"http://www.hp.com/schemas/imaging/con/dictionaries/1.0/\" xmlns:dd3=\"http://www.hp.com/schemas/imaging/con/dictionaries/2009/04/06\">"
            + "<dd:Name>TEST-PC</dd:Name><dd3:Hostname>TEST-PC-ivabc123</dd3:Hostname><wus:LinkType>Network</wus:LinkType></wus:WalkupScanToCompDestination>")
    }

    @Test(arguments: [
        ("TEST-PC", "TEST-PC"),
        ("  Ana's laptop <b>  ", "Anas laptop b"),
        ("<>&\"", "PC"),
        ("A-VERY-LONG-COMPUTER-NAME-THAT-GOES-ON-AND-ON", "A-VERY-LONG-COMPUTER-NAME-THAT-G"),
    ])
    func The_panel_name_is_the_computers_cut_to_plain_letters(_ computer: String, _ shown: String) {
        #expect(LedmWalkupScan.panelName(computer) == shown)
    }

    @Test(arguments: [
        ("http://192.0.2.10/WalkupScanToComp/WalkupScanToCompDestinations/7", "/WalkupScanToComp/WalkupScanToCompDestinations/7"),
        ("/WalkupScanToComp/WalkupScanToCompDestinations/a-1", "/WalkupScanToComp/WalkupScanToCompDestinations/a-1"),
        ("/WalkupScanToComp/WalkupScanToCompDestinations/../../DevMgmt/ProductConfigDyn.xml", nil),
        ("/DevMgmt/ProductConfigDyn.xml", nil),
        ("/WalkupScanToComp/WalkupScanToCompDestinations/", nil),
        ("/WalkupScanToComp/WalkupScanToCompDestinations", nil),
        ("//elsewhere/WalkupScanToComp/WalkupScanToCompDestinations/1", nil),
        ("/WalkupScanToComp/WalkupScanToCompDestinations/1?x=y", nil),
        (nil, nil),
    ] as [(String?, String?)])
    func Only_a_path_below_the_list_is_ever_this_PCs_to_delete(_ location: String?, _ own: String?) {
        #expect(LedmWalkupScan.ownPath(location, FakeScanToComputer.listPath) == own)
    }

    @Test func A_list_or_event_of_another_shape_offers_nothing_and_a_hostile_one_is_bounded() throws {
        #expect(LedmWalkupScan.read(try DeviceXml.load("<WalkupScanDestinations/>")) == nil)
        #expect(LedmWalkupScan.eventType(try DeviceXml.load("<Other><WalkupScanToCompEventType>ScanRequested</WalkupScanToCompEventType></Other>")) == nil)
        #expect(LedmWalkupScan.paths(try DeviceXml.load(
            "<m><ResourceMap><ResourceLink><ResourceURI>//evil</ResourceURI></ResourceLink><ResourceNode><ResourceLink><ResourceURI>/x</ResourceURI></ResourceLink>"
                + "<ResourceType><t>WalkupScanToCompDestinations</t></ResourceType></ResourceNode><ResourceNode><ResourceLink><ResourceURI>/y</ResourceURI></ResourceLink>"
                + "<ResourceType><t>WalkupScanToCompEvent</t></ResourceType></ResourceNode></ResourceMap></m>")) == nil)

        let long = String(repeating: "x", count: 10_000)
        let many = "<WalkupScanToCompDestinations>" + (0..<500).map { // 5 MB: what a reply may hold (Windows builds 5000 in memory)
            "<WalkupScanToCompDestination><ResourceURI>/l/\($0)</ResourceURI><Name>\(long)</Name></WalkupScanToCompDestination>"
        }.joined() + "</WalkupScanToCompDestinations>"
        let read = try #require(LedmWalkupScan.read(try DeviceXml.load(many)))
        #expect(read.count == LedmWalkupScan.maxDestinations)
        #expect(read.allSatisfy { $0.name?.count == LedmWalkupScan.maxNameLength })
        let shout = String(repeating: "S", count: 5000)
        #expect(LedmWalkupScan.eventType(try DeviceXml.load(
            "<WalkupScanToCompEvent><WalkupScanToCompEventType>\(shout)</WalkupScanToCompEventType></WalkupScanToCompEvent>"))?.count == LedmWalkupScan.maxNameLength)
        #expect(!LedmWalkupScan.isStart("HostSelected"))
        #expect(LedmWalkupScan.isStart("scanrequested"))
    }

    // MARK: the printer's panel

    @Test func The_M234dw_offers_no_panel_and_nothing_is_written_to_it() async throws {
        let printer = Self.panel(inTree: false)
        let conn = try await Self.connect(printer)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))

        await button.it.usePrinter(conn)

        #expect(button.it.way == .none)
        #expect(button.it.text("Document") == loc("This printer's own Scan button can't send scans here: it offers neither HP's Scan to Computer nor a scan button macOS can report."))
        #expect(printer.writes.isEmpty)
    }

    @Test func The_fixture_printers_list_shows_the_PC_after_connect_and_not_after_exit() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))

        await button.it.usePrinter(conn)
        try await Self.until("listed") { button.it.panelState == .listed }

        #expect(button.it.way == .panel)
        #expect(printer.names == [Self.pc])
        #expect(printer.hosts == [Self.marker]) // its marker: a run after a crash finds it again
        #expect(button.it.text("Document") == loc(
            "On the printer's panel: Scan to Computer › {0}. Pressing Scan there runs {1} here while Inkvolt Print or its menu bar icon is running.",
            Self.pc, "Document"))
        #expect(printer.writes == ["POST \(FakeScanToComputer.listPath)"])

        await button.it.close() // quit

        #expect(printer.names.isEmpty)
        #expect(printer.writes.last == "DELETE \(FakeScanToComputer.listPath)/1")
        #expect(button.saved.on) // the next run adds it again
    }

    @Test func Off_by_default_it_only_reads_and_turning_it_on_and_off_adds_and_removes_the_PC() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let button = Button()

        await button.it.usePrinter(conn)
        #expect(button.it.way == .panel)
        #expect(button.it.text("Document") == loc(
            "Turn this on to add this Mac ({0}) to the printer's panel under Scan to Computer. Choosing it there then scans here.", Self.pc))
        #expect(printer.writes.isEmpty)

        await button.it.setOn(true)
        try await Self.until("added") { printer.names.count == 1 }
        await button.it.setOn(false)

        #expect(printer.names.isEmpty)
        #expect(!button.saved.on)
    }

    @Test func A_simulated_walkup_press_runs_the_preset_and_saves_its_file() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-button-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var preset = ScanPreset()
        preset.id = "p1"
        preset.name = "Receipts"
        preset.source = .glass
        preset.fileName = "{preset} {n}"
        let chosen = preset
        let saved = Mutex<URL?>(nil)
        // What a press runs: the chosen preset, matched to this printer's scanner, its pages saved under its file name.
        let button = Button(ScanButtonChoice(on: true, presetId: chosen.id, tag: Self.tag)) {
            _ = Task {
                let plan = PresetPlan.plan(chosen, conn.probe.scanner!, feederLoaded: nil, ocrAvailable: false, metric: false)
                var pages: [[UInt8]] = []
                for try await page in conn.scanner!.scan(plan.request) { pages.append(page) }
                let name = FileNameTemplate.fileName(chosen.fileName, NameContext(now: Date(), preset: chosen.name, printer: "Demo printer", number: 1, pages: pages.count))
                let file = folder.appendingPathComponent(name + ".jpg")
                try Data(pages[0]).write(to: file)
                saved.withLock { $0 = file }
            }
        }
        await button.it.usePrinter(conn)
        try await Self.until("listed") { button.it.panelState == .listed }

        #expect(printer.press())

        try await Self.until("saved") { saved.withLock { $0 } != nil }
        let path = try #require(saved.withLock { $0 })
        #expect(path.lastPathComponent == "Receipts 1.jpg")
        #expect(Array(try Data(contentsOf: path)) == Self.page)
        try await Self.pause(200)
        #expect(button.presses == 1) // one press, one scan
        await button.it.close()
    }

    @Test func Only_a_scan_request_for_this_PC_counts() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let other = printer.add("OTHER-PC")
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))
        await button.it.usePrinter(conn)
        try await Self.until("listed") { button.it.panelState == .listed }
        let mine = printer.paths[try #require(printer.hosts.firstIndex(of: Self.marker))]

        printer.press(other)                       // another computer chosen on the panel
        printer.press(mine, type: "HostSelected")  // this Mac chosen, Scan not pressed yet
        try await Self.pause()
        #expect(button.presses == 0)

        printer.press(mine)
        try await Self.until("pressed") { button.presses == 1 }
        await button.it.close()
        #expect(printer.names == ["OTHER-PC"]) // only its own destination is removed
    }

    @Test func A_press_from_before_it_started_is_not_run() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let mine = printer.add(Self.pc, host: Self.marker) // as if added by an earlier run that crashed, and pressed since
        printer.press(mine)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))

        await button.it.usePrinter(conn)
        try await Self.until("listed") { button.it.panelState == .listed }
        try await Self.pause()

        #expect(button.presses == 0)
        #expect(printer.writes.isEmpty) // the remembered destination is adopted, not added again
        await button.it.close()
    }

    @Test func After_the_printer_restarts_the_PC_goes_back_on_its_panel() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))
        await button.it.usePrinter(conn)
        try await Self.until("added") { printer.names.count == 1 }

        printer.powerUp()

        try await Self.until("added again") { printer.names.count == 1 && printer.writes.filter { $0.hasPrefix("POST") }.count == 2 }
        printer.press()
        try await Self.until("pressed") { button.presses == 1 }
        await button.it.close()
    }

    @Test func A_PC_another_program_put_on_the_panel_is_left_alone() async throws {
        let printer = Self.panel()
        printer.add(Self.pc) // HP's software, say
        let conn = try await Self.connect(printer)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))

        await button.it.usePrinter(conn)
        try await Self.until("seen") { button.it.panelState == .listedByOther }
        #expect(button.it.text(nil) == loc(
            "A computer named {0} is already on the printer's panel, put there by other software (HP's, perhaps), so Inkvolt Print doesn't add it twice. Close that software or restart the printer, then turn this off and on.",
            Self.pc))
        await button.it.close()

        #expect(printer.writes.isEmpty)
        #expect(printer.names == [Self.pc])
    }

    @Test(arguments: [(401, PanelState.needsPassword), (400, PanelState.refused)])
    func A_refused_POST_is_said_and_never_sent_again_on_its_own(_ answer: Int, _ expected: PanelState) async throws {
        let printer = Self.panel()
        printer.postAnswer = answer
        let conn = try await Self.connect(printer)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))

        await button.it.usePrinter(conn)
        try await Self.until(expected.rawValue) { button.it.panelState == expected }
        printer.powerUp() // a restart doesn't make it try again: turning it off and on does
        try await Self.pause()
        await button.it.close()

        #expect(printer.writes.count == 1)
    }

    @Test func Without_a_Location_the_list_says_where_the_PC_went() async throws {
        let printer = Self.panel()
        printer.noLocation = true
        let conn = try await Self.connect(printer)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))

        await button.it.usePrinter(conn)
        try await Self.until("listed") { button.it.panelState == .listed }

        #expect(printer.hosts == [Self.marker])
        await button.it.close()
        #expect(printer.names.isEmpty)
    }

    @Test func Another_device_at_the_address_gets_nothing() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))
        await button.it.usePrinter(conn)
        try await Self.until("added") { printer.names.count == 1 }

        await button.it.usePrinter(nil) // the session let go: another device answers there
        printer.press()
        try await Self.pause()

        #expect(button.presses == 0)
        #expect(!printer.writes.contains { $0.hasPrefix("DELETE") }) // not sent to the other device either
    }

    @Test func Record_a_printer_saves_the_walkup_documents() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-record-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let printer = Self.panel()

        let result = try await PrinterRecorder.record(Self.host, to: folder, RecordOptions(transport: printer))

        #expect(result.files.contains("WalkupScanToComp_WalkupScanToCompManifest.xml"))
        #expect(result.files.contains("WalkupScanToComp_WalkupScanToCompDestinations.xml"))
        #expect(result.files.contains("WalkupScanToComp_WalkupScanToCompEvent.xml"))
        #expect(printer.writes.isEmpty) // reading only: the Mac isn't added to the list
    }

    // MARK: a USB scanner's button

    private static let usb = "demo-usb-scanner"

    private static func usbScanner(_ buttons: [String]?) -> FakeScannerButtons.Scanner { FakeScannerButtons.Scanner(id: usb, buttons: buttons) }

    @Test func The_FakeWiaSystems_button_event_runs_the_preset_while_turned_on() async throws {
        let scanner = Self.usbScanner(["scan"])
        let system = FakeScannerButtons([scanner])
        let button = Button()
        await button.it.useDriver(system, deviceId: Self.usb, buttons: scanner.buttons)

        #expect(button.it.way == .driver)
        #expect(button.it.switchText == loc("Scan here when the scanner's button is pressed"))
        scanner.press()
        #expect(button.presses == 0) // off: not heard
        #expect(scanner.listenerCount == 0)

        await button.it.setOn(true)
        scanner.press()
        scanner.press("mail") // a button this driver doesn't report
        #expect(button.presses == 1)
        #expect(button.it.text("Document") == loc(
            "When the scanner's button sends a scan to this Mac, {0} runs here while Inkvolt Print or its menu bar icon is running.", "Document"))

        await button.it.close()
        #expect(scanner.listenerCount == 0)
    }

    @Test func A_scanner_without_buttons_and_a_printer_without_the_panel_say_neither() async throws {
        let scanner = Self.usbScanner(nil)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))
        let printer = Self.panel(inTree: false)
        let conn = try await Self.connect(printer)

        #expect(button.it.way == .unknown)
        await button.it.usePrinter(conn)
        await button.it.useDriver(FakeScannerButtons([scanner]), deviceId: Self.usb, buttons: scanner.buttons)

        #expect(button.it.way == .none)
        #expect(button.it.text(nil) == loc("This printer's own Scan button can't send scans here: it offers neither HP's Scan to Computer nor a scan button macOS can report."))
    }

    @Test func The_panel_comes_before_the_drivers_button() async throws {
        let scanner = Self.usbScanner(["scan"])
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))

        await button.it.useDriver(FakeScannerButtons([scanner]), deviceId: Self.usb, buttons: scanner.buttons)
        #expect(scanner.listenerCount == 1)
        await button.it.usePrinter(conn)

        #expect(button.it.way == .panel)
        #expect(scanner.listenerCount == 0) // one press, one scan: not both ways at once
        await button.it.close()
    }

    @Test func The_drivers_scan_buttons_are_picked_from_its_events_in_any_spelling() {
        #expect(ScannerButtonNames.scanButtonsIn(["ICButtonTypeScan", "MAIL", "ICButtonTypePrint", "junk"]) == ["scan", "mail"])
        #expect(ScannerButtonNames.scanButtonsIn([]).isEmpty)
    }

    // MARK: review findings (c32c510c)

    @Test func A_forgotten_printers_choice_never_comes_back() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let kept = Mutex<[String: ScanButtonChoice]>([:])
        let button = ScanButton(panelName: Self.pc, choice: ScanButtonChoice(on: true, tag: Self.tag), save: { c in kept.withLock { $0["printer"] = c } },
                                pressed: {}, panelRetry: .milliseconds(100))
        await button.usePrinter(conn)
        try await Self.until("listed") { button.panelState == .listed }

        button.seal()           // forgetting it: first its button, then its choice
        kept.withLock { $0.removeAll() }
        await button.close()
        await button.setOn(false)
        button.setPreset("p2")

        #expect(kept.withLock { $0.isEmpty })
        #expect(printer.names.isEmpty) // still taken off the panel
    }

    @Test func Once_closed_nothing_starts_again() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let scanner = Self.usbScanner(["scan"])
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))

        await button.it.close()
        await button.it.usePrinter(conn)
        await button.it.useDriver(FakeScannerButtons([scanner]), deviceId: Self.usb, buttons: scanner.buttons)
        scanner.press()
        try await Self.pause()

        #expect(printer.writes.isEmpty)
        #expect(scanner.listenerCount == 0)
        #expect(button.presses == 0)
    }

    @Test func A_busy_list_is_tried_again_not_taken_as_a_refusal() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let button = Button(ScanButtonChoice(tag: Self.tag))
        await button.it.usePrinter(conn)

        printer.listAnswer = 503
        await button.it.setOn(true)
        try await Self.until("not reached") { button.it.panelState == .notReached }
        printer.listAnswer = nil // the printer recovers; its EventTable stays quiet

        try await Self.until("listed after a retry") { button.it.panelState == .listed }
        #expect(printer.names == [Self.pc])
        await button.it.close()
    }

    @Test func A_POST_whose_answer_was_lost_is_found_by_its_marker_and_removed() async throws {
        let printer = Self.panel()
        printer.addedThenAnswer = 503 // added, then a 503
        let conn = try await Self.connect(printer)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))

        await button.it.usePrinter(conn)
        try await Self.until("listed by its marker") { button.it.panelState == .listed }
        await button.it.close()

        #expect(printer.writes.filter { $0.hasPrefix("POST") }.count == 1) // never a second one
        #expect(printer.names.isEmpty)
    }

    @Test func Exit_removes_this_apps_destination_even_when_its_path_was_never_known() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        printer.add(Self.pc, host: Self.marker) // an earlier run's, its answer lost
        let found = try await ScanToComputer.detect(conn)

        let panel = try #require(found.panel)
        #expect(await panel.remove(PanelOwner(Self.pc, Self.marker)))
        #expect(printer.names.isEmpty)
    }

    @Test func A_list_in_no_namespace_gets_a_destination_in_none() throws {
        let body = LedmWalkupScan.build(try DeviceXml.load("<WalkupScanToCompDestinations/>"), panelName: Self.pc, hostName: Self.marker)

        #expect(body == "<?xml version=\"1.0\" encoding=\"UTF-8\"?><WalkupScanToCompDestination xmlns:dd=\"http://www.hp.com/schemas/imaging/con/dictionaries/1.0/\""
            + " xmlns:dd3=\"http://www.hp.com/schemas/imaging/con/dictionaries/2009/04/06\"><dd:Name>TEST-PC</dd:Name><dd3:Hostname>TEST-PC-ivabc123</dd3:Hostname>"
            + "<LinkType>Network</LinkType></WalkupScanToCompDestination>")
    }

    @Test func A_printer_that_couldnt_be_read_says_nothing_yet_and_is_looked_at_again() async throws {
        let printer = Self.panel()
        printer.listAnswer = 503
        let conn = try await Self.connect(printer)
        let button = Button()

        await button.it.usePrinter(conn)
        #expect(button.it.way == .unknown) // not "this printer offers no button"
        #expect(button.it.text(nil) == "")

        printer.listAnswer = nil
        try await Self.until("found on a retry") { button.it.way == .panel }
    }

    @Test func The_status_and_the_panel_share_one_long_poll() async throws {
        let printer = Self.panel()
        let conn = try await Self.connect(printer)
        let status = Task {
            for await _ in conn.watch(fallbackInterval: .seconds(60)) {}
        }
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))
        await button.it.usePrinter(conn)
        try await Self.until("listed") { button.it.panelState == .listed }

        printer.press()
        try await Self.until("pressed") { button.presses == 1 }
        try await Self.pause()

        #expect(printer.mostPolls == 1)
        let ledm = try #require(conn.ledm)
        #expect(ledm.events.polls == 1)
        await button.it.close()
        status.cancel()
        await status.value
        try await Self.until("the poll stops when nobody watches") { ledm.events.polls == 0 }
    }

    @Test func Events_from_before_an_outage_at_start_are_not_presses() async throws {
        let printer = Self.panel()
        let mine = printer.add(Self.pc, host: Self.marker)
        printer.press(mine) // pressed before this app started
        printer.tableAnswer = 503 // and the EventTable isn't answering when it starts
        let conn = try await Self.connect(printer)
        let button = Button(ScanButtonChoice(on: true, tag: Self.tag))

        await button.it.usePrinter(conn)
        try await Self.until("listed") { button.it.panelState == .listed }
        printer.tableAnswer = nil
        try await Task.sleep(for: Timing.limit(Duration.seconds(3))) // the poll's first retry comes after 2 s

        #expect(button.presses == 0)
        printer.press(mine)
        try await Self.until("a new press") { button.presses == 1 }
        await button.it.close()
    }

    @Test func Seen_events_roll_without_ever_forgetting_what_the_table_still_holds() {
        var seen = SeenEvents()
        let old = LedmEvent(category: "ScanEvent", agingStamp: "1-1")
        #expect(seen.take([old], start: true).isEmpty)

        for i in 0..<(3 * SeenEvents.max) {
            #expect(seen.take([old, LedmEvent(category: "PowerUpEvent", agingStamp: "\(i + 2)-1")], start: false).count == 1) // only the new one
        }

        #expect(seen.count <= SeenEvents.max)
        #expect(seen.take([old], start: false).isEmpty)
    }

    @Test func A_registration_made_after_its_caller_gave_up_is_undone_on_its_thread() {
        let undone = Mutex<[String]>([])
        let late = WorkClaim<String> { s in undone.withLock { $0.append(s) } }
        #expect(late.abandon() == nil)              // timed out: nothing delivered yet
        #expect(late.deliver("registration") == nil) // then it comes
        #expect(undone.withLock { $0 } == ["registration"])

        let inTime = WorkClaim<String> { s in undone.withLock { $0.append(s) } }
        #expect(inTime.deliver("second") == "second")
        #expect(inTime.abandon() == "second")  // delivered just before the caller gave up: the caller undoes it
        #expect(undone.withLock { $0.count } == 1)
    }
}
