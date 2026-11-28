import Foundation

/// One USB device as IOKit has it (`IOUSBHostDevice`, PrintMac's `IOKitUsbDevices`), read only: its vendor and product
/// ids, the names it reports for itself and its interfaces' classes. Never its serial number (`USB Serial Number`), which is
/// a device identifier: it isn't read at all. The Windows app's `UsbPrinterNode` (Windows' device nodes); IOKit lists only
/// devices plugged in now, so there is no "present".
public struct UsbDevice: Equatable, Sendable {
    public var vendorId: Int
    public var productId: Int
    /// What the device calls its product (`USB Product Name`: "Perfection V19", "HP LaserJet P1006").
    public var productName: String?
    /// What the device calls its maker (`USB Vendor Name`: "EPSON", "Hewlett-Packard").
    public var vendorName: String?
    /// The device's own class (`bDeviceClass`): 0 when its interfaces say, 7 printer, 6 still image, 255 its maker's own.
    public var deviceClass: Int
    /// Each interface's class (`bInterfaceClass`), in IOKit's order.
    public var interfaceClasses: [Int]
    /// The names interfaces report for themselves (`USB Interface Name`), where they do: an all-in-one's scanner part may say
    /// "… Scanner".
    public var interfaceNames: [String]

    public init(vendorId: Int, productId: Int, productName: String? = nil, vendorName: String? = nil, deviceClass: Int = 0,
                interfaceClasses: [Int] = [], interfaceNames: [String] = []) {
        self.vendorId = vendorId
        self.productId = productId
        self.productName = productName
        self.vendorName = vendorName
        self.deviceClass = deviceClass
        self.interfaceClasses = interfaceClasses
        self.interfaceNames = interfaceNames
    }

    /// "04B8:013C": the same for every one of the model, never a serial.
    public var usbId: String { String(format: "%04X:%04X", vendorId & 0xFFFF, productId & 0xFFFF) }

    /// The USB printer class (7) on the device or one of its interfaces.
    public var isPrinterClass: Bool { deviceClass == 7 || interfaceClasses.contains(7) }

    /// The still-image class (6: scanners and cameras, PTP) on the device or one of its interfaces.
    public var isStillImageClass: Bool { deviceClass == 6 || interfaceClasses.contains(6) }
}

/// The USB devices plugged in now (the seam: PrintMac's `IOKitUsbDevices`, the tests' and demo mode's fakes).
public protocol UsbDeviceSource: Sendable {
    /// Every USB device IOKit lists now; none when it can't be asked.
    func devices() -> [UsbDevice]
}

/// What a device needing its driver is.
public enum NeedsDriverKind: Sendable { case printer, scanner }

/// A USB printer or scanner that is plugged in but macOS can't use yet: no queue for the printer (macOS has no driver for
/// it, or no driverless way), no ImageCaptureCore device for the scanner (no maker's driver). Listed on the printer list with
/// what to do (`NeedsDriverText`). The Windows app's `NeedsDriverPrinter`; the Mac has no "Driver installed, not set up"
/// stage (macOS sets a USB printer up by itself once it has a driver; Printers & Scanners is the other way).
public struct NeedsDriverPrinter: Equatable, Sendable, Identifiable {
    /// "usb-needs-driver:" and its kind and USB ids ("usb-needs-driver:scanner-04b8-013c"): never a serial or a queue's id.
    public var id: String
    public var name: String
    /// The maker's short name ("HP", "Epson"…), nil when not known.
    public var maker: String?
    public var kind: NeedsDriverKind
    /// Its USB vendor and product ids ("04B8:013C"); nil: not known.
    public var usbId: String?
    /// Made up (demo mode): nothing about it is real.
    public var isMadeUp: Bool

    public init(id: String, name: String, maker: String?, kind: NeedsDriverKind = .printer, usbId: String? = nil, isMadeUp: Bool = false) {
        self.id = id
        self.name = name
        self.maker = maker
        self.kind = kind
        self.usbId = usbId
        self.isMadeUp = isMadeUp
    }

    public var isScanner: Bool { kind == .scanner }
}

/// The rules for "Plugged in, needs its driver" on the Mac (the Windows app's `NeedsDriver.Find`): which USB devices
/// plugged in now nothing on this Mac can use. A device of the printer class with no CUPS queue for it (a USB or IPP-over-USB
/// queue of its model, temporary ones included: macOS prints to those driverless) needs its driver; one with a queue prints.
/// A scanner (`UsbScanners`, an all-in-one's scanner part included) that ImageCaptureCore doesn't list (by its USB ids, or
/// its model) needs its maker's driver, unless its printer part is listed already (one entry a device). Host-based printers
/// (most older USB lasers) have no driverless mode: only their maker's driver prints to them.
public enum NeedsDriver {
    static let idPrefix = "usb-needs-driver:"

    public static func isNeedsDriverId(_ id: String?) -> Bool { id?.hasPrefix(idPrefix) == true }

