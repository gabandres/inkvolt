import Foundation
import Testing
@testable import PdfCore

/// Ported from RedactionCheckTests.cs. The PDFs with binary streams (a deflated attachment, a picture) are written as
/// Latin-1 (`RedactionTestPdf`). Left out: BatchFailsAFileWithLeftovers (Batch comes with E8). Added on the Mac:
/// invisibleTextCountsOnlyOverADarkArea (MuPDF says here which characters are drawn invisibly, as an OCR layer's are).
struct RedactionCheckTests {
    static let name = "Zephyrine Okonkwo"

    /// Two pages. Page 1 shows the name (to be redacted). The name is also planted on page 2 (shown, outside the page, in
    /// a hidden layer), in a note's text, a text box's appearance, a form field's value, a bookmark, the document
    /// properties, the XMP packet, an attached file (compressed), and the alternate text of a tag.
    static func everywhere() -> [UInt8] {
        let n = name
        return RedactionTestPdf.build([
            "<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R /Names << /EmbeddedFiles << /Names [(notes.txt) 12 0 R] >> >> /Metadata 14 0 R "
                + "/AcroForm << /Fields [9 0 R] >> /OCProperties << /OCGs [15 0 R] /D << /OFF [15 0 R] >> >> /StructTreeRoot 16 0 R /MarkInfo << /Marked true >> >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents [6 0 R 18 0 R] /Resources << /Font << /F1 7 0 R >> /Properties << /oc1 15 0 R >> >> /Annots [8 0 R 9 0 R 19 0 R] >>",
            RedactionTestPdf.stream("BT /F1 18 Tf 72 700 Td (Patient: \(n)) Tj ET BT /F1 18 Tf 72 650 Td (Visit notes follow) Tj ET"),
            RedactionTestPdf.stream("BT /F1 12 Tf 72 700 Td (Also seen: \(n) here) Tj ET BT /F1 12 Tf 700 900 Td (\(n)) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] /Contents (Call \(n)) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (patient) /V (\(n)) /Rect [72 400 300 420] /P 4 0 R >>",
            "<< /Type /Outlines /First 11 0 R /Last 11 0 R /Count 1 >>",
            "<< /Title (\(n) file) /Parent 10 0 R /Dest [4 0 R /Fit] >>",
            "<< /Type /Filespec /F (notes.txt) /UF (notes.txt) /EF << /F 13 0 R >> >>",
            RedactionTestPdf.stream(RedactionTestPdf.deflated("Notes about \(n), seen on Monday."), "/Type /EmbeddedFile /Filter /FlateDecode"),
            RedactionTestPdf.stream("<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:description>About \(n)</dc:description></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>", "/Type /Metadata /Subtype /XML"),
            "<< /Type /OCG /Name (Private) >>",
            "<< /Type /StructTreeRoot /K [17 0 R] >>",
            "<< /Type /StructElem /S /Figure /P 16 0 R /Pg 4 0 R /Alt (Photo of \(n)) >>",
            RedactionTestPdf.stream("/OC /oc1 BDC BT /F1 12 Tf 72 500 Td (Private: \(n)) Tj ET EMC"),
            "<< /Type /Annot /Subtype /FreeText /Rect [72 300 300 320] /Contents (see the note) /DA (/F1 12 Tf 0 g) /AP << /N 20 0 R >> >>",
            RedactionTestPdf.stream("BT /F1 12 Tf 2 5 Td (\(n)) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 228 20] /Resources << /Font << /F1 7 0 R >> >>"),
            "<< /Title (Report on \(n)) >>",
        ], trailerExtra: "/Info 21 0 R")
    }

    /// The areas of every match of `text` on a page, grown by a point.
    static func areasOf(_ data: [UInt8], _ page: Int, _ text: String) throws -> [Int: [RectD]] {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        let t = try engine.text(page)
        let rects = t.find(text, matchCase: true, wholeWord: false).map { m in t.rects(m.start, m.end).reduce(RectD.zero) { $0.union($1) }.inflate(1) }
        try #require(!rects.isEmpty)
        return [page: rects]
    }

    /// Redacts `text` on `page` as the app does, then checks with what was redacted.
    static func redactAndCheck(_ data: [UInt8], _ page: Int, _ text: String) throws -> (redacted: [UInt8], report: RedactionCheckReport) {
        let areas = try areasOf(data, page, text)
        let engine = try PdfEngine.open(data)
        let values = try RedactionCheck.valuesUnder(engine, areas)
        engine.close()
        let redacted = try Redaction.apply(data, nil, areas, dpi: 100)
        return (redacted, try RedactionCheck.run(redacted, nil, RedactionCheckOptions(values: values, areas: areas, original: data)))
    }

    static func describe(_ r: RedactionCheckReport) -> String { r.findings.map { "\($0.kind) \($0.place): \($0.text)" }.joined(separator: "; ") }

    @Test func theValuesUnderTheAreasAreWhatIsLookedFor() throws {
        let data = Self.everywhere()
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        #expect(try RedactionCheck.valuesUnder(engine, Self.areasOf(data, 0, Self.name)) == [Self.name])
    }

    /// With INKVOLTPDF_SAMPLES set, `everywhere()` is written there (redaction-check-sample.pdf) for the app, and a box
    /// drawn over text (redaction-check-box.pdf).
    @Test func everyLeftoverOfARedactedValueIsFound() throws {
        if let dir = ProcessInfo.processInfo.environment["INKVOLTPDF_SAMPLES"], !dir.isEmpty {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try Data(Self.everywhere()).write(to: URL(fileURLWithPath: dir).appendingPathComponent("redaction-check-sample.pdf"))
            try Data(Self.bad("box").bad).write(to: URL(fileURLWithPath: dir).appendingPathComponent("redaction-check-box.pdf"))
        }
        let (_, report) = try Self.redactAndCheck(Self.everywhere(), 0, Self.name)
        let found = report.findings
        let all = Self.describe(report)

        #expect(!found.contains { $0.page == 0 }, "the redacted page itself is clean: \(all)")
        let kinds = Set(found.map(\.kind))
        for kind: RedactionLeak in [.pageText, .hiddenText, .hiddenContent, .annotation, .formField, .bookmark, .metadata, .attachment, .structureTree] {
            #expect(kinds.contains(kind), "\(kind): \(all)")
        }
        #expect(found.contains { $0.kind == .pageText && $0.page == 1 && $0.text == Self.name && !$0.box.isEmpty && $0.fix == .redact })
        #expect(found.contains { $0.kind == .hiddenText && $0.page == 1 && $0.sanitize == .hiddenLayers }, "\(all)")
        #expect(found.contains { $0.kind == .hiddenText && $0.place.contains("outside the visible page") }, "\(all)")
        #expect(found.contains { $0.kind == .annotation && $0.text.contains("Call \(Self.name)") && $0.sanitize == .comments })
        #expect(found.contains { $0.kind == .annotation && $0.place == "Text box on page 2" }, "in its appearance only: \(all)")
        #expect(found.contains { $0.kind == .formField && $0.place.contains("patient") && $0.sanitize == .formValues })
        #expect(found.contains { $0.kind == .metadata && $0.place == "Document properties" })
        #expect(found.contains { $0.kind == .metadata && $0.place == "XMP metadata" }, "\(all)")
        #expect(found.contains { $0.kind == .attachment && $0.place == "Attached file 'notes.txt'" && $0.text.contains(Self.name) }, "\(all)")
        #expect(found.contains { $0.kind == .structureTree && $0.fix == .none })
        #expect(!found.contains { $0.kind == .areaNotRemoved }, "\(all)")
        #expect(report.values.contains(Self.name))
    }

    @Test func fixingRemovesEverythingThatCanBeFixed() throws {
        let (redacted, report) = try Self.redactAndCheck(Self.everywhere(), 0, Self.name)
        #expect(report.canFix)
        let fixed = try RedactionCheck.fix(redacted, nil, report.findings)
        let again = try RedactionCheck.run(fixed, nil, RedactionCheckOptions(values: report.values))
        #expect(again.findings.allSatisfy { $0.fix == .none }, "\(Self.describe(again))")
        #expect(!again.findings.contains { [.pageText, .metadata, .attachment, .bookmark].contains($0.kind) }, "\(Self.describe(again))")
    }

    @Test func aCleanRedactionReportsNothing() throws {
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 18 Tf 72 700 Td (Patient: \(Self.name)) Tj ET BT /F1 18 Tf 72 650 Td (Visit notes follow) Tj ET"),
            Core2Pdf.stream("BT /F1 12 Tf 72 700 Td (Second page, nothing private) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ])
        let (redacted, report) = try Self.redactAndCheck(data, 0, Self.name)
        #expect(report.isClean, "\(Self.describe(report))")
        // Checked as a file received from someone else (nothing known about it): clean too.
        let unknown = try RedactionCheck.run(redacted, nil)
        #expect(unknown.isClean, "\(Self.describe(unknown))")
    }

    @Test func ordinaryFilesHaveNothingToReport() throws {
        for data in [TestPdf.make(3), Self.table()] {
            let report = try RedactionCheck.run(data, nil)
            #expect(report.isClean, "\(Self.describe(report))")
        }
    }

    /// A dark table header with white text on it, square bullets drawn beside list items, a black rule.
    static func table() -> [UInt8] {
        onePage("0.1 0.1 0.3 rg 72 680 468 24 re f 1 g BT /F1 14 Tf 80 687 Td (Name    Amount    Date) Tj ET "
            + "0 g 72 640 5 5 re f BT /F1 12 Tf 84 638 Td (First item) Tj ET 72 620 5 5 re f BT /F1 12 Tf 84 618 Td (Second item) Tj ET "
            + "72 600 468 2 re f")
    }

    static func onePage(_ content: String, annots: String = "", more: [String] = [], xobjects: String = "") -> [UInt8] {
        RedactionTestPdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << \(xobjects) >> >> \(annots.isEmpty ? "" : "/Annots [\(annots)]") >>",
            RedactionTestPdf.stream(content),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ] + more)
    }

