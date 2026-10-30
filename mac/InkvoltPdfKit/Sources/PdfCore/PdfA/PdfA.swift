import CoreText
import Foundation
import MuPDFShim

/// PDF/A-2 levels: B keeps the look; A also keeps the structure (tags, language, Unicode text) for accessibility.
public enum PdfAConformance: String, Equatable, Sendable {
    case b = "B", a = "A"

    /// How the app says the level.
    public var name: String { self == .a ? "PDF/A-2a" : "PDF/A-2b" }
}

/// A document can't be made PDF/A-2b (or 2a); `blockers` says why (nothing was changed) (the Windows app's `PdfAException`).
public struct PdfAError: Error, Equatable, Sendable, CustomStringConvertible {
    public var blockers: [String]
    public init(_ blockers: [String]) { self.blockers = blockers }
    public var description: String { "This PDF can't be saved as PDF/A: " + blockers.joined(separator: " ") }
}

/// A PDF/A copy and what was changed to conform, in words (removed scripts, embedded fonts, ...).
public struct PdfAResult: Sendable {
    public var data: [UInt8]
    public var changes: [String]
}

/// Save as PDF/A-2b (ISO 19005-2, level B: the look is preserved for archiving), the Windows app's `PdfA`. A copy is
/// made that: is unencrypted; carries an sRGB output intent (`IccProfiles.srgb`, a profile written here) and a new XMP
/// packet with pdfaid part 2, conformance B, matching the document properties; has no JavaScript, forbidden actions
/// (Launch, Sound, Movie, ResetForm, ImportData, Hide, SetOCGState, Rendition, Trans, GoTo3DView, named actions other
/// than page navigation), additional actions, XFA, multimedia or embedded files; whose annotations print and have a normal
/// appearance only (hidden ones and ones without an appearance are removed; form fields get appearances first); whose
/// images don't interpolate or carry alternates or OPI; with LZW streams re-encoded with Flate, transfer and halftone
/// functions dropped, optional-content configurations named; and whose fonts are all embedded: the standard Helvetica,
/// Times and Courier faces (also named Arial, Times New Roman, Courier New) are embedded from the metric-compatible
/// fonts macOS ships, the same Arial, Times New Roman and Courier New as Windows' (a subset, `TrueTypeSubset`, WinAnsi
/// with differences), CIDSet and CharSet removed. What can't be fixed without changing the look refuses the conversion
/// (`PdfAError`): other fonts that aren't embedded, CMYK color without a profile (the output intent is RGB), PostScript
/// or external content, digital signatures (a rewrite would break them), widgets without appearances. `validate`
/// checks the rules handled here; it is not a full validator.
///
/// Level A (PDF/A-2a): the tags kept, a language required, every character's Unicode value (`FontUnicode`); a document that
/// says it is PDF/UA keeps saying so, with the extension schema PDF/A requires for that. Make Accessible makes such a
/// document.
public enum PdfA {
    static let forbiddenActions: Set<String> = ["Launch", "Sound", "Movie", "ResetForm", "ImportData", "Hide", "SetOCGState", "Rendition", "Trans",
                                                "GoTo3DView", "JavaScript", "RichMediaExecute", "SetState", "NOP"]
    static let allowedNamed: Set<String> = ["NextPage", "PrevPage", "FirstPage", "LastPage"]
    static let removedAnnotations: Set<String> = ["Sound", "Movie", "Screen", "3D", "RichMedia", "FileAttachment", "TrapNet"]
    static let flagInvisible = 1, flagHidden = 2, flagPrint = 4, flagNoView = 32, flagToggleNoView = 256

    /// What stops `data` from being made PDF/A-2b or 2a (empty: it can be). Nothing is changed.
    /// - Throws: `OwnerPasswordRequired` for an encrypted document opened without its permissions password.
    public static func check(_ data: [UInt8], _ password: String?, conformance: PdfAConformance = .b) throws -> [String] {
        do {
            _ = try convert(data, password, conformance: conformance)
            return []
        } catch let e as PdfAError {
            return e.blockers
        }
    }

