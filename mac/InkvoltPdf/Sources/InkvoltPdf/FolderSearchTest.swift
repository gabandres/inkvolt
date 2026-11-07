import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for roadmap 3.5 (`--edit` on the synthetic text document, after `CompareTest`;
/// `--only-folder-search` runs it alone): a folder of synthetic PDFs made here (in a subfolder too, a damaged one) indexed
/// into an index folder of the test's own, never Application Support's, and never kept in the settings. Edit › Find ›
/// Search Folders… finds a word, a phrase, a word typed without its accents, says no match and a query of punctuation;
/// a result opens its PDF at the hit with the Find bar on; a changed file is found again by FSEvents; Pause and Resume;
/// the damaged file listed as skipped; Remove deletes the index file. Only counts are written.
@MainActor
struct FolderSearchTest {
    /// Running: the documents it opens get no self-test of their own.
    private(set) static var isActive = false
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[folder-search] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func wait(_ seconds: Double = 30, _ done: () -> Bool) async -> Bool {
        let end = Date() + seconds
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        return done()
    }

    /// Searches `query` in the window as typed there, and waits for what it says.
    private func search(_ w: FolderSearchWindowController, _ query: String) async -> Bool {
        var said = false
        w.onSearched = { said = true }
        w.field.stringValue = query
        w.search()
        let ok = await wait { said }
        w.onSearched = nil
        return ok
    }

    mutating func run() async {
        Self.isActive = true
        defer { Self.isActive = false }
        lines.append("== Search Folders (synthetic PDFs, an index of the test's own)")
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-folder-search-\(UUID().uuidString.prefix(8))")
        let folder = (root as NSString).appendingPathComponent("Papers")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (folder as NSString).appendingPathComponent("2026"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: root) }
        func put(_ name: String, _ pages: [[String]]) {
            fm.createFile(atPath: (folder as NSString).appendingPathComponent(name), contents: Data(CompareTest.pdf(pages, box: 300)))
        }
        put("lease.pdf", [["Lease agreement", "The brass lantern stays in the hall."], ["Signatures"]])
        // "Le RESUME du Cafe" with accents, in WinAnsi (\311 is É, \351 is é).
        put("2026/notes.pdf", [["Meeting notes"], ["Le R\\311SUM\\311 du Caf\\351", "a lantern for the porch"]])
        fm.createFile(atPath: (folder as NSString).appendingPathComponent("broken.pdf"), contents: Data("%PDF-1.7\nnot a PDF".utf8))

        let searches = FolderSearches.shared
        let savedDirectory = FolderSearches.indexDirectory
        FolderSearches.indexDirectory = (root as NSString).appendingPathComponent("index")
        searches.persists = false
        defer {
            FolderSearches.indexDirectory = savedDirectory
            searches.persists = true
        }

        FolderSearchWindowController.show()
        guard let w = FolderSearchWindowController.shared else {
            check(false, "Edit › Find › Search Folders… opens its window")
            return finish()
        }
        check(w.window?.isVisible == true && w.window?.title == loc("Search Folders"), "Edit › Find › Search Folders… opens its window")
        w.add(folder)
        guard let f = searches.all.first(where: { $0.path.hasSuffix("/Papers") }) else {
            check(false, "the folder is added")
            return finish()
        }
        let indexed = await wait { f.indexer?.status.phase == .upToDate && f.indexer?.status.searchable == 2 }
        let started = Date()
        check(indexed, "the folder indexed: 2 PDFs searchable, 1 skipped (\(f.indexer?.status.skipped.values.reduce(0, +) ?? -1)), status shown")
        let base = FolderIndex.basePathFor(FolderSearches.indexDirectory, f.path)
        let files = (try? fm.contentsOfDirectory(atPath: FolderSearches.indexDirectory)) ?? []
        check(files.contains { $0.hasSuffix(".idx") } && base.hasPrefix(root), "the index file is in the index folder given, named by a hash (\(files.count) files)")

        // A word, with its context and the hit in bold.
        let found = await search(w, "lantern")
        let rows = w.rows
        check(found && rows.count == 2 && rows[0].hit.relativePath == "2026/notes.pdf" && rows[0].hit.page == 1
                && rows[1].hit.relativePath == "lease.pdf" && rows[1].hit.match.lowercased() == "lantern",
              "a word: 2 pages in 2 files, in path order, with the hit in its excerpt (\(rows.count) rows; \(w.status.stringValue))")
        _ = await search(w, "brass lantern")
        check(w.rows.count == 1 && w.rows[0].hit.relativePath == "lease.pdf", "a phrase: its page only (\(w.rows.count) rows)")
        _ = await search(w, "resume du cafe")
        check(w.rows.count == 1 && w.rows[0].hit.page == 1, "accents ignored: “resume du cafe” finds “RÉSUMÉ du Café” (\(w.rows.count) rows)")
        w.ignoreAccents.state = .off
        _ = await search(w, "resume")
        check(w.rows.isEmpty, "accents not ignored when asked: no match")
        w.ignoreAccents.state = .on
        _ = await search(w, "zeppelin")
        check(w.rows.isEmpty && w.status.stringValue.contains("zeppelin"), "no match is said")
        _ = await search(w, "+ - /")
        check(w.rows.isEmpty && w.status.stringValue == loc("Type a word with letters or digits: the index keeps those. To find punctuation, use Find in an open document."),
              "a query of punctuation says what the index keeps")

        // A result opens at its hit.
        _ = await search(w, "lantern")
        if let first = w.rows.first {
            var opened: DocumentWindowController?
            var came = false
            w.open(first) { c in
                opened = c
                came = true
            }
            _ = await wait { came }
            let shown = await wait(10) { opened?.foundIndex ?? -1 >= 0 }
            check(shown && opened?.foundQuery == "lantern" && opened?.activePages.currentPage == first.hit.page,
                  "a result opens its PDF at the hit, page \(first.hit.page + 1), with the Find bar showing the words")
            (opened?.document as? NSDocument)?.close()
        } else {
            check(false, "a result opens its PDF at the hit")
        }

        // A changed file is found again (FSEvents, then the regular look).
        put("lease.pdf", [["Lease agreement, amended", "The copper kettle stays in the hall."]])
        let changed = Date()
        let again = await wait(60) {
            guard let index = f.indexer?.currentIndex, let run = try? index.search("kettle") else { return false }
            defer { run.close() }
            return (try? run.all().count) == 1
        }
        check(again, String(format: "a changed file found again in %.1f s", Date().timeIntervalSince(changed)))
        _ = await search(w, "brass")
        check(w.rows.isEmpty, "its old words are gone")

        // Pause, Resume, what was skipped.
        searches.setPaused(f, true)
        let paused = await wait { f.indexer?.status.phase == .paused }
        searches.setPaused(f, false)
        let resumed = await wait { f.indexer?.status.phase == .upToDate }
        check(paused && resumed, "Pause and Resume")
        let skipped = f.indexer?.skipped() ?? []
        check(skipped.count == 1 && skipped[0].relativePath == "broken.pdf" && skipped[0].why == .damaged,
              "the damaged file is listed as skipped, with why")
        check(f.indexer?.status.text.contains(FolderIndexer.describe(.damaged)) == true, "the status line says what was skipped")

        // Remove: the index file goes, the PDFs stay.
        searches.remove(f)
        let removed = await wait {
            ((try? fm.contentsOfDirectory(atPath: FolderSearches.indexDirectory)) ?? []).isEmpty
        }
        check(removed && fm.fileExists(atPath: (folder as NSString).appendingPathComponent("lease.pdf")) && !searches.all.contains { $0 === f },
              "Remove deletes the index file and leaves the PDFs")
        lines.append(String(format: "TIME indexed then checked in %.1f s", Date().timeIntervalSince(started)))
        w.close()
        finish()
    }

    private func finish() {
        var out = lines
        out.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(out.joined(separator: "\n"))
    }
}
