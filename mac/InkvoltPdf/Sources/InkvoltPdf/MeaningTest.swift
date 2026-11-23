import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for roadmap 4.21, search by meaning (`--edit`, after `FolderAskTest`; `--only-meaning` runs it
/// alone): a folder of synthetic PDFs indexed into an index folder of the test's own, and a stand-in model on loopback
/// that makes embeddings (each word adds to one of 16 numbers; "income" and "earnings" mean "revenue") and answers
/// questions. Search Folders' By meaning asks for its settings first; the send window lists every page before a folder is
/// embedded and nothing goes before Send; the requests carry the model and the texts only; the closest page comes first
/// and opens at its page; a second search sends only its words; Ask Across Folders' Also find pages by meaning brings in
/// a page sharing no word; Remove deletes the meaning index. Settings and keys stay in memory; only counts are written.
@MainActor
struct MeaningTest {
    private(set) static var isActive = false
    private var lines: [String] = []
    private var failures = 0

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[meaning] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func wait(_ seconds: Double = 30, _ done: @MainActor () -> Bool) async -> Bool {
        let end = Date() + seconds
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
        return done()
    }

    /// The stand-in embedding: each word adds to one of 16 numbers; "income" and "earnings" mean "revenue".
    nonisolated static func embed(_ text: String) -> [Float] {
        var v = [Float](repeating: 0, count: 16)
        for raw in text.lowercased().split(whereSeparator: { " .,:?\n".contains($0) }) {
            let word = raw == "income" || raw == "earnings" ? "revenue" : String(raw)
            var h: Int32 = 17
            for c in word.utf16 { h = h &* 31 &+ Int32(c) }
            v[Int(UInt32(bitPattern: h) % 16)] += 1
        }
        return v
    }

    /// The server's answer: embeddings for /embeddings, a short streamed answer for a question.
    nonisolated static func answer(_ received: AiLoopbackServer.Received) -> AiLoopbackServer.Answer {
        guard received.head.contains("/embeddings") else { return .sse(["Earnings grew in the north [1, p. 1]."]) }
        guard let root = try? JSONSerialization.jsonObject(with: Data(received.body.utf8)) as? [String: Any],
              let input = root["input"] as? [String] else { return .json(400, #"{"error":"bad request"}"#) }
        let data = input.enumerated().map { i, text in
            "{\"index\":\(i),\"embedding\":[\(embed(text).map { String(Int($0)) }.joined(separator: ","))]}"
        }
        return .json(200, "{\"data\":[\(data.joined(separator: ","))]}")
    }

    mutating func run() async {
        Self.isActive = true
        defer { Self.isActive = false }
        lines.append("== Search by meaning (roadmap 4.21) on synthetic PDFs, an index of the test's own, a stand-in model on loopback")
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-meaning-\(UUID().uuidString.prefix(8))")
        let folder = (root as NSString).appendingPathComponent("Ledgers")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        func put(_ name: String, _ pages: [[String]]) {
            fm.createFile(atPath: (folder as NSString).appendingPathComponent(name), contents: Data(CompareTest.pdf(pages, box: 300)))
        }
        put("q3.pdf", [["Quarterly revenue grew in the north."], ["Staff party photos and cake."]])
        put("minutes.pdf", [["The board met and talked about hiring."]])

        AppSettings.aiKeys = AiMemoryKeyStore()
        guard let server = AiLoopbackServer(answer: Self.answer) else {
            check(false, "the stand-in model starts")
            return finish()
        }
        defer { server.stop() }
        var settings = AiSettings()
        settings.enabled = true
        settings.preset = "Custom"
        settings.customUrl = "http://127.0.0.1:\(server.port)/v1"
        settings.model = "test-model"
        AppSettings.ai = settings
        AppSettings.meaningEnabled = false
        AppSettings.meaningModel = ""
        defer {
            AppSettings.ai = AiSettings()
            AppSettings.meaningEnabled = false
            AppSettings.meaningModel = ""
        }

        let searches = FolderSearches.shared
        let savedDirectory = FolderSearches.indexDirectory
        FolderSearches.indexDirectory = (root as NSString).appendingPathComponent("index")
        searches.persists = false
        defer {
            FolderSearches.indexDirectory = savedDirectory
            searches.persists = true
        }
        searches.add(folder)
        guard let f = searches.all.first(where: { $0.path.hasSuffix("/Ledgers") }) else {
            check(false, "the folder is added")
            return finish()
        }
        var removed = false
        defer { if !removed { searches.remove(f) } }
        let indexed = await wait(60) { f.indexer?.status.phase == .upToDate && f.indexer?.status.searchable == 2 }
        check(indexed, "the folder indexed: 2 PDFs searchable")

        FolderSearchWindowController.show()
        guard let w = FolderSearchWindowController.shared else {
            check(false, "Search Folders opens")
            return finish()
        }
        defer { w.close() }

        // By meaning asks for its settings first; nothing is sent.
        w.byMeaning.state = .on
        w.byMeaningClicked()
        let asked = await wait(10) { MeaningSettingsSheet.current != nil }
        check(asked && server.received.isEmpty, "By meaning, while off, asks for its settings first; nothing sent")
        MeaningSettingsSheet.current?.turnOn.state = .on
        MeaningSettingsSheet.current?.model.stringValue = "embed-model"
        MeaningSettingsSheet.current?.saveClicked()
        let saved = await wait(5) { MeaningSettingsSheet.current == nil }
        check(saved && AppSettings.meaningEnabled && FolderMeaning.model == "embed-model" && w.byMeaning.state == .on && !w.matchCase.isEnabled,
              "saved: on, with its model; Match case and the like don't apply")

        // The first search: every page listed before it goes.
        w.field.stringValue = "income north"
        w.search()
        let shown = await wait(30) { AiConfirmSheet.current != nil }
        let sheet = AiConfirmSheet.current
        let listing = sheet?.listing.string ?? ""
        check(shown && server.received.isEmpty && sheet?.window?.title == loc("Send for search by meaning?"),
              "the send window shows before anything is sent, titled for search by meaning")
        check(listing.contains("minutes.pdf: \(loc("page {0}", CoreLanguage.number(1)))") && listing.contains("q3.pdf: \(loc("pages {0}", "1–2"))"),
              "it lists every page that goes: \(listing.replacingOccurrences(of: "\n", with: " | "))")
        sheet?.sendClicked()
        await w.meaningJob?.value
        let embeds = server.received.filter { $0.head.contains("/v1/embeddings") }
        let bodies = embeds.map(\.body).joined()
        check(embeds.count == 2 && embeds.count == server.received.count, "one batch of pieces and the query: \(embeds.count) requests to /v1/embeddings")
        check(bodies.contains("\"model\":\"embed-model\"") && bodies.contains("Quarterly revenue grew") && !bodies.contains("q3.pdf") && !bodies.contains(root),
              "the requests carry the model and the texts only: no file name or folder")
        let first = w.rows.first
        check(first?.hit.relativePath == "q3.pdf" && first?.hit.page == 0 && (first?.meaning ?? 0) > 0,
              "the closest page comes first: \(first?.hit.relativePath ?? "none") page \((first?.hit.page ?? -1) + 1) (\(w.rows.count) rows; \(w.status.stringValue))")
        check(fm.fileExists(atPath: f.meaningPath), "the embeddings are kept beside the folder's index")

        // A second search: only its words go.
        w.field.stringValue = "The board met and talked about hiring" // its own words: as close as a page gets
        w.search()
        let again = await wait(30) { AiConfirmSheet.current != nil }
        check(again && AiConfirmSheet.current?.listing.string.isEmpty != false
                && AiConfirmSheet.current?.whatLabel.stringValue.contains("embed-model") == true,
              "a second search: the send window shows the search words only: \(AiConfirmSheet.current?.whatLabel.stringValue.prefix(70) ?? "")")
        AiConfirmSheet.current?.sendClicked()
        await w.meaningJob?.value
        check(server.received.count == 3 && w.rows.first?.hit.relativePath == "minutes.pdf", "one more request; the closest page is minutes.pdf (\(server.received.count) requests)")

        // A result opens at its page.
        if let row = w.rows.first {
            var opened: DocumentWindowController?
            var came = false
            w.open(row) { c in
                opened = c
                came = true
            }
            let ok = await wait(15) { came && opened?.pages.pageRects.isEmpty == false }
            check(ok && opened?.findBar.isHidden != false, "a page found by meaning opens at its page, without the Find bar")
            (opened?.document as? NSDocument)?.close()
        }

        // Ask Across Folders: a page sharing no word with the question comes by meaning.
        FolderAskWindowController.show()
        if let ask = FolderAskWindowController.shared {
            check(ask.alsoMeaning.state == .on, "Ask Across Folders offers Also find pages by meaning, on while it is set up")
            ask.question.stringValue = "How did income change?"
            ask.askClicked()
            let meaningSheet = await wait(30) { AiConfirmSheet.current != nil }
            check(meaningSheet && AiConfirmSheet.current?.window?.title == loc("Send for search by meaning?"), "the question's words are shown before they go for meaning")
            AiConfirmSheet.current?.sendClicked()
            let askSheet = await wait(30) { AiConfirmSheet.current != nil && AiConfirmSheet.current?.window?.title != loc("Send for search by meaning?") }
            let asking = AiConfirmSheet.current?.listing.string ?? ""
            check(askSheet && asking.contains("q3.pdf"), "the page close in meaning is sent: \(asking.replacingOccurrences(of: "\n", with: " | "))")
            AiConfirmSheet.current?.sendClicked()
            await ask.job?.value
            check(ask.lastCard?.links.count == 1, "the answer links to it (\(ask.lastCard?.links.count ?? -1) links)")
            ask.close()
        } else {
            check(false, "Ask Across Folders opens")
        }

        // Remove deletes the meaning index too.
        let path = f.meaningPath
        searches.remove(f)
        removed = true
        check(!fm.fileExists(atPath: path), "Remove deletes the folder's meaning index")
        finish()
    }

    private func finish() {
        var out = lines
        out.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(out.joined(separator: "\n"))
    }
}
