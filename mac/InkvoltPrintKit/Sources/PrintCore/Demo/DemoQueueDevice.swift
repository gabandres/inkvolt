import Foundation

/// Demo mode's queue printers that say more than their queue (roadmap 3.6): the made-up Mac's USB laser is an IPP-over-USB
/// printer (`ippusb://`), and this stands for its answer to Get-Printer-Attributes, so its status card says where its levels
/// came from as a real one's does. Nothing is asked anywhere.
public struct DemoQueueDevice: QueueDeviceReader {
    public static let usbLaserQueue = "Demo_USB_laser"

    /// The readers for one of the made-up queues: the USB laser's, none for the others.
    public static func readers(for d: CupsDestination) -> [any QueueDeviceReader] {
        d.name == usbLaserQueue && IppQueueReading.route(d) == .printerOverUsb ? [DemoQueueDevice()] : []
    }

    public init() {}

    /// Ready, its toner low (as cupsd's copy says, a little lower now) and its drum, which cupsd doesn't have.
    public func read() async throws -> QueueDeviceReading? {
        let a: [String: [IppAttributeValue]] = [
            "printer-state": [.integer(3)],
            "printer-state-reasons": [.text("toner-low-warning")],
            "marker-names": [.text("Black Toner"), .text("Imaging Drum")],
            "marker-types": [.text("toner"), .text("opc")],
            "marker-colors": [.text("#000000"), .text("none")],
            "marker-levels": [.integer(11), .integer(64)],
            "marker-low-levels": [.integer(15), .integer(10)],
            "marker-high-levels": [.integer(100), .integer(100)],
        ]
        return IppQueueReading.from(IppResponse(statusCode: 0, attributes: a), usb: true)
    }
}
