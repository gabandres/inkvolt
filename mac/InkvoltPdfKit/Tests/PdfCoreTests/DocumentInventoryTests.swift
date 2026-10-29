import Foundation
import Testing
@testable import PdfCore

/// Ported from DocumentInventoryTests.cs. Adapted: the planted corpus is the Mac's `SanitizerTests.dirty()` (the same
/// objects) with the update appended by `RedactionCheckTests.append`; `Where` is `place`, `In` is `items(in:)`;
/// reportsSaveAsHtmlAndJson reads the JSON's top-level field order from its text (JSONSerialization keeps no order);
/// anOrdinaryFileCarriesNothing gives its titled file a /Title of its own (the hand-written `TestPdf` has no properties;
/// PDFsharp's save writes one on Windows). Left out: InventoryBatchTests (Batch's Report What's in Each File comes with
/// E8).
struct DocumentInventoryTests {
    static let all = Set(SanitizeItem.allCases)

    /// `SanitizerTests.dirty()` (one of everything Sanitize removes) with a second version appended that no longer shows
    /// "Visible text".
    static func planted() throws -> [UInt8] {
        let first = SanitizerTests.dirty()
        let content = "BT /F1 12 Tf 72 700 Td (Shown text) Tj ET /OC /L1 BDC BT /F1 12 Tf 72 650 Td (Shown layer) Tj ET EMC "
            + "/OC /L2 BDC 1 0 0 rg BT /F1 12 Tf 72 600 Td (Secret layer) Tj ET 0 0 100 100 re f EMC q /Sec Do Q q 10 0 0 10 300 300 cm /Im Do Q "
        return try RedactionCheckTests.append(first, 4, Core2Pdf.stream(content), trailerExtra: "/Info 6 0 R ")
    }

    static func dump(_ items: [InventoryItem]) -> String {
        items.map { "\($0.section) | \($0.what) | \($0.place) | \($0.trigger) | \($0.detail)" }.joined(separator: "\n")
    }

    static func has(_ r: InventoryReport, _ section: InventorySection, _ match: (InventoryItem) -> Bool,
                    sourceLocation: SourceLocation = #_sourceLocation) throws -> InventoryItem {
        try #require(r.items.first { $0.section == section && match($0) }, "Not in \(section):\n\(dump(r.items))", sourceLocation: sourceLocation)
    }

    @Test func listsEachPlantedKind() throws {
        let r = try DocumentInventory.run(Self.planted(), nil)

        // Scripts, where they run, and what they call.
        let open = try Self.has(r, .scripts) { $0.detail.contains("app.alert") }
        #expect(open.place == "When the document opens")
        #expect(open.trigger == .automatic)
        #expect(open.calls.contains("shows a message or asks a question"))
        #expect(open.removedBy == .activeContent)
        #expect(try Self.has(r, .scripts) { $0.detail.contains("willClose") }.place == "Before the document closes")
        #expect(try Self.has(r, .scripts) { $0.detail.contains("docInit") }.place.contains("document script \u{201C}init\u{201D}"))
        #expect(try Self.has(r, .scripts) { $0.detail.contains("pageOpen") }.place == "When page 1 opens")
        let keystroke = try Self.has(r, .scripts) { $0.detail.contains("AFNumber_Keystroke") }
        #expect(keystroke.trigger == .use)
        #expect(keystroke.place.contains("\u{201C}name\u{201D}"))
        #expect(try Self.has(r, .scripts) { $0.detail.contains("evil") }.trigger == .use)
        _ = try Self.has(r, .scripts) { $0.what == "XFA form" }
        _ = try Self.has(r, .scripts) { $0.detail == "RichMedia" }
        _ = try Self.has(r, .scripts) { $0.detail == "Sound" }

        // The open action's next step only goes to a page: nothing to list.
        #expect(r.items(in: .actions).isEmpty, "\(Self.dump(r.items(in: .actions)))")

        // Every address, file and program, and how it is reached.
        let link = try Self.has(r, .addresses) { $0.detail == "https://example.com/link" }
        #expect(link.trigger == .use)
        #expect(link.page == 0)
        #expect(!link.withoutClick)
        #expect(try Self.has(r, .addresses) { $0.detail == "https://example.com/outline" }.place.contains("bookmark \u{201C}Chapter\u{201D}"))
        #expect(try Self.has(r, .addresses) { $0.detail == "https://example.com/submit" }.what == "Sends the form's data")
        #expect(try Self.has(r, .addresses) { $0.detail == "calc.exe" }.what == "Starts a program or opens a file")

        // Attachments: the document's list, the attachment comment, the associated file.
        #expect(r.items(in: .attachments).filter { $0.what == "Attached file" && $0.detail.hasPrefix("a.txt") }.count == 2)
        _ = try Self.has(r, .attachments) { $0.what == "Associated file" && $0.detail == "a.txt" }

        // Metadata: properties, XMP, other apps' data, an image's own packet.
        #expect(try Self.has(r, .metadata) { $0.what == "Title" }.detail == "Secret title")
        #expect(try Self.has(r, .metadata) { $0.what == "Author" }.detail == "Jane Doe")
        #expect(try Self.has(r, .metadata) { $0.what == "Written by" }.detail == "Word")
        #expect(try Self.has(r, .metadata) { $0.what == "Custom" }.detail == "internal")
        #expect(try Self.has(r, .metadata) { $0.what == "Author (XMP)" }.detail == "Jane Doe")
        _ = try Self.has(r, .metadata) { $0.what == "Private data of other apps" && $0.detail == "Illustrator" && $0.place == "The document" }
        _ = try Self.has(r, .metadata) { $0.what == "Private data of other apps" && $0.detail == "App" && $0.place == "Page 1" }
        _ = try Self.has(r, .metadata) { $0.what == "XMP metadata" && $0.place == "Page 1, a picture" }

        // Earlier versions, and the text only the earlier one shows.
        _ = try Self.has(r, .earlierVersions) { $0.what == "Earlier versions" && $0.detail.hasPrefix("1 earlier version") }
        _ = try Self.has(r, .earlierVersions) { $0.what == RedactionCheck.name(.earlierRevision) && $0.detail.localizedCaseInsensitiveContains("visible") }

        // Hidden: the layer, a hidden comment, a hidden field.
        _ = try Self.has(r, .hidden) { $0.what == "Hidden layer" && $0.detail.contains("Hidden notes") }
        _ = try Self.has(r, .hidden) { $0.what == "Hidden comment" && $0.detail == "hidden square" }
        _ = try Self.has(r, .hidden) { $0.what == "Hidden form field" && $0.detail == "hidden data" }

        // Form values.
        #expect(try Self.has(r, .formValues) { $0.place.contains("\u{201C}name\u{201D}") }.detail == "John Smith")
        #expect(try Self.has(r, .formValues) { $0.place.contains("\u{201C}agree\u{201D}") }.detail == "on (Yes)")
        #expect(!r.items(in: .formValues).contains { $0.place.contains("send") }) // a push button has no value

        #expect(!r.isEmpty)
        #expect(r.pages == 1)
        #expect(r.counts[.activeContent] == 11)
    }

