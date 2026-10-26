import Foundation
import Testing
@testable import PrintCore

/// What the Mac app's printer list and menu bar are made of: Bonjour's services joined into printers, the remembered state,
/// supplies as the pane words them, the menu's lines. New for the Mac (the Windows app's join sits in its Windows-only
/// discovery; its supply wording and tray lines in view models without tests of their own).
struct PrinterPaneTests {
    private static let uuid = "12345678-1234-4abc-8def-123456789abc"

    private static func service(_ type: String, _ instance: String = "Office laser", uuid: String? = PrinterPaneTests.uuid, host: String? = "npi1.local",
                                ipv4: String? = "192.0.2.10", port: Int? = nil, txt: [String: String] = [:]) -> AnnouncedService {
        var txt = txt
        if let uuid { txt["UUID"] = uuid }
        return AnnouncedService(instance: instance, dnssd: DnssdService(service: type, uuid: uuid, hostName: host, ipv4: ipv4, port: port, txt: txt))
    }

    // MARK: Discovery

    @Test func aPrintersServicesJoinIntoOnePrinterWithItsIppAndScanAddresses() {
        let printers = DiscoveredPrinters.join([
            Self.service("_ipps._tcp", port: 631, txt: ["ty": "HP LaserJet MFP M234dw", "rp": "ipp/print"]),
            Self.service("_ipp._tcp", port: 631, txt: ["ty": "HP LaserJet MFP M234dw", "rp": "ipp/print"]),
            Self.service("_uscan._tcp", port: 8080, txt: ["rs": "eSCL"]),
        ])
        #expect(printers.count == 1)
        let p = printers[0]
        #expect(p.uuid == Self.uuid)
        #expect(p.name == "Office laser")
        #expect(p.model == "HP LaserJet MFP M234dw")
        #expect(p.host == "192.0.2.10")
        #expect(p.ippUri?.absoluteString == "http://192.0.2.10:631/ipp/print") // plain IPP when it offers both
        #expect(p.esclRoot?.absoluteString == "http://192.0.2.10:8080/eSCL/")
        #expect(p.hasScanner)
        #expect(p.addresses == ["192.0.2.10"])
    }

    @Test func aServiceWithoutUuidJoinsItsHostsOtherServicesAndOnlyPrintersWithAnAddressAreListed() {
        let printers = DiscoveredPrinters.join([
            Self.service("_ipps._tcp", "B printer"),
            Self.service("_uscans._tcp", "B printer", uuid: nil),
            Self.service("_ipp._tcp", "A printer", uuid: "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b", host: "a.local", ipv4: "192.0.2.11"),
            Self.service("_ipp._tcp", "No address", uuid: "3c9a7e51-8d2b-4f60-a1e4-5b7c9d0e2f13", host: "c.local", ipv4: nil),
            Self.service("_ipp._tcp", "No UUID anywhere", uuid: nil, host: "d.local", ipv4: "192.0.2.13"),
        ])
        #expect(printers.map(\.name) == ["A printer", "B printer"])
        #expect(printers[1].ippUri?.absoluteString == "https://192.0.2.10:631/ipp/print") // IPPS only: https
        #expect(printers[1].esclRoot?.absoluteString == "https://192.0.2.10/eSCL/")
    }

    @Test func twoDevicesClaimingOneUuidListEveryAddress() {
        let printers = DiscoveredPrinters.join([
            Self.service("_ipp._tcp", host: "a.local", ipv4: "192.0.2.10"),
            Self.service("_uscan._tcp", host: "b.local", ipv4: "192.0.2.20"),
        ])
        #expect(printers.count == 1)
        #expect(printers[0].addresses == ["192.0.2.10", "192.0.2.20"])
    }

    // MARK: State

    @Test func theStateIsSavedOnEachChangeAndReadBack() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        let store = StateStore(file: file)
        store.remember(KnownPrinter(uuid: Self.uuid, name: "Laser", host: "192.0.2.10"))
        store.remember(KnownPrinter(uuid: Self.uuid.uppercased(), name: "Laser", model: "M234dw", host: "192.0.2.23"))
        store.accept(Self.uuid, ["87654321-4321-4cba-8fed-cba987654321"])
        #expect(store.setPinIfAbsent(Self.uuid, port: 443, "AA") == "AA")
        #expect(store.setPinIfAbsent(Self.uuid, port: 443, "BB") == "AA") // never overwritten
        #expect(store.pins(Self.uuid).setIfAbsent(631, "CC") == "CC")

        let again = StateStore(file: file)
        #expect(again.current.printers == [KnownPrinter(uuid: Self.uuid.uppercased(), name: "Laser", model: "M234dw", host: "192.0.2.23")])
        #expect(again.accepted(Self.uuid.uppercased()) == ["87654321-4321-4cba-8fed-cba987654321"])
        #expect(again.pin(Self.uuid, port: 443) == "AA")
        #expect(again.pin(Self.uuid, port: 631) == "CC")
        again.clearPins(Self.uuid)
        #expect(again.pin(Self.uuid, port: 631) == nil)