    static let line = "BT /F1 18 Tf 72 700 Td (Name: \(name) lives here) Tj ET"

    /// Where the name is drawn by `line`, in PDF space: x1 y1 x2 y2.
    static func nameBox() throws -> (x1: Double, y1: Double, x2: Double, y2: Double) {
        let area = try #require(try areasOf(onePage(line), 0, name)[0]?.first)
        return (area.x, 792 - area.bottom, area.right, 792 - area.y)
    }

    /// .NET's "0.##".
    static func f(_ v: Double) -> String { PdfNum.f2(v) }

    static func re(_ b: (x1: Double, y1: Double, x2: Double, y2: Double)) -> String { "\(f(b.x1)) \(f(b.y1)) \(f(b.x2 - b.x1)) \(f(b.y2 - b.y1)) re" }

    static func rect(_ b: (x1: Double, y1: Double, x2: Double, y2: Double)) -> String { "[\(f(b.x1)) \(f(b.y1)) \(f(b.x2)) \(f(b.y2))]" }

    /// A small picture with four colors (no byte of it spells "endstream").
    static func picture() -> String {
        let colors: [[UInt8]] = [[200, 30, 30], [30, 200, 30], [30, 30, 200], [220, 220, 40]]
        let bytes = (0..<16).flatMap { colors[$0 % 4] }
        return RedactionTestPdf.stream(latin1String(bytes), "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8")
    }

