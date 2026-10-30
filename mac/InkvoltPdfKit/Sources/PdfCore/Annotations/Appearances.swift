import Foundation

/// Numbers as content streams and appearance entries write them (the Windows app's `PdfObj.F`): rounded to three
/// decimals, no trailing zeros.
public enum PdfNum {
    public static func f(_ v: Double) -> String {
        let r = (v * 1000).rounded() / 1000
        if r == 0 || !r.isFinite { return "0" }
        if r == r.rounded() && abs(r) < 1e15 { return String(Int(r)) }
        var s = String(format: "%.3f", r)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Two decimals at most (.NET's "0.##"), for /DA font sizes and Fill & Sign text.
    public static func f2(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if r == 0 || !r.isFinite { return "0" }
        if r == r.rounded() && abs(r) < 1e15 { return String(Int(r)) }
        var s = String(format: "%.2f", r)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }
}

/// A device color from a PDF operand list: 1 = gray, 3 = RGB, 4 = CMYK.
struct PdfColorValue: Equatable {
    var c: [Double]

    static let black = PdfColorValue(c: [0])

    static func from(_ a: PObj?) -> PdfColorValue? {
        guard let a, a.isArray, [1, 3, 4].contains(a.count) else { return nil }
        return PdfColorValue(c: (0..<a.count).map { a.num($0) })
    }

    private var operands: String { c.map(PdfNum.f).joined(separator: " ") }
    var fill: String { operands + (c.count == 1 ? " g" : c.count == 3 ? " rg" : " k") }
    var stroke: String { operands + (c.count == 1 ? " G" : c.count == 3 ? " RG" : " K") }
}

/// A parsed default-appearance string (/DA): the font resource name, the size (0 = auto) and the text color.
struct DefaultAppearance {
    var fontName: String
    var size: Double
    var color: PdfColorValue

    static func parse(_ da: String?) -> DefaultAppearance {
        let tokens = (da ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }).map(String.init)
        var font = "/Helv"
        var size = 0.0
        var color = PdfColorValue.black
        for (i, t) in tokens.enumerated() {
            switch t {
            case "Tf" where i >= 2:
                if tokens[i - 2].hasPrefix("/") { font = tokens[i - 2] }
                if let s = Double(tokens[i - 1]), s.isFinite { size = min(s, 1000) } else { size = 0 }
            case "g", "rg", "k":
                let n = t == "g" ? 1 : t == "rg" ? 3 : 4
                if i < n { break }
                let values = tokens[(i - n)..<i].compactMap { Double($0) }.filter(\.isFinite)
                if values.count == n { color = PdfColorValue(c: values) }
            default:
                break
            }
        }
        return DefaultAppearance(fontName: font, size: size, color: color)
    }
}

/// Lays out and draws text for an appearance stream (the Windows app's `TextPainter`). Text the standard font can encode
/// (WinAnsi) is written with that non-embedded font; anything else (Greek, Cyrillic, Arabic, Hebrew, Indic, CJK, ...) is
/// shaped by Core Text (`TextShaper`) and drawn with embedded fonts (`Type3FontWriter`), so any script renders in every
/// viewer and extracts as typed.
final class TextPainter {
    private let std: StdFont
    private let primary: TrueTypeFont?
    private var items: [(text: String, x: Double, y: Double, size: Double)] = []
    private var writer: Type3FontWriter?
    let unicode: Bool

    init(_ std: StdFont, _ texts: [String]) {
        self.std = std
        if texts.allSatisfy(WinAnsi.canEncode) {
            primary = nil
            unicode = false
        } else {
            primary = std.metrics ?? SystemFonts.get("arial.ttf")
            unicode = primary != nil
        }
    }

    var ascent: Double { std.ascent }
    var descent: Double { std.descent }

    /// The width of `s` at 1 pt.
    func measure(_ s: String) -> Double { unicode ? TextShaper.measure(s, primary) : std.measure(s) }

    /// Queues a line of text with its baseline's left end at (x, y) in the appearance's bbox coordinates.
    func draw(_ text: String, _ x: Double, _ y: Double, _ size: Double) {
        if !text.isEmpty { items.append((text, x, y, size)) }
    }

    /// The text-drawing operators and the resources they need (the font under `resourceName`, e.g. "/Helv").
    func build(_ doc: MuDoc, _ width: Double, _ height: Double, _ resourceName: String, _ color: PdfColorValue) -> (ops: [UInt8], resources: PObj) {
        let ops = ops(resourceName, color)
        return (ops, resources(doc, resourceName))
    }