    /// The devices plugged in now that need their driver, each once, in IOKit's order.
    public static func find(_ devices: [UsbDevice], queues: [CupsDestination], scanners: [SystemScanner]) -> [NeedsDriverPrinter] {
        var found: [NeedsDriverPrinter] = []
        for d in devices {
            let name = PrinterNames.forUsb(vendor: d.vendorName, product: d.productName)
            if d.isPrinterClass && !hasQueue(d, queues) {
                found.append(NeedsDriverPrinter(id: idPrefix + "printer-" + d.usbId.replacingOccurrences(of: ":", with: "-").lowercased(),
                                                name: name, maker: UsbScanners.maker(of: d), usbId: d.usbId))
                continue // its scanner part, if any, waits on the same driver: one entry a device
            }
            guard UsbScanners.isScanner(d), !scannerListed(d, scanners) else { continue }
            found.append(NeedsDriverPrinter(id: idPrefix + "scanner-" + d.usbId.replacingOccurrences(of: ":", with: "-").lowercased(),
                                            name: UsbScanners.name(of: d), maker: UsbScanners.maker(of: d), kind: .scanner, usbId: d.usbId))
        }
        var seen = Set<String>()
        return found.filter { seen.insert($0.id).inserted }
    }

    /// A queue that prints to it: a USB queue (`usb://`, `ippusb://`, or the Bonjour name IPP over USB goes by) of its model,
    /// by the queue's device URI, make and model or name. A class, a fax or another computer's queue never.
    public static func hasQueue(_ d: UsbDevice, _ queues: [CupsDestination]) -> Bool {
        let want = PrinterNames.forUsb(vendor: d.vendorName, product: d.productName)
        guard want != "USB printer" else { return false } // a device that names nothing matches no queue
        return queues.contains { q in
            guard !q.has(CupsDestination.TypeBit.class), !q.has(CupsDestination.TypeBit.fax), !q.has(CupsDestination.TypeBit.remote) else { return false }
            guard let uri = q.deviceUri?.lowercased(), uri.hasPrefix("usb:") || uri.hasPrefix("ippusb:") || uri.hasPrefix("dnssd:")
                    || uri.hasPrefix("ipp://localhost") || uri.hasPrefix("ipps://localhost") else { return false }
            let names = [usbUriModel(q.deviceUri), q.makeAndModel, q.displayName].compactMap { $0 }
            return names.contains { PrinterNames.sameModel(want, $0) }
        }
    }

    /// "HP LaserJet P1006" from `usb://HP/LaserJet%20P1006?serial=…`: its maker and model only (what follows `?`, the serial
    /// among it, is never read). Nil for any other URI.
    public static func usbUriModel(_ uri: String?) -> String? {
        guard let uri, uri.lowercased().hasPrefix("usb://") else { return nil }
        let rest = uri.dropFirst(6).prefix { $0 != "?" && $0 != "#" }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).prefix(2).map { String($0).removingPercentEncoding ?? String($0) }
        let text = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : String(text.prefix(200))
    }

    /// ImageCaptureCore lists it: a USB scanner of its USB ids, or of its model.
    public static func scannerListed(_ d: UsbDevice, _ scanners: [SystemScanner]) -> Bool {
        let name = UsbScanners.name(of: d)
        return scanners.contains { s in s.usb && (s.usbId == d.usbId || UsbScanners.sameModel(name, s.name)) }
    }
}

/// Where a device that needed its driver is now (the Windows app's `DeviceNow`).
public enum DeviceNow: Sendable {
    /// Not plugged in (unplugged, perhaps as an installer said to): waiting, never "found".
    case absent
    /// Plugged in, still with nothing that can use it.
    case needsDriver
    /// Plugged in and usable: the printer has a queue, ImageCaptureCore lists the scanner.
    case working
}

/// Whether a device that needed its driver has it now (the Windows app's `DeviceState`): "Get the driver" counts it found only
/// when it is plugged in and works, never when it merely left the needs-driver list (an unplugged device leaves it too). Its
/// device is the one with its USB ids.
public enum DeviceState {
    public static func of(_ device: NeedsDriverPrinter, _ devices: [UsbDevice], queues: [CupsDestination], scanners: [SystemScanner]) -> DeviceNow {
        let mine = devices.filter { $0.usbId == device.usbId }
        guard !mine.isEmpty else { return .absent }
        if device.isScanner { return mine.contains { NeedsDriver.scannerListed($0, scanners) } ? .working : .needsDriver }
        return mine.contains { NeedsDriver.hasQueue($0, queues) } ? .working : .needsDriver
    }

    /// Found: plugged in and working (a scanner: listed by ImageCaptureCore, what the Scan tab uses).
    public static func found(_ now: DeviceNow) -> Bool { now == .working }
}

