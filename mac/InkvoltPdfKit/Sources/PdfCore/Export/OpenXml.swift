import Compression
import Foundation

/// Where an export's bytes go: a file being written, or memory.
public protocol ByteSink: AnyObject {
    func write(_ bytes: [UInt8]) throws
}

/// Bytes kept in memory.
public final class MemorySink: ByteSink {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    public func write(_ bytes: [UInt8]) throws { self.bytes += bytes }
}

/// Bytes written to an open file.
final class FileSink: ByteSink {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ bytes: [UInt8]) throws { try handle.write(contentsOf: bytes) }
}

/// Raw DEFLATE (RFC 1951) through the Compression framework, for ZIP entries and PNG's zlib stream.
enum Deflate {
    /// The data deflated; nil when it doesn't get smaller (or can't be compressed).
    static func compress(_ data: [UInt8]) -> [UInt8]? {
        if data.isEmpty { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, capacity, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        if n == 0 || n >= data.count { return nil }
        return Array(out.prefix(n))
    }

    /// A zlib stream (RFC 1950) of the data: deflated, or in stored blocks when that doesn't help.
    static func zlib(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        if let deflated = compress(data) {
            out += deflated
        } else {
            var at = 0
            repeat {
                let n = min(65535, data.count - at)
                let final: UInt8 = at + n == data.count ? 1 : 0
                out += [final, UInt8(n & 255), UInt8(n >> 8), UInt8(~n & 255), UInt8((~n >> 8) & 255)]
                out += data[at..<at + n]
                at += n
            } while at < data.count
        }
        var a: UInt32 = 1, b: UInt32 = 0
        var k = 0
        while k < data.count {
            // Sums stay below 2^32 for 5552 bytes between reductions (zlib's NMAX).
            let end = min(data.count, k + 5552)
            for i in k..<end {
                a += UInt32(data[i])
                b += a
            }
            a %= 65521
            b %= 65521
            k = end
        }
        let adler = b << 16 | a
        out += [UInt8(adler >> 24), UInt8((adler >> 16) & 255), UInt8((adler >> 8) & 255), UInt8(adler & 255)]
        return out
    }
}

/// CRC-32 (ZIP's and PNG's).
enum Crc32 {
    static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func update(_ crc: UInt32, _ data: some Sequence<UInt8>) -> UInt32 {
        var c = crc
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }

    static func of(_ data: [UInt8]) -> UInt32 { update(0xFFFF_FFFF, data) ^ 0xFFFF_FFFF }
}

/// A ZIP archive written as entries arrive (what .NET's `ZipArchive` in Create mode does for the Windows writers):
/// stored or deflated entries, UTF-8 names, then the central directory. ZIP64 isn't written: an archive over 4 GB fails.
final class ZipWriter {
    private let sink: ByteSink
    private var offset = 0
    private var central: [UInt8] = []
    private var count = 0
    private let time: UInt16
    private let date: UInt16

    init(_ sink: ByteSink) {
        self.sink = sink
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        date = UInt16(max(0, (c.year ?? 1980) - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }

    /// Adds an entry; `compress` deflates it when that makes it smaller.
    func add(_ name: String, _ data: [UInt8], compress: Bool) throws {
        let deflated = compress ? Deflate.compress(data) : nil
        let body = deflated ?? data
        let method: UInt16 = deflated == nil ? 0 : 8
        let crc = Crc32.of(data)
        let nameBytes = Array(name.utf8)
        guard offset + 30 + nameBytes.count + body.count < Int(UInt32.max) else {
            throw PdfEngineError(message: "The file would be larger than 4 GB.")
        }
        var local: [UInt8] = []
        local += le32(0x0403_4B50) + le16(20) + le16(0x0800) + le16(method) + le16(time) + le16(date)
        local += le32(crc) + le32(UInt32(body.count)) + le32(UInt32(data.count)) + le16(UInt16(nameBytes.count)) + le16(0)
        local += nameBytes
        central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0x0800) + le16(method) + le16(time) + le16(date)
        central += le32(crc) + le32(UInt32(body.count)) + le32(UInt32(data.count)) + le16(UInt16(nameBytes.count))
        central += le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(UInt32(offset))
        central += nameBytes
        try sink.write(local)
        try sink.write(body)
        offset += local.count + body.count
        count += 1
    }

    /// Writes the central directory: the archive is complete.
    func finish() throws {
        let end = le32(0x0605_4B50) + le16(0) + le16(0) + le16(UInt16(count)) + le16(UInt16(count))
            + le32(UInt32(central.count)) + le32(UInt32(offset)) + le16(0)
        try sink.write(central + end)
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 255), UInt8((v >> 8) & 255), UInt8((v >> 16) & 255), UInt8(v >> 24)] }
}

/// Writes XML the way the Windows writers' `XmlWriter` does (UTF-8, standalone declaration, no indentation), with
/// prefixed names given in full ("w:p") and namespaces declared as attributes on the root.
final class XmlOut {
    private var out = "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>"
    private var stack: [String] = []
    private var open = false // a start tag waits for its ">"