    static let badKinds = ["box", "highlight", "black-on-black", "white", "mark", "picture", "picture-comment", "spacing"]

    /// The roadmap's corpus: bad redactions of each kind. `kind` picks one.
    static func bad(_ kind: String) throws -> (bad: [UInt8], expected: RedactionLeak, area: RectD) {
        let b = try nameBox()
        let re = Self.re(b), rect = Self.rect(b)
        let area = RectD.fromEdges(b.x1, 792 - b.y2, b.x2, 792 - b.y1)
        let pictureAt = "q 200 0 0 100 72 400 cm /Im1 Do Q"
        let picArea = RectD(100, 792 - 480, 100, 60)
        let quads = "[\(b.x1) \(b.y2) \(b.x2) \(b.y2) \(b.x1) \(b.y1) \(b.x2) \(b.y1)]"
        switch kind {
        case "box": return (onePage("\(line) 0 g \(re) f"), .coveredText, area)
        case "highlight":
            return (onePage(line, annots: "6 0 R", more: [
                "<< /Type /Annot /Subtype /Highlight /Rect \(rect) /C [0 0 0] /QuadPoints \(quads) /AP << /N 7 0 R >> >>",
                RedactionTestPdf.stream("0 g 0 0 \(f(b.x2 - b.x1)) \(f(b.y2 - b.y1)) re f", "/Type /XObject /Subtype /Form /BBox [0 0 \(f(b.x2 - b.x1)) \(f(b.y2 - b.y1))]"),
            ]), .coveredText, area)
        case "black-on-black": return (onePage("0 g \(re) f \(line)"), .coveredText, area)
        case "white": return (onePage("BT /F1 18 Tf 72 700 Td (Name: ) Tj 1 g (\(name)) Tj 0 g ( lives here) Tj ET"), .coveredText, area)
        case "mark":
            return (onePage(line, annots: "6 0 R", more: ["<< /Type /Annot /Subtype /Redact /Rect \(rect) /QuadPoints \(quads) /IC [0 0 0] >>"]),
                    .unappliedMark, area)
        case "picture": return (onePage("\(pictureAt) 0 g 100 420 100 60 re f", more: [picture()], xobjects: "/Im1 6 0 R"), .coveredContent, picArea)
        case "picture-comment":
            return (onePage(pictureAt, annots: "7 0 R", more: [
                picture(),
                "<< /Type /Annot /Subtype /Square /Rect [100 420 200 480] /C [0 0 0] /IC [0 0 0] /AP << /N 8 0 R >> >>",
                RedactionTestPdf.stream("0 g 0 0 100 60 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 60]"),
            ], xobjects: "/Im1 6 0 R"), .coveredContent, picArea)
        // The name was taken out and a box drawn where it was; "lives here" kept its place.
        case "spacing":
            return (onePage("BT /F1 18 Tf 72 700 Td (Name: ) Tj ET 0 g \(re) f BT /F1 18 Tf \(f(b.x2 + 5)) 700 Td (lives here) Tj ET"), .glyphSpacing, area)
        default: throw PdfEditError(kind)
        }
    }

