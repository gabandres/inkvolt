import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// The printer's own copier over HP LEDM (`LedmCopy`, `PrinterCopier`) and the copy's choices (`CopyRoute`). The M234dw's tree
/// lists the copy documents; the documents themselves are the hand-written demo ones (`Fixtures/hp-demo`), as none has been
/// captured. Ported from PrinterCopyTests.cs; all 18 tests, none left out. Adapted: the PUT body is the Mac's bytes (an XML
/// declaration, and only the namespaces it uses declared: Windows' also declares the Dyn root's unused `dd`); the refusal
/// sentences point to the printer's control panel, as the Mac has no copy through the computer to choose instead.
struct PrinterCopyTests {
    private static let host = "192.0.2.10"

    private static let demoLaser = ["m234dw", "hp-demo"]

    private static func fixture(_ folders: [String], _ name: String) -> [UInt8]? {
        folders.lazy.compactMap { try? Fixtures.data("\($0)/\(name)") }.first
    }

    private static func doc(_ name: String) throws -> XmlElement { try DeviceXml.load(try #require(fixture(demoLaser, name))) }

    private struct Sent: Sendable {
        var method: String
        var url: URL
        var contentType: String?
        var body: [UInt8]
        var connectionClose: Bool
    }

    /// A printer's web server from fixtures that records every request and answers writes with `put`.
    private final class Recorder: HttpTransport {
        private let documents: FixtureTransport
        private let put: Int
        private let fail: (@Sendable (HttpRequest) -> (any Error)?)?
        private let sent = Mutex<[Sent]>([])

        init(_ folders: [String], put: Int = 200, fail: (@Sendable (HttpRequest) -> (any Error)?)? = nil) {
            documents = FixtureTransport(document: { PrinterCopyTests.fixture(folders, $0) })
            self.put = put
            self.fail = fail
        }

        var requests: [Sent] { sent.withLock { $0 } }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            let type = request.header("Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
            sent.withLock {
                $0.append(Sent(method: request.method, url: request.url, contentType: type, body: request.bodyBytes(),
                               connectionClose: request.header("Connection")?.lowercased() == "close"))
            }
            if let error = fail?(request) { throw error }
            if request.method == "PUT" { return HttpResponse(status: put) }
            return try await documents.send(request)
        }
    }

    private static func connect(_ folders: [String], put: Int = 200, fail: (@Sendable (HttpRequest) -> (any Error)?)? = nil) async throws
        -> (PrinterConnection, PrinterCopier?, Recorder) {
        let printer = Recorder(folders, put: put, fail: fail)
        let conn = try await PrinterConnection.open(host, transport: printer)
        return (conn, await PrinterCopier.detect(conn), printer)
    }

    // MARK: finding it

    @Test func The_M234dws_tree_lists_both_copy_documents() throws {
        let tree = DiscoveryTree.parse(try Self.doc("DevMgmt_DiscoveryTree.xml"))

        #expect(LedmCopy.listed(tree))
        #expect(tree.uri(for: LedmCopy.capResource) == "/DevMgmt/CopyConfigCap.xml")
        #expect(tree.uri(for: LedmCopy.dynResource) == "/DevMgmt/CopyConfigDyn.xml")
    }

    @Test func Without_its_copy_documents_the_M234dw_offers_no_printer_copy_and_only_reads() async throws {
        let (_, copier, printer) = try await Self.connect(["m234dw"]) // the recorded fixtures: the tree lists them, nothing answers there

        #expect(copier == nil)
        for s in printer.requests { #expect(s.method == "GET" || s.contentType == "application/ipp", "\(s.method) \(s.url)") }
        #expect(printer.requests.contains { $0.url.path == "/DevMgmt/CopyConfigCap.xml" })
    }

    @Test func The_demo_laser_offers_its_start_by_reading_only() async throws {
        let (_, copier, printer) = try await Self.connect(Self.demoLaser)

        let start = try #require(copier).start
        #expect(start.path == ["CopyState"])
        #expect(start.value == "start")
        #expect(!printer.requests.contains { $0.method != "GET" && $0.contentType != "application/ipp" })
    }

    // MARK: the request

    @Test func One_copy_is_one_PUT_of_the_start_alone_over_HTTPS_byte_for_byte() async throws {
        let (_, copier, printer) = try await Self.connect(Self.demoLaser)
        let before = printer.requests.count

        let result = try await #require(copier).copy()

        #expect(result.ok, "\(result.problem ?? "")")
        let writes = printer.requests.dropFirst(before).filter { $0.method != "GET" }
        try #require(writes.count == 1)
        let put = writes[writes.startIndex]
        #expect(put.method == "PUT")
        #expect(put.url == URL(string: "https://\(Self.host)/DevMgmt/CopyConfigDyn.xml")) // HTTPS: an admin password never crosses in clear text
        #expect(put.contentType == "text/xml")
        #expect(put.connectionClose) // sent once, on a connection of its own (sendOnce)
        // The printer's own names and namespaces, and only the start: its copies, two-sided and the rest stay as its panel has them.
        #expect(String(decoding: put.body, as: UTF8.self) ==
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><cpcfgdyn:CopyConfigDyn xmlns:cpcfgdyn=\"http://www.hp.com/schemas/imaging/con/ledm/cpcfgdyn/2008/05/05\">"
            + "<cpcfgdyn:CopyState>start</cpcfgdyn:CopyState></cpcfgdyn:CopyConfigDyn>")
    }

    @Test(arguments: [
        (404, "doesn't take copy requests"),
        (405, "doesn't take copy requests"),
        (503, "busy"),
        (409, "busy"),
        (500, "turned the copy down"),
    ])
    func A_refusal_is_told_in_words_and_never_sent_again(_ status: Int, _ says: String) async throws {
        let (_, copier, printer) = try await Self.connect(Self.demoLaser, put: status)

        let result = try await #require(copier).copy()

        #expect(!result.ok)
        #expect(result.problem?.contains(says) == true)
        #expect(result.problem?.contains(String(status)) == false)
        #expect(printer.requests.filter { $0.method == "PUT" }.count == 1)
    }

    @Test func No_answer_to_the_PUT_says_it_may_already_be_copying_not_try_again() async throws {
        let (_, copier, printer) = try await Self.connect(Self.demoLaser, fail: { $0.method == "PUT" ? DeviceNetworkError.failed("reset") : nil })

        let result = try await #require(copier).copy()

        #expect(!result.ok)
        #expect(result.problem?.contains("may already be copying") == true)
        #expect(result.problem?.contains("Try again") == false)
        #expect(printer.requests.filter { $0.method == "PUT" }.count == 1)
    }

    @Test(arguments: [401, 403])
    func A_printer_asking_for_its_password_throws_for_the_caller_to_ask(_ status: Int) async throws {
        let (_, copier, _) = try await Self.connect(Self.demoLaser, put: status)

        do {
            _ = try await #require(copier).copy()
            Issue.record("No password asked for")
        } catch let error as LedmAuthRequiredError {
            #expect(!error.credentialsWereSent)
        }
    }

    // MARK: hostile documents

    private static let ns = "xmlns:c=\"urn:example:cap\" xmlns:d=\"urn:example:dyn\" xmlns:dd=\"urn:example:dd\""

    private static func dyn(_ body: String = "<d:CopySettings><dd:Copies>1</dd:Copies></d:CopySettings><d:CopyState>idle</d:CopyState>") -> String {
        "<d:CopyConfigDyn \(ns)>\(body)</d:CopyConfigDyn>"
    }

    private static func startCap(_ xpath: String = "d:CopyConfigDyn/d:CopyState", access: String = "readWrite",
                                 values: String = "<d:CopyState>start</d:CopyState>") -> String {
        "<c:CopyStateSupport elementXPath=\"\(xpath)\" access=\"\(access)\">\(values)</c:CopyStateSupport>"
    }

    private static func read(_ dyn: String, _ capEntries: String) throws -> CopyStart? {
        LedmCopy.read(try DeviceXml.load(dyn), try DeviceXml.load("<c:CopyConfigCap \(ns)>\(capEntries)</c:CopyConfigCap>"))
    }

    @Test func Only_a_writable_explicit_start_command_counts() throws {
        #expect(try Self.read(Self.dyn(), Self.startCap()) != nil)
        #expect(try Self.read(Self.dyn(), Self.startCap(values: "<d:CopyState>idle</d:CopyState><d:CopyState>startCopy</d:CopyState>"))?.value == "startCopy")
        #expect(try Self.read(Self.dyn(), Self.startCap(values: "<d:CopyState>Start</d:CopyState>"))?.value == "Start") // the printer's own spelling

        #expect(try Self.read(Self.dyn(), Self.startCap(access: "readOnly")) == nil)
        #expect(try Self.read(Self.dyn(), Self.startCap(values: "<d:CopyState>processing</d:CopyState>")) == nil) // a state, not a command
        #expect(try Self.read(Self.dyn(), Self.startCap(values: "<d:CopyState>idle</d:CopyState><d:CopyState>copying</d:CopyState>")) == nil)
        #expect(try Self.read(Self.dyn("<d:CopySettings />"), Self.startCap()) == nil) // the Cap names it, the Dyn hasn't got it
        #expect(LedmCopy.read(try DeviceXml.load(Self.dyn()), nil) == nil)
        // A writable copy setting that isn't a start (copies, say) never makes an offer.
        #expect(try Self.read(Self.dyn(), "<c:Copies min=\"1\" max=\"99\" elementXPath=\"d:CopyConfigDyn/d:CopySettings/dd:Copies\" access=\"readWrite\" />") == nil)
    }

    @Test func Long_choice_lists_and_long_values_are_cut() throws {
        let many = (0..<40).map { "<d:CopyState>junk\($0)</d:CopyState>" }.joined()
        #expect(try Self.read(Self.dyn(), Self.startCap(values: many + "<d:CopyState>start</d:CopyState>")) == nil) // past the 32 choices read
        #expect(try Self.read(Self.dyn(), Self.startCap(values: "<d:CopyState>start\(String(repeating: " ", count: 100))x</d:CopyState>")) == nil)
    }

    @Test func The_whole_elementXPath_is_followed_not_just_its_last_step() throws {
        // A CopyState under CopySettings isn't the root's CopyState the Cap names.
        let nested = Self.dyn("<d:CopySettings><d:CopyState>idle</d:CopyState></d:CopySettings>")
        #expect(try Self.read(nested, Self.startCap()) == nil)
        #expect(try Self.read(nested, Self.startCap("d:CopyConfigDyn/d:CopySettings/d:CopyState"))?.path == ["CopySettings", "CopyState"])
        #expect(try Self.read(nested, Self.startCap("/d:CopySettings[1]/d:CopyState"))?.path == ["CopySettings", "CopyState"]) // without the root, a leading slash, [1]
        // The second of a name: a PUT built from the first of each name couldn't reach it.
        let twice = Self.dyn("<d:CopySettings /><d:CopySettings><d:CopyState>idle</d:CopyState></d:CopySettings>")
        #expect(try Self.read(twice, Self.startCap("d:CopyConfigDyn/d:CopySettings[2]/d:CopyState")) == nil)
        #expect(try Self.read(twice, Self.startCap("d:CopyConfigDyn/d:CopySettings/d:CopyState")) == nil)
        // An element holding elements, not a value.
        #expect(try Self.read(Self.dyn("<d:CopyState><d:Inner>idle</d:Inner></d:CopyState>"), Self.startCap()) == nil)
    }

    @Test(arguments: ["", "/", "d:CopyConfigDyn/d:CopyState[@x='1']", "d:CopyConfigDyn/d:CopyState[0]", "d:CopyConfigDyn/d:CopyState[",
                      "d:CopyConfigDyn//d:CopyState", "d:CopyConfigDyn/*", "d:CopyConfigDyn/b:"])
    func An_elementXPath_it_doesnt_understand_offers_nothing(_ xpath: String) throws {
        #expect(try Self.read(Self.dyn(), Self.startCap(xpath)) == nil)
    }

    @Test func A_very_long_or_deep_elementXPath_offers_nothing() throws {
        #expect(try Self.read(Self.dyn(), Self.startCap(String(repeating: "d:A/", count: 20) + "d:CopyState")) == nil)
        #expect(try Self.read(Self.dyn(), Self.startCap("d:CopyConfigDyn/" + String(repeating: "a", count: 600) + "/d:CopyState")) == nil)
    }

    @Test func Without_an_elementXPath_the_start_is_the_roots_child_named_like_the_entry() throws {
        let cap = "<c:CopyStateSupport access=\"readWrite\"><d:CopyState>start</d:CopyState></c:CopyStateSupport>"
        #expect(try Self.read(Self.dyn(), cap)?.path == ["CopyState"])
        #expect(try Self.read(Self.dyn("<d:CopySettings><d:CopyState>idle</d:CopyState></d:CopySettings>"), cap) == nil) // not anywhere below
    }

    // MARK: which way a copy goes, and what the copy shows

    @Test(arguments: [
        (true, true, false, true),
        (true, false, false, false), // through the computer, Windows' default
        (true, true, true, false), // an ID card is laid out by the computer
        (false, true, false, false), // the printer doesn't offer it
    ])
    func The_printer_copies_by_itself_only_when_it_offers_it_for_a_page_copy_and_it_was_chosen(_ offers: Bool, _ chosen: Bool, _ idCard: Bool, _ expected: Bool) {
        #expect(CopyRoute.onPrinter(offers, chosen, idCard: idCard) == expected)
    }

    @Test func The_printers_own_copier_needs_neither_the_scanner_nor_a_queue() {
        #expect(CopyRoute.blocker(onPrinter: true, scannerChecked: false, hasScanner: false, canPrint: false) == .none)
        #expect(CopyRoute.blocker(onPrinter: false, scannerChecked: false, hasScanner: false, canPrint: false) == .connecting)
        #expect(CopyRoute.blocker(onPrinter: false, scannerChecked: true, hasScanner: false, canPrint: true) == .noScanner)
        #expect(CopyRoute.blocker(onPrinter: false, scannerChecked: true, hasScanner: true, canPrint: false) == .noQueue)
        #expect(CopyRoute.blocker(onPrinter: false, scannerChecked: true, hasScanner: true, canPrint: true) == .none)
    }

    @Test func On_the_printer_no_option_is_shown_its_panel_decides() {
        #expect(CopyRoute.controls(onPrinter: true, idCard: false, copies: 5, queueTwoSided: true) == CopyControls(false, false, false, false, false))
    }

    @Test(arguments: [
        (false, 1, true, CopyControls(true, false, true, true, true)),
        (false, 2, true, CopyControls(true, true, true, true, true)), // collate once there's more than one copy
        (false, 2, false, CopyControls(true, true, true, false, true)), // two-sided only when the queue can
        (true, 2, true, CopyControls(true, false, true, false, false)), // an ID card: one sheet, no collate, no page options
    ])
    func Through_the_PC_the_options_follow_the_copy(_ idCard: Bool, _ copies: Int, _ queueTwoSided: Bool, _ expected: CopyControls) {
        #expect(CopyRoute.controls(onPrinter: false, idCard: idCard, copies: copies, queueTwoSided: queueTwoSided) == expected)
    }

    @Test(arguments: [(0, 1), (-5, 1), (1, 1), (42, 42), (99, 99), (100, 99), (Int.max, 99), (Int.min, 1)])
    func Copies_stay_between_one_and_ninety_nine(_ typed: Int, _ kept: Int) {
        #expect(CopyRoute.clampCopies(typed) == kept)
    }
}