    var bytes: [UInt8] {
        precondition(stack.isEmpty, "Unclosed elements.")
        return Array(out.utf8)
    }

    func start(_ name: String, _ attributes: [(String, String)] = []) {
        closeStart()
        out += "<" + name
        stack.append(name)
        open = true
        for (k, v) in attributes { attr(k, v) }
    }

    func attr(_ name: String, _ value: String) {
        precondition(open, "An attribute outside a start tag.")
        out += " " + name + "=\"" + Self.escape(value, attribute: true) + "\""
    }

    func text(_ value: String) {
        closeStart()
        out += Self.escape(value, attribute: false)
    }

    func end() {
        let name = stack.removeLast()
        if open {
            out += " />"
            open = false
        } else {
            out += "</" + name + ">"
        }
    }

    /// An element with only attributes.
    func empty(_ name: String, _ attributes: [(String, String)] = []) {
        start(name, attributes)
        end()
    }

    /// An element holding text.
    func element(_ name: String, _ value: String) {
        start(name)
        text(value)
        end()
    }

    private func closeStart() {
        if open {
            out += ">"
            open = false
        }
    }

    static func escape(_ s: String, attribute: Bool) -> String {
        var r = ""
        r.reserveCapacity(s.utf8.count)
        for c in s.unicodeScalars {
            switch c {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"" where attribute: r += "&quot;"
            case "\t" where attribute: r += "&#x9;"
            case "\n" where attribute: r += "&#xA;"
            case "\r": r += "&#xD;"
            default: r.unicodeScalars.append(c)
            }
        }
        return r
    }
}

/// Package parts shared by the .docx and .xlsx writers.
enum OpenXmlParts {
    static func entry(_ zip: ZipWriter, _ name: String, _ write: (XmlOut) -> Void) throws {
        let w = XmlOut()
        write(w)
        try zip.add(name, w.bytes, compress: true)
    }

    /// At most the first `max` UTF-16 units, never splitting a surrogate pair (an emoji) in two.
    static func cut(_ text: String, _ max: Int) -> String {
        let u = Array(text.utf16)
        if u.count <= max { return text }
        if max <= 0 { return "" }
        let n = UTF16.isLeadSurrogate(u[max - 1]) ? max - 1 : max
        return String(decoding: u[0..<n], as: UTF16.self)
    }

    /// Text with the characters XML can't hold (control characters, U+FFFE, U+FFFF) dropped; tabs and newlines kept, a
    /// carriage return made a newline. (A Swift string holds no lone surrogates.)
    static func clean(_ text: String) -> String {
        if !text.unicodeScalars.contains(where: { !ok($0) }) { return text }
        var out = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            if ok(c) { out.append(c) } else if c == "\r" { out.append("\n") }
        }
        return String(out)

        func ok(_ c: Unicode.Scalar) -> Bool { c == "\t" || c == "\n" || (c.value >= 0x20 && c.value != 0xFFFE && c.value != 0xFFFF) }
    }

    static func contentTypes(_ w: XmlOut, _ overrides: [(part: String, type: String)]) {
        w.start("Types", [("xmlns", "http://schemas.openxmlformats.org/package/2006/content-types")])
        for (ext, type) in [("rels", "application/vnd.openxmlformats-package.relationships+xml"), ("xml", "application/xml"),
                            ("png", "image/png"), ("jpeg", "image/jpeg")] {
            w.empty("Default", [("Extension", ext), ("ContentType", type)])
        }
        let all = overrides + [
            ("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml"),
            ("/docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml"),
        ]
        for (part, type) in all { w.empty("Override", [("PartName", part), ("ContentType", type)]) }
        w.end()
    }

    static func coreProperties(_ w: XmlOut, _ title: String?) {
        w.start("cp:coreProperties", [
            ("xmlns:cp", "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"),
            ("xmlns:dc", "http://purl.org/dc/elements/1.1/"),
            ("xmlns:dcterms", "http://purl.org/dc/terms/"),
            ("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance"),
        ])
        if let title, !title.isBlank { w.element("dc:title", clean(title)) }
        w.start("dcterms:created", [("xsi:type", "dcterms:W3CDTF")])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        w.text(f.string(from: Date()))
        w.end()
        w.end()
    }

    static func appProperties(_ w: XmlOut) {
        w.start("Properties", [("xmlns", "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties")])
        w.element("Application", "Inkvolt PDF")
        w.end()
    }

    static func relationships(_ w: XmlOut, _ rels: [(id: String, type: String, target: String)]) {
        w.start("Relationships", [("xmlns", "http://schemas.openxmlformats.org/package/2006/relationships")])
        for (id, type, target) in rels { w.empty("Relationship", [("Id", id), ("Type", type), ("Target", target)]) }
        w.end()
    }

    /// Points to twentieths of a point, rounded as .NET's `Math.Round` does.
    static func twips(_ pt: Double) -> String { String(Int(bankers(pt * 20))) }

    /// Points to EMUs.
    static func emu(_ pt: Double) -> String { String(Int(bankers(pt * 12700))) }
}
