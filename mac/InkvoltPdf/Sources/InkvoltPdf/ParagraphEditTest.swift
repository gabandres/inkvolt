import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for roadmap 2.1, paragraph editing (`--edit`, once; `--only-paragraph-edit` runs it alone), on a
/// page made here (a heading, a paragraph of four lines in Helvetica, a line under it): Edit Text & Images chosen, a click
/// on the paragraph's second line rewrites it with twenty words more (it rewraps in its box, what follows stays, one undo
/// step that undo and redo take back and forth); the paragraph editor opened over it, bold, a color and a bigger size
/// given to words through its look bar and the note under it read, then applied (the looks read back as spans); new text
/// that would run into the line below declined, then confirmed; a character Helvetica lacks drawn from a font on this
/// Mac. The document is closed unsaved. Only what it made is written.
@MainActor
struct ParagraphEditTest {
    /// Running: the document it opens gets no self-test of its own.
    private(set) static var isActive = false
    private var lines: [String] = []
    private var failures = 0

    private static let body = "The quick brown fox jumps over the lazy dog while five boxing wizards jump quickly and a sphinx of black "
        + "quartz judges my vow of silence on a calm and quiet evening by the river"
    private static let twenty = "Then seven tired hikers walked along the narrow path toward the old stone bridge before the rain came at last"

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[paragraphs] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    /// A one-page PDF (Helvetica, not embedded) with `content` as its page's content.
    private static func pdf(_ content: String) -> [UInt8] {
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(out.utf8)
    }

    /// `text` wrapped at 300 points in Helvetica 11, as the editor measures it.
    private static func wrap(_ text: String) -> [String] {
        guard let probe = try? ContentEditor.read(pdf("BT /F1 11 Tf 72 700 Td (a) Tj ET"), nil, 0).runs.first else { return [text] }
        var lines: [String] = []
        var cur = ""
        for word in text.split(separator: " ").map(String.init) {
            if !cur.isEmpty && probe.check(cur + " " + word).width > 300 {
                lines.append(cur)
                cur = word
            } else {
                cur = cur.isEmpty ? word : cur + " " + word
            }
        }
        lines.append(cur)
        return lines
    }

    private static func sample() -> [UInt8] {
        let lines = wrap(body)
        var sb = "BT /F1 16 Tf 72 740 Td (A Heading Here) Tj ET\nBT /F1 11 Tf 14 TL 72 700 Td (\(lines[0])) Tj"
        for l in lines.dropFirst() { sb += " T* (\(l)) Tj" }
        sb += " 0 -70 Td (Next block starts here) Tj ET\n"
        return pdf(sb)
    }

    private func settle(_ c: DocumentWindowController) async {
        for _ in 0..<3 {
            await c.pages.pendingEdit?.value
            await c.content.settle()
        }
    }

    /// The page's content as the document has it now.
    private func read(_ c: DocumentWindowController) -> PageContent {
        guard let s = c.pdf.session else { return .empty }
        return (try? ContentEditor.read(s.data, s.password, 0)) ?? .empty
    }

    private func paragraph(_ c: DocumentWindowController, _ start: String) -> TextParagraph? {
        read(c).paragraphs.first { $0.text.hasPrefix(start) }
    }

    private func click(_ c: DocumentWindowController, _ p: PointD) async {
        let pages = c.pages
        let view = pages.viewPoint(p, pages.pageRects[0])
        let location = pages.convert(view, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: c.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { pages.mouseDown(with: e) } else { pages.mouseUp(with: e) }
        }
        await settle(c)
    }

    /// Waits until `count` edits have ended.
    private func waitEdits(_ c: DocumentWindowController, _ count: Int) async -> Bool {
        let end = Date() + 10
        while c.editor.finishedEdits < count && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        return c.editor.finishedEdits >= count
    }

    mutating func run() async {
        Self.isActive = true
        defer { Self.isActive = false }
        lines.append("== Paragraph editing (roadmap 2.1) on a page made here")
        guard let document = NewDocuments.open(Self.sample(), name: "Paragraph test"),
              let c = document.windowControllers.first as? DocumentWindowController else {
            check(false, "the sample page opens")
            return finish()
        }
        defer { document.close() }
        for _ in 0..<250 where c.pages.pageRects.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        c.setZoom(1)
        c.go(0)
        let item = NSMenuItem()
        item.tag = Tool.editContent.rawValue
        c.chooseTool(item)
        _ = await c.content.ensure(0)
        await rewrap(c)
        await looks(c)
        await overlap(c)
        await standIns(c)
        c.content.testParagraph = nil
        c.content.testOverlapAnswer = nil
        finish()
    }

    /// A click on the paragraph's second line, with twenty words more: rewrapped in its box, what follows stays; undo, redo.
    private mutating func rewrap(_ c: DocumentWindowController) async {
        guard let p = paragraph(c, "The quick"), let next = read(c).runs.first(where: { $0.text == "Next block starts here" }) else {
            return check(false, "the sample's paragraph and the line under it are read")
        }
        check(p.blocked == nil && p.lines.count >= 3 && p.text == Self.body, "the paragraph is one of \(p.lines.count) lines, editable")
        let text = Self.body + " " + Self.twenty
        let edits = c.editor.finishedEdits
        c.content.testParagraph = (text, nil)
        await click(c, PointD(p.lines[1].x + 20, p.lines[1].centerY))
        let written = await waitEdits(c, edits + 1)
        await settle(c)
        let q = paragraph(c, "The quick")
        let next2 = read(c).runs.first { $0.text == "Next block starts here" }
        check(written && q?.text == text, "a click on its second line rewrites it (\(q?.lines.count ?? 0) lines, was \(p.lines.count))")
        check((q?.lines.count ?? 0) > p.lines.count && (q?.box.right ?? 999) <= p.box.right + 0.5, "it rewraps inside its box")
        check(next2.map { abs($0.box.y - next.box.y) < 0.01 } == true, "the line under it stays where it was")
        let undo = c.window?.undoManager
        let title = undo?.undoMenuItemTitle ?? ""
        check(title == Shown.undo(loc("Edit paragraph")), "one undo step: “\(title)”")
        undo?.undo()
        await settle(c)
        check(paragraph(c, "The quick")?.text == Self.body, "undo takes it back")
        undo?.redo()
        await settle(c)
        check(paragraph(c, "The quick")?.text == text, "redo writes it again")
    }

