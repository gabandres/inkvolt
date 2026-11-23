import Testing
@testable import PrintCore

/// Share a printer with phones (roadmap 4.10). Windows serves its queues itself (PrinterSharingTests.cs: the IPP server, mDNS,
/// raster); a sandboxed Mac app may not, and macOS's own Printer Sharing already shares a CUPS queue over IPP and Bonjour, so
/// the Mac only says, per queue printer, whether macOS shares it (`printer-is-shared`) and points to System Settings. Ported:
/// Queues_that_save_a_file_or_hand_to_an_app_arent_shared (by device URI and CUPS's printer-type bits, where Windows reads the
/// port and driver). Mac only: aQueuesSharingIsWhatCupsSays. The rest is Windows' server (PLAN, "Mac differences").
struct PrinterSharingTests {
    private static func queue(_ uri: String, type: Int = 0, shared: String? = nil, temporary: Bool = false) -> CupsDestination {
        var options = ["device-uri": uri, "printer-type": String(type)]
        if let shared { options["printer-is-shared"] = shared }
        if temporary { options["printer-is-temporary"] = "true" }
        return CupsDestination(name: "q", options: options)
    }

    @Test(arguments: [
        ("usb://Brother/HL-L2350DW%20series", 0, true),
        ("ipp://192.0.2.11/ipp/print", 0, true),
        ("dnssd://Demo%20Laser._ipp._tcp.local./?uuid=00000000-0000-0000-0000-000000000000", 0, true),
        ("lpd://192.0.2.12/queue", 0, true),
        ("file:///dev/null", 0, false),
        ("cups-pdf:/", 0, false),
        ("PDFwriter:/", 0, false),
        ("ipp://192.0.2.11/ipp/print", CupsDestination.TypeBit.fax, false),
        ("ipp://192.0.2.13/printers/Office", CupsDestination.TypeBit.remote, false),
        ("", CupsDestination.TypeBit.class, false),
    ])
    func queuesThatSaveAFileOrHandToAnAppArentShared(_ uri: String, _ type: Int, _ shared: Bool) {
        #expect(PrinterSharing.canShare(Self.queue(uri, type: type)) == shared)
    }

    @Test func aQueuesSharingIsWhatCupsSays() {
        #expect(PrinterSharing.state(Self.queue("usb://Brother/HL", shared: "true")) == .shared)
        #expect(PrinterSharing.state(Self.queue("usb://Brother/HL", shared: "false")) == .notShared)
        #expect(PrinterSharing.state(Self.queue("usb://Brother/HL")) == .notSaid)
        #expect(PrinterSharing.state(Self.queue("file:///dev/null", shared: "true")) == nil) // never offered
        #expect(PrinterSharing.state(Self.queue("ipp://192.0.2.11/ipp/print", shared: "true", temporary: true)) == nil)
    }
}