    /// Makes a PDF/A-2b copy of the document (see the type's remarks). `.a` (PDF/A-2a) needs a tagged document with a
    /// language (Make Accessible makes one); its tags are kept.
    /// - Throws: `PdfAError` when something can't be made conforming without changing the look, or (2a) it isn't tagged;
    ///   `OwnerPasswordRequired` for an encrypted document opened without its permissions password.
    public static func convert(_ data: [UInt8], _ password: String?, now: Date? = nil, conformance: PdfAConformance = .b) throws -> PdfAResult {
        var data = data
        var changes: [String] = []
        if SignedEdits.looksSigned(data) && Signatures.verify(data, password).contains(where: { $0.status != .unsigned }) {
            throw PdfAError(["It is digitally signed: a PDF/A copy is a rewrite, which would break the signatures. (Sanitize can remove them first.)"])
        }
        if try PdfSecurity.readSecurity(data, password).isEncrypted {
            data = try PdfSecurity.unprotect(data, password)
            changes.append("password protection removed (PDF/A files can't be encrypted)")
        }

        // Scripts, actions that run things, multimedia, XFA and attached files: what Sanitize removes.
        let sanitized = try Sanitizer.sanitize(data, nil, [.activeContent, .embeddedFiles])
        if sanitized.removed[.activeContent] > 0 {
            changes.append("\(count(sanitized.removed[.activeContent], "script or active item", "scripts and active items")) removed")
        }
        if sanitized.removed[.embeddedFiles] > 0 {
            changes.append("\(count(sanitized.removed[.embeddedFiles], "attached file", "attached files")) removed")
        }
        data = sanitized.data

        let doc = try PdfEdit.open(data, nil, failure: "This PDF can't be converted")
        var pdfUa = false
        if conformance == .a {
            var blockers: [String] = []
            let catalog = doc.catalog
            if !catalog.has("StructTreeRoot") || catalog.dict("MarkInfo")?["Marked"].map({ $0.kind == .bool && $0.bool }) != true {
                blockers.append("It isn't tagged: PDF/A-2a keeps the document's structure, so tag it first (Tools › Make Accessible).")
            }
            if !AutoTag.isLanguage(catalog.text("Lang")) { blockers.append("It doesn't say its language: PDF/A-2a needs one (Make Accessible sets it).") }
            if !blockers.isEmpty { throw PdfAError(blockers) }
            pdfUa = Xmp.saysPdfUa(Xmp.read(doc))
            // Level A wants every character's Unicode value (6.2.11.7.2): TeX's math glyphs get theirs.
            let fonts = try FontUnicode.complete(doc)
            if fonts > 0 { changes.append("\(count(fonts, "font", "fonts")) given the Unicode values of their characters") }
        }
        let pass = try Pass(doc, changes)
        try pass.run()
        if !pass.blockers.isEmpty { throw PdfAError(unique(pass.blockers)) }
        changes = pass.changes

        let version = Int(inkv_pdf_version(doc.ctx, doc.doc))
        if version > 17 || version < 14 {
            doc.catalog.remove("Version")
            doc.note { inkv_set_pdf_version(doc.ctx, doc.doc, 17, $0) }
        }
        InfoDict.setDate(doc, "ModDate", now ?? Date())
        cleanInfo(doc) // the XMP packet carries the same values (6.6.2.3): trimmed, without control characters
        InfoDict.get(doc, create: false)?.remove("Trapped") // optional, and a wrong value would break conformance
        let packet = Xmp.buildPdfA(Xmp.Values(doc), conformance: conformance.rawValue, pdfUa: pdfUa)
        let catalog = doc.catalog
        if let stream = catalog["Metadata"], stream.isStream {
            stream.setStream(packet, deflate: false)
            stream.set("Type", doc.name("Metadata"))
            stream.set("Subtype", doc.name("XML"))
        } else {
            catalog.set("Metadata", doc.addStream(packet, dict: doc.dict([("Type", doc.name("Metadata")), ("Subtype", doc.name("XML"))]), deflate: false))
        }
        // PDF/A wants a file identifier (6.1.3); MuPDF writes one only when the document had one.
        if (doc.trailer.array("ID")?[0]?.bytes ?? []).isEmpty {
            let id = (0..<16).map { _ in UInt8.random(in: 0...255) }
            doc.trailer.set("ID", doc.array([doc.string(id), doc.string(id)]))
        }
        try doc.checkFailure()
        let result = try doc.write("garbage=compact")
        let left = validate(result, conformance: conformance)
        if !left.isEmpty { throw PdfAError(left) }
        return PdfAResult(data: result, changes: changes)
    }

    // ───────────── what the app says (the Windows app's PdfAActions) ─────────────