    /// The editor over the paragraph: bold, a color and a bigger size from its look bar, its note, then Apply.
    private mutating func looks(_ c: DocumentWindowController) async {
        c.content.testParagraph = nil
        guard let p = paragraph(c, "The quick") else { return check(false, "the paragraph is read again") }
        c.content.editParagraph(p)
        for _ in 0..<100 where c.content.paragraphEditor?.isViewLoaded != true { try? await Task.sleep(for: .milliseconds(20)) }
        guard let editor = c.content.paragraphEditor, editor.isViewLoaded else { return check(false, "the paragraph editor opens") }
        check(editor.textView.string == p.text, "the paragraph editor opens with its text")
        let red = NSButton()
        red.tag = 2 // ParagraphEditorController.colors[2]: red, 0xC00000
        let found = editor.select("quick")
        editor.toggleBold(nil)
        let found2 = editor.select("lazy dog")
        editor.chooseColor(red)
        let found3 = editor.select("fox")
        editor.larger(nil)
        editor.larger(nil)
        let typed = editor.select("river")
        editor.type("river bank")
        let (_, spans) = editor.content()
        editor.updateNote() // typing lays the note out a moment later, off the main thread
        check(found && found2 && found3 && typed && spans.count == 3, "the look bar gives three stretches their looks (\(spans.count))")
        let note = editor.note.stringValue
        check(!note.isEmpty && note.contains(CoreLanguage.number(p.check(editor.content().text, spans: spans).lineCount)), "its note says the lines: “\(note.prefix(80))”")
        let edits = c.editor.finishedEdits
        editor.applyEdit(nil)
        await settle(c)
        let written = await waitEdits(c, edits + 1)
        await settle(c)
        guard let q = paragraph(c, "The quick") else { return check(false, "the paragraph reads back") }
        let wanted: [(String, (TextLook) -> Bool)] = [
            ("quick", { $0.bold == true }), ("lazy dog", { $0.color == 0xC00000 }), ("fox", { $0.size.map { abs($0 - 13) < 0.05 } == true }),
        ]
        let back = wanted.allSatisfy { word, test in
            q.spans.contains { s in
                let u = Array(q.text.utf16)
                return s.end <= u.count && String(decoding: u[s.start..<s.end], as: UTF16.self) == word && test(s.look)
            }
        }
        check(written && back && q.text.contains("by the river bank"), "Apply writes the text and its looks, read back as spans (\(q.spans.count))")
        check(c.content.paragraphEditor == nil, "the editor closes")
    }

    /// New text that would run into the line below: declined (nothing written), then confirmed.
    private mutating func overlap(_ c: DocumentWindowController) async {
        guard let p = paragraph(c, "The quick") else { return check(false, "the paragraph is read for the overlap") }
        let long = p.text + " " + Self.twenty + " " + Self.twenty + " " + Self.twenty + " " + Self.twenty
        check(p.check(long).overlaps != nil, "much longer text would run into the line under it")
        let edits = c.editor.finishedEdits
        c.content.testParagraph = (long, nil)
        c.content.testOverlapAnswer = false
        c.content.editParagraph(p)
        await settle(c)
        try? await Task.sleep(for: .milliseconds(200))
        check(c.editor.finishedEdits == edits && paragraph(c, "The quick")?.text == p.text, "declined, nothing is written")
        c.content.testOverlapAnswer = true
        c.content.editParagraph(p)
        let written = await waitEdits(c, edits + 1)
        await settle(c)
        check(written && paragraph(c, "The quick")?.text == long, "confirmed, it is written anyway")
        c.window?.undoManager?.undo()
        await settle(c)
        check(paragraph(c, "The quick")?.text == p.text, "and undo takes it back")
    }

    /// A character Helvetica (WinAnsi) lacks: drawn from a font on this Mac, the rest in the page's font.
    private mutating func standIns(_ c: DocumentWindowController) async {
        guard let p = paragraph(c, "The quick") else { return check(false, "the paragraph is read for stand-ins") }
        let text = "North → south, " + p.text
        let check1 = p.check(text)
        check(check1.borrowed == ["→"] && !check1.standIns.isEmpty, "“→” is drawn from \(check1.standIns.joined(separator: ", "))")
        let edits = c.editor.finishedEdits
        c.content.testParagraph = (text, nil)
        c.content.editParagraph(p)
        let written = await waitEdits(c, edits + 1)
        await settle(c)
        let q = paragraph(c, "North")
        let standIn = q?.runs.contains { $0.text == "→" && $0.fontName != p.lead.fontName } == true
        let engineText: String
        if let s = c.pdf.session, let engine = try? PdfEngine.open(s.data, password: s.password) {
            engineText = (try? engine.text(0, cache: false).text) ?? ""
            engine.close()
        } else {
            engineText = ""
        }
        check(written && q?.text == text && standIn, "written, the arrow in its stand-in, the paragraph one again")
        check(engineText.contains("North → south"), "MuPDF reads it as typed")
    }

    private mutating func finish() {
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
