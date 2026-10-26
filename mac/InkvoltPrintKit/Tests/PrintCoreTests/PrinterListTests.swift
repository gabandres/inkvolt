import Foundation
import Testing
@testable import PrintCore

/// The printer list module (`PrinterList`): queue printers from CUPS, the hidden list and the selection. Ported from
/// PrinterListTests.cs (its queue tests; Windows scanners come with ImageCaptureCore, and CUPS queues aren't renamed:
/// renaming one in Printers & Scanners changes its `printer-info`, not its name).
struct PrinterListTests {
    static let laser = "12345678-1234-4abc-8def-123456789abc"

    static let usb = CupsDestination(name: "Demo_Laser_2100", options: [
        "printer-info": "Demo USB laser", "device-uri": "usb://Demo/Laser%202100?serial=0000", "printer-make-and-model": "Demo Laser 2100",
        "printer-type": "4", "printer-state": "3", "printer-state-reasons": "none",
    ])
    static let tcp = CupsDestination(name: "Office_color_MFP", options: [
        "printer-info": "Office color MFP", "device-uri": "socket://192.0.2.15", "printer-make-and-model": "Demo Color MFP 4400",
        "printer-type": "8", "printer-state": "3",
    ])
    static let pdf = CupsDestination(name: "PDFwriter", options: ["printer-info": "PDFwriter", "device-uri": "pdfwriter:/", "printer-type": "4"])
    static let laserQueue = CupsDestination(name: "HP_LaserJet_MFP_M234dw", options: [
        "printer-info": "HP LaserJet MFP M234dw", "device-uri": "dnssd://HP%20LaserJet%20MFP%20M234dw%20(95BE5B)._ipp._tcp.local./?uuid=\(laser)",
        "printer-make-and-model": "HP LaserJet MFP M234dw - IPP Everywhere", "printer-type": "36948", "printer-state": "3",
    ])

    static let network = ListedPrinter(id: laser, kind: .network, name: "HP LaserJet MFP M234dw (95BE5B)", model: "HP LaserJet MFP M234dw",
                                       hosts: ["192.0.2.10", "NPI95BE5B.local"])

    private static func input(_ listed: [ListedPrinter], _ selected: String? = nil, _ destinations: [CupsDestination]?, sweepDone: Bool = true,
                              forgotten: [String] = []) -> PrinterListInput {
        PrinterListInput(listed: listed, selected: selected, destinations: destinations, sweepDone: sweepDone, forgotten: forgotten)
    }

    /// The list after the change, as the caller makes it.
    private static func apply(_ listed: [ListedPrinter], _ change: PrinterListChange) -> [ListedPrinter] {
        listed.filter { !change.removed.contains($0.id) } + change.addedQueues.map(ListedPrinter.forQueue)
    }

    @Test func realQueuesNoNetworkPrinterStandsForAreListed() {
        let change = PrinterList.reconcile(Self.input([Self.network], Self.laser, [Self.usb, Self.tcp, Self.pdf, Self.laserQueue]))

        #expect(change.addedQueues == [Self.usb, Self.tcp]) // not the PDF printer, not the laser's own queue
        #expect(change.removed.isEmpty)
        #expect(change.selected == Self.laser)
    }

    @Test func networkQueuesWaitForDiscoverysFirstSweep() {
        let change = PrinterList.reconcile(Self.input([], nil, [Self.usb, Self.tcp], sweepDone: false))

        #expect(change.addedQueues == [Self.usb])
        #expect(change.selected == CupsQueues.id(for: Self.usb.name)) // nothing was selected
    }

    @Test func aQueueTheUserRemovedStaysHiddenUntilMacOSNoLongerHasIt() {
        let hidden = CupsQueues.id(for: Self.usb.name)
        let change = PrinterList.reconcile(Self.input([], nil, [Self.usb, Self.tcp], forgotten: [hidden]))
        #expect(change.addedQueues == [Self.tcp])
        #expect(change.unforget.isEmpty)

        #expect(PrinterList.reconcile(Self.input([], nil, [Self.tcp], forgotten: [hidden])).unforget == [hidden])
        #expect(PrinterList.reconcile(Self.input([], nil, [], forgotten: [hidden])).unforget.isEmpty) // no queues read: nothing to go by
    }

    @Test func aQueueANetworkPrinterNowStandsForGoesAndTheSelectionMovesToThatPrinter() {
        let queue = ListedPrinter.forQueue(Self.laserQueue)

        let change = PrinterList.reconcile(Self.input([Self.network, queue], queue.id, [Self.laserQueue]))

        #expect(change.removed == [queue.id])
        #expect(change.selected == Self.laser)
    }

    @Test func aQueueChosenLastTimeIsSelectedWhenItIsListed() {
        var input = Self.input([Self.network], Self.laser, [Self.usb, Self.tcp])
        input.wantedQueue = CupsQueues.id(for: Self.tcp.name)
        let change = PrinterList.reconcile(input)

        #expect(change.selected == CupsQueues.id(for: Self.tcp.name))
        #expect(change.wantedQueue == nil) // the sweep is done: not waited for any more
    }

    @Test func aQueueMacOSNoLongerHasGoesAndTheFirstIsSelected() {
        let usb = ListedPrinter.forQueue(Self.usb)
        let change = PrinterList.reconcile(Self.input([Self.network, usb], usb.id, []))

        #expect(change.removed == [usb.id])
        #expect(change.selected == Self.laser)
    }

    @Test func removingANetworkPrinterHidesItsQueuesWithIt() {
        #expect(PrinterList.hiddenWith(Self.network, [Self.usb, Self.laserQueue, Self.pdf]) == [Self.laser, CupsQueues.id(for: Self.laserQueue.name)])
        #expect(PrinterList.hiddenWith(.forQueue(Self.usb), [Self.usb]) == [CupsQueues.id(for: Self.usb.name)])
    }

    @Test func applyingAChangeTwiceChangesNothingMore() {
        let listed = [Self.network]
        let destinations = [Self.usb, Self.tcp, Self.laserQueue]
        let first = PrinterList.reconcile(Self.input(listed, Self.laser, destinations))
        let second = PrinterList.reconcile(Self.input(Self.apply(listed, first), first.selected, destinations))

        #expect(!second.changes)
        #expect(second.selected == first.selected)
    }

    @Test func theMadeUpMacsQueuesAddThreePrinters() {
        let listed = Demo.state().printers.map { ListedPrinter(id: $0.uuid, kind: .network, name: $0.name, model: $0.model, hosts: [$0.host]) }
        let change = PrinterList.reconcile(PrinterListInput(listed: listed, selected: Demo.uuid, destinations: Demo.destinations))
        #expect(change.addedQueues.map(\.displayName) == ["Demo USB laser", "Front desk @ demo-mac", "Office color MFP"])
        #expect(change.selected == Demo.uuid)
        let shared = CupsStatus.view(Demo.destinations[1])
        #expect(shared.phase == .offline)
        #expect(CupsStatus.view(Demo.destinations[0]).severity == .warning) // toner low
    }
}
