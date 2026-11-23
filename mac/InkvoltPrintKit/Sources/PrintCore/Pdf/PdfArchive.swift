import Foundation

/// How `PdfWriter.write` writes a scan: as before (nil), for archiving (`pdfA`: PDF/A-2b), or with a password (`password`:
/// AES-256). PDF/A forbids encryption, so the two never go together. The Windows core's `PdfWriteOptions` (roadmap 4.18).
public struct PdfWriteOptions: Equatable, Sendable {
    /// PDF/A-2b (ISO 19005-2, level B): an sRGB output intent, XMP metadata that says so, a file identifier.
    public var pdfA: Bool

    /// The password that opens the file (`PdfEncryption`), or nil.
    public var password: String?

    /// The creation date written (now when nil); the same instant in the Info dictionary and the XMP packet.
    public var now: Date?

    public init(pdfA: Bool = false, password: String? = nil, now: Date? = nil) {
        self.pdfA = pdfA
        self.password = password
        self.now = now
    }
}

/// PDF/A-2b's metadata for a scan (`PdfWriter`), the Windows core's `PdfArchive`.
public enum PdfArchive {
    /// The XMP packet (UTF-8, uncompressed as PDF/A asks): the title, producer and creation date the Info dictionary holds
    /// (ISO 19005-2, 6.6.2.3: the same values), and pdfaid:part 2, conformance B. The text is XML-escaped here, as .NET's
    /// XElement writes it, so a title can't reach the packet's syntax.
    public static func xmp(title: String, producer: String, created: Date) -> [UInt8] {
        let description = "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\" "
            + "xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\">"
            + "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escape(OcrText.clean(title)))</rdf:li></rdf:Alt></dc:title>"
            + "<pdf:Producer>\(escape(producer))</pdf:Producer>"
            + "<xmp:CreateDate>\(isoDate(created))</xmp:CreateDate>"
            + "<pdfaid:part>2</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance></rdf:Description>"
        let root = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + description + "</rdf:RDF></x:xmpmeta>"
        return Array(("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n" + root + "\n<?xpacket end=\"w\"?>").utf8)
    }

    /// Element text as XML writes it: `&`, `<` and `>` as entities.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for c in text.unicodeScalars {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            default: out.unicodeScalars.append(c)
            }
        }
        return out
    }

    /// The UTC date and time as XMP writes it, always in the Gregorian calendar: "2026-11-22T14:30:05Z".
    static func isoDate(_ date: Date) -> String {
        let c = utcParts(date)
        return "\(c.year)-\(two(c.month))-\(two(c.day))T\(two(c.hour)):\(two(c.minute)):\(two(c.second))Z"
    }

    /// The UTC date and time as a PDF date writes it, always in the Gregorian calendar (a Thai or Hijri regional format would
    /// otherwise write another year, and a PDF/A file's Info date would no longer match its XMP one): "D:20261122143005Z".
    static func pdfDate(_ date: Date) -> String {
        let c = utcParts(date)
        return "D:\(c.year)\(two(c.month))\(two(c.day))\(two(c.hour))\(two(c.minute))\(two(c.second))Z"
    }

    private static func utcParts(_ date: Date) -> (year: String, month: Int, day: Int, hour: Int, minute: Int, second: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = String(min(max(c.year ?? 2000, 0), 9999))
        return (String(repeating: "0", count: 4 - year.count) + year, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    private static func two(_ v: Int) -> String { v < 10 ? "0\(v)" : "\(v)" }
}
