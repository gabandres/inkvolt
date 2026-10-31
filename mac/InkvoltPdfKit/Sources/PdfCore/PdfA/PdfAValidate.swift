import Foundation

extension PdfA {
    /// The PDF/A-2b (or 2a) rules `convert` handles, checked on a finished file (empty: none broken). Not a full validator:
    /// font program internals, color in shadings and inline images, and many other rules are not looked at.
    public static func validate(_ pdf: [UInt8], conformance: PdfAConformance = .b) -> [String] {
        let level = conformance.rawValue
        var problems: [String] = []
        if !hasPdfAHeader(pdf) { problems.append("The file header isn't a PDF 1.x header followed by a binary comment.") }
        let doc: MuDoc
        do {
            doc = try MuDoc.open(pdf)
        } catch let e as PdfEngineError {
            return problems + ["The file can't be read: \(e.message)"]
        } catch {
            return problems + ["The file can't be read: \(error)"]
        }
        if doc.hasEncrypt { problems.append("It is encrypted.") }
        if (doc.trailer.array("ID")?[0]?.bytes ?? []).isEmpty { problems.append("The trailer has no file identifier (/ID).") }
        let catalog = doc.catalog
        if conformance == .a {
            if !catalog.has("StructTreeRoot") { problems.append("It isn't tagged (no structure tree).") }
            if catalog.dict("MarkInfo")?["Marked"].map({ $0.kind == .bool && $0.bool }) != true { problems.append("It doesn't say it is tagged (MarkInfo).") }
            if !AccessibilityCheck.isLanguage(catalog.text("Lang")) { problems.append("It doesn't say its language.") }
        }
        let pdfa = catalog.array("OutputIntents")?.elements.first { $0.isDict && $0.name("S") == "GTS_PDFA1" }
        let profile = pdfa?.dict("DestOutputProfile")
        let icc = profile?.isStream == true && profile?.int("N") == 3 ? profile?.streamData ?? [] : []
        if icc.count <= 128 || Array(icc[36..<40]) != Array("acsp".utf8) {
            problems.append("There is no RGB PDF/A output intent with an ICC profile.")
        }
        if let meta = catalog.dict("Metadata"), meta.isStream, let raw = meta.rawStreamData {
            if meta.has("Filter") { problems.append("The XMP metadata is compressed.") }
            let xmp = String(decoding: raw, as: UTF8.self)
            if !xmp.contains("pdfaid:part=\"2\"") && !xmp.contains("<pdfaid:part>2</pdfaid:part>") { problems.append("The XMP metadata doesn't say PDF/A-2.") }
            if !xmp.contains("pdfaid:conformance=\"\(level)\"") && !xmp.contains("<pdfaid:conformance>\(level)</pdfaid:conformance>") {
                problems.append("The XMP metadata doesn't say conformance \(level).")
            }
            if conformance == .a && xmp.contains("pdfuaid") && !xmp.contains("pdfaSchema:prefix>pdfuaid<") {
                problems.append("The XMP metadata says PDF/UA without the extension schema PDF/A requires.")
            }
        } else {
            problems.append("There is no XMP metadata.")
        }
        if catalog.has("AA") { problems.append("The document has additional actions.") }
        if let names = catalog.dict("Names"), names.has("JavaScript") || names.has("EmbeddedFiles") {
            problems.append("The document has scripts or attached files.")
        }
        if let acro = catalog.dict("AcroForm"), acro.has("XFA") || acro["NeedAppearances"].map({ $0.kind == .bool && $0.bool }) == true {
            problems.append("The form is an XFA form or needs the viewer to draw its fields.")
        }

        var seen = Set<UInt>()
        var stack = [catalog]
        while let o = stack.popLast() {
            guard o.isDict || o.isArray, seen.insert(o.identity).inserted else { continue }
            if o.isArray {
                for e in o.elements where e.isDict || e.isArray { stack.append(e) }
                continue
            }
            let d = o
            for key in d.keys where key != "Parent" && key != "P" {
                if let v = d[key], v.isDict || v.isArray { stack.append(v) }
            }
            problems += objectProblems(d)
        }
        for page in (try? doc.pages()) ?? [] {
            for a in page.array("Annots")?.elements ?? [] where a.isDict {
                let subtype = a.name("Subtype") ?? ""
                let flags = a.int("F") ?? 0
                if removedAnnotations.contains(subtype) { problems.append("It has a \(subtype) annotation.") }
                if flags & flagPrint == 0 || flags & (flagInvisible | flagHidden | flagNoView | flagToggleNoView) != 0 {
                    problems.append("An annotation doesn't print or is hidden.")
                }
                let ap = a.dict("AP")
                if let ap, ap.has("R") || ap.has("D") { problems.append("An annotation has rollover or down appearances.") }
                if ap?["N"] == nil && subtype != "Popup" && subtype != "Link" && !zeroRect(a.array("Rect")) {
                    problems.append("An annotation has no appearance.")
                }
            }
        }
        return unique(problems)
    }

    /// What one dictionary of a finished file breaks.
    private static func objectProblems(_ d: PObj) -> [String] {
        var problems: [String] = []
        if d.has("AA") { problems.append("Something has additional actions.") }
        let type = d.name("Type")
        let subtype = d.name("Subtype")
        if let s = d.name("S"), !d.has("K"), type == "Action" || forbiddenActions.contains(s),
           forbiddenActions.contains(s) || s == "Named" && !allowedNamed.contains(d.name("N") ?? "") {
            problems.append("It has a \(s) action.")
        }
        if d.isStream, let filter = d["Filter"], filter.name == "LZWDecode" || filter.elements.contains(where: { $0.name == "LZWDecode" }) {
            problems.append("A stream is LZW-compressed.")
        }
        if subtype == "Image" && (d["Interpolate"].map { $0.kind == .bool && $0.bool } == true || d.has("Alternates") || d.has("OPI")) {
            problems.append("A picture has interpolation, alternates or OPI.")
        }
        if subtype == "PS" { problems.append("It has a PostScript XObject.") }
        if d.has("TR") || d.has("HTP") { problems.append("A graphics state has a transfer function or halftone origin.") }
        let simple = type == "Font" && (subtype == "Type1" || subtype == "TrueType" || subtype == "MMType1")
        if (simple || subtype == "CIDFontType0" || subtype == "CIDFontType2") && !Pass.isEmbedded(d.dict("FontDescriptor")) {
            problems.append("The font \(d.name("BaseFont") ?? "") isn't embedded.")
        }
        return problems
    }

    /// "%PDF-1.x", a line end, then a comment of at least four bytes over 127 (6.1.2).
    static func hasPdfAHeader(_ pdf: [UInt8]) -> Bool {
        let head = Array("%PDF-1.".utf8)
        guard pdf.count >= 14, Array(pdf[0..<7]) == head, (48...55).contains(pdf[7]) else { return false }
        var i = 8
        if pdf[i] == 13 { i += 1 }
        guard i < pdf.count, pdf[i] == 10 else { return false }
        i += 1
        guard i + 5 <= pdf.count, pdf[i] == 37 else { return false }
        return pdf[(i + 1)..<(i + 5)].allSatisfy { $0 >= 0x80 }
    }
}
