import Foundation
import Testing
@testable import PdfCore

/// Ported from IncrSignatureTests.cs: edits of signed documents are saved as incremental updates (MuPDF's), so the
/// signatures keep verifying. Adapted: CommentsAttachmentsAndMetadataAreAppended leaves out the attachment (E9); the
/// page tree after a rotation is read with MuPDF (PDFsharp on Windows); the update's file ID is compared ignoring case
/// (MuPDF writes hex strings in lower case).
struct IncrSignatureTests {
    static let contentsHexLength = 16384
    private static let placeholderRange = "[0 0000000000 0000000000 0000000000]"

    /// A signed form: a signature field ("Approval", signed), a text field ("Name"), optionally a second page. With
    /// `xrefStream` the file uses a cross-reference stream and keeps the text field and the font in an object stream.
    static func signedForm(xrefStream: Bool = false, twoPages: Bool = false) throws -> [UInt8] {
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 6 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 8 0 R >> >> /SigFlags 3 >> >>",
            twoPages ? "<< /Type /Pages /Kids [3 0 R 9 0 R] /Count 2 >>" : "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R 6 0 R] /Contents 7 0 R /Resources << /Font << /F1 8 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Approval) /Rect [72 650 272 700] /V 5 0 R /P 3 0 R /F 4 >>",
            "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange \(placeholderRange) /Contents <\(String(repeating: "0", count: contentsHexLength))> /M (D:20260101120000Z) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 500 300 530] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 720 Td (Hello contract) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        if twoPages {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 10 0 R /Resources << /Font << /F1 8 0 R >> >> >>")
            objects.append(Core2Pdf.stream("BT /F1 24 Tf 72 720 Td (Second page) Tj ET"))
        }
        let pdf = xrefStream ? buildWithXrefStream(objects, [6, 8]) : Core2Pdf.build(objects)
        return try Core2SignatureTests.sign(pdf, placeholderRange, cn: "CN=Incremental Signer")
    }

    /// Objects 1…n; `compressed` go into an object stream; a cross-reference stream at the end.
    private static func buildWithXrefStream(_ objects: [String], _ compressed: [Int]) -> [UInt8] {
        let n = objects.count
        let objStm = n + 1, xref = n + 2
        var out = Array("%PDF-1.7\n%\u{e2}\u{e3}\u{cf}\u{d3}\n".unicodeScalars.map { UInt8($0.value) })
        var offsets: [Int: Int] = [:]
        for i in 1...n where !compressed.contains(i) {
            offsets[i] = out.count
            out += Array("\(i) 0 obj\n\(objects[i - 1])\nendobj\n".utf8)
        }
        var header = "", body = ""
        for c in compressed {
            header += "\(c) \(body.utf8.count) "
            body += objects[c - 1] + "\n"
        }
        let content = header + body
        offsets[objStm] = out.count
        out += Array("\(objStm) 0 obj\n<< /Type /ObjStm /N \(compressed.count) /First \(header.utf8.count) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream\nendobj\n".utf8)
        offsets[xref] = out.count
        func be(_ v: Int, _ width: Int) -> [UInt8] { (0..<width).map { UInt8((v >> (8 * (width - 1 - $0))) & 0xFF) } }
        var rows: [UInt8] = []
        for i in 0...xref {
            if i == 0 { rows += [0, 0, 0, 0, 0, 0xFF, 0xFF] } else if let k = compressed.firstIndex(of: i) { rows += [2] + be(objStm, 4) + be(k, 2) } else { rows += [1] + be(offsets[i]!, 4) + [0, 0] }
        }
        out += Array("\(xref) 0 obj\n<< /Type /XRef /Size \(xref + 1) /W [1 4 2] /Root 1 0 R /ID [<0123456789ABCDEF0123456789ABCDEF> <0123456789ABCDEF0123456789ABCDEF>] /Length \(rows.count) >>\nstream\n".utf8)
        out += rows
        out += Array("\nendstream\nendobj\nstartxref\n\(offsets[xref]!)\n%%EOF\n".utf8)
        return out
    }

    private static func approval(_ pdf: [UInt8]) throws -> SignatureInfo {
        try #require(Signatures.verify(pdf).first { $0.fieldName == "Approval" })
    }

    private static func update(_ original: [UInt8], _ edited: [UInt8]) -> String { latin1(Array(edited[original.count...])) }

    /// The edit kept the signed bytes as they were and the signature still checks out, with later changes: permitted
    /// ones (form filling, comments, metadata), or, with `permitted` false, ones that change the signed pages.
    private static func assertAppended(_ original: [UInt8], _ edited: [UInt8], permitted: Bool = true) throws {
        #expect(try approval(original).status == .valid)
        #expect(edited.count > original.count)
        #expect(Array(edited[..<min(original.count, edited.count)]) == original, "the original bytes must be kept as they are")
        let s = try approval(edited)
        #expect(s.status == (permitted ? .modifiedAfterSigning : .disallowedChanges), "\(s.detail ?? "")")
        #expect(!s.coversWholeDocument)
        #expect(s.signerName == "Incremental Signer")
        if permitted {
            #expect(Signatures.brokenByEdits(Signatures.verify(original), edited).isEmpty)
        } else {
            #expect(s.detail?.contains("page") == true)
        }
        // Unchanged objects (the signed page content) aren't repeated in the update.
        #expect(!update(original, edited).contains("Hello contract"))
    }

    @Test(arguments: [false, true])
    func formFillIsAppended(_ xrefStream: Bool) throws {
        let pdf = try Self.signedForm(xrefStream: xrefStream)
        let filled = try FormEditor.setValues(pdf, nil, ["Name": "Ada Lovelace"])
        try Self.assertAppended(pdf, filled)
        let update = Self.update(pdf, filled)
        #expect(update.contains(xrefStream ? "/Type/XRef" : "\nxref\n") || update.contains("/Type /XRef"), "\(update.suffix(400))")
        let text = latin1(pdf)
        let prev = text[text.range(of: "startxref", options: .backwards)!.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n")[0]
        #expect(update.replacingOccurrences(of: " ", with: "").contains("/Prev\(prev)"))
        #expect(try FormEditor.read(filled, nil).first { $0.fieldName == "Name" }?.value == "Ada Lovelace")
        #expect(try Core2Pdf.allText(filled).contains("Ada Lovelace"))
        #expect(try Core2Pdf.allText(filled).contains("Hello contract"))
        if xrefStream { #expect(update.lowercased().contains("0123456789abcdef0123456789abcdef")) }

        // A second edit appends another update after the first.
        let again = try FormEditor.setValues(filled, nil, ["Name": "Grace Hopper"])
        #expect(Array(again[..<filled.count]) == filled)
        #expect(try Self.approval(again).status == .modifiedAfterSigning)
        #expect(try Core2Pdf.allText(again).contains("Grace Hopper"))
        #expect(!(try Core2Pdf.allText(again).contains("Ada Lovelace")))
    }

    @Test(arguments: [false, true])
    func fillAndSignTextIsAppended(_ xrefStream: Bool) throws {
        let pdf = try Self.signedForm(xrefStream: xrefStream)
        let stamped = try TextStamps.put(pdf, nil, 0, RectD(72, 300, 200, 20), .text, "Received", 12)
        try Self.assertAppended(pdf, stamped)
        #expect(try Core2Pdf.allText(stamped).contains("Received"))
        let stamps = try TextStamps.read(stamped, nil)
        try #require(stamps.count == 1)
        let removed = try TextStamps.remove(stamped, nil, stamps[0].id)
        #expect(try Self.approval(removed).status == .modifiedAfterSigning)
        #expect(try TextStamps.read(removed, nil).isEmpty)
    }

    @Test func commentsAndMetadataAreAppended() throws {
        let pdf = try Self.signedForm()
        let noted = try Annotations.addNote(pdf, nil, 0, 400, 100, "Checked", author: "Reviewer")
        try Self.assertAppended(pdf, noted)
        #expect(try Annotations.read(noted, nil).contains { $0.contents == "Checked" })

        let titled = try PageEditor.writeMetadata(noted, nil, "Contract", "Ada", "", "")
        #expect(try Self.approval(titled).status == .modifiedAfterSigning)
        #expect(try PageEditor.readMetadata(titled, nil).title == "Contract")
    }

    @Test(arguments: [false, true])
    func pageRotateAndDeleteAreAppendedButNotPermitted(_ xrefStream: Bool) throws {
        // The signature stays intact, but rotating or removing a signed page changes what was signed.
        let pdf = try Self.signedForm(xrefStream: xrefStream, twoPages: true)
        let rotated = try PageEditor.rotate(pdf, nil, [1], 90)
        try Self.assertAppended(pdf, rotated, permitted: false)
        #expect(try Self.approval(rotated).detail?.contains("page 2") == true)
        let doc = try Core2Pdf.open(rotated)
        #expect(PageBoxes.rotate(doc.page(0)) == 0)
        #expect(PageBoxes.rotate(doc.page(1)) == 90)
        let engine = try PdfEngine.open(rotated)
        #expect(engine.pageCount == 2)
        #expect(engine.page(1).width > engine.page(1).height, "MuPDF shows page 2 rotated")
        engine.close()

        let deleted = try PageEditor.delete(pdf, nil, [1])
        try Self.assertAppended(pdf, deleted, permitted: false)
        #expect(try Self.approval(deleted).detail?.contains("pages added, removed or moved") == true)
        let shown = try PdfEngine.open(deleted)
        #expect(shown.pageCount == 1)
        shown.close()
        #expect(try Core2Pdf.allText(deleted).contains("Hello contract"))
    }

    /// A signed one-page file with a nested page tree (inherited /MediaBox), an Info dictionary and an XMP packet.
    static func signedNested() throws -> [UInt8] {
        let xmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">Original</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /Metadata 10 0 R /AcroForm << /Fields [4 0 R 6 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 8 0 R >> >> /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [11 0 R] /Count 1 /MediaBox [0 0 400 500] >>",
            "<< /Type /Page /Parent 11 0 R /Annots [4 0 R 6 0 R] /Contents 7 0 R /Resources << /Font << /F1 8 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Approval) /Rect [72 650 272 700] /V 5 0 R /P 3 0 R /F 4 >>",
            "<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange \(placeholderRange) /Contents <\(String(repeating: "0", count: contentsHexLength))> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 500 300 530] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>",
            Core2Pdf.stream("BT /F1 24 Tf 72 720 Td (Hello contract) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Title (Original) /Producer (Test) >>",
            Core2Pdf.stream(xmp, "/Type /Metadata /Subtype /XML"),
            "<< /Type /Pages /Parent 2 0 R /Kids [3 0 R] /Count 1 >>",
        ]
        return try Core2SignatureTests.sign(Core2Pdf.build(objects, trailerExtra: "/Info 9 0 R "), placeholderRange, cn: "CN=Incremental Signer")
    }

    @Test func nestedPageTreeInfoAndXmpSurviveAppendedEdits() throws {
        let pdf = try Self.signedNested()
        let filled = try FormEditor.setValues(pdf, nil, ["Name": "Ada"])
        try Self.assertAppended(pdf, filled)
        #expect(try Core2Pdf.allText(filled).contains("Ada"))

        let rotated = try PageEditor.rotate(filled, nil, [0], 180)
        #expect(try Self.approval(rotated).status == .disallowedChanges)
        var engine = try PdfEngine.open(rotated)
        #expect(engine.pageCount == 1)
        #expect(abs(engine.page(0).width - 400) <= 1)
        engine.close()
        #expect(try Core2Pdf.allText(rotated).contains("Hello contract"))

        // Adding a page changes the page tree; the old page keeps its inherited size.
        let grown = try PageEditor.insertBlank(rotated, nil, 1, 1, 300, 300)
        #expect(try Self.approval(grown).status == .disallowedChanges)
        engine = try PdfEngine.open(grown)
        #expect(engine.pageCount == 2)
        #expect(abs(engine.page(0).width - 400) <= 1 && abs(engine.page(0).height - 500) <= 1)
        #expect(abs(engine.page(1).width - 300) <= 1)
        engine.close()
        let shrunk = try PageEditor.delete(grown, nil, [1])
        #expect(try Self.approval(shrunk).status == .disallowedChanges)
        engine = try PdfEngine.open(shrunk)
        #expect(engine.pageCount == 1)
        engine.close()

        let titled = try PageEditor.writeMetadata(filled, nil, "Signed contract", "", "", "")
        #expect(try Self.approval(titled).status == .modifiedAfterSigning)
        #expect(try PageEditor.readMetadata(titled, nil).title == "Signed contract")
        let doc = try Core2Pdf.open(titled)
        let meta = try #require(doc.catalog.dict("Metadata")?.streamData)
        #expect(String(decoding: meta, as: UTF8.self).contains("Signed contract"))
    }

    @Test func redactionAndExtractionRewriteTheFile() throws {
        let pdf = try Self.signedForm(twoPages: true)
        let original = Signatures.verify(pdf)
        let redacted = try Redaction.apply(pdf, nil, [0: [RectD(72, 60, 100, 20)]], dpi: 72)
        let n = min(pdf.count, redacted.count)
        #expect(Array(redacted[..<n]) != Array(pdf[..<n]))
        #expect(Signatures.brokenByEdits(original, redacted).map(\.fieldName) == ["Approval"])

        let extracted = try PageEditor.extract(pdf, nil, [1])
        #expect(extracted.count < pdf.count)
    }

    @Test func unsignedFilesAreStillRewritten() throws {
        let pdf = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Tx /T (Name) /Rect [72 500 300 530] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) >>"])
        let filled = try FormEditor.setValues(pdf, nil, ["Name": "Ada"])
        #expect(!(filled.count > pdf.count && Array(filled[..<pdf.count]) == pdf))
    }
}
