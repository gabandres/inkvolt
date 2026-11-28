import Foundation
import Testing
@testable import PrintCore

/// USB printers that need their driver (`NeedsDriver`, ported from NeedsDriverTests.cs): a printer-class USB device IOKit
/// lists with no CUPS queue of its model. Windows' spooler, placeholder-driver, port, "Set it up" and protected print mode
/// tests stay with Windows (the Mac has no spooler drivers, ports or such a mode: macOS sets a USB printer up by itself once it
/// has a driver). No real device: the devices are written the way IOKit reports them.
struct NeedsDriverTests {
    static let serial = "VNC3A12345"

    /// An HP LaserJet P1006 as IOKit reports it: printer class, HP's vendor id, named by the device.
    static let p1006 = UsbDevice(vendorId: 0x03F0, productId: 0x3E17, productName: "HP LaserJet P1006", vendorName: "Hewlett-Packard",
                                 interfaceClasses: [7])

    static func queue(_ name: String, uri: String, model: String? = nil, info: String? = nil, temporary: Bool = false, type: Int = 0) -> CupsDestination {
        var o = ["device-uri": uri, "printer-type": String(type)]
        if let model { o["printer-make-and-model"] = model }
        if let info { o["printer-info"] = info }
        if temporary { o["printer-is-temporary"] = "true" }
        return CupsDestination(name: name, options: o)
    }

    static func find(_ devices: UsbDevice..., queues: [CupsDestination] = [], scanners: [SystemScanner] = []) -> [NeedsDriverPrinter] {
        NeedsDriver.find(devices, queues: queues, scanners: scanners)
    }

    @Test(arguments: [nil, ""] as [String?])
    func A_usb_device_with_only_its_vendor_and_product_ids_is_a_usb_printer(_ product: String?) {
        // A printer-class device that names nothing: its ids say nothing a person can read.
        #expect(PrinterNames.forUsb(vendor: nil, product: product) == "USB printer")
        let found = Self.find(UsbDevice(vendorId: 0x03F0, productId: 0x2B17, productName: product, interfaceClasses: [7]))
        #expect(found.map(\.name) == ["USB printer"])
    }

    @Test func A_usb_printer_with_no_queue_needs_its_driver() throws {
        let found = try #require(Self.find(Self.p1006).first)
        #expect(Self.find(Self.p1006).count == 1)
        #expect(found.name == "HP LaserJet P1006")
        #expect(found.maker == "HP")
        #expect(found.usbId == "03F0:3E17")
        #expect(!found.isScanner)
        #expect(NeedsDriver.isNeedsDriverId(found.id))
        #expect(found.id == "usb-needs-driver:printer-03f0-3e17")
        #expect(NeedsDriverText.listStatus(found) == "Plugged in, needs its driver")
    }

    @Test func A_printer_with_its_real_driver_and_a_queue_is_not_listed() {
        // A maker's driver's queue (usb://), and macOS's own driverless queues for IPP over USB (temporary ones too).
        #expect(Self.find(Self.p1006, queues: [Self.queue("HP_LaserJet_P1006", uri: "usb://HP/LaserJet%20P1006?serial=\(Self.serial)")]).isEmpty)
        #expect(Self.find(Self.p1006, queues: [Self.queue("Laser", uri: "usb://HP/Whatever?serial=1", model: "HP LaserJet P1006, hpcups 3.22")]).isEmpty)
        let m234 = UsbDevice(vendorId: 0x03F0, productId: 0x0F2A, productName: "HP LaserJet MFP M234dw", vendorName: "HP", interfaceClasses: [7, 255])
        let ippUsb = Self.queue("HP_LaserJet_MFP_M234dw", uri: "ippusb://HP%20LaserJet%20MFP%20M234dw%20(1A2B3C)._ipp._tcp.local./",
                                info: "HP LaserJet MFP M234dw (1A2B3C)", temporary: true)
        // Its printer part prints; its scanner part, which ImageCaptureCore doesn't list here, is the one left.
        #expect(Self.find(m234, queues: [ippUsb]).map(\.isScanner) == [true])
    }