    @Test(arguments: badKinds)
    func badRedactionsAreFlaggedAndProperOnesAreNot(_ kind: String) throws {
        let (bad, expected, area) = try Self.bad(kind)
        let report = try RedactionCheck.run(bad, nil)
        let hits = report.findings.filter { $0.kind == expected }
        try #require(hits.count == 1, "\(Self.describe(report))")
        let hit = hits[0]
        #expect(hit.page == 0)
        #expect(!hit.box.isEmpty)
        #expect(hit.box.inflate(2).contains(area.centerX, area.centerY), "\(hit.box) should hold \(area)")
        if expected == .coveredText || expected == .unappliedMark { #expect(hit.text == Self.name) }
        #expect(hit.fix == .redact)

        // Redacted properly (the area applied), nothing is left: the fix does the same.
        let proper = try Redaction.apply(bad, nil, [0: [area.inflate(1)]], dpi: 100)
        let after = try RedactionCheck.run(proper, nil)
        #expect(after.isClean, "\(Self.describe(after))")
        let fixed = try RedactionCheck.run(RedactionCheck.fix(bad, nil, report.findings), nil)
        #expect(fixed.isClean, "\(Self.describe(fixed))")
    }

    @Test func aRedactedAreaThatStillShowsSomethingIsFound() throws {
        // Checked as if the name had been redacted, but it wasn't.
        let data = Self.onePage(Self.line)
        let areas = try Self.areasOf(data, 0, Self.name)
        let report = try RedactionCheck.run(data, nil, RedactionCheckOptions(values: [Self.name], areas: areas))
        #expect(report.findings.contains { $0.kind == .areaNotRemoved && $0.page == 0 })

        // A box drawn over a picture that was never changed: the area looks black, but the picture is the original.
        let (bad, _, area) = try Self.bad("picture")
        let boxed = try RedactionCheck.run(bad, nil, RedactionCheckOptions(areas: [0: [area]], original: bad))
        #expect(boxed.findings.contains { $0.kind == .areaNotRemoved && $0.text.contains("original") })
    }

    /// Appends an incremental update replacing object `number` (`trailerExtra`: more entries for its trailer).
    static func append(_ pdf: [UInt8], _ number: Int, _ body: String, trailerExtra: String = "") throws -> [UInt8] {
        let text = latin1(pdf)
        let at = try #require(text.range(of: "startxref", options: .backwards))
        let prevXref = try #require(Int(text[at.upperBound...].split(separator: "\n")[0].trimmingCharacters(in: .whitespaces)))
        let sizeMatch = try #require(text.range(of: #"/Size (\d+)"#, options: .regularExpression))
        let size = text[sizeMatch].dropFirst(6)
        let update = "\(number) 0 obj\n\(body)\nendobj\n"
        let xref = pdf.count + 1 + latin1Bytes(update).count
        let tail = "\n\(update)xref\n\(number) 1\n\(String(format: "%010d", pdf.count + 1)) 00000 n \ntrailer\n<< /Size \(size) /Root 1 0 R /Prev \(prevXref) \(trailerExtra)>>\nstartxref\n\(xref)\n%%EOF\n"
        return pdf + latin1Bytes(tail)
    }

    @Test func aValueInAnEarlierRevisionIsCaught() throws {
        // Version 1 shows the number; version 2 (appended) draws the line without it and a box where it was.
        let first = Self.onePage("BT /F1 18 Tf 72 700 Td (Account 219-09-9999) Tj ET")
        let second = try Self.append(first, 4, RedactionTestPdf.stream("BT /F1 18 Tf 72 700 Td (Account) Tj ET 0 g 150 695 110 22 re f"))
        #expect(!(try RedactionPatternTests.text(second, 0).contains("219")))

        // Nothing known: the earlier version's page showed text the current one doesn't.
        let report = try RedactionCheck.run(second, nil)
        #expect(report.findings.contains { $0.kind == .earlierRevision && $0.text.contains("219-09-9999") && $0.fix == .rewrite }, "\(Self.describe(report))")
        // The value known (written differently): found in the earlier version's objects too.
        let known = try RedactionCheck.run(second, nil, RedactionCheckOptions(values: ["219 09 9999"]))
        #expect(known.findings.contains { $0.kind == .earlierRevision && $0.place == "Earlier version 1 of the file" && $0.text.contains("219-09-9999") },
                "\(Self.describe(known))")

        // Rewritten as one version (and the box beside "Account" redacted), nothing is left.
        let fixed = try RedactionCheck.fix(second, nil, report.findings)
        #expect(RedactionCheck.revisions(fixed).isEmpty)
        let after = try RedactionCheck.run(fixed, nil, RedactionCheckOptions(values: ["219-09-9999"]))
        #expect(after.isClean, "\(Self.describe(after))")
    }

