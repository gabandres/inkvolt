import Foundation
import Testing
@testable import PrintCore

/// USB scanners on the printer list (PrinterListTests.cs's scanner tests, with ImageCaptureCore's scanners for Windows'
/// WIA ones): a scanner goes to the queue printer it belongs to, one no printer claims is listed on its own, a hidden one
/// stays hidden, and a scanner of its own with pages not saved stays.
struct ScannerListTests {
    static let usbScanner = SystemScanner(id: "ICC-0001", name: "Demo Laser 2100", usb: true)
    static let flatbed = SystemScanner(id: "ICC-0002", name: "Demo Photo Scanner 40", usb: true)
    static let networkScanner = SystemScanner(id: "ICC-0003", name: "HP LaserJet MFP M234dw (1A2B3C)", usb: false)

    private static func input(_ listed: [ListedPrinter], _ selected: String?, scanners: [SystemScanner], destinations: [CupsDestination]? = nil,
                              forgotten: [String] = []) -> PrinterListInput {
        var i = PrinterListInput(listed: listed, selected: selected, destinations: destinations, forgotten: forgotten)
        i.scanners = scanners
        return i
    }

    @Test func aScannerGoesToTheQueuePrinterItBelongsToAndOneNoPrinterClaimsIsListedOnItsOwn() {
        let usb = ListedPrinter.forQueue(PrinterListTests.usb)
        let change = PrinterList.reconcile(Self.input([PrinterListTests.network, usb], PrinterListTests.laser,
                                                      scanners: [Self.usbScanner, Self.flatbed, Self.networkScanner]))
        #expect(change.systemScanners?[usb.id] == .some(Self.usbScanner))
        #expect(change.addedScanners == [Self.flatbed]) // the network one scans over eSCL: neither listed nor given
        #expect(change.selected == PrinterListTests.laser)
    }

    @Test func queuesAndScannersInOnePassGiveANewQueuePrinterItsScanner() {
        let change = PrinterList.reconcile(Self.input([PrinterListTests.network], PrinterListTests.laser, scanners: [Self.usbScanner],
                                                      destinations: [PrinterListTests.usb]))
        #expect(change.addedQueues == [PrinterListTests.usb])
        #expect(change.systemScanners?[CupsQueues.id(for: PrinterListTests.usb.name)] == .some(Self.usbScanner))
        #expect(change.addedScanners.isEmpty)
    }

    @Test func aScannerOnItsOwnGoesWhenMacOSDropsItUnlessItHoldsUnsavedScans() {
        let flatbed = ListedPrinter.forScanner(Self.flatbed)
        let change = PrinterList.reconcile(Self.input([PrinterListTests.network, flatbed], flatbed.id, scanners: []))
        #expect(change.removed == [flatbed.id])
        #expect(change.selected == PrinterListTests.laser)

        var keeping = flatbed
        keeping.hasUnsavedScans = true
        let kept = PrinterList.reconcile(Self.input([PrinterListTests.network, keeping], flatbed.id, scanners: []))
        #expect(kept.removed.isEmpty)
        #expect(kept.selected == flatbed.id)
    }

    @Test func aHiddenScannerStaysHiddenUntilMacOSNoLongerHasIt() {
        let id = ScannerMatch.id(for: Self.flatbed)
        #expect(PrinterList.reconcile(Self.input([], nil, scanners: [Self.flatbed], forgotten: [id])).addedScanners.isEmpty)
        #expect(PrinterList.reconcile(Self.input([], nil, scanners: [], forgotten: [id])).unforget == [id])
    }

    @Test(arguments: [
        ("HP LaserJet MFP M234dw (1A2B3C) - IPP Everywhere", "hp laserjet m234dw"),
        ("Hewlett-Packard LaserJet M234dw series", "hp laserjet m234dw"),
        ("EPSON ET-2850 Series", "epson et-2850"),
    ])
    func namesAreComparedWithoutMakersWordsSeriesOrSuffixes(_ name: String, _ key: String) {
        #expect(ScannerMatch.normalized(name) == key)
    }

    @Test func anAmbiguousNameClaimsNothing() {
        let printers = [(id: "a", names: ["Demo Laser 2100"]), (id: "b", names: ["Demo Laser 2100 series"])]
        #expect(ScannerMatch.owner(Self.usbScanner, printers) == nil)
        #expect(ScannerMatch.owner(Self.usbScanner, [printers[0]]) == "a")
        #expect(!ScannerMatch.isScannerId(CupsQueues.id(for: "Demo")))
    }
}