    @Test func A_queue_of_another_model_or_a_class_or_another_computers_makes_it_no_queue_printer() {
        // Another model; the same model on the network (an IPP queue isn't the USB one); a class; another computer's.
        #expect(Self.find(Self.p1006, queues: [Self.queue("HP_LaserJet_P10065", uri: "usb://HP/LaserJet%20P10065?serial=1")]).count == 1)
        #expect(Self.find(Self.p1006, queues: [Self.queue("HP_LaserJet_P1006", uri: "ipp://192.0.2.20/ipp/print", model: "HP LaserJet P1006")]).count == 1)
        #expect(Self.find(Self.p1006, queues: [Self.queue("Lasers", uri: "usb://HP/LaserJet%20P1006", type: CupsDestination.TypeBit.class)]).count == 1)
        #expect(Self.find(Self.p1006, queues: [Self.queue("P1006_at_desk", uri: "dnssd://x._ipp._tcp.local./", model: "HP LaserJet P1006",
                                                          type: CupsDestination.TypeBit.remote)]).count == 1)
    }

    @Test func Unplugged_it_is_gone() {
        #expect(NeedsDriver.find([], queues: [], scanners: []).isEmpty)
    }

    @Test func A_printer_class_usb_device_with_no_driver_at_all_is_listed_once() {
        // Two of the same model plugged in are one entry (the same ids); a device that isn't a printer is none.
        #expect(Self.find(Self.p1006, Self.p1006).count == 1)
        #expect(Self.find(UsbDevice(vendorId: 0x0781, productId: 0x5581, productName: "Ultra", vendorName: "SanDisk", interfaceClasses: [8])).isEmpty)
        // A printer class on the device itself, not its interfaces.
        #expect(Self.find(UsbDevice(vendorId: 0x03F0, productId: 0x3E17, productName: "HP LaserJet P1006", deviceClass: 7)).count == 1)
    }

    @Test(arguments: [
        ("Hewlett-Packard", "HP LaserJet P1006", "HP LaserJet P1006"),
        ("Hewlett-Packard", "LaserJet P1006", "HP LaserJet P1006"),
        ("HEWLETT-PACKARD", "HP LASERJET P1006", "HP Laserjet P1006"),
        ("EPSON", "EPSON L1110 Series", "Epson L1110 Series"),
        ("EPSON", "L1110 Series", "Epson L1110 Series"),
        ("Brother", "HL-L2350DW series", "Brother HL-L2350DW series"),
        ("Canon", "MG2500 series", "Canon MG2500 series"),
        ("Acme Corp", "Label Writer 9", "Label Writer 9"),
        ("", "Acme Label Writer 9", "Acme Label Writer 9"),
    ])
    func Its_name_comes_from_the_names_the_device_reports(_ vendor: String, _ product: String, _ expected: String) {
        #expect(PrinterNames.forUsb(vendor: vendor, product: product) == expected)
    }

    @Test func A_usb_queues_model_is_read_from_its_uri_never_its_serial() {
        #expect(NeedsDriver.usbUriModel("usb://HP/LaserJet%20P1006?serial=\(Self.serial)") == "HP LaserJet P1006")
        #expect(NeedsDriver.usbUriModel("usb://EPSON/ET-2800%20Series?serial=\(Self.serial)&interface=1") == "EPSON ET-2800 Series")
        #expect(NeedsDriver.usbUriModel("ipp://192.0.2.20/ipp/print") == nil)
        #expect(NeedsDriver.usbUriModel(nil) == nil)
    }

    @Test(arguments: [
        ("HP LaserJet P1006", "HP LaserJet P1006, hpcups 3.22", true),
        ("Epson ET-2800 Series", "EPSON ET-2800 Series", true),
        ("Epson ET-2800 Series", "ET-2800", true),
        ("HP LaserJet MFP M234dw", "HP LaserJet MFP M234dw (1A2B3C) - IPP Everywhere", true),
        ("HP LaserJet P1006", "HP LaserJet P10065", false),
        ("HP LaserJet P1006", "HP LaserJet P1005", false),
        ("HP LaserJet P1006", "", false),
    ])
    func A_queue_is_the_printers_by_its_model(_ shown: String, _ listed: String, _ same: Bool) {
        #expect(PrinterNames.sameModel(shown, listed) == same)
    }

    @Test func Its_maker_picks_the_driver_page_and_others_get_a_web_search() throws {
        let hp = try #require(Self.find(Self.p1006).first)
        #expect(DriverHelp.page(for: hp).absoluteString == "https://support.hp.com/drivers")
        #expect(NeedsDriverText.makerButton(hp) == "Open HP's driver page")
        var acme = hp
        acme.name = "Acme Label Writer 9"
        acme.maker = nil
        #expect(NeedsDriverText.makerButton(acme) == "Search the web for its driver")
        #expect(DriverHelp.page(for: acme).absoluteString.contains("Acme%20Label%20Writer%209%20driver"))
    }

    @Test func No_serial_or_container_in_anything_it_says() throws {
        let queue = Self.queue("Other", uri: "usb://HP/LaserJet%20P10065?serial=\(Self.serial)")
        let all = NeedsDriver.find([Self.p1006, UsbDevice(vendorId: 0x03F0, productId: 0x2B17, interfaceClasses: [7])], queues: [queue], scanners: [])
        #expect(all.count == 2)
        for p in all {
            let said = [p.id, p.name, NeedsDriverText.line(p), NeedsDriverText.statusNote(p), NeedsDriverText.headline(p), NeedsDriverText.stepGetDriver(p),
                        DriverHelp.page(for: p).absoluteString, String(describing: p)]
            for text in said { #expect(!text.localizedCaseInsensitiveContains(Self.serial)) }
        }
        #expect(!NeedsDriverText.reportLine(all).localizedCaseInsensitiveContains(Self.serial))
    }

    @Test func The_cli_says_needs_its_driver() throws {
        let p = try #require(Self.find(Self.p1006).first)
        #expect(NeedsDriverText.line(p) == "HP LaserJet P1006 | USB 03F0:3E17 | maker HP | printer | plugged in, needs its driver")
        #expect(NeedsDriverText.reportLine([p]) == "1: HP LaserJet P1006 (printer), plugged in, needs its driver")
        #expect(NeedsDriverText.reportLine([]) == "none")
    }

    @Test func Its_words_are_spanish_where_the_interface_is() throws {
        let p = try #require(Self.find(Self.p1006).first)
        let table = CoreLanguage.Table(language: "es", sentences: [
            "Plugged in, needs its driver [printer]": "Conectada, le falta su controlador",
            "Plugged in, needs its driver [scanner]": "Conectado, le falta su controlador",
        ])
        CoreLanguage.withTable(table) {
            #expect(NeedsDriverText.listStatus(p) == "Conectada, le falta su controlador")
            var scanner = p
            scanner.kind = .scanner
            #expect(NeedsDriverText.listStatus(scanner) == "Conectado, le falta su controlador")
        }
    }
}
