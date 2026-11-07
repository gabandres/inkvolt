import Foundation

/// Fill & Sign items. `signature`: a handwritten signature or initials image; `image`: a picture placed with the Image
/// tool (both `SignatureStamps`); `stamp`: a stamp (`RubberStamps`).
public enum StampKind: String, Sendable { case text, check, cross, signature, image, stamp }

/// Text or a mark placed on a page by Fill & Sign (a FreeText annotation Inkvolt PDF created), or a placed picture or
/// stamp.
public struct TextStamp: Equatable, Sendable {
    public var id: String
    public var pageIndex: Int
    public var rect: RectD
    public var kind: StampKind
    public var text: String
    public var fontSize: Double
}

/// Fill & Sign (the Windows app's `TextStamps`): typed text, check marks and crosses placed anywhere on a page, for forms
/// without fields (scans). Each is a standard FreeText annotation with its own appearance, so every viewer shows it and
/// Inkvolt PDF can edit it later. Text uses the built-in Helvetica when it can (WinAnsi: accents work, no font
/// embedding) and embedded fonts for other scripts; marks use ZapfDingbats. Font objects are shared between stamps.
public enum TextStamps {
    private static let idPrefix = "InkvoltPdf-"
    /// The id prefix of stamps made before the Inkvolt rename; still recognized so they stay editable.
    private static let legacyIdPrefix = "PdfDesk-"

    /// True for an /NM this app gives its stamps (Fill & Sign text, marks and signatures), old or new.
    static func isOwnId(_ nm: String?) -> Bool {
        guard let nm else { return false }
        return nm.hasPrefix(idPrefix) || nm.hasPrefix(legacyIdPrefix)
    }

    public static func read(_ data: [UInt8], _ password: String?) throws -> [TextStamp] {
        let doc = try PdfEdit.openToRead(data, password)
        var list: [TextStamp] = []
        for p in 0..<(try doc.pageCount()) {
            let page = doc.page(p)
            for a in page.array("Annots")?.elements ?? [] where a.isDict && a.name("Subtype") == "FreeText" {
                guard let nm = a.text("NM"), isOwnId(nm), let r = a.array("Rect"), r.count >= 4 else { continue }
                let rect = PageBoxes.rectToPage(page, r)
                let kind: StampKind = nm.contains("-check-") ? .check : nm.contains("-cross-") ? .cross : .text
                list.append(TextStamp(id: nm, pageIndex: p, rect: rect, kind: kind, text: a.text("Contents") ?? "",
                                      fontSize: parseFontSize(a.text("DA") ?? "")))
            }
        }
        return list
    }

    /// Adds (or, with an existing id, replaces) a stamp. `rect` is in page space; text lines are split on '\n'.
    public static func put(_ data: [UInt8], _ password: String?, _ pageIndex: Int, _ rect: RectD, _ kind: StampKind, _ text: String,
                           _ fontSize: Double, replaceId: String? = nil) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            try Annotations.checkPage(doc, pageIndex)
            let page = doc.page(pageIndex)
            if let replaceId { _ = try removeFrom(doc, replaceId) }
            let annots = doc.annots(page)
            let r = PageBoxes.fromPageSpace(page, rect)

