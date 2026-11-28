import Foundation
import Testing
@testable import PrintCore

/// USB scanners that need their driver (`UsbScanners`, listed by `NeedsDriver.find`), ported from UsbScannerTests.cs's
/// needs-driver half: a scanner IOKit lists that ImageCaptureCore doesn't (no maker's driver). Windows' driver problem codes
/// stay with Windows: on the Mac a scanner "has its driver" when ImageCaptureCore lists it.
extension UsbScannerTests {
    /// The Epson Perfection V19 as IOKit reports it: its maker's own class, named by the device.
    static let v19 = UsbDevice(vendorId: 0x04B8, productId: 0x013C, productName: "Perfection V19", vendorName: "EPSON", deviceClass: 0,
                               interfaceClasses: [255])

    static func needing(_ devices: UsbDevice..., queues: [CupsDestination] = [], scanners: [SystemScanner] = []) -> [NeedsDriverPrinter] {
        NeedsDriver.find(devices, queues: queues, scanners: scanners)
    }

    static func device(_ vid: Int, _ name: String, _ classes: [Int]) -> UsbDevice {
        UsbDevice(vendorId: vid, productId: 0x0001, productName: name, interfaceClasses: classes)
    }

    @Test func The_V19_with_no_driver_is_a_scanner_that_needs_its_driver_named_by_the_bus() throws {
        let s = try #require(Self.needing(Self.v19).first)
        #expect(Self.needing(Self.v19).count == 1)
        #expect(s.isScanner)
        #expect(s.name == "Epson Perfection V19")
        #expect(s.maker == "Epson")
        #expect(s.usbId == "04B8:013C")
        #expect(s.id == "usb-needs-driver:scanner-04b8-013c")
        #expect(NeedsDriverText.englishStatus == "plugged in, needs its driver")
        #expect(NeedsDriverText.listStatus(s) == "Plugged in, needs its driver")
    }

    @Test func A_scanner_with_a_working_driver_or_unplugged_is_not_listed() {
        // ImageCaptureCore lists it (its maker's driver is installed): by its USB ids, or by its model.
        #expect(Self.needing(Self.v19, scanners: [SystemScanner(id: "ica-1", name: "Some name", usb: true, usbId: "04B8:013C")]).isEmpty)
        #expect(Self.needing(Self.v19, scanners: [SystemScanner(id: "ica-1", name: "EPSON Perfection V19", usb: true)]).isEmpty)
        // A network scanner of the same name is another device.
        #expect(Self.needing(Self.v19, scanners: [SystemScanner(id: "net", name: "EPSON Perfection V19", usb: false)]).count == 1)
        #expect(NeedsDriver.find([], queues: [], scanners: []).isEmpty)
    }

    @Test func A_still_image_device_of_any_maker_is_a_scanner_with_a_name_of_its_own() throws {
        let s = try #require(Self.needing(UsbDevice(vendorId: 0x1234, productId: 0x5678, productName: "DocuScan 300", interfaceClasses: [6])).first)
        #expect(s.name == "DocuScan 300")
        #expect(s.maker == nil)
    }

    @Test(arguments: [
        (0x04E8, "Galaxy S24", [6]), // Samsung phone in PTP mode
        (0x03F0, "HP Webcam HD 4310", [255]), // HP makes webcams
        (0x03F0, "HP USB Optical Mouse", [255]),
        (0x04B8, "EPSON USB Device", [255]), // an Epson that says nothing of scanning
        (0x04A9, "Canon EOS R6 camera", [6]), // a camera
        (0x04A9, "Canon EOS R6", [6]), // a camera that doesn't say so
        (0x04A9, "Canon PowerShot G7 X Mark III", [6]),
        (0x04B0, "Nikon Z 6II", [6]),
        (0x05AC, "Apple iPhone", [6]),
        (0x2717, "Redmi Note 13", [6]), // a phone in PTP mode, named by its model only
        (0x04E8, "SM-S921B", [6]),
        (0x18D1, "Pixel 9", [255]), // not a scanner maker
    ])
    func A_phone_a_camera_a_webcam_or_an_unnamed_device_is_not_a_scanner(_ vid: Int, _ name: String, _ classes: [Int]) {
        #expect(Self.needing(Self.device(vid, name, classes)).isEmpty)
    }

    @Test(arguments: [
        (0x04A9, "CanoScan LiDE 300", "Canon"),
        (0x04C5, "ScanSnap iX1600", "Fujitsu"),
        (0x03F0, "HP ScanJet Pro 2600 f1", "HP"),
        (0x04F9, "Brother ADS-1700W", "Brother"),
        (0x07B3, "Plustek OpticFilm 8200i", "Plustek"),
    ])
    func A_scanner_makers_scanner_or_all_in_one_is_listed_with_its_maker(_ vid: Int, _ name: String, _ maker: String) {
        #expect(Self.needing(Self.device(vid, name, [255])).map(\.maker) == [maker])
    }

