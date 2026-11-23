import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for roadmap 4.23, Edit by Asking (`--edit`, after `MeaningTest`; `--only-ask-edit` runs it
/// alone), on three pages made here, against a stand-in model on loopback that answers with tool calls. Off: asking opens
/// the assistant's settings and sends nothing. On: the send window shows the request with the tools and no document text;
/// the steps proposed are listed ticked, a call of another tool said and left out; Run rotates, bookmarks, highlights and
/// deletes, each one undo step, a later step's page following the deleted one; Undo takes them all back. A model that
/// can't call tools is said so. Settings and keys stay in memory; only counts and the test's own words are written.
@MainActor
struct AskEditTest {
    private(set) static var isActive = false
    private var lines: [String] = []
    private var failures = 0

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[ask-edit] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func wait(_ seconds: Double = 30, _ done: @MainActor () -> Bool) async -> Bool {
        let end = Date() + seconds
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return done()
    }

    /// Three Letter pages: "Cover", "The deadline is Friday.", "Appendix".
    static func sample() -> [UInt8] {
        let texts = ["Cover page of the quarterly plan", "The deadline is Friday for the quarterly plan.", "Appendix with the tables"]
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"]
        for i in 0..<3 { objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(6 + i) 0 R /Resources << /Font << /F1 9 0 R >> >> >>") }
        for t in texts {
            let c = "BT /F1 14 Tf 72 700 Td (\(t)) Tj ET"
            objects.append("<< /Length \(c.utf8.count) >>\nstream\n\(c)\nendstream")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
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

    /// `s` as a JSON string.
    nonisolated static func quoted(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: s, options: [.fragmentsAllowed])) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// The stand-in: a model named gemma3 can't call tools; any other proposes the steps, and a call of another tool.
    nonisolated static func answer(_ received: AiLoopbackServer.Received) -> AiLoopbackServer.Answer {
        if received.body.contains("\"model\":\"gemma3\"") {
            return .json(400, #"{"error":"registry.ollama.ai/library/gemma3 does not support tools"}"#)
        }
        let calls = [
            ("rotate_pages", #"{"pages":"2","degrees":90}"#),
            ("add_bookmark", #"{"title":"Appendix","page":3}"#),
            ("highlight_text", #"{"text":"deadline"}"#),
            ("delete_pages", #"{"pages":"1"}"#),
            ("erase_disk", "{}"),
        ].enumerated().map { i, c in
            "{\"id\":\"c\(i)\",\"type\":\"function\",\"function\":{\"name\":\"\(c.0)\",\"arguments\":\(quoted(c.1))}}"
        }
        return .json(200, "{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[\(calls.joined(separator: ","))]}}]}")
    }

    mutating func run() async {
        Self.isActive = true
        defer { Self.isActive = false }
        lines.append("== Edit by Asking (roadmap 4.23) on pages made here, a stand-in model with tools on loopback")
        AppSettings.aiKeys = AiMemoryKeyStore()
        AppSettings.ai = AiSettings()
        defer { AppSettings.ai = AiSettings() }
        guard let server = AiLoopbackServer(answer: Self.answer) else {
            check(false, "the stand-in model starts")
            return finish()
        }
        defer { server.stop() }
        guard let document = NewDocuments.open(Self.sample(), name: "Edit by Asking test"),
              let c = document.windowControllers.first as? DocumentWindowController else {
            check(false, "the sample pages open")
            return finish()
        }
        defer { document.close() }
        for _ in 0..<250 where c.pages.pageRects.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        let request = "Turn page 2 the right way, bookmark page 3 as Appendix, highlight every deadline and delete page 1"

        // Off: asking opens the assistant's settings, and nothing is sent.
        c.ai.job = Task { @MainActor in await c.askEdit(request) }
        let setup = await wait(10) { AiSettingsSheet.current != nil }
        check(setup, "Edit by Asking with the assistant off opens its settings")
        AiSettingsSheet.current?.cancelClicked()
        await c.ai.job?.value
        check(server.received.isEmpty, "Cancel: nothing sent (\(server.received.count) requests)")

        var settings = AiSettings()
        settings.enabled = true
        settings.preset = "Custom"
        settings.customUrl = "http://127.0.0.1:\(server.port)/v1"
        settings.model = "qwen3"
        AppSettings.ai = settings
        c.ai.job = Task { @MainActor in await c.askEdit(request) }
        let asked = await wait(30) { AiConfirmSheet.current != nil }
        let sheet = AiConfirmSheet.current
        check(asked && server.received.isEmpty && sheet?.window?.title == loc("Send your request to the AI assistant?"),
              "the send window shows before anything is sent")
        let preview = sheet?.fullPreviewText ?? ""
        check(preview.contains("delete page 1") && preview.contains("── tools ──") && preview.contains("rotate_pages") && !preview.contains("Appendix with the tables")
                && preview.contains("The document has 3 pages"),
              "it shows the request, the page count and the tools, and no text of the document")
        sheet?.sendClicked()
        let steps = await wait(30) { AskEditStepsSheet.current != nil }
        let body = server.received.first?.body ?? ""
        check(server.received.count == 1 && body.contains("\"tools\":[") && body.contains("\"stream\":false") && !body.contains("Appendix with"),
              "one request: the model, the messages and the tools, not streamed")
        let stepsSheet = AskEditStepsSheet.current
        check(steps && stepsSheet?.boxes.count == 4 && stepsSheet?.boxes.allSatisfy { $0.state == .on } == true,
              "the four steps that check out are listed, each ticked: \(stepsSheet?.boxes.map(\.title).joined(separator: " | ") ?? "")")
        check(c.ai.lastAskEdit.contains("erase_disk"), "the call of another tool is said and left out")
        stepsSheet?.runClicked()
        await c.ai.job?.value
        let rects = c.pages.pageRects
        check(c.engine.pageCount == 2, "Run: page 1 deleted (\(c.engine.pageCount) pages)")
        check(rects.count == 2 && rects[0].width > rects[0].height, "the turned page, now page 1, lies on its side")
        let marks = (try? Annotations.read(c.pdf.session?.data ?? [], c.pdf.session?.password)) ?? []
        check(marks.contains { $0.pageIndex == 0 }, "every \"deadline\" highlighted on the page that moved up (\(marks.count) comments)")
        let bookmarks = c.readBookmarks()
        let leadsThere = bookmarks.contains { $0.title == "Appendix" && $0.pageIndex == 1 }
        let shown: [String] = bookmarks.map { b in b.title + "→" + String(b.pageIndex + 1) }
        check(leadsThere, "the bookmark leads to the Appendix page, after the deletion: \(shown)")
        check(c.ai.lastAskEdit.contains("ran 4 of 4"), "4 of 4 steps ran: \(c.ai.lastAskEdit.suffix(60))")
        for _ in 0..<4 { c.pdf.undo() }
        check(c.engine.pageCount == 3 && ((try? Annotations.read(c.pdf.session?.data ?? [], nil)) ?? []).isEmpty && c.readBookmarks().isEmpty,
              "four Undos take every step back")

        // A model that can't call tools: said in words.
        settings.model = "gemma3"
        AppSettings.ai = settings
        c.ai.job = Task { @MainActor in await c.askEdit("go to page 2") }
        _ = await wait(30) { AiConfirmSheet.current != nil }
        AiConfirmSheet.current?.sendClicked()
        await c.ai.job?.value
        check(c.ai.lastAskEdit.hasPrefix("failed: gemma3") && c.ai.lastAskEdit.contains("qwen3"), "a model that can't call tools is said so: \(c.ai.lastAskEdit.prefix(80))")
        finish()
    }

    private func finish() {
        var out = lines
        out.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(out.joined(separator: "\n"))
    }
}
