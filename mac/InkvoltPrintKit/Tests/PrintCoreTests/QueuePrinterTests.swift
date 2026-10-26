import Foundation
import Testing
@testable import PrintCore

/// Queue printers on the Mac: which CUPS destinations are printers of their own, how this Mac reaches them, and their state
/// in plain words. The Mac's counterpart of QueuePrinterTests.cs (its spooler bits become IPP's printer-state-reasons, which
/// cupsd keeps per queue).
struct QueuePrinterTests {
    private static func queue(_ name: String, _ uri: String, info: String? = nil, model: String? = nil, type: Int = 4, state: Int = 3,
                              reasons: String = "none", accepting: Bool = true, jobs: Int? = nil, extra: [String: String] = [:]) -> CupsDestination {
        var o = ["device-uri": uri, "printer-type": String(type), "printer-state": String(state), "printer-state-reasons": reasons,
                 "printer-is-accepting-jobs": accepting ? "true" : "false"]
        if let info { o["printer-info"] = info }
        if let model { o["printer-make-and-model"] = model }
        o.merge(extra) { $1 }
        return CupsDestination(name: name, options: o, jobs: jobs)
    }

    // MARK: Kinds

    @Test(arguments: [
        ("usb://Demo/Laser?serial=1", "USB"),
        ("dnssd://Demo%20Laser._ipp._tcp.local./?uuid=0e1f2a3b-0000-4000-8000-000000000001", "Network"),
        ("ipp://192.0.2.40/ipp/print", "Network"),
        ("socket://192.0.2.40:9100", "Network"),
        ("lpd://printer.example/queue", "Network"),
        ("smb://office-pc/Front%20desk", "Shared from office-pc"),
        ("dnssd://Front%20desk%20%40%20office-mac._ipp._tcp.local./cups?uuid=0e1f2a3b-0000-4000-8000-000000000002", "Network"),
        ("serial:/dev/cu.serial", "Set up on this Mac"),
    ])
    func theConnectionComesFromTheDeviceUri(_ uri: String, _ text: String) {
        #expect(CupsQueues.connectionText(Self.queue("Example", uri)) == text)
    }

    @Test func aPrinterSharedFromAnotherMacSaysWhich() {
        let shared = Self.queue("Front_desk", "dnssd://Front%20desk%20%40%20office-mac._ipp._tcp.local./cups?uuid=0e1f2a3b-0000-4000-8000-000000000002",
                                type: 4 | CupsDestination.TypeBit.remote)
        #expect(CupsQueues.connection(shared) == .shared)
        #expect(CupsQueues.connectionText(shared) == "Shared from office-mac")
    }

    @Test(arguments: [
        ("usb://Demo/Laser?serial=1", "USB"),
        ("socket://192.0.2.40:9100", "Network (192.0.2.40)"),
        ("ipp://NPI1A2B3C.local/ipp/print", "Network (NPI1A2B3C.local)"),
        ("ipp://Demo%20Laser._ipp._tcp.local./", "Network (Bonjour)"),
    ])
    func theConnectionDetailSaysWhere(_ uri: String, _ detail: String) {
        #expect(CupsQueues.connectionDetail(Self.queue("Example", uri)) == detail)
    }