    @Test func An_all_in_ones_scanner_part_is_listed_when_its_printer_part_prints() throws {
        // The usual case: an Epson ET prints through its queue (driverless), its scanner part has no driver.
        let et = UsbDevice(vendorId: 0x04B8, productId: 0x1186, productName: "ET-2800 Series", vendorName: "EPSON", interfaceClasses: [255, 7],
                           interfaceNames: ["EPSON ET-2800 Series MFP"])
        let queue = NeedsDriverTests.queue("EPSON_ET_2800_Series", uri: "usb://EPSON/ET-2800%20Series?serial=1", model: "EPSON ET-2800 Series")
        let s = try #require(Self.needing(et, queues: [queue]).first)
        #expect(Self.needing(et, queues: [queue]).count == 1)
        #expect(s.isScanner)
        #expect(s.name == "Epson ET-2800 Series")
        // The HP LaserJet MFP M140we names its kind: its scanner part is one too.
        let mfp = UsbDevice(vendorId: 0x03F0, productId: 0x0001, productName: "HP LaserJet MFP M140we", interfaceClasses: [7, 255])
        let hpQueue = NeedsDriverTests.queue("HP_LaserJet_MFP_M140we", uri: "usb://HP/LaserJet%20MFP%20M140we?serial=1")
        #expect(Self.needing(mfp, queues: [hpQueue]).map(\.maker) == ["HP"])
    }

    @Test func A_still_image_device_from_a_scanner_maker_that_says_nothing_of_cameras_is_a_scanner() {
        #expect(Self.needing(UsbDevice(vendorId: 0x04A9, productId: 0x1234, productName: "Canon DR-C225", interfaceClasses: [6])).count == 1)
    }

    @Test func An_all_in_ones_scanner_part_is_not_listed_again_beside_its_printer() throws {
        let et = UsbDevice(vendorId: 0x04B8, productId: 0x1186, productName: "ET-2800 Series", vendorName: "EPSON", interfaceClasses: [255, 7],
                           interfaceNames: ["EPSON ET-2800 Series MFP"])
        let found = try #require(Self.needing(et).first) // no queue: its printer part is listed, once
        #expect(Self.needing(et).count == 1)
        #expect(!found.isScanner)
    }

    @Test func Placeholder_names_give_way_to_the_makers_and_long_names_are_shortened() {
        var unnamed = Self.v19
        unnamed.productName = nil
        #expect(UsbScanners.name(of: unnamed) == "Epson scanner")
        var named = Self.v19
        named.productName = "EPSON Perfection V19"
        #expect(UsbScanners.name(of: named) == "Epson Perfection V19")
        named.productName = "Epson " + String(repeating: "x", count: 300)
        #expect(UsbScanners.name(of: named).count <= 81)
    }

    @Test(arguments: [
        ("Epson Perfection V19", "EPSON Perfection V19", true),
        ("Epson Perfection V19", "EPSON Perfection V19 2", true),
        ("Epson Perfection V19", "Epson Perfection V19 Scanner", true),
        ("Epson Perfection V19", "EPSON Perfection V19 II", false),
        ("Epson Perfection V19", "EPSON Perfection V39", false),
        ("Epson Perfection V19", "", false),
    ])
    func ImageCaptureCore_lists_it_by_its_model(_ shown: String, _ listed: String, _ same: Bool) {
        #expect(UsbScanners.sameModel(shown, listed) == same)
    }

    @Test func A_huge_name_from_a_scanners_driver_is_compared_at_once() async throws {
        // A driver's name can be anything: a long run of " 1" ending in another word.
        let hostile = "Epson Perfection V19" + String(repeating: " 1", count: 60_000) + "x"
        let start = ContinuousClock.now
        #expect(!UsbScanners.sameModel("Epson Perfection V19", hostile))
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    // MARK: After its driver's installer: is it there and working?

    static let laser = NeedsDriverPrinter(id: "usb-needs-driver:printer-03f0-3e17", name: "HP LaserJet P1006", maker: "HP", usbId: "03F0:3E17")

    @Test func A_scanner_unplugged_while_waiting_is_absent_not_found() throws {
        let listed = try #require(Self.needing(Self.v19).first)
        #expect(DeviceState.of(listed, [], queues: [], scanners: []) == .absent)
        #expect(!DeviceState.found(.absent))
    }

    @Test func A_scanner_is_found_only_plugged_in_with_a_working_driver_and_listed_by_WIA() throws {
        let listed = try #require(Self.needing(Self.v19).first)
        #expect(DeviceState.of(listed, [Self.v19], queues: [], scanners: []) == .needsDriver)
        let ica = SystemScanner(id: "ica-1", name: "EPSON Perfection V19", usb: true, usbId: "04B8:013C")
        #expect(DeviceState.of(listed, [Self.v19], queues: [], scanners: [ica]) == .working)
        #expect(DeviceState.found(.working))
        #expect(!DeviceState.found(.needsDriver))
        // Listed by ImageCaptureCore but unplugged now (a stale list): not found.
        #expect(DeviceState.of(listed, [], queues: [], scanners: [ica]) == .absent)
    }

    @Test func A_printer_unplugged_while_waiting_is_absent_and_one_with_a_queue_or_a_real_driver_is_working() {
        #expect(DeviceState.of(Self.laser, [], queues: [], scanners: []) == .absent)
        #expect(DeviceState.of(Self.laser, [NeedsDriverTests.p1006], queues: [], scanners: []) == .needsDriver)
        let queue = NeedsDriverTests.queue("HP_LaserJet_P1006", uri: "usb://HP/LaserJet%20P1006?serial=1", model: "HP LaserJet P1006 Foomatic")
        #expect(DeviceState.of(Self.laser, [NeedsDriverTests.p1006], queues: [queue], scanners: []) == .working)
    }
}