    /// The operators drawing the text queued since the last call, which is then forgotten (text on many pages can share
    /// one painter: each page's operators, then one `resources` after the last, so each font is embedded once).
    func ops(_ resourceName: String, _ color: PdfColorValue) -> [UInt8] {
        var out: [UInt8] = []
        if !unicode {
            for item in items {
                let head = "BT \(color.fill) \(resourceName) \(PdfNum.f(item.size)) Tf 1 0 0 1 \(PdfNum.f(item.x)) \(PdfNum.f(item.y)) Tm ("
                out += Array(head.utf8) + WinAnsi.literal(item.text) + Array(") Tj ET\n".utf8)
            }
        } else {
            let w = writer ?? Type3FontWriter()
            writer = w
            var sb = ""
            for item in items {
                sb += "BT \(color.fill) 1 0 0 1 \(PdfNum.f(item.x)) \(PdfNum.f(item.y)) Tm "
                w.emit(&sb, TextShaper.shape(item.text, primary), size: item.size)
                sb += "ET\n"
            }
            out = Array(sb.utf8)
        }
        items.removeAll()
        return out
    }

    /// The resources every `ops` so far needs (call once, after the last).
    func resources(_ doc: MuDoc, _ resourceName: String) -> PObj {
        var fonts = doc.dict()
        if !unicode {
            fonts.set(PdfNames.bare(resourceName), FontResources.standard(doc, std.baseFont))
        } else if let writer {
            fonts = writer.buildFonts(doc)
        }
        return doc.dict([("Font", fonts)])
    }

    /// Greedy word wrap to `maxWidth` (explicit line breaks kept; a word that doesn't fit is split between characters).
    func wrap(_ text: String, _ maxWidth: Double, _ size: Double) -> [String] {
        var lines: [String] = []
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for para in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            for word in para.split(separator: " ", omittingEmptySubsequences: false).map(String.init) {
                let candidate = line.isEmpty ? word : line + " " + word
                if measure(candidate) * size <= maxWidth || candidate.isEmpty {
                    line = candidate
                    continue
                }
                if !line.isEmpty { lines.append(line) }
                line = word
                // A single word wider than the box: broken between characters in one pass, at least one per line.
                if measure(line) * size > maxWidth {
                    let chars = Array(word)
                    var start = 0
                    var width = 0.0
                    for i in chars.indices {
                        let cw = measure(String(chars[i])) * size
                        if i > start && width + cw > maxWidth {
                            lines.append(String(chars[start..<i]))
                            start = i
                            width = 0
                        }
                        width += cw
                    }
                    line = String(chars[start...])
                }
            }
            lines.append(line)
        }
        return lines
    }
}

/// PDF names written with or without their slash.
enum PdfNames {
    static func bare(_ name: String) -> String { name.hasPrefix("/") ? String(name.dropFirst()) : name }
}

/// Standard-14 font dictionaries, shared per document: the form's /DR fonts or earlier stamps' when they match, else one
/// new object per font.
enum FontResources {
    static func standard(_ doc: MuDoc, _ baseFont: String) -> PObj {
        if let hit = doc.standardFonts[baseFont] { return hit }
        let winAnsi = baseFont != "ZapfDingbats" && baseFont != "Symbol"

        func matches(_ item: PObj) -> Bool {
            guard item.isRef, item.isDict, item.name("Subtype") == "Type1", item.name("BaseFont") == baseFont,
                  !item.has("FontDescriptor") else { return false }
            return winAnsi ? item.name("Encoding") == "WinAnsiEncoding" : !item.has("Encoding")
        }

        var found: PObj?
        if let dr = doc.catalog.dict("AcroForm")?.dict("DR")?.dict("Font") {
            found = dr.values.first(where: matches)
        }
        if found == nil, let count = try? doc.pageCount() {
            search: for p in 0..<count {
                for a in doc.page(p).array("Annots")?.elements ?? [] where a.isDict {
                    guard let nm = a.text("NM"), TextStamps.isOwnId(nm) || Annotations.isOwnId(nm) else { continue }
                    if let f = a.dict("AP")?.dict("N")?.dict("Resources")?.dict("Font"), let hit = f.values.first(where: matches) {
                        found = hit
                        break search
                    }
                }
            }
        }
        let font: PObj
        if let found {
            font = found
        } else {
            var entries: [(String, PObj)] = [("Type", doc.name("Font")), ("Subtype", doc.name("Type1")), ("BaseFont", doc.name(baseFont))]
            if winAnsi { entries.append(("Encoding", doc.name("WinAnsiEncoding"))) }
            font = doc.add(doc.dict(entries))
        }
        doc.standardFonts[baseFont] = font
        return font
    }
}

extension PObj {
    /// A dictionary's values.
    var values: [PObj] { keys.compactMap { self[$0] } }
}