    @Test func sanitizedEverythingReportsNothing() throws {
        let before = try DocumentInventory.run(Self.planted(), nil)
        for i in before.items where i.section != .earlierVersions && i.section != .hidden {
            #expect(i.removedBy != nil, "no Sanitize kind for \(i.section) | \(i.what) | \(i.detail)")
        }

        let sanitized = try Sanitizer.sanitize(Self.planted(), nil, Self.all).data
        let after = try DocumentInventory.run(sanitized, nil)
        #expect(after.isEmpty, "\(Self.dump(after.items))")
        #expect(after.summary.hasPrefix("Nothing but its pages"))
    }

    @Test func textThatDoesNotShowAndCoversAreListed() throws {
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 18 Tf 72 700 Td (Shown words) Tj ET 1 1 1 rg BT /F1 18 Tf 72 600 Td (White secret) Tj ET 0 g "
                + "BT /F1 18 Tf 72 1200 Td (Offpage secret) Tj ET BT /F1 18 Tf 72 500 Td (Boxed secret) Tj ET 0 g 60 490 200 30 re f"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ])
        let r = try DocumentInventory.run(data, nil)
        _ = try Self.has(r, .redaction) { $0.detail.contains("White secret") && $0.page == 0 && $0.place.contains("color behind") }
        _ = try Self.has(r, .hidden) { $0.detail.contains("Offpage secret") && $0.place.contains("outside the visible page") }
        _ = try Self.has(r, .redaction) { $0.detail.contains("Boxed secret") && $0.what == RedactionCheck.name(.coveredText) }
        #expect(!r.items.contains { $0.detail.contains("Shown words") })
    }

    @Test func addressesReachedWithoutAClickAreMarked() throws {
        let data = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R /OpenAction << /S /URI /URI (https://tracker.example/open) >> /AcroForm << /Fields [8 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Annots [5 0 R 8 0 R] /AA << /C 7 0 R >> >>",
            Core2Pdf.stream(""),
            "<< /Type /Annot /Subtype /Link /Rect [72 700 200 720] /AA << /E 6 0 R >> /A << /S /GoTo /D [3 0 R /Fit] >> >>",
            "<< /S /JavaScript /JS (app.launchURL\\(\"https://hover.example/x?id=1\"\\); this.submitForm\\(\"mailto:a@example.com\"\\)) >>",
            "<< /S /Launch /F (setup.exe) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature1) /Rect [300 100 400 150] /P 3 0 R /V 9 0 R >>",
            "<< /Type /Sig /Filter /Adobe.PPKLite /Name (Jane Signer) /M (D:20260301120000Z) /Reason (Approved) /Location (San Juan) >>",
        ])
        let r = try DocumentInventory.run(data, nil)

        let open = try Self.has(r, .addresses) { $0.detail == "https://tracker.example/open" }
        #expect(open.trigger == .automatic)
        #expect(open.withoutClick)
        _ = try Self.has(r, .actions) { $0.detail == "https://tracker.example/open" && $0.what == "Opens a web address" }

        let hover = try Self.has(r, .addresses) { $0.detail == "https://hover.example/x?id=1" }
        #expect(hover.trigger == .pointer)
        #expect(hover.place.contains("pointer enters"))
        _ = try Self.has(r, .addresses) { $0.detail == "mailto:a@example.com" && $0.trigger == .pointer }
        let script = try Self.has(r, .scripts) { $0.detail.contains("launchURL") }
        #expect(script.calls == ["opens a web address", "sends the form's data"])

        let launch = try Self.has(r, .addresses) { $0.detail == "setup.exe" }
        #expect(launch.place == "When page 1 closes")
        #expect(launch.withoutClick)
        _ = try Self.has(r, .actions) { $0.detail == "setup.exe" }
        #expect(!r.items.contains { $0.section == .addresses && $0.what == "Goes to a page" }) // a click to a page reaches nothing

        let sig = try Self.has(r, .signatures) { $0.place.contains("Signature1") }
        #expect(sig.detail == "Jane Signer, 1 March 2026, 12:00, reason: Approved, at San Juan")
        #expect(sig.removedBy == .signatures)

        #expect(r.summary.contains("4 addresses are reached without a click"), "\(r.summary)")
    }

    @Test(arguments: [
        ("this.print({bUI: false})", "prints"),
        ("var x = eval(code)", "runs code it builds as it goes"),
        ("this.exportDataObject({cName: 'a'})", "writes a file"),
        ("var n = identity.name", "reads who you are or what your computer runs"),
        ("Net.HTTP.request({cURL: u})", "connects to the internet"),
        ("app.setTimeOut('f()', 100)", "runs on a timer"),
    ])
    func scriptCallsAreNamed(_ source: String, _ words: String) {
        #expect(DocumentInventory.scriptCalls(source).contains(words))
    }

    @Test func scriptsWithoutOutwardCallsNameNone() {
        #expect(DocumentInventory.scriptCalls("var total = this.getField('a').value + 1; event.value = total;").isEmpty)
    }

    @Test func reportsSaveAsHtmlAndJson() throws {
        let r = try DocumentInventory.run(Self.planted(), nil)
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 28, 9, 30)
        let at = try #require(Calendar(identifier: .gregorian).date(from: c))
        let html = InventoryReportFiles.html(r, "planted <file>.pdf", madeAt: at)
        #expect(html.hasPrefix("<!DOCTYPE html>"))
        #expect(html.contains("<title>What's in this PDF: planted &lt;file&gt;.pdf</title>"))
        for s in Set(r.items.map(\.section)) {
            #expect(html.contains(">\(InventoryReportFiles.encode(DocumentInventory.title(s))) ("))
        }
        #expect(html.contains("(no click needed)"))
        #expect(html.contains("app.alert"))
        #expect(!html.contains("<script"))
        #expect(!html.contains("src="))

        let json = InventoryReportFiles.json(r, "planted.pdf", madeAt: at)
        let root = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(root["format"] as? String == InventoryReportFiles.jsonFormat)
        #expect(root["version"] as? Int == 1)
        let order = json.split(separator: "\n").filter { $0.hasPrefix("  \"") }.compactMap { $0.dropFirst(3).split(separator: "\"").first.map(String.init) }
        #expect(order == ["format", "version", "file", "madeAt", "pages", "summary", "items", "sanitizeFinds", "notes"])
        let items = try #require(root["items"] as? [[String: Any]])
        #expect(items.count == r.items.count)
        #expect(items.first?["section"] as? String == "scripts")
        #expect((root["sanitizeFinds"] as? [String: Any])?["activeContent"] as? Int == 11)
        // Same report, same bytes.
        #expect(json == InventoryReportFiles.json(try DocumentInventory.run(Self.planted(), nil), "planted.pdf", madeAt: at))
    }

    @Test func anOrdinaryFileCarriesNothing() throws {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 6 0 R >> >> /Annots [7 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 6 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 18 Tf 72 700 Td (Just a page) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Link /Rect [72 690 200 720] /A << /S /GoTo /D [4 0 R /Fit] >> >>",
        ]
        let r = try DocumentInventory.run(Core2Pdf.build(objects), nil)
        #expect(r.isEmpty, "\(Self.dump(r.items))")
        #expect(r.pages == 2)
        // Metadata when there is some.
        let titled = try DocumentInventory.run(Core2Pdf.build(objects + ["<< /Title (Synthetic) >>"], trailerExtra: "/Info 8 0 R"), nil)
        #expect(titled.items(in: .metadata).first { $0.what == "Title" }?.detail == "Synthetic")
    }
}
