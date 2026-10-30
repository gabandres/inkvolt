import CoreText
import Foundation
import MuPDFShim

/// A document can't be made PDF/A-2b; `blockers` says why (nothing was changed) (the Windows app's `PdfAException`).
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
/// Level A (PDF/A-2a, Windows' `PdfAConformance.A`: the tags kept, a language required, every character's Unicode value)
/// needs Make Accessible, which isn't on the Mac yet (roadmap 2.4): when it comes, `convert` takes the level, checks the
/// tags and language before `Pass` runs, writes "A" into the packet (`Xmp.buildPdfA`) and `validate` checks the tags.
public enum PdfA {
    static let forbiddenActions: Set<String> = ["Launch", "Sound", "Movie", "ResetForm", "ImportData", "Hide", "SetOCGState", "Rendition", "Trans",
                                                "GoTo3DView", "JavaScript", "RichMediaExecute", "SetState", "NOP"]
    static let allowedNamed: Set<String> = ["NextPage", "PrevPage", "FirstPage", "LastPage"]
    static let removedAnnotations: Set<String> = ["Sound", "Movie", "Screen", "3D", "RichMedia", "FileAttachment", "TrapNet"]
    static let flagInvisible = 1, flagHidden = 2, flagPrint = 4, flagNoView = 32, flagToggleNoView = 256
    /// The conformance level written and checked (B; see the type's remarks for A).
    static let level = "B"

    /// What stops `data` from being made PDF/A-2b (empty: it can be). Nothing is changed.
    /// - Throws: `OwnerPasswordRequired` for an encrypted document opened without its permissions password.
    public static func check(_ data: [UInt8], _ password: String?) throws -> [String] {
        do {
            _ = try convert(data, password)
            return []
        } catch let e as PdfAError {
            return e.blockers
        }
    }

    /// Makes a PDF/A-2b copy of the document (see the type's remarks).
    /// - Throws: `PdfAError` when something can't be made conforming without changing the look; `OwnerPasswordRequired`
    ///   for an encrypted document opened without its permissions password.
    public static func convert(_ data: [UInt8], _ password: String?, now: Date? = nil) throws -> PdfAResult {
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
        let packet = Xmp.buildPdfA(Xmp.Values(doc))
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
        let left = validate(result)
        if !left.isEmpty { throw PdfAError(left) }
        return PdfAResult(data: result, changes: changes)
    }

    // ───────────── what the app says (the Windows app's PdfAActions) ─────────────

    /// The copy's suggested file name: "Report (PDF-A).pdf" for "Report.pdf".
    public static func copyName(_ displayName: String) -> String {
        ((displayName as NSString).deletingPathExtension) + " (PDF-A).pdf"
    }

    /// Why nothing was saved: each blocker on a line of its own.
    public static func refusalMessage(_ blockers: [String]) -> String {
        "Nothing was saved. This document has what PDF/A-2b doesn't allow, and changing it would change how the document looks:\n\n"
            + blockers.map { "• " + $0 }.joined(separator: "\n")
    }

    /// What the saved copy is and what was changed to get there.
    public static func savedMessage(_ fileName: String, _ changes: [String]) -> String {
        "\(fileName) is an archival copy (PDF/A-2b). To get there:\n\n"
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

    /// A new packet for a PDF/A-2b file: the Info-backed properties, dates and IDs (as `build` writes them), plus
    /// pdfaid:part 2 and the conformance. Only schemas PDF/A predefines.
    static func buildPdfA(_ info: Values, conformance: String = PdfA.level) -> [UInt8] {
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
        return packet(xml)
    }
}