    @Test func anObjectNothingUsesIsFound() throws {
        let data = Self.onePage("BT /F1 18 Tf 72 700 Td (Nothing private here) Tj ET", more: ["<< /Note (Draft for \(Self.name)) >>"])
        let report = try RedactionCheck.run(data, nil, RedactionCheckOptions(values: [Self.name]))
        try #require(report.findings.count == 1, "\(Self.describe(report))")
        #expect(report.findings[0].kind == .fileData)
        #expect(report.findings[0].fix == .rewrite)
        let after = try RedactionCheck.run(RedactionCheck.fix(data, nil, report.findings), nil, RedactionCheckOptions(values: [Self.name]))
        #expect(after.isClean, "\(Self.describe(after))")
    }

    @Test func invisibleTextCountsOnlyOverADarkArea() throws {
        // An OCR layer's words over paper show nothing by design: not a leftover.
        let ocr = Self.onePage("BT 3 Tr /F1 18 Tf 72 700 Td (Name: \(Self.name) lives here) Tj ET")
        let clean = try RedactionCheck.run(ocr, nil)
        #expect(clean.isClean, "\(Self.describe(clean))")
        // The same words over a black box (a page made a picture with the box burnt in, its old text kept invisibly): found.
        let b = try Self.nameBox()
        let boxed = Self.onePage("0 g \(Self.re(b)) f BT 3 Tr /F1 18 Tf 72 700 Td (Name: \(Self.name) lives here) Tj ET")
        let report = try RedactionCheck.run(boxed, nil)
        #expect(report.findings.contains { $0.kind == .coveredText && $0.text == Self.name && $0.fix == .redact }, "\(Self.describe(report))")
    }

    @Test(arguments: [
        ("219-09-9999", "SSN 219 09 9999.", true),
        ("219-09-9999", "ref 219099999", true),
        ("219-09-9999", "1219-09-9999", false),
        (name, "ZEPHYRINE\nOKONKWO", true),
        (name, "Zephy\u{AD}rine Okonkwo", true),
        (name, "Zephyrine Okonkwos", false),
    ])
    func valuesMatchWrittenOtherwise(_ value: String, _ text: String, _ found: Bool) {
        let matcher = RedactionCheck.ValueMatcher([value])
        #expect(!matcher.matches(text).isEmpty == found)
    }
}