    /// The copy's suggested file name: "Report (PDF-A).pdf" for "Report.pdf", "Report (PDF-A-2a).pdf" at level A.
    public static func copyName(_ displayName: String, conformance: PdfAConformance = .b) -> String {
        ((displayName as NSString).deletingPathExtension) + (conformance == .a ? " (PDF-A-2a).pdf" : " (PDF-A).pdf")
    }

    /// Why nothing was saved: each blocker on a line of its own.
    public static func refusalMessage(_ blockers: [String], conformance: PdfAConformance = .b) -> String {
        "Nothing was saved. This document has what \(conformance.name) doesn't allow, and changing it would change how the document looks:\n\n"
            + blockers.map { "• " + $0 }.joined(separator: "\n")
    }

    /// What the saved copy is and what was changed to get there.
    public static func savedMessage(_ fileName: String, _ changes: [String], conformance: PdfAConformance = .b) -> String {
        "\(fileName) is an archival copy (\(conformance.name)\(conformance == .a ? ", tagged for accessibility" : "")). To get there:\n\n"
            + changes.map { "• " + capitalized($0) }.joined(separator: "\n")
            + "\n\nInkvolt PDF checks the rules it changes; for a formal check, use a PDF/A validator such as veraPDF."
    }

    /// Embeds the standard Helvetica, Times and Courier faces the document draws with but doesn't embed, as the PDF/A copy
    /// does (the Mac's metric-compatible fonts); other fonts are left as they are. How many were embedded.
    @discardableResult
    static func embedStandardFonts(_ doc: MuDoc) throws -> Int {
        let pass = try Pass(doc, [])
        pass.fonts()
        return pass.embedded
    }

    /// The first letter capitalized, unless the word is one like "sRGB" (Windows writes "SRGB").
    static func capitalized(_ s: String) -> String {
        let c = Array(s)
        if c.count > 1 && c[1].isUppercase { return s }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    static func count(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }

    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// Writes the document properties back as the XMP packet will carry them (`Xmp.clean`), so both say exactly the same.
    private static func cleanInfo(_ doc: MuDoc) {
        guard let info = InfoDict.get(doc, create: false) else { return }
        for key in ["Title", "Author", "Subject", "Keywords", "Creator", "Producer"] {
            guard let value = info.text(key) else { continue }
            let clean = Xmp.clean(value)
            if clean == value { continue }
            if clean.isEmpty { info.remove(key) } else { info.set(key, doc.text(clean)) }
        }
    }

    /// The base-14 Latin face a font name stands for, and so the system font with its metrics: the standard names
    /// (Helvetica-Bold, Times-Roman, Courier-Oblique ...) and the Windows twins as PDF writers name them (Arial,Bold;
    /// Arial-BoldMT; TimesNewRomanPS-ItalicMT; CourierNew,BoldItalic), with a subset prefix or not. Nil for anything else:
    /// other designs of the family (Helvetica Neue, condensed, narrow, black) have other widths.
    static func standardFace(_ baseFont: String) -> StdFont? {
        var n = Substring(baseFont)
        while n.hasPrefix("/") { n = n.dropFirst() }
        if n.count > 7 && n[n.index(n.startIndex, offsetBy: 6)] == "+" { n = n.dropFirst(7) }
        let name = n.replacingOccurrences(of: " ", with: "")
        var family: String, style: String
        if let comma = name.firstIndex(of: ",") {
            (family, style) = (String(name[..<comma]), String(name[name.index(after: comma)...]))
        } else if let dash = name.firstIndex(of: "-") {
            (family, style) = (String(name[..<dash]), String(name[name.index(after: dash)...]))
        } else {
            (family, style) = (name, "")
        }
        for tail in ["PSMT", "MT", "PS"] where family.hasSuffix(tail) { family.removeLast(tail.count) }
        if style.hasSuffix("MT") { style.removeLast(2) }
        let f: StdFamily?
        switch family {
        case "Helvetica", "Arial": f = .helvetica
        case "Times", "TimesNewRoman": f = .times
        case "Courier", "CourierNew": f = .courier
        default: f = nil
        }
        let s: (bold: Bool, italic: Bool)?
        switch style {
        case "", "Roman", "Regular", "Normal": s = (false, false)
        case "Bold": s = (true, false)
        case "Italic", "Oblique": s = (false, true)
        case "BoldItalic", "BoldOblique": s = (true, true)
        default: s = nil
        }
        guard let f, let s else { return nil }
        return StdFont(f, s.bold, s.italic)
    }
}

extension TrueTypeFont {
    /// The font file's bytes (Core Text's URL for the font), for embedding; nil when it has no file.
    var fileData: [UInt8]? {
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL, let data = try? Data(contentsOf: url) else { return nil }
        return [UInt8](data)
    }
}

extension Xmp {
    static let pdfaid = "http://www.aiim.org/pdfa/ns/id/"