            // The appearance, drawn upright in the viewer (counter-rotated against the page's /Rotate). Text the
            // standard Helvetica can encode stays non-embedded; other scripts get embedded fonts.
            let content: [UInt8]
            let resources: PObj
            if kind == .text && !WinAnsi.canEncode(text) {
                let painter = TextPainter(.helvetica, [text])
                let leading = fontSize * 1.2
                var y = rect.height - fontSize
                for line in text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
                    painter.draw(String(line), fontSize * 0.15, y, fontSize)
                    y -= leading
                }
                let built = painter.build(doc, rect.width, rect.height, "/Helv", .black)
                content = Array("/Tx BMC ".utf8) + built.ops + Array(" EMC".utf8)
                resources = built.resources
            } else {
                content = kind == .text ? textContent(text, fontSize, rect.height) : markContent(kind, rect.width, rect.height)
                let fonts = kind == .text
                    ? doc.dict([("Helv", FontResources.standard(doc, "Helvetica"))])
                    : doc.dict([("ZaDb", FontResources.standard(doc, "ZapfDingbats"))])
                resources = doc.dict([("Font", fonts)])
            }
            let ap = doc.formXObject(content, 0, 0, rect.width, rect.height, resources, matrix: doc.counterRotation(page), deflate: false)

            let tag = kind.rawValue
            var id = replaceId ?? "\(idPrefix)\(tag)-\(NewIds.hex())"
            if let replaceId, !replaceId.contains("-\(tag)-") { id = "\(idPrefix)\(tag)-\(NewIds.hex())" }
            let contents = kind == .check ? "✓" : kind == .cross ? "✗" : text
            let annot = doc.add(doc.dict([
                ("Type", doc.name("Annot")), ("Subtype", doc.name("FreeText")), ("Rect", doc.realArray([r.x1, r.y1, r.x2, r.y2])),
                ("Contents", doc.text(contents)), ("NM", doc.text(id)), ("F", doc.int(4)),
                ("DA", doc.text("0 g /Helv \(PdfNum.f2(fontSize)) Tf")), ("BS", doc.dict([("W", doc.int(0))])), ("M", doc.now()),
                ("AP", doc.dict([("N", ap)])), ("P", page),
            ]))
            annots.append(annot)
        }
    }

    /// Removes a stamp (Fill & Sign text or mark, a placed signature, picture or stamp).
    public static func remove(_ data: [UInt8], _ password: String?, _ id: String) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            // On a signed file the stamp stays in the signed revision (an appended removal), like a deleted comment.
            if try removeFrom(doc, id) { SignedEdits.noteRemoval() }
        }
    }

    private static func removeFrom(_ doc: MuDoc, _ id: String) throws -> Bool {
        var any = false
        for p in 0..<(try doc.pageCount()) {
            let page = doc.page(p)
            guard page.array("Annots") != nil else { continue }
            let annots = doc.annots(page)
            for i in stride(from: annots.count - 1, through: 0, by: -1) {
                if let a = annots[i], a.isDict, a.text("NM") == id {
                    annots.remove(at: i)
                    any = true
                }
            }
        }
        return any
    }

    /// Text lines, top-left aligned, black Helvetica.
    private static func textContent(_ text: String, _ size: Double, _ boxHeight: Double) -> [UInt8] {
        let leading = size * 1.2
        var out = Array("/Tx BMC q BT 0 g /Helv \(PdfNum.f2(size)) Tf \(PdfNum.f2(leading)) TL ".utf8)
        out += Array("1 0 0 1 \(PdfNum.f2(size * 0.15)) \(PdfNum.f2(boxHeight - size)) Tm ".utf8)
        var first = true
        for line in text.replacingOccurrences(of: "\r", with: "").split(separator: "\n", omittingEmptySubsequences: false) {
            if !first { out += Array("T* ".utf8) }
            out += [40] + WinAnsi.literal(String(line)) + Array(") Tj ".utf8)
            first = false
        }
        out += Array("ET Q EMC".utf8)
        return out
    }

    /// ZapfDingbats ✔ ("4") or ✘ ("8") scaled to the box.
    private static func markContent(_ kind: StampKind, _ w: Double, _ h: Double) -> [UInt8] {
        let size = min(w, h) * 1.05
        let glyph = kind == .check ? "4" : "8"
        // ZapfDingbats' check is about 0.75 em wide; centered in the box.
        let x = (w - size * 0.8) / 2
        let y = (h - size * 0.7) / 2
        return Array("q BT 0 g /ZaDb \(PdfNum.f2(size)) Tf 1 0 0 1 \(PdfNum.f2(x)) \(PdfNum.f2(y)) Tm (\(glyph)) Tj ET Q".utf8)
    }

    private static func parseFontSize(_ da: String) -> Double {
        let parts = da.split(separator: " ").map(String.init)
        guard let i = parts.firstIndex(of: "Tf"), i > 0, let s = Double(parts[i - 1]), s > 0 else { return 12 }
        return s
    }
}
