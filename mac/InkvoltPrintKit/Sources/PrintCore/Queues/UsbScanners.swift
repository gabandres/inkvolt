import Foundation

/// Which USB devices are scanners (or an all-in-one's scanner part), for "Plugged in, needs its driver" (the Windows app's
/// `UsbScanners`, the same rules): one of the still-image class (6) or from a maker of scanners whose own name says scanner
/// or all-in-one, or a scanner maker's still-image device that isn't named as a camera (that class is mostly cameras and
/// phones). Most scanners report their maker's own class (255), so the maker and the name decide. A phone, a camera or a
/// webcam (Samsung and HP make those too) is never one. Read from the device's ids and the names it reports, never its serial.
public enum UsbScanners {
    /// USB vendor ids of makers of scanners and all-in-ones, and the short name shown.
    static let makers: [Int: String] = [
        0x04B8: "Epson", 0x04A9: "Canon", 0x03F0: "HP", 0x04F9: "Brother", 0x04C5: "Fujitsu", 0x07B3: "Plustek",
        0x0638: "Avision", 0x04A7: "Visioneer", 0x040A: "Kodak", 0x043D: "Lexmark",
    ]

    /// The vendor ids of the makers above: what PrintMac's watcher wakes for besides the printer and still-image classes.
    public static var makerVendorIds: [Int] { makers.keys.sorted() }

    /// Words in a name that make a maker's device a scanner or an all-in-one (whole words or a model's prefix).
    private static let scannerWords = regex(
        #"scan|perfection|\blide\b|\bfi-\d|\bds-\d|\bes-\d|\bads-\d|\bdr-[a-z]?\d|opticfilm|opticbook|opticslim|ephoto|fastfoto|\bff-\d|documate|\bmfp\b|all-in-one|\baio\b|multifunction|\bmfc-|\bdcp-|\bmf\d{3}"#)

    /// Words that make a device a phone, a camera or a webcam, whoever made it: never listed as a scanner.
    private static let notScannerWords = regex(
        #"phone|android|galaxy|\bipad\b|\bmtp\b|\bptp\b|camera|webcam|\bcam\b|video|\badb\b|tablet|headset|audio|mouse|keyboard|\beos\b|powershot|\bixus\b|\bixy\b|coolpix|lumix|cyber-shot|finepix|easyshare|\bdsc\b|dslr|mirrorless|gopro|instax|\brebel\b"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ re: NSRegularExpression, _ text: String) -> Bool {
        let t = String(text.prefix(2000))
        return re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    private static func names(_ d: UsbDevice) -> String {
        ([d.productName, d.vendorName].compactMap { $0 } + d.interfaceNames).joined(separator: " ")
    }

    /// A scanner or an all-in-one's scanner part, by the rules above.
    public static func isScanner(_ d: UsbDevice) -> Bool {
        let said = names(d)
        if matches(notScannerWords, said) { return false }
        let fromMaker = makers[d.vendorId] != nil
        // A name that says scanner, from a scanner maker or of the still-image class. That class alone is mostly cameras and
        // phones (PTP), so without such a name only a scanner maker's still-image device that names itself, and not as a
        // camera, counts.
        if matches(scannerWords, ([d.productName].compactMap { $0 } + d.interfaceNames).joined(separator: " ")) { return d.isStillImageClass || fromMaker }
        return d.isStillImageClass && fromMaker && !(d.productName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The maker's short name, from its vendor id ("Epson"), else from its names; nil when not known.
    public static func maker(of d: UsbDevice) -> String? {
        if let maker = makers[d.vendorId] { return maker }
        return PrinterNames.maker(of: PrinterNames.forUsb(vendor: d.vendorName, product: d.productName))
    }

    /// The name to show: what the device reports ("Epson Perfection V19"; "EPSON" as "Epson"), with its maker's name before a
    /// model that doesn't have it ("Perfection V19" from an Epson), else the maker's "Epson scanner", else "USB scanner".
    /// Shortened to 80 characters.
    public static func name(of d: UsbDevice) -> String {
        let product = d.productName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var shown: String
        if product.isEmpty {
            shown = maker(of: d).map { "\($0) scanner" } ?? "USB scanner"
        } else {
            shown = PrinterNames.forDevice(product)
            if let m = maker(of: d), PrinterNames.maker(of: shown) == nil, shown.lowercased() != m.lowercased() { shown = "\(m) \(shown)" }
        }
        return shown.count > 80 ? String(shown.prefix(80)).trimmingCharacters(in: .whitespaces) + "…" : shown
    }

    /// The scanner ImageCaptureCore lists under `listed` is this one: the same model words, the maker's way of writing its
    /// name aside ("EPSON Perfection V19" is "Epson Perfection V19"; "Epson Perfection V19 II" isn't).
    public static func sameModel(_ shown: String, _ listed: String) -> Bool {
        func words(_ s: String) -> String {
            String(PrinterNames.forDevice(s).lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
                .split(separator: " ").joined(separator: " ")
        }
        let a = words(shown), b = words(listed)
        // No model's name is this long: a name that is (a driver's can be anything) is never compared by the rule below.
        guard (1...PrinterNames.maxModelName).contains(a.count), (1...PrinterNames.maxModelName).contains(b.count) else { return false }
        // A listed name may add the kind ("Epson Perfection V19 Scanner") or a number for a second one ("… 2").
        func trimmed(_ s: String) -> String {
            var w = s.split(separator: " ").map(String.init)
            while let last = w.last, ["scanner", "series", "photo"].contains(last) || (last.count == 1 && last.first!.isNumber) { w.removeLast() }
            return w.joined(separator: " ")
        }
        return trimmed(a) == trimmed(b)
    }
}
