import Foundation
import Testing
@testable import PdfCore

/// Ported from ReleaseBugHuntTests.cs (same names): its redaction tests, the bugs Windows' hunt before 1.6 found in
/// redaction by pattern. Left out: its four Translate tests (hidden layers, signed and AES-256 copies, right-to-left
/// answers), which belong to roadmap 3.1's port. Adapted: the batch's recognizer is `BatchHost.reader`; a malformed set's
/// error is `RedactionPatternSetError`, a malformed preset's `BatchPresetError`; A_pattern_nested_very_deep… accepts ICU
/// refusing a pattern nested 990 deep in plain words, where .NET reads it.
final class ReleaseBugHuntTests {
    private let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-bughunt-\(NewIds.hex().prefix(8))")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    private func p(_ name: String) -> String { (root as NSString).appendingPathComponent(name) }

    private static let ssn = "123-45-6789"
    private static let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"

    private static func found(_ pattern: RedactionPattern, _ lines: String...) throws -> [String] {
        try RedactionPatterns.find(RedactionPatternTests.page(lines), 0, RedactionPatternOptions(patterns: [pattern])).map(\.text)
    }

    /// A page of ordinary text; `more` are objects 6 on, `catalog` and `page` go in those objects.
    private static func doc(catalog: String = "", page: String = "", content: String = "BT /F1 14 Tf 72 700 Td (An ordinary line of words) Tj ET",
                            more: [String] = [], trailer: String = "") -> [UInt8] {
        let properties = page.hasPrefix("/Properties")
        return Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R \(catalog) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> \(properties ? page : "") >> \(properties ? "" : page) >>",
            Core2Pdf.stream(content),
            font,
        ] + more, trailerExtra: trailer)
    }

    private func redact(_ pdf: [UInt8], _ options: RedactionPatternOptions = RedactionPatternOptions(), _ ocr: (any TextRecognizer)? = nil) async throws -> BatchSummary {
        let path = p("in\(NewIds.hex().prefix(8)).pdf")
        try Data(pdf).write(to: URL(fileURLWithPath: path))
        let plan = BatchPlan(steps: [.redactPatterns(options)], outputFolder: p("out"))
        return try await BatchRunner.run([BatchFile(path)], plan, BatchHost(reader: ocr))
    }

    private static func fails(_ summary: BatchSummary) {
        #expect(summary.items[0].state == .failed, "\(summary.items[0].state): \(summary.items[0].message)")
    }

    private static func passes(_ summary: BatchSummary) {
        #expect(summary.items[0].state == .done, "\(summary.items[0].state): \(summary.items[0].message) (\(summary.items[0].notes.joined(separator: "; ")))")
    }

    // ---- numbers the patterns skip ----

    @Test(arguments: ["Ref 2026 4111 1111 1111 1111 paid", "Room 3012 4111-1111-1111-1111"])
    func A_card_after_a_four_digit_number_is_found(_ line: String) throws {
        #expect(try Self.found(.paymentCard, line).contains { $0.replacingOccurrences(of: "-", with: " ").contains("4111 1111 1111 1111") })
    }

    @Test func Two_cards_side_by_side_are_both_found() throws {
        #expect(try Self.found(.paymentCard, "4111 1111 1111 1111 5555 5555 5555 4444").count == 2)
    }

    @Test func An_iban_after_a_code_is_found() throws {
        #expect(try Self.found(.iban, "Code AB12 DE89 3704 0044 0532 0130 00").contains { $0.hasPrefix("DE89") })
    }

    @Test(arguments: [
        (RedactionPattern.socialSecurity, "Jane,123-45-6789,223-45-6789,x", 2),
        (.phone, "555-201-3434,555-201-3435", 2),
        (.ipAddress, "10.0.0.1,10.0.0.2", 2),
        (.paymentCard, "4111111111111111,5555555555554444", 2),
        (.date, "10/27/2026,11/27/2026", 2),
        (.date, "01/01/2025-12/31/2025", 2),
        (.socialSecurity, "123-45-6789/223-45-6789", 2),
        (.ipAddress, "10.0.0.1/24", 1),
        (.phone, "555-201-3434/555-201-3435", 2),
    ])
    func Values_run_together_by_a_comma_or_slash_are_all_found(_ pattern: RedactionPattern, _ line: String, _ count: Int) throws {
        let hits = try Self.found(pattern, line)
        #expect(hits.count == count, "\(hits)")
    }

    // ---- saved sets ----

    @Test(arguments: [
        #"{"format":"Inkvolt PDF redaction patterns","version":"1","name":"x","phrases":["a"]}"#,
        #"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"\uD800x","phrases":["a"]}"#,
        #"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","phrases":["\uDC00"]}"#,
        #"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":["\uD800"]}"#,
    ])
    func A_malformed_set_is_refused_with_a_reason(_ json: String) {
        #expect(throws: RedactionPatternSetError.self) { try RedactionPatternSets.read(json, "x.json") }
    }

    @Test func A_malformed_set_doesnt_stop_the_others_from_listing() throws {
        try #"{"format":"Inkvolt PDF redaction patterns","version":"1","name":"x"}"#.write(toFile: p("bad.json"), atomically: true, encoding: .utf8)
        try RedactionPatternSets.save(RedactionPatternSet("good", RedactionPatternOptions()), root)
        let (sets, problems) = RedactionPatternSets.list(root)
        #expect(sets.count == 1)
        #expect(problems.count == 1)
    }

    // ---- the rest of the file ----

    private static func withAttachment(_ name: String, _ text: String) -> [UInt8] {
        doc(catalog: "/Names << /EmbeddedFiles << /Names [(\(name)) 6 0 R] >> >>",
            more: ["<< /Type /Filespec /F (\(name)) /UF (\(name)) /EF << /F 7 0 R >> >>", Core2Pdf.stream(text, "/Type /EmbeddedFile")])
    }

    @Test(.enabled(if: ScanCorpus.runs)) func A_value_late_in_a_long_attachment_is_found() async throws {
        Self.fails(try await redact(Self.withAttachment("data.csv", String(repeating: "x", count: 1_500_000) + "\nSSN " + Self.ssn + "\n")))
    }

    @Test func A_value_in_a_link_action_held_apart_is_found() async throws {
        Self.fails(try await redact(Self.doc(page: "/Annots [6 0 R]", more: ["<< /Type /Annot /Subtype /Link /Rect [72 690 300 720] /A 7 0 R >>", "<< /S /URI /URI (mailto:jane.doe@example.com) >>"])))
    }

    @Test func A_value_in_a_forms_xfa_data_is_found() async throws {
        Self.fails(try await redact(Self.doc(catalog: "/AcroForm << /Fields [] /XFA [(datasets) 6 0 R] >>", more: [Core2Pdf.stream("<xfa:datasets><data><ssn>\(Self.ssn)</ssn></data></xfa:datasets>")])))
    }

    @Test func A_value_in_a_hidden_layer_is_found() async throws {
        Self.fails(try await redact(Self.doc(
            catalog: "/OCProperties << /OCGs [6 0 R] /D << /OFF [6 0 R] >> >>",
            page: "/Properties << /L1 6 0 R >>",
            content: "BT /F1 14 Tf 72 700 Td (An ordinary line of words) Tj ET /OC /L1 BDC BT /F1 14 Tf 72 600 Td (SSN \(Self.ssn)) Tj ET EMC",
            more: ["<< /Type /OCG /Name (Secret) >>"])))
    }

    /// The document with its content replaced by an incremental update: the old text stays in the file.
    private static func updated(_ pdf: [UInt8], _ content: String) -> [UInt8] {
        let text = latin1String(pdf)
        let tail = text[text.range(of: "startxref", options: .backwards)!.upperBound...]
        let prev = Int(tail.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n")[0].trimmingCharacters(in: .whitespaces))!
        var sb = text
        let at = sb.utf8.count
        sb += "4 0 obj\n\(Core2Pdf.stream(content))\nendobj\n"
        let xref = sb.utf8.count
        sb += "xref\n4 1\n\(String(format: "%010d", at)) 00000 n \ntrailer\n<< /Size 6 /Root 1 0 R /Prev \(prev) >>\nstartxref\n\(xref)\n%%EOF\n"
        return latin1Bytes(sb)
    }

    @Test func A_value_only_in_an_earlier_version_is_found() async throws {
        let pdf = Self.updated(Self.doc(content: "BT /F1 14 Tf 72 700 Td (SSN \(Self.ssn)) Tj ET"), "BT /F1 14 Tf 72 700 Td (An ordinary line of words) Tj ET")
        let engine = try PdfEngine.open(pdf)
        #expect(try !engine.text(0).text.contains(Self.ssn))
        engine.close()
        Self.fails(try await redact(pdf))
    }

    @Test func A_program_version_that_reads_as_an_address_doesnt_fail_the_file() async throws {
        Self.passes(try await redact(Self.doc(more: [#"<< /Producer (iText 5.5.13.3 \(c\)2000-2022 iText Group NV) /Creator (Report 16.0.1.2) >>"#], trailer: "/Info 6 0 R")))
    }

    @Test func A_programs_version_in_xmp_doesnt_fail_the_file() async throws {
        let xmp = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"><pdf:Producer>iText 5.5.13.3</pdf:Producer><xmp:CreatorTool>Report 16.0.1.2</xmp:CreatorTool></rdf:Description></rdf:RDF></x:xmpmeta>"
        Self.passes(try await redact(Self.doc(catalog: "/Metadata 6 0 R", more: [Core2Pdf.stream(xmp, "/Type /Metadata /Subtype /XML")])))
    }

    @Test func A_section_number_in_a_destinations_name_isnt_an_address() async throws {
        Self.passes(try await redact(Self.doc(catalog: "/Names << /Dests 6 0 R >>", page: "/Annots [7 0 R]",
                                              more: ["<< /Names [(paragraph.1.2.3.4) [3 0 R /Fit]] >>", "<< /Type /Annot /Subtype /Link /Rect [72 690 300 720] /A << /S /GoTo /D (paragraph.1.2.3.4) >> >>"])))
    }

    @Test func An_address_in_a_files_title_is_still_found() async throws {
        Self.fails(try await redact(Self.doc(more: ["<< /Title (Server 10.1.2.3) >>"], trailer: "/Info 6 0 R")))
    }

    /// A time stamp whose digits pass a card's check, with a zone that lets the digits end there.
    private static func cardLikeStamp() -> String {
        var s = 0
        while true {
            let stamp = "202401151030" + String(format: "%02d", s % 60)
            if RedactionPatterns.luhn(stamp) { return "D:\(stamp)+00'00'" }
            s += 1
        }
    }

    @Test func A_time_stamp_isnt_taken_for_a_card_number() async throws {
        Self.passes(try await redact(Self.doc(more: ["<< /CreationDate (\(Self.cardLikeStamp())) >>"], trailer: "/Info 6 0 R")))
        Self.passes(try await redact(Self.doc(page: "/Annots [6 0 R]", more: ["<< /Type /Annot /Subtype /Text /Rect [72 690 90 710] /M (\(Self.cardLikeStamp())) /Contents (A note) >>"])))
    }

    @Test func A_later_redaction_after_an_export_is_refused() {
        let plan = BatchPlan(steps: [.redactPatterns(RedactionPatternOptions()), .export(.word, dpi: 150), .redactPatterns(RedactionPatternOptions(phrases: ["word"]))],
                             outputFolder: root)
        #expect(plan.validate(ocrAvailable: true)?.contains("before exports") == true)
    }

    @Test func A_report_that_cant_be_written_doesnt_lose_the_batch() async throws {
        let blocker = p("afile")
        try "x".write(toFile: blocker, atomically: true, encoding: .utf8)
        let path = p("in.pdf")
        try Data(Self.doc()).write(to: URL(fileURLWithPath: path))
        let plan = BatchPlan(steps: [.redactPatterns(RedactionPatternOptions())], outputFolder: (blocker as NSString).appendingPathComponent("out"))
        let summary = try await BatchRunner.run([BatchFile(path)], plan, BatchHost())
        #expect(summary.items[0].state == .failed)
        #expect(summary.redactionReportPath == nil)
    }

    @Test func A_batch_note_doesnt_repeat_a_value_in_a_files_own_names() async throws {
        let summary = try await redact(Self.withAttachment(Self.ssn + ".txt", "Nothing here"))
        Self.fails(summary)
        #expect(!(summary.items[0].notes + [summary.items[0].message]).joined(separator: " ").contains(Self.ssn))

        let field = try await redact(Self.doc(catalog: "/AcroForm << /Fields [6 0 R] >>", page: "/Annots [6 0 R]",
                                              more: ["<< /Type /Annot /Subtype /Widget /FT /Tx /T (Holder \(Self.ssn)) /Rect [72 500 300 530] /V (x) >>"]))
        Self.fails(field)
        #expect(!(field.items[0].notes + [field.items[0].message]).joined(separator: " ").contains(Self.ssn))
    }

    @Test func A_date_on_the_page_that_is_also_the_files_own_date_doesnt_fail_it() async throws {
        let xmp = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"><xmp:CreateDate>2026-10-27T10:00:00Z</xmp:CreateDate></rdf:Description></rdf:RDF></x:xmpmeta>"
        let pdf = Self.doc(catalog: "/Metadata 6 0 R", content: "BT /F1 14 Tf 72 700 Td (Dated 2026-10-27 and more words) Tj ET",
                           more: [Core2Pdf.stream(xmp, "/Type /Metadata /Subtype /XML")])
        Self.passes(try await redact(pdf))
    }

    @Test func A_value_in_a_string_held_apart_is_found() async throws {
        Self.fails(try await redact(Self.doc(more: ["<< /Title 7 0 R >>", "(Holder \(Self.ssn))"], trailer: "/Info 6 0 R")))
    }

    @Test func An_attachment_that_cant_be_read_fails_the_file() async throws {
        Self.fails(try await redact(Self.doc(catalog: "/Names << /EmbeddedFiles << /Names [(a.bin) 6 0 R] >> >>",
                                             more: ["<< /Type /Filespec /F (a.bin) /EF << /F 7 0 R >> >>", Core2Pdf.stream("this is not flate data at all", "/Type /EmbeddedFile /Filter /FlateDecode")])))
    }

    @Test func A_value_in_an_attached_pdf_with_kerned_text_is_found() async throws {
        let inner = Self.doc(content: "BT /F1 14 Tf 72 700 Td [(SSN 123-)-20(45-)30(6789)] TJ ET")
        Self.fails(try await redact(Self.withAttachment("inner.pdf", String(decoding: inner, as: UTF8.self))))
    }

    @Test func A_file_that_never_got_to_the_search_is_in_the_report_as_failed() async throws {
        let (good, bad) = (p("good.pdf"), p("bad.pdf"))
        try Data(Self.doc()).write(to: URL(fileURLWithPath: good))
        try "this isn't a pdf".write(toFile: bad, atomically: true, encoding: .utf8)
        let plan = BatchPlan(steps: [.redactPatterns(RedactionPatternOptions())], outputFolder: p("out"))
        let summary = try await BatchRunner.run([BatchFile(good), BatchFile(bad)], plan, BatchHost())
        let report = try #require(summary.redactionReport)
        #expect(report.files.count == 2)
        #expect(report.hasFailures)
        let csv = Csv.decode(Array(try Data(contentsOf: URL(fileURLWithPath: try #require(summary.redactionReportPath)))))
        #expect(try Csv.read(csv).contains { $0[0] == "bad.pdf" && $0[4].hasPrefix("Failed") })
    }

    @Test func A_report_with_nothing_removed_doesnt_say_it_was_read_back() {
        var kept = RedactionRemoval(0, .phone, "***", .kept)
        #expect(!RedactionReport([RedactionFileReport("a.pdf", [kept], [], nil)]).headline.contains("Read back"))
        kept.outcome = .removed
        #expect(RedactionReport([RedactionFileReport("a.pdf", [kept], [], nil)]).headline.contains("Read back"))
    }

    @Test(.enabled(if: ScanCorpus.runs)) func A_picture_nothing_could_read_isnt_said_to_have_been_read() async throws {
        let summary = try await redact(try Self.lightOnBand(0.2, PlantedReader()))
        Self.passes(summary)
        #expect(!summary.items[0].notes.contains { $0.contains("read by text recognition") })
        #expect(summary.items[0].notes.contains { $0.contains("Look by hand") && $0.contains("couldn't be read") }, "\(summary.items[0].notes)")
    }

    @Test(.enabled(if: ScanCorpus.runs)) func A_file_with_a_picture_nothing_could_read_says_to_look_not_just_done() async throws {
        let summary = try await redact(try Self.lightOnBand(0.2, PlantedReader()))
        #expect(summary.items[0].state == .done) // a logo mustn't fail a batch
        #expect(summary.items[0].message.contains("look by hand at page 1"), "\(summary.items[0].message)")
        #expect(summary.text.contains("1 to look at by hand"), "\(summary.text)")
        let report = try #require(summary.redactionReport)
        #expect(!report.hasFailures)
        let rows = try Csv.read(Csv.decode(Array(try Data(contentsOf: URL(fileURLWithPath: try #require(summary.redactionReportPath))))))
        #expect(rows.contains { $0[2] == "Result for this file" && $0[4].hasPrefix("Look by hand") })
        #expect(rows.contains { $0[1] == "1" && $0[4] == "Look by hand" })
        let why = RedactionLook.why(report.files[0].looks)
        #expect(why.contains("couldn't be read"))
        #expect(!why.contains("read by text recognition"))
        #expect(!(report.headline + report.files[0].summary).lowercased().contains("clean"))
    }

    @Test func Areas_marked_earlier_are_counted_in_the_report() {
        let only = RedactionReport([RedactionFileReport("a.pdf", [], [], nil, markedAreas: 2)])
        #expect(only.headline.contains("Read back"))
        #expect(only.headline.contains("2 other marked areas"))
        #expect(only.files[0].summary.contains("2 other marked areas"))
        #expect(!only.files[0].summary.contains("nothing found"))
    }

    // ---- ink the search doesn't see ----

    /// A page of text with a picture on it: a band of a shade with light words in it (a banner, a card).
    private static func lightOnBand(_ shade: Double, _ reader: PlantedReader) throws -> [UInt8] {
        let source = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 60] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("\(shade) g 0 0 300 60 re f 1 g BT /F1 14 Tf 20 22 Td (SSN \(ssn)) Tj ET"),
            font,
        ])
        let engine = try PdfEngine.open(source)
        defer { engine.close() }
        let (gray, w, h) = try RedactionCorpus.gray(engine, 0, scale: 2)
        reader.plantWords(612, 792, [("SSN", RectD(92, 330, 34, 18)), (ssn, RectD(128, 330, 90, 18))])
        return RedactionCorpus.build([
            RedactionCorpus.obj("<< /Type /Catalog /Pages 2 0 R >>"),
            RedactionCorpus.obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            RedactionCorpus.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im0 6 0 R >> >> >>"),
            RedactionCorpus.stream("BT /F1 14 Tf 72 700 Td (An ordinary line of words) Tj ET q 300 0 0 60 72 400 cm /Im0 Do Q"),
            RedactionCorpus.helvetica,
            RedactionCorpus.stream(gray, "/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceGray /BitsPerComponent 8"),
        ])
    }

    @Test(.enabled(if: ScanCorpus.runs), arguments: [0.0, 0.3, 0.5, 0.7])
    func Light_words_on_a_band_in_a_picture_arent_called_clean(_ shade: Double) throws {
        let reader = PlantedReader()
        let pdf = try Self.lightOnBand(shade, reader)
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        #expect(!(try RedactionSearch.find(engine, RedactionPatternOptions(), ocr: reader)).looks.isEmpty)
    }

    /// A scan under a text layer that holds only its first line; the recognizer reads both, and the lines are close.
    @Test(.enabled(if: ScanCorpus.runs)) func A_value_on_the_next_line_of_one_the_text_layer_has_is_still_found() async throws {
        let source = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 12 Tf 72 700 Td (\(Self.ssn)) Tj ET BT /F1 12 Tf 72 688 Td (223-45-6789) Tj ET"),
            Self.font,
        ])
        let render = try PdfEngine.open(source)
        let (gray, w, h) = try RedactionCorpus.gray(render, 0, scale: 150.0 / 72)
        let reader = PlantedReader()
        reader.plant(612, 792, try render.text(0))
        render.close()
        let pdf = RedactionCorpus.build([
            RedactionCorpus.obj("<< /Type /Catalog /Pages 2 0 R >>"),
            RedactionCorpus.obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            RedactionCorpus.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im0 6 0 R >> >> >>"),
            RedactionCorpus.stream("q 612 0 0 792 0 0 cm /Im0 Do Q BT 3 Tr /F1 12 Tf 72 700 Td (\(Self.ssn)) Tj ET"),
            RedactionCorpus.helvetica,
            RedactionCorpus.stream(gray, "/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /ColorSpace /DeviceGray /BitsPerComponent 8"),
        ])
        let engine = try PdfEngine.open(pdf)
        let found = try RedactionSearch.find(engine, RedactionPatternOptions(), ocr: reader)
        engine.close()
        #expect(found.hits.contains { $0.normalized == "223-45-6789" }, "\(found.hits.map { "\($0.normalized) ocr=\($0.fromOcr)" })")
        Self.passes(try await redact(pdf, RedactionPatternOptions(), reader))
    }

    @Test func A_pattern_nested_very_deep_doesnt_stop_the_app() throws {
        // ICU refuses a pattern nested this deep, in plain words (.NET takes it): either way nothing overflows.
        let deep = String(repeating: "(", count: 990) + "a" + String(repeating: ")", count: 990)
        if let refused = RedactionPatterns.validateExpression(deep) {
            #expect(refused.contains("mistake"))
            #expect(throws: PdfEditError.self) { try RedactionPatterns.find(RedactionPatternTests.page("x a y"), 0, RedactionPatternOptions(patterns: [], expression: deep)) }
        } else {
            #expect(try RedactionPatterns.find(RedactionPatternTests.page("x a y"), 0, RedactionPatternOptions(patterns: [], expression: deep)).count == 1)
        }
    }

    @Test func A_malformed_preset_is_refused_with_a_reason() {
        let json = #"{"format":"Inkvolt PDF batch preset","version":1,"name":"\uD800","steps":[{"action":"redactPatterns","phrases":["\uD800"]}]}"#
        do {
            _ = try BatchPresets.read(json)
        } catch is BatchPresetError {
        } catch {
            Issue.record("\(error)")
        }
    }
}
