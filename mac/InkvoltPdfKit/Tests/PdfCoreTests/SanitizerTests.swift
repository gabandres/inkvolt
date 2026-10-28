import Foundation
import Testing
@testable import PdfCore

/// Ported from SanitizerTests.cs. Adapted: "everything in the file" reads every object through MuPDF (its keys, names,
/// strings and decoded streams; Windows prints PDFsharp's objects); with metadata chosen the XMP packet goes altogether
/// (Windows writes a bare one naming PDFsharp); SignedFilesNeedConsentAndLoseTheirSignatures uses the signed-looking
/// fixture (`SignedEditTests.signed()`) and doesn't verify signatures (E2); CleanFileStaysClean: the hand-written
/// `TestPdf` has no properties, so its scan counts no metadata (PDFsharp's save writes a title and dates on Windows).
/// Added on the Mac: aJustWrittenModificationDateGoesToo (an edit made by the app just before writes /ModDate, which a
/// scan while removing doesn't count; with metadata chosen the properties go anyway).
struct SanitizerTests {
    static let all = Set(SanitizeItem.allCases)

    static let xmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
        + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:creator><rdf:Seq><rdf:li>Jane Doe</rdf:li></rdf:Seq></dc:creator></rdf:Description>"
        + "</rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"

    /// One page holding one of everything Sanitize removes (numbers in the comments are the object numbers): metadata
    /// (Info with 4 entries, 2 XMP packets, 2 PieceInfo), a hidden layer drawing text, a vector box and a form XObject, an
    /// annotation in that layer, 2 hidden annotations (one a filled field), a comment with its popup, 3 filled fields, a
    /// bookmark leading to a web page, a thumbnail, 11 pieces of active content, 2 external links and 3 embedded files.
    static func dirty(pageContent: String = "", extraResources: String = "", xmp: String? = nil, trailerExtra: String = "") -> [UInt8] {
        let content = "BT /F1 12 Tf 72 700 Td (Visible text) Tj ET /OC /L1 BDC BT /F1 12 Tf 72 650 Td (Shown layer) Tj ET EMC "
            + "/OC /L2 BDC 1 0 0 rg BT /F1 12 Tf 72 600 Td (Secret layer) Tj ET 0 0 100 100 re f EMC q /Sec Do Q q 10 0 0 10 300 300 cm /Im Do Q " + pageContent
        let objects = [
            /* 1 */ "<< /Type /Catalog /Pages 2 0 R /Metadata 7 0 R /OpenAction 8 0 R /AA << /WC 10 0 R >> /Names << /JavaScript 11 0 R /EmbeddedFiles 13 0 R >> "
                + "/Outlines 16 0 R /PageMode /UseOutlines /OCProperties << /OCGs [18 0 R 19 0 R] /D << /OFF [19 0 R] /Order [18 0 R 19 0 R] >> >> "
                + "/AcroForm << /Fields [23 0 R 25 0 R 26 0 R 40 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> /XFA 27 0 R >> "
                + "/PieceInfo << /Illustrator << /Private (catalog private) >> >> /AF [14 0 R] >>",
            /* 2 */ "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            /* 3 */ "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Thumb 21 0 R /AA << /O 22 0 R >> "
                + "/PieceInfo << /App << /Private (page private) >> >> /LastModified (D:20200101) "
                + "/Resources << /Font << /F1 5 0 R >> /Properties << /L1 18 0 R /L2 19 0 R >> /XObject << /Sec 20 0 R /Im 38 0 R >> \(extraResources) >> "
                + "/Annots [23 0 R 25 0 R 26 0 R 28 0 R 29 0 R 30 0 R 31 0 R 32 0 R 33 0 R 34 0 R 35 0 R 36 0 R 37 0 R 40 0 R] >>",
            /* 4 */ Core2Pdf.stream(content),
            /* 5 */ "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            /* 6 */ "<< /Title (Secret title) /Author (Jane Doe) /Producer (Word) /Custom (internal) >>",
            /* 7 */ Core2Pdf.stream(xmp ?? Self.xmp, "/Type /Metadata /Subtype /XML"),
            /* 8 */ "<< /S /JavaScript /JS (app.alert\\(1\\)) /Next 9 0 R >>",
            /* 9 */ "<< /S /GoTo /D [3 0 R /Fit] >>",
            /* 10 */ "<< /S /JavaScript /JS (willClose\\(\\)) >>",
            /* 11 */ "<< /Names [(init) 12 0 R] >>",
            /* 12 */ "<< /S /JavaScript /JS (docInit\\(\\)) >>",
            /* 13 */ "<< /Names [(a.txt) 14 0 R] >>",
            /* 14 */ "<< /Type /Filespec /F (a.txt) /UF (a.txt) /EF << /F 15 0 R >> >>",
            /* 15 */ Core2Pdf.stream("attached secret", "/Type /EmbeddedFile"),
            /* 16 */ "<< /Type /Outlines /First 17 0 R /Last 17 0 R /Count 1 >>",
            /* 17 */ "<< /Title (Chapter) /Parent 16 0 R /A << /S /URI /URI (https://example.com/outline) >> >>",
            /* 18 */ "<< /Type /OCG /Name (Shown) >>",
            /* 19 */ "<< /Type /OCG /Name (Hidden notes) >>",
            /* 20 */ Core2Pdf.stream("BT /F1 12 Tf 72 500 Td (Secret form) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /OC 19 0 R /Resources << /Font << /F1 5 0 R >> >>"),
            /* 21 */ Core2Pdf.stream("abcdefghijkl", "/Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8"),
            /* 22 */ "<< /S /JavaScript /JS (pageOpen\\(\\)) >>",
            /* 23 */ "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (John Smith) /Rect [72 400 272 420] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) /AA << /K 24 0 R >> >>",
            /* 24 */ "<< /S /JavaScript /JS (AFNumber_Keystroke\\(2\\)) >>",
            /* 25 */ "<< /Type /Annot /Subtype /Widget /FT /Tx /T (hiddenfield) /V (hidden data) /Rect [72 300 272 320] /P 3 0 R /F 2 /DA (/Helv 12 Tf 0 g) >>",
            /* 26 */ "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (send) /Rect [300 400 400 420] /P 3 0 R /F 4 /A << /S /SubmitForm /F << /FS /URL /F (https://example.com/submit) >> >> >>",
            /* 27 */ Core2Pdf.stream("<xdp:xdp xmlns:xdp=\"http://ns.adobe.com/xdp/\"/>"),
            /* 28 */ "<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] /Contents (Private comment) /Popup 29 0 R /F 4 >>",
            /* 29 */ "<< /Type /Annot /Subtype /Popup /Rect [520 600 600 700] /Parent 28 0 R >>",
            /* 30 */ "<< /Type /Annot /Subtype /Link /Rect [72 690 200 710] /A << /S /JavaScript /JS (evil\\(\\)) >> >>",
            /* 31 */ "<< /Type /Annot /Subtype /Link /Rect [72 640 200 660] /A << /S /URI /URI (https://example.com/link) >> >>",
            /* 32 */ "<< /Type /Annot /Subtype /Link /Rect [72 590 200 610] /A << /S /Launch /F (calc.exe) >> >>",
            /* 33 */ "<< /Type /Annot /Subtype /FileAttachment /Rect [550 500 570 520] /FS 14 0 R /Contents (attachment) >>",
            /* 34 */ "<< /Type /Annot /Subtype /Square /Rect [400 100 450 150] /F 2 /Contents (hidden square) >>",
            /* 35 */ "<< /Type /Annot /Subtype /Square /Rect [400 200 450 250] /OC 19 0 R /Contents (layer square) >>",
            /* 36 */ "<< /Type /Annot /Subtype /RichMedia /Rect [100 100 200 200] >>",
            /* 37 */ "<< /Type /Annot /Subtype /Sound /Rect [220 100 240 120] >>",
            /* 38 */ Core2Pdf.stream("abcdefghijkl", "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Metadata 39 0 R"),
            /* 39 */ Core2Pdf.stream("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>", "/Type /Metadata /Subtype /XML"),
            /* 40 */ "<< /Type /Annot /Subtype /Widget /FT /Btn /T (agree) /V /Yes /AS /Yes /Rect [72 200 82 210] /P 3 0 R /F 4 /AP << /N << /Yes 41 0 R /Off 42 0 R >> >> >>",
            /* 41 */ Core2Pdf.stream("0 0 1 rg 0 0 10 10 re f", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
            /* 42 */ Core2Pdf.stream("", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
            /* 43 */ "<< /Unused (orphan data) >>",
        ]
        return Core2Pdf.build(objects, trailerExtra: "/Info 6 0 R " + trailerExtra)
    }

    /// Everything in the file as text: its bytes plus every object (keys, names, strings) and stream decoded, to look for
    /// what must be gone.
    static func everything(_ data: [UInt8], _ password: String? = nil) throws -> String {
        var sb = latin1(data)
        let doc = try PdfEdit.openToRead(data, password)
        func dump(_ o: PObj, _ depth: Int) {
            if depth > 16 { return }
            switch o.kind {
            case .string: sb += "(" + (o.text ?? "") + ")"
            case .name: sb += "/" + (o.name ?? "")
            case .int, .real: sb += " \(o.number ?? 0) "
            case .array:
                sb += "["
                for e in o.elements { if e.isRef { sb += " \(e.num) 0 R " } else { dump(e, depth + 1) } }
                sb += "]"
            case .dict:
                sb += "<<"
                for k in o.keys {
                    sb += "/\(k) "
                    if let v = o[k] { if v.isRef { sb += " \(v.num) 0 R " } else { dump(v, depth + 1) } }
                }
                sb += ">>"
            default: break
            }
        }
        dump(doc.trailer, 0)
        for o in doc.allObjects() {
            dump(o, 0)
            sb += "\n"
            if o.isStream, let s = o.streamData { sb += latin1(s) + "\n" }
        }
        return sb
    }

    static func pageText(_ data: [UInt8], _ password: String? = nil) throws -> String {
        let engine = try PdfEngine.open(data, password: password)
        defer { engine.close() }
        return try engine.text(0).text
    }

    static func nonZero(_ r: SanitizeReport) -> String { r.counts.filter { $0.value > 0 }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") }

    /// With INKVOLTPDF_SAMPLES set, `dirty()` is written there (sanitize-sample.pdf) for the app.
    @Test func scanCountsEachKind() throws {
        if let dir = ProcessInfo.processInfo.environment["INKVOLTPDF_SAMPLES"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(Self.dirty()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("sanitize-sample.pdf"))
        }
        let scan = try Sanitizer.scan(Self.dirty(), nil)
        #expect(scan[.metadata] == 8) // 4 Info entries, 2 XMP packets, 2 PieceInfo
        #expect(scan[.hiddenLayers] == 1)
        #expect(scan[.hiddenAnnotations] == 2)
        #expect(scan[.comments] == 1) // the popup goes with its note
        #expect(scan[.formValues] == 3) // the hidden field's value too; the push button has none
        #expect(scan[.bookmarks] == 1)
        #expect(scan[.thumbnails] == 1)
        // Open action, document will-close, document script, page open, keystroke, link script, Launch, SubmitForm,
        // RichMedia, Sound, XFA.
        #expect(scan[.activeContent] == 11)
        #expect(scan[.externalLinks] == 2) // a link and the bookmark's action
        #expect(scan[.embeddedFiles] == 3) // name tree, attachment annotation, /AF
        #expect(scan[.signatures] == 0)
        #expect(scan.unusedObjects >= 1)
        #expect(scan.earlierRevisions == 0)
        #expect(!scan.isClean)
    }

    @Test func removesEverythingAndRescansClean() throws {
        let pdf = Self.dirty()
        let result = try Sanitizer.sanitize(pdf, nil, Self.all)
        let before = try Sanitizer.scan(pdf, nil)
        // The hidden field went as a hidden annotation before its value was counted, the bookmark before its web address.
        for item in Self.all {
            let expected = before[item] - (item == .formValues || item == .externalLinks ? 1 : 0)
            #expect(expected == result.removed[item], "\(item): \(before[item]) found, \(result.removed[item]) removed")
        }
        let remaining = try #require(result.remaining)
        #expect(remaining.isClean, "\(Self.nonZero(remaining))")
        #expect(remaining.unusedObjects == 0)
        #expect(result.removed.notes.isEmpty, "\(result.removed.notes)")

        // The page still shows what it showed; what was hidden is gone from the file, not just from view.
        let text = try Self.pageText(result.data)
        #expect(text.contains("Visible text"))
        #expect(text.contains("Shown layer"))
        let all = try Self.everything(result.data)
        for secret in ["Secret layer", "Secret form", "Hidden notes", "Secret title", "Jane Doe", "Word", "internal", "attached secret", "John Smith",
                       "hidden data", "app.alert", "docInit", "pageOpen", "AFNumber", "evil", "calc.exe", "example.com", "Private comment", "private",
                       "orphan", "xdp"] {
            #expect(!all.contains(secret), "still in the file: \(secret)")
        }

        let doc = try Core2Pdf.open(result.data)
        let catalog = doc.catalog
        for key in ["AA", "Outlines", "PieceInfo", "AF", "PageMode"] { #expect(!catalog.has(key), "\(key)") }
        #expect(catalog.dict("OCProperties")?.array("OCGs")?.count == 1) // the layer that shows
        #expect(catalog.dict("OpenAction")?.name("S") == "GoTo") // the script before it went
        let page = doc.page(0)
        #expect(!page.has("Thumb"))
        #expect(!page.has("AA"))
        // Left: the visible text field (emptied), the push button (without its action) and the check box (off).
        let annots = page.array("Annots")?.elements ?? []
        #expect(annots.map { $0.text("T") } == ["name", "send", "agree"])
        #expect(annots.count == 3 && annots[2].name("AS") == "Off")
        #expect(annots.count == 3 && !annots[1].has("A"))
        #expect(catalog.dict("AcroForm")?.array("Fields")?.count == 3) // the hidden field went with its widget
        #expect(catalog.dict("AcroForm")?.has("XFA") == false)
        // No XMP packet is left.
        #expect(!all.contains("ModifyDate"))
        #expect(!all.contains("DocumentID"))
    }

    @Test func removesOnlyWhatIsChosen() throws {
        let result = try Sanitizer.sanitize(Self.dirty(), nil, [.activeContent])
        #expect(result.removed[.activeContent] == 11)
        #expect(result.removed[.comments] == 0)
        let left = try #require(result.remaining)
        #expect(left[.activeContent] == 0)
        #expect(left[.comments] == 1)
        #expect(left[.externalLinks] == 2)
        #expect(left[.bookmarks] == 1)
        #expect(left[.hiddenLayers] == 1)
        #expect(left[.formValues] == 3)
        #expect(try Self.everything(result.data).contains("Secret title"))

        // The open action's script went; the page it then went to stays.
        let doc = try Core2Pdf.open(result.data)
        let open = try #require(doc.catalog.dict("OpenAction"))
        #expect(open.name("S") == "GoTo")
        #expect(!open.has("Next"))
        // The link that ran a script (and so leads nowhere now) went; the web link stays.
        let subtypes = (doc.page(0).array("Annots")?.elements ?? []).map { $0.name("Subtype") ?? "" }
        #expect(subtypes.filter { $0 == "Link" }.count == 1)
        #expect(!subtypes.contains("RichMedia"))
    }

    @Test func externalLinksLeaveBookmarksInPlace() throws {
        let result = try Sanitizer.sanitize(Self.dirty(), nil, [.externalLinks])
        #expect(result.removed[.externalLinks] == 2)
        let doc = try Core2Pdf.open(result.data)
        let item = try #require(doc.catalog.dict("Outlines")?.dict("First"))
        #expect(item.text("Title") == "Chapter")
        #expect(!item.has("A"))
        #expect(result.remaining?[.bookmarks] == 1)
    }

    static func strip(_ content: String, _ tag: @escaping (String) -> Bool, _ xobject: @escaping (String) -> Bool) -> (text: String?, kept: String?) {
        let r = HiddenContent.strip(Array(content.utf8), hiddenTag: tag, hiddenXObject: xobject)
        return (r.content.map(latin1), r.kept)
    }

    @Test func hiddenLayerContentGoesButItsStateStays() throws {
        // Inside a text object: hidden text followed by text placed from a new position is cut, its Td kept.
        var r = Self.strip("BT /F1 12 Tf 72 700 Td (A) Tj /OC /H BDC 0 -20 Td (Secret) Tj EMC 0 -20 Td (B) Tj ET", { $0 == "H" }, { _ in false })
        #expect(r.kept == nil)
        var text = try #require(r.text)
        #expect(!text.contains("Secret"))
        #expect(text.contains("0 -20 Td\n"))
        #expect(text.contains("(B) Tj"))

        // Visible text placed right after the hidden text relies on its width: that section stays.
        r = Self.strip("BT /F1 12 Tf 72 700 Td /OC /H BDC (Secret) Tj EMC (B) Tj ET", { $0 == "H" }, { _ in false })
        #expect(r.text == nil)
        #expect(r.kept != nil)

        // Clipping, color and q/Q survive; drawing doesn't. ' becomes a line move.
        r = Self.strip("/OC /H BDC q 0 0 50 50 re W n 1 0 0 rg 0 0 100 100 re f /Img Do Q EMC (after) Tj", { $0 == "H" }, { _ in false })
        text = try #require(r.text)
        #expect(r.kept == nil)
        #expect(text.contains("q\n0 0 50 50 re\nW\nn\n1 0 0 rg\nQ\n"))
        #expect(!text.contains("100 100 re"))
        #expect(!text.contains("Img"))
        #expect(!text.contains("BDC"))
        #expect(text.contains("(after) Tj"))
        r = Self.strip("BT 72 700 Td /OC /H BDC (x) ' EMC 0 -10 Td (y) Tj ET", { $0 == "H" }, { _ in false })
        text = try #require(r.text)
        #expect(text.contains("T*"))
        #expect(!text.contains("(x)"))

        // A hidden XObject's Do goes; other content stays. Nothing hidden: nothing changes.
        r = Self.strip("q /A Do Q q /B Do Q", { _ in false }, { $0 == "B" })
        #expect(r.text == "q /A Do Q q  Q")
        #expect(Self.strip("/OC /V BDC (x) Tj EMC", { _ in false }, { _ in false }).text == nil)
    }

    @Test func membershipDictionariesKeepShowingWhatTheyShowed() throws {
        // /M1: shown while L2 is off (AnyOff) -> stays, and keeps showing once L2 is gone. /M2: needs L1 and L2 on -> hidden, removed.
        let pdf = Self.dirty(pageContent: "/OC /M1 BDC BT /F1 12 Tf 72 450 Td (Shown while off) Tj ET EMC /OC /M2 BDC BT /F1 12 Tf 72 420 Td (Both needed) Tj ET EMC",
                             extraResources: "/Properties << /L1 18 0 R /L2 19 0 R /M1 << /Type /OCMD /OCGs [19 0 R] /P /AnyOff >> /M2 << /Type /OCMD /OCGs [18 0 R 19 0 R] /P /AllOn >> >>")
        // (Windows first checks that the page shows "Shown while off" and not "Both needed": MuPDF 1.25.2 reads /P the other
        // way round, AllOn as AnyOff, so it shows them the other way.)
        let result = try Sanitizer.sanitize(pdf, nil, [.hiddenLayers])
        let after = try Self.pageText(result.data)
        #expect(after.contains("Shown while off"))
        #expect(after.contains("Shown layer"))
        let all = try Self.everything(result.data)
        for gone in ["Both needed", "Secret layer", "Secret form", "Hidden notes"] { #expect(!all.contains(gone), "\(gone)") }
        #expect(result.remaining?[.hiddenLayers] == 0)
    }

    @Test func earlierRevisionsAreGone() throws {
        var pdf = Self.dirty()
        // An incremental update that renames the document: the old title stays in the first revision.
        let text = latin1(pdf)
        let at = try #require(text.range(of: "startxref", options: .backwards))
        let prevXref = try #require(Int(text[at.upperBound...].split(separator: "\n")[0].trimmingCharacters(in: .whitespaces)))
        let update = "6 0 obj\n<< /Title (New title) >>\nendobj\n"
        let xref = pdf.count + 1 + update.utf8.count
        let tail = "\n\(update)xref\n6 1\n\(String(format: "%010d", pdf.count + 1)) 00000 n \ntrailer\n<< /Size 44 /Root 1 0 R /Info 6 0 R /Prev \(prevXref) >>\nstartxref\n\(xref)\n%%EOF\n"
        pdf += Array(tail.utf8)
        #expect(try Sanitizer.scan(pdf, nil).earlierRevisions == 1)
        #expect(try Sanitizer.scan(pdf, nil)[.metadata] == 5) // the newest Info has one entry

        let result = try Sanitizer.sanitize(pdf, nil, []) // nothing chosen: the rewrite alone
        #expect(result.removed.earlierRevisions == 1)
        #expect(result.remaining?.earlierRevisions == 0)
        let all = try Self.everything(result.data)
        #expect(!all.contains("Secret title"))
        #expect(all.contains("New title"))
    }

    @Test func signedFilesNeedConsentAndLoseTheirSignatures() throws {
        let signed = SignedEditTests.signed()
        #expect(try Sanitizer.scan(signed, nil)[.signatures] == 1)
        #expect(throws: SignaturesWouldBreak.self) { try Sanitizer.sanitize(signed, nil, Self.all) }
        let (data, report) = try SignedEdits.run({ try Sanitizer.sanitize(signed, nil, Self.all).data }, allowRewrite: true)
        #expect(!report.appended)
        #expect(try Sanitizer.scan(data, nil)[.signatures] == 0)
        #expect(!(try Self.everything(data).contains("/ByteRange")))
        #expect(try Self.pageText(data).contains("Hello contract"))
    }

    @Test func encryptedFilesKeepTheirProtection() throws {
        let pdf = try PdfSecurity.protect(Self.dirty(), nil, userPassword: "open", ownerPassword: "owner")
        #expect(throws: OwnerPasswordRequired.self) { try Sanitizer.sanitize(pdf, "open", Self.all) }
        let result = try KeptProtection.run(openPassword: "open", dropOpenPassword: false) { try Sanitizer.sanitize(pdf, "owner", Self.all) }
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(result.data) }
        #expect(try PdfSecurity.readSecurity(result.data, "open").method == .aes256)
        let remaining = try #require(result.remaining)
        #expect(remaining.isClean, "\(Self.nonZero(remaining))")
        #expect(try Self.pageText(result.data, "open").contains("Visible text"))
        #expect(!(try Self.everything(result.data, "owner").contains("Secret layer")))
    }

    @Test func cleanFileStaysClean() throws {
        let pdf = TestPdf.make(2)
        #expect(try Sanitizer.scan(pdf, nil)[.metadata] == 0) // the hand-written file has no properties
        let result = try Sanitizer.sanitize(pdf, nil, Self.all)
        #expect(result.remaining?.isClean == true)
        #expect(TestPdf.pageNumbers(result.data) == [1, 2])
    }

    // ---- Review regressions: each one also shows up in the rescan ----

    static let originalId = "00112233445566778899AABBCCDDEEFF"

    static func ids(_ data: [UInt8], _ password: String? = nil) throws -> [[UInt8]] {
        try (PdfEdit.openToRead(data, password).trailer.array("ID")?.elements ?? []).compactMap(\.bytes)
    }

    @Test func fieldsNoPageListsLoseTheirScripts() throws {
        // A widget and a field's kid that no page has in /Annots: viewers still run their actions.
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R 5 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /FT /Btn /Ff 65536 /T (go) /Subtype /Widget /Rect [0 0 10 10] /A << /S /JavaScript /JS (fieldScriptA\\(\\)) >> >>",
            "<< /FT /Tx /T (parent) /Kids [<< /Subtype /Widget /Rect [0 0 10 10] /Parent 5 0 R /A << /S /JavaScript /JS (kidScriptB\\(\\)) >> "
                + "/AA << /K << /S /JavaScript /JS (kidKeyC\\(\\)) >> >> >>] >>",
        ])
        #expect(try Sanitizer.scan(pdf, nil)[.activeContent] == 3)
        let result = try Sanitizer.sanitize(pdf, nil, [.activeContent])
        #expect(result.removed[.activeContent] == 3)
        #expect(result.remaining?[.activeContent] == 0)
        let all = try Self.everything(result.data)
        for script in ["fieldScriptA", "kidScriptB", "kidKeyC"] { #expect(!all.contains(script), "\(script)") }
    }

    @Test func fileIdentifierIsMadeNew() throws {
        let pdf = Self.dirty(trailerExtra: "/ID [<\(Self.originalId)> <\(Self.originalId)>]")
        let before = try Self.ids(pdf)
        // The rescan of a copy that kept the identifier says so.
        #expect(try Sanitizer.scan(pdf, nil)[.metadata] + 1 == Sanitizer.scan(pdf, nil, originalIds: [before[0]])[.metadata])

        let result = try Sanitizer.sanitize(pdf, nil, Self.all)
        let after = try Self.ids(result.data)
        #expect(after.count == 2)
        #expect(!after.contains(where: before.contains))
        #expect(!latin1(result.data).uppercased().contains(Self.originalId))
        let remaining = try #require(result.remaining)
        #expect(remaining.isClean, "\(Self.nonZero(remaining))")

        // Without metadata chosen the identifier stays (and so isn't reported).
        let kept = try Sanitizer.sanitize(pdf, nil, [.thumbnails])
        #expect(try Self.ids(kept.data).first == before[0])
    }

    @Test func encryptedFileGetsANewIdentifierAndStillOpens() throws {
        // AES-128: the key is made from the first identifier, so the protection must be written with the new one.
        let pdf = try PdfSecurity.protect(Self.dirty(trailerExtra: "/ID [<\(Self.originalId)> <\(Self.originalId)>]"), nil,
                                          userPassword: "open", ownerPassword: "owner", method: .aes128)
        let before = try Self.ids(pdf, "owner")
        let result = try KeptProtection.run(openPassword: "open", dropOpenPassword: false) { try Sanitizer.sanitize(pdf, "owner", Self.all) }
        let after = try Self.ids(result.data, "owner")
        #expect(after.count == 2)
        #expect(!after.contains(where: before.contains))
        #expect(try PdfSecurity.readSecurity(result.data, "open").method == .aes128)
        #expect(try Self.pageText(result.data, "open").contains("Visible text"))
        #expect(try Self.pageText(result.data, "owner").contains("Visible text"))
        let remaining = try #require(result.remaining)
        #expect(remaining.isClean, "\(Self.nonZero(remaining))")
    }

    @Test func xmpWithOnlyDocumentIdsIsMetadata() throws {
        let idsOnly = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:xmpMM=\"http://ns.adobe.com/xap/1.0/mm/\"><xmpMM:DocumentID>uuid:orig-doc-1111</xmpMM:DocumentID>"
            + "<xmpMM:InstanceID>uuid:orig-inst-2222</xmpMM:InstanceID><xmpMM:OriginalDocumentID>uuid:orig-first-3333</xmpMM:OriginalDocumentID>"
            + "</rdf:Description></rdf:RDF></x:xmpmeta>"
        let pdf = Self.dirty(xmp: idsOnly)
        #expect(try Sanitizer.scan(pdf, nil)[.metadata] == 8) // the packet still counts
        let result = try Sanitizer.sanitize(pdf, nil, [.metadata])
        #expect(result.remaining?[.metadata] == 0)
        #expect(!(try Self.everything(result.data).contains("orig-")))
    }

    @Test func aJustWrittenModificationDateGoesToo() throws {
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>",
            "<< /ModDate (\(PdfDates.format(Date()))) >>",
            "<< /Type /Annot /Subtype /Text /Rect [20 20 40 40] /Contents (A note) >>",
        ], trailerExtra: "/Info 4 0 R")
        #expect(try Sanitizer.scan(pdf, nil)[.metadata] == 1)
        let result = try Sanitizer.sanitize(pdf, nil, [.metadata, .comments])
        #expect(result.remaining?.isClean == true, "\(result.remaining.map(Self.nonZero) ?? "")")
    }

    @Test func directDictionariesAndArticlesAreCleaned() throws {
        // A link and a note written straight into /Annots (not as objects of their own), and an article's properties.
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /Threads [<< /Type /Thread /I << /Title (Thread secret) /Author (Bob Thread) >> >>] >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots ["
                + "<< /Type /Annot /Subtype /Link /Rect [0 0 10 10] /Dest [3 0 R /Fit] /AF [4 0 R] /PieceInfo << /App << /Private (direct private) >> >> "
                + "/NM (secret-nm) /T (Jane Author) /M (D:20200101) >> "
                + "<< /Type /Annot /Subtype /Text /Rect [20 20 30 30] /Contents (kept note) /T (Note Author) /CreationDate (D:20190101) >>] >>",
            "<< /Type /Filespec /F (b.txt) /EF << /F 5 0 R >> >>",
            Core2Pdf.stream("direct attached secret", "/Type /EmbeddedFile"),
        ])
        let scan = try Sanitizer.scan(pdf, nil)
        #expect(scan[.metadata] == 5) // private data, two annotations' authors and dates, the article's 2 entries
        #expect(scan[.embeddedFiles] == 1)
        let result = try Sanitizer.sanitize(pdf, nil, [.metadata, .embeddedFiles])
        #expect(result.remaining?[.metadata] == 0)
        #expect(result.remaining?[.embeddedFiles] == 0)
        let all = try Self.everything(result.data)
        for secret in ["Jane Author", "Note Author", "secret-nm", "direct private", "Thread secret", "Bob Thread", "direct attached secret", "D:2019", "D:2020"] {
            #expect(!all.contains(secret), "still in the file: \(secret)")
        }
        #expect(all.contains("kept note")) // the comment itself stays: only who wrote it and when went
    }
}