    @Test func faxesClassesPdfWritersAndBonjoursTemporaryDestinationsAreNotPrintersOfTheirOwn() {
        #expect(CupsQueues.isVirtual(Self.queue("Fax", "dnssd://Demo%20Fax._ipp._tcp.local./?uuid=0e1f2a3b-0000-4000-8000-000000000003",
                                                type: 4 | CupsDestination.TypeBit.fax)))
        #expect(CupsQueues.isVirtual(Self.queue("Office", "", type: CupsDestination.TypeBit.class)))
        #expect(CupsQueues.isVirtual(Self.queue("PDFwriter", "pdfwriter:/")))
        #expect(CupsQueues.isVirtual(Self.queue("Save_as_PDF", "file:///dev/null")))
        let temporary = Self.queue("Demo_Laser", "ipp://Demo%20Laser._ipp._tcp.local./", type: 4 | CupsDestination.TypeBit.discovered)
        #expect(!CupsQueues.isRealQueue(temporary))
        #expect(CupsQueues.isRealQueue(Self.queue("Demo_Laser", "usb://Demo/Laser")))
    }

    @Test func queueIdsAreStableAndNeverLookLikeAUuid() {
        let id = CupsQueues.id(for: "Example_Inkjet_3700")
        #expect(id == CupsQueues.id(for: "example_inkjet_3700"))
        #expect(CupsQueues.isQueueId(id))
        #expect(!PrinterId.isValid(id))
        #expect(!CupsQueues.isQueueId("12345678-1234-4abc-8def-123456789abc"))
    }

    @Test func theNameIsPrinterInfoElseTheQueuesName() {
        #expect(Self.queue("Front_desk", "usb://x", info: "Front desk laser").displayName == "Front desk laser")
        #expect(Self.queue("Front_desk", "usb://x").displayName == "Front desk")
    }

    // MARK: Status

    @Test func anIdleQueueIsReady() {
        let r = CupsStatus.describe(Self.queue("Example", "usb://x"))
        #expect(r.status.code == "ready")
        #expect(r.status.message == "Ready")
        #expect(r.status.severity == .info)
        #expect(r.status.alerts.isEmpty)
        #expect(!r.offline)
    }

    @Test(arguments: [
        ("media-jam-error", "Paper jam", "media-jam"),
        ("media-empty-error", "Out of paper", "media-empty"),
        ("door-open-error", "A door is open", "door-open"),
        ("toner-empty-error", "Toner empty", "toner-empty"),
    ])
    func problemsAreErrors(_ reason: String, _ message: String, _ id: String) throws {
        let r = CupsStatus.describe(Self.queue("Example", "usb://x", state: 5, reasons: reason))
        #expect(r.status.message == message)
        #expect(r.status.severity == .error)
        #expect(try #require(r.status.alerts.first).id == id)
        #expect(!r.offline)
    }

    @Test func tonerLowIsAWarningBesideReady() throws {
        let r = CupsStatus.describe(Self.queue("Example", "usb://x", reasons: "toner-low-warning"))
        #expect(r.status.message == "Ready")
        #expect(r.status.severity == .warning)
        #expect(try #require(r.status.alerts.first).id == "toner-low")
    }

    @Test func severalProblemsLeadWithTheWorst() {
        let r = CupsStatus.describe(Self.queue("Example", "usb://x", state: 5, reasons: "toner-low-warning,media-jam-error"))
        #expect(r.status.message == "Paper jam")
        #expect(r.status.alerts.map(\.id) == ["toner-low", "media-jam"])
    }

    @Test func printingIsInfo() {
        #expect(CupsStatus.describe(Self.queue("Example", "usb://x", state: 4)).status.message == "Printing")
    }

    @Test func aPausedQueueHoldsJobs() {
        let r = CupsStatus.describe(Self.queue("Example", "usb://x", state: 5, reasons: "paused", jobs: 2))
        #expect(r.status.code == "paused")
        #expect(r.status.message == "Paused in macOS")
        #expect(r.status.severity == .warning)
        #expect(r.status.detail?.contains("2 jobs") == true)
        #expect(!r.offline)
    }

    @Test func aQueueNotAcceptingJobsSaysSo() {
        let r = CupsStatus.describe(Self.queue("Example", "usb://x", accepting: false, jobs: 1))
        #expect(r.status.code == "rejecting")
        #expect(r.status.detail?.contains("1 job is waiting") == true)
    }

    @Test func offlineSaysToCheckTheCableOrTheNetwork() {
        let usb = CupsStatus.describe(Self.queue("Example", "usb://x", reasons: "offline-report"))
        #expect(usb.offline)
        #expect(usb.status.code == "offline")
        #expect(usb.status.severity == .error)
        #expect(usb.status.detail?.contains("USB cable") == true)
        #expect(CupsStatus.describe(Self.queue("Example", "socket://192.0.2.40", reasons: "offline-report")).status.detail?.contains("network") == true)
    }

    @Test func cupssNotesAboutItselfAreNoProblem() {
        let r = CupsStatus.describe(Self.queue("Example", "usb://x", reasons: "cups-waiting-for-job-completed,cups-ipp-conformance-failure-report"))
        #expect(r.status.severity == .info)
        #expect(r.status.alerts.isEmpty)
    }

    @Test func suppliesComeFromTheQueuesMarkers() throws {
        let q = Self.queue("Example", "usb://x", extra: [
            "marker-names": "Black Toner,Cyan\\, Magenta and Yellow", "marker-levels": "20,85", "marker-low-levels": "10,10",
            "marker-types": "toner,toner", "marker-colors": "#000000,#00FFFF#FF00FF#FFFF00",
        ])
        let s = CupsStatus.supplies(q)
        #expect(s.map(\.name) == ["Black Toner", "Cyan, Magenta and Yellow"])
        #expect(s.map(\.percentRemaining) == [20, 85])
        #expect(try #require(s.first).colorCode == "K")
    }

    @Test(arguments: [
        ("a,b", ["a", "b"]),
        ("a\\,b,c", ["a,b", "c"]),
        ("\"a,b\",c", ["a,b", "c"]),
        ("", [String]()),
    ])
    func listOptionsSplitOnUnescapedCommas(_ text: String, _ values: [String]) {
        #expect(CupsDestination.list(text) == values)
    }

    // MARK: Duplicates

    @Test func queuesANetworkPrinterAlreadyHasAreNotListedAgain() {
        let uuid = "0e1f2a3b-0000-4000-8000-000000000001"
        let known = [QueueClaim(id: uuid, name: "Example Laser 2100 (1A2B3C)", model: "Example Laser 2100", hosts: ["192.0.2.10", "NPI1A2B3C.local"], uuids: [uuid])]
        let queues = [
            Self.queue("Laser_bonjour", "dnssd://Somewhere._ipp._tcp.local./?uuid=\(uuid)"),           // its UUID
            Self.queue("Office_copy", "socket://192.0.2.10"),                                           // its address
            Self.queue("Front", "ipp://NPI1A2B3C.local./ipp/print"),                                    // its Bonjour host name
            Self.queue("Service", "ipp://Example%20Laser%202100%20(1A2B3C)._ipp._tcp.local./"),        // its Bonjour service
            Self.queue("Example_Laser_2100", "lpd://printer.example/queue", info: "Example Laser 2100"), // its model, unambiguous
            Self.queue("Example_Inkjet_3700", "usb://Example/Inkjet", info: "Example Inkjet 3700"),     // a USB printer: kept
            Self.queue("PDFwriter", "pdfwriter:/"),                                                     // virtual: left out
        ]
        #expect(CupsQueues.unclaimed(queues, known).map(\.name) == ["Example_Inkjet_3700"])
    }

    @Test func anAmbiguousNameClaimsNothing() {
        let known = [QueueClaim(id: "a", name: "Example Laser"), QueueClaim(id: "b", name: "Example Laser 2100")]
        #expect(CupsQueues.claim(Self.queue("Example_Laser_2100", "usb://x", info: "Example Laser 2100"), known) == nil)
    }

    @Test func withoutNetworkPrintersEveryRealQueueShows() {
        let queues = [Self.queue("Example_Inkjet_3700", "usb://x"), Self.queue("Office_laser", "socket://192.0.2.40")]
        #expect(CupsQueues.unclaimed(queues, []).count == 2)
    }

    @Test func theAddressToAskIsANetworkQueuesHostNotABonjourName() {
        #expect(CupsQueues.address(Self.queue("A", "socket://192.0.2.40:9100")) == "192.0.2.40")
        #expect(CupsQueues.address(Self.queue("A", "ipp://Demo._ipp._tcp.local./")) == nil)
        #expect(CupsQueues.address(Self.queue("A", "usb://x")) == nil)
    }
}