    /// A new packet for a PDF/A-2 file: the Info-backed properties, dates and IDs (as `build` writes them), plus pdfaid:part
    /// 2 and the conformance. Only schemas PDF/A predefines, and with `pdfUa` pdfuaid:part 1 with the extension schema PDF/A
    /// asks for it.
    static func buildPdfA(_ info: Values, conformance: String = "B", pdfUa: Bool = false) -> [UInt8] {
        let xml = document(info, original: nil)
        let r = rdfElement(xml)!
        let d = XMLElement(name: "rdf:Description", uri: rdf)
        d.addAttribute(XMLNode.attribute(withName: "rdf:about", uri: rdf, stringValue: "") as! XMLNode)
        d.addNamespace(XMLNode.namespace(withName: "pdfaid", stringValue: pdfaid) as! XMLNode)
        let part = XMLElement(name: "pdfaid:part", uri: pdfaid)
        part.stringValue = "2"
        let level = XMLElement(name: "pdfaid:conformance", uri: pdfaid)
        level.stringValue = conformance
        d.addChild(part)
        d.addChild(level)
        r.addChild(d)
        if pdfUa { addPdfUaSchema(r) }
        return packet(xml)
    }

    /// pdfuaid:part 1 and the extension schema that describes it.
    private static func addPdfUaSchema(_ r: XMLElement) {
        let pdfaExtension = "http://www.aiim.org/pdfa/ns/extension/", pdfaSchema = "http://www.aiim.org/pdfa/ns/schema#", pdfaProperty = "http://www.aiim.org/pdfa/ns/property#"
        func element(_ name: String, _ uri: String, _ value: String? = nil, _ children: [XMLElement] = []) -> XMLElement {
            let e = XMLElement(name: name, uri: uri)
            if let value { e.stringValue = value }
            for c in children { e.addChild(c) }
            return e
        }
        func description(_ namespaces: [(String, String)], _ children: [XMLElement]) -> XMLElement {
            let d = XMLElement(name: "rdf:Description", uri: rdf)
            d.addAttribute(XMLNode.attribute(withName: "rdf:about", uri: rdf, stringValue: "") as! XMLNode)
            for (prefix, uri) in namespaces { d.addNamespace(XMLNode.namespace(withName: prefix, stringValue: uri) as! XMLNode) }
            for c in children { d.addChild(c) }
            return d
        }
        func resource(_ children: [XMLElement]) -> XMLElement {
            let li = element("rdf:li", rdf, nil, children)
            li.addAttribute(XMLNode.attribute(withName: "rdf:parseType", uri: rdf, stringValue: "Resource") as! XMLNode)
            return li
        }
        r.addChild(description([("pdfuaid", pdfUaId)], [element("pdfuaid:part", pdfUaId, "1")]))
        let property = resource([
            element("pdfaProperty:name", pdfaProperty, "part"), element("pdfaProperty:valueType", pdfaProperty, "Integer"),
            element("pdfaProperty:category", pdfaProperty, "internal"),
            element("pdfaProperty:description", pdfaProperty, "Indicates, which part of ISO 14289 standard is followed"),
        ])
        let schema = resource([
            element("pdfaSchema:schema", pdfaSchema, "PDF/UA Universal Accessibility Schema"), element("pdfaSchema:namespaceURI", pdfaSchema, pdfUaId),
            element("pdfaSchema:prefix", pdfaSchema, "pdfuaid"), element("pdfaSchema:property", pdfaSchema, nil, [element("rdf:Seq", rdf, nil, [property])]),
        ])
        r.addChild(description([("pdfaExtension", pdfaExtension), ("pdfaSchema", pdfaSchema), ("pdfaProperty", pdfaProperty)],
                               [element("pdfaExtension:schemas", pdfaExtension, nil, [element("rdf:Bag", rdf, nil, [schema])])]))
    }
}