        again.remove(Self.uuid)
        #expect(StateStore(file: file).current.printers.isEmpty)
        #expect(again.isForgotten(Self.uuid.uppercased()))
    }

    @Test func anUnreadableStateFileStartsEmptyAndIsKeptAside() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-state-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("state.json")
        try Data("{ not json".utf8).write(to: file)
        #expect(StateStore(file: file).current == PrintState())
        #expect(FileManager.default.fileExists(atPath: file.appendingPathExtension("bad").path))
        // A file from a version with fields this one doesn't know still loads.
        try Data(#"{"printers":[],"selectedUuid":"x","later":1}"#.utf8).write(to: file)
        #expect(StateStore(file: file).current.selectedUuid == "x")
    }

    @Test func demoModesStateIsInMemoryAndRemembersItsPrinters() {
        let store = StateStore(memory: Demo.state())
        #expect(store.isInMemory)
        #expect(store.current.printers.count == 5)
        #expect(store.current.selectedUuid == Demo.uuid)
        #expect(store.current.printers.allSatisfy { $0.host.hasPrefix("192.0.2.") })
    }

    // MARK: Supplies

    private static let us = Locale(identifier: "en_US")

    private static func supply(_ state: String, percent: Int? = nil, pages: Int? = nil, kind: String = "toner", threshold: Int? = nil) -> SupplyText {
        SupplyText(Consumable(name: "Black toner", kind: kind, colorCode: kind == "toner" ? "K" : nil, percentRemaining: percent, state: state,
                              productNumber: "W1360A", selectibilityNumber: kind == "toner" ? "136A" : nil, lowThreshold: threshold,
                              estimatedPagesRemaining: pages), locale: us)
    }

    @Test func suppliesAreWordedAsThePaneShowsThem() {
        let ok = Self.supply("ok", percent: 45, pages: 1200)
        #expect(ok.headline == "About 1,200 pages left")
        #expect(ok.percentText == "45%")
        #expect(ok.fraction == 0.45)
        #expect(ok.level == .ok)
        #expect(ok.cartridge == "Replacement: HP 136A  ·  W1360A")
        #expect(ok.accessibleText == "Black toner, 45%, About 1,200 pages left")

        #expect(Self.supply("low", percent: 9).headline == "Running low")
        #expect(Self.supply("ok", percent: 9, threshold: 10).level == .low)
        #expect(Self.supply("out", percent: 0).headline == "Empty — replace now")
        #expect(Self.supply("out", percent: 0).level == .empty)
        #expect(Self.supply("missing").percentText == "Missing")
        #expect(Self.supply("missing").headline == "Missing — install it")

        let box = Self.supply("ok", kind: "wasteToner")
        #expect(box.headline == nil)
        #expect(box.percentText == "OK")
        #expect(box.fraction == nil)
        #expect(box.accessibleText == "Black toner, OK")
        #expect(Self.supply("almostFull", kind: "wasteToner").headline == "Replace soon")
        #expect(Self.supply("weird", kind: "wasteToner").percentText == "—")
    }

    // MARK: Menu bar

    @Test func aPrinterNotAnsweringIsGreyInTheMenuAtOnceAndItsProblemComesFirst() {
        var view = PrinterView.connecting
        view.phase = .offline
        view.statusMessage = "Can't reach the printer"
        #expect(TrayText.line(name: "Laser", tracked: .ok, problem: nil, view: view) == PrinterLine(name: "Laser", level: .offline, text: "Can't reach the printer"))
        #expect(TrayText.line(name: "Laser", tracked: .error, problem: "Paper jam", view: view).level == .error)
        view.phase = .online
        view.statusMessage = "Ready"
        #expect(TrayText.line(name: "Laser", tracked: .warning, problem: "Black toner low", view: view)
            == PrinterLine(name: "Laser", level: .warning, text: "Black toner low"))
        view.phase = .connecting
        #expect(TrayText.line(name: "Laser", tracked: .ok, problem: nil, view: view).level == .ok)
    }

    @Test func oneAlertIsShownAsItIsAndSeveralAsALineEach() {
        let jam = AlertNotice(uuid: Self.uuid, printerName: "Laser", kind: .paperJam, title: "Paper jam", body: "Clear the jam.")
        let low = AlertNotice(uuid: Self.uuid, printerName: "Inkjet", kind: .supplyLow, title: "Cyan ink low", body: "About 50 pages left.")
        #expect(TrayText.notice([jam]) == ("Paper jam", "Clear the jam."))
        #expect(TrayText.notice([jam, low]) == ("2 printer alerts", "Laser: Paper jam\nInkjet: Cyan ink low"))
    }
}
