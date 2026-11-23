import Foundation

/// Writes XML the way the Windows writers' `XmlWriter` does (UTF-8, standalone declaration, no indentation), with
/// prefixed names given in full ("w:p") and namespaces declared as attributes on the root.
public final class XmlOut {
    public init() {}

    private var out = "<?xml version=\"1.0\" encoding=\"utf-8\" standalone=\"yes\"?>"
    private var stack: [String] = []
    private var open = false // a start tag waits for its ">"

    public var bytes: [UInt8] {
        precondition(stack.isEmpty, "Unclosed elements.")
        return Array(out.utf8)
    }

    public func start(_ name: String, _ attributes: [(String, String)] = []) {
        closeStart()
        out += "<" + name
        stack.append(name)
        open = true
        for (k, v) in attributes { attr(k, v) }
    }

    public func attr(_ name: String, _ value: String) {
        precondition(open, "An attribute outside a start tag.")
        out += " " + name + "=\"" + Self.escape(value, attribute: true) + "\""
    }

    public func text(_ value: String) {
        closeStart()
        out += Self.escape(value, attribute: false)
    }

    public func end() {
        let name = stack.removeLast()
        if open {
            out += " />"
            open = false
        } else {
            out += "</" + name + ">"
        }
    }

    /// An element with only attributes.
    public func empty(_ name: String, _ attributes: [(String, String)] = []) {
        start(name, attributes)
        end()
    }

    /// An element holding text.
    public func element(_ name: String, _ value: String) {
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

    public static func escape(_ s: String, attribute: Bool) -> String {
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

/// Package parts shared by the Office Open XML writers: Inkvolt PDF's .docx, .pptx and .xlsx exports and Inkvolt Print's
/// scans to Word (`ScanDocx`), as Windows' shared core holds them.
public enum OpenXmlParts {
    /// A part's XML, written by `write`.
    public static func xml(_ write: (XmlOut) -> Void) -> [UInt8] {
        let w = XmlOut()
        write(w)
        return w.bytes
    }

    /// At most the first `max` UTF-16 units, never splitting a surrogate pair (an emoji) in two.
    public static func cut(_ text: String, _ max: Int) -> String {
        let u = Array(text.utf16)
        if u.count <= max { return text }
        if max <= 0 { return "" }
        let n = UTF16.isLeadSurrogate(u[max - 1]) ? max - 1 : max
        return String(decoding: u[0..<n], as: UTF16.self)
    }

    /// Text with the characters XML can't hold (control characters, U+FFFE, U+FFFF) dropped; tabs and newlines kept, a
    /// carriage return made a newline. (A Swift string holds no lone surrogates.)
    public static func clean(_ text: String) -> String {
        if !text.unicodeScalars.contains(where: { !ok($0) }) { return text }
        var out = String.UnicodeScalarView()
        for c in text.unicodeScalars {
            if ok(c) { out.append(c) } else if c == "\r" { out.append("\n") }
        }
        return String(out)

        func ok(_ c: Unicode.Scalar) -> Bool { c == "\t" || c == "\n" || (c.value >= 0x20 && c.value != 0xFFFE && c.value != 0xFFFF) }
    }

    public static func contentTypes(_ w: XmlOut, _ overrides: [(part: String, type: String)]) {
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

    public static func coreProperties(_ w: XmlOut, _ title: String?) {
        w.start("cp:coreProperties", [
            ("xmlns:cp", "http://schemas.openxmlformats.org/package/2006/metadata/core-properties"),
            ("xmlns:dc", "http://purl.org/dc/elements/1.1/"),
            ("xmlns:dcterms", "http://purl.org/dc/terms/"),
            ("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance"),
        ])
        // Scalar by scalar, as before the move (a space and a combining mark is a title).
        if let title, !title.unicodeScalars.allSatisfy(\.properties.isWhitespace) { w.element("dc:title", clean(title)) }
        w.start("dcterms:created", [("xsi:type", "dcterms:W3CDTF")])
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        w.text(f.string(from: Date()))
        w.end()
        w.end()
    }

    /// docProps/app.xml: the application that wrote the file.
    public static func appProperties(_ w: XmlOut, application: String) {
        w.start("Properties", [("xmlns", "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties")])
        w.element("Application", application)
        w.end()
    }

    public static func relationships(_ w: XmlOut, _ rels: [(id: String, type: String, target: String)]) {
        w.start("Relationships", [("xmlns", "http://schemas.openxmlformats.org/package/2006/relationships")])
        for (id, type, target) in rels { w.empty("Relationship", [("Id", id), ("Type", type), ("Target", target)]) }
        w.end()
    }
}