/// A USB printer's name to show (the Windows app's `PrinterNames`), from what the device reports: its maker's name and its
/// product's ("EPSON" and "ET-2800 Series": "Epson ET-2800 Series"; "Hewlett-Packard" and "HP LaserJet P1006": "HP LaserJet
/// P1006"). The maker's long name goes ("Hewlett-Packard" → "HP"), a repeated one is dropped.
public enum PrinterNames {
    /// Makers as their names come, longest first, and the short name to show.
    static let makers: [(long: String, short: String)] = [
        ("Hewlett-Packard", "HP"), ("Hewlett Packard", "HP"), ("KONICA MINOLTA", "Konica Minolta"), ("FUJI XEROX", "Fuji Xerox"),
        ("FUJIFILM", "Fujifilm"), ("OKI DATA CORP", "OKI"), ("Kyocera Mita", "Kyocera"), ("KYOCERA", "Kyocera"), ("SAMSUNG", "Samsung"),
        ("Brother", "Brother"), ("Lexmark", "Lexmark"), ("Panasonic", "Panasonic"), ("Toshiba", "Toshiba"), ("Pantum", "Pantum"),
        ("EPSON", "Epson"), ("Canon", "Canon"), ("Xerox", "Xerox"), ("Ricoh", "Ricoh"), ("Sharp", "Sharp"), ("Zebra", "Zebra"),
        ("DYMO", "Dymo"), ("Dell", "Dell"), ("OKI", "OKI"), ("HP", "HP"),
    ]

    /// The name to show for a USB printer from its vendor's and product's names; "USB printer" when it reports neither.
    public static func forUsb(vendor: String?, product: String?) -> String {
        let p = product?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let v = vendor?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if p.isEmpty { return "USB printer" }
        let shown = forDevice(p)
        // "ET-2800 Series" from "EPSON": "Epson ET-2800 Series"; a vendor Inkvolt Print doesn't know adds nothing.
        if maker(of: shown) != nil || maker(of: forDevice(v) + " x") == nil { return shown }
        return forDevice(v + " " + p)
    }

    /// A name as a device or CUPS writes it, cleaned: the maker's short name, single spaces, an all-capitals model as typed.
    public static func forDevice(_ name: String) -> String {
        clean(String(name.prefix(400)))
    }

    /// The maker's short name, when the name starts with one Inkvolt Print knows.
    public static func maker(of name: String) -> String? {
        var seen = Set<String>()
        return makers.map(\.short).filter { seen.insert($0).inserted }.first { name.lowercased().hasPrefix($0.lowercased() + " ") }
    }

    private static func clean(_ raw: String) -> String {
        let s = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for (long, short) in makers where s.lowercased().hasPrefix(long.lowercased()) {
            var rest = String(s.dropFirst(long.count))
            if let first = rest.first, first != " " { continue } // "HPE…", "Dellmore": not the maker
            rest = rest.trimmingCharacters(in: .whitespaces)
            if rest.isEmpty { return short }
            // "Hewlett-Packard HP LaserJet", "EPSON EPSON L1110": the model names its maker again.
            for again in makers where again.short == short && rest.lowercased().hasPrefix(again.long.lowercased() + " ") {
                rest = String(rest.dropFirst(again.long.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            return "\(short) \(model(rest))"
        }
        return model(s)
    }

    /// A model in capitals ("LASERJET P1006") reads as typed; mixed case stays as the maker wrote it.
    private static func model(_ s: String) -> String {
        if s.contains(where: \.isLowercase) { return s }
        return s.split(separator: " ").map { w in
            w.count > 1 && w.allSatisfy(\.isLetter) ? w.prefix(1) + w.dropFirst().lowercased() : String(w)
        }.joined(separator: " ")
    }

    /// The longest name `sameModel` compares: no model's is longer.
    static let maxModelName = 200

    /// A name's model words, lower case, the maker's long name as its short one: "Hewlett-Packard HP LaserJet P1006" →
    /// ["hp", "laserjet", "p1006"].
    public static func modelWords(_ name: String) -> [String] {
        let s = forDevice(name).lowercased()
        return s.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static let kindWords: Set<String> = ["printer", "scanner", "series", "photo", "mfp", "usb", "ipp", "everywhere", "airprint", "driverless"]

    /// The queue (or the scanner ImageCaptureCore lists) under `listed` is the device named `shown`: the same model words, the
    /// maker's way of writing its name and kind words aside ("EPSON ET-2800 Series" is "Epson ET-2800"; "… - IPP Everywhere"
    /// and "(1A2B3C)" go; "HP LaserJet P1006" isn't "HP LaserJet P10065"). A make-and-model may add the driver's words after
    /// the model ("HP LaserJet P1006, hpcups 3.22"): words after a comma or " - " are left out.
    public static func sameModel(_ shown: String, _ listed: String) -> Bool {
        func words(_ s: String) -> [String] {
            guard s.count <= maxModelName else { return [] }
            var t = s
            for cut in [",", " - ", "("] { if let r = t.range(of: cut) { t = String(t[..<r.lowerBound]) } }
            return modelWords(t).filter { !kindWords.contains($0) }
        }
        let a = words(shown), b = words(listed)
        guard !a.isEmpty, !b.isEmpty, a.contains(where: { $0.contains(where: \.isNumber) }) else { return a == b && !a.isEmpty }
        if a == b { return true }
        // One name with its maker, the other without ("Epson ET-2800" and "ET-2800").
        if let m = a.first, maker(of: m + " x") != nil, Array(a.dropFirst()) == b { return true }
        if let m = b.first, maker(of: m + " x") != nil, Array(b.dropFirst()) == a { return true }
        return false
    }
}
