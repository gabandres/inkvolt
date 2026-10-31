import AppKit
import PdfCore

/// The app's self-test, for checking a build over SSH where nobody sees the screen:
///   open -a "Inkvolt PDF" a.pdf b.pdf --args --self-test /tmp/report.txt [--quit] [--password pw]
/// For each document opened it runs the reader's paths in the real app (geometry; every page drawn at three zooms; text,
/// find, selection and copy; links and outline; the view drawn and sharpened at several zooms; a password-protected
/// copy; damaged copies) and appends pass/fail lines to the report. Only counts, sizes and timings are written, never a
/// document's text. A file that can't be opened is reported as such. With `--quit` the app quits once every document
/// is done.
///
/// Editing (`--edit`): after the reader's checks, `PdfATest` and `AccessibleTest` on the synthetic text document (`--only-pdfa` and
/// `--only-accessible` run them alone), then each document goes through `EditTest` (every comment tool through the
/// page view's own mouse and key handling, the inspector, the comments list, undo and redo, Save As and Save into a
/// temporary folder, never over the file opened, the "changed on disk" bar, Revert, recovery copies), then `FeatureTest`
/// (forms, Fill & Sign, Edit Text & Images, Recognize Text, export, each with its file read back), then `PagesTest` (links,
/// selection across pages, organize pages, bookmarks, passwords, printing to PDF files, the close question), then
/// `RedactTest` (redaction marked and applied, the redaction check and its fix, What's in This PDF, Sanitize Document; `--only-redaction`
/// runs it alone), and on the synthetic text document `PrepareFormTest` (`--only-prepare-form` runs it alone), `MeasureTest` (`--only-measure` runs it alone), `SignTest` and
/// `CompareTest`; with
/// `--quit`, `AppTest` drives the app's own windows (start page, Settings, command palette, What's New, About, Scan,
/// Combine, new PDFs, opening from another app) on copies of the synthetic documents, then every document is closed
/// through AppKit's close-all with unsaved changes. `--synthetic` opens
/// two PDFs made here (two pages of text and a scan; a form, which gets only `FeatureTest`); `--snapshots <dir>` writes
/// PNGs of the window there (for the synthetic documents only: never a real file's pages). `--recovery-root <dir>` keeps
/// recovery copies away from the user's;
/// `--crash-after-recovery` kills the app once a copy is written, and `--restore-recovery` restores what it left without
/// asking. Put the flags without a value last: AppKit reads "-name value" pairs from the arguments, and a path left
/// unpaired is opened as a document.
@MainActor
enum Report {
    private(set) static var path: String?
    private(set) static var password: String?
    private(set) static var edits = false
    /// `--only-redaction`: with `--edit`, only `RedactTest` (quicker runs while working on redaction).
    private(set) static var onlyRedaction = false
    /// `--only-measure`: with `--edit`, only `MeasureTest` (quicker runs while working on Measure).
    private(set) static var onlyMeasure = false
    /// `--only-prepare-form`: with `--edit`, only `PrepareFormTest` (quicker runs while working on Prepare Form).
    private(set) static var onlyPrepareForm = false
    /// `--only-pdfa`: with `--edit`, only `PdfATest` (quicker runs while working on Save as PDF/A).
    private(set) static var onlyPdfA = false
    /// `--only-accessible`: with `--edit`, only `AccessibleTest` (quicker runs while working on Make Accessible).
    private(set) static var onlyAccessible = false
    private(set) static var snapshots: String?
    private(set) static var recoveryRoot: String?
    private(set) static var restoresRecovery = false
    private(set) static var crashAfterRecovery = false
    private(set) static var syntheticPath: String?
    private(set) static var syntheticFormPath: String?
    static let recoveryInterval = 0.5
    private static var quit = false
    private static var started = 0
    private static var finished = 0

    static var isRunning: Bool { path != nil }

    static func startIfAsked() {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        guard let p = value("--self-test") else { return }
        path = p
        password = value("--password")
        quit = args.contains("--quit")
        edits = args.contains("--edit")
        onlyRedaction = args.contains("--only-redaction")
        onlyMeasure = args.contains("--only-measure")
        onlyPrepareForm = args.contains("--only-prepare-form")
        onlyPdfA = args.contains("--only-pdfa")
        onlyAccessible = args.contains("--only-accessible")
        snapshots = value("--snapshots")
        recoveryRoot = value("--recovery-root")
        restoresRecovery = args.contains("--restore-recovery")
        crashAfterRecovery = args.contains("--crash-after-recovery")
        write("# Inkvolt PDF self-test, \(Date())")
        // Settings go to a suite of the self-test's own, never the user's.
        AppSettings.clearTestSuite(AppTest.settingsSuite)
        AppSettings.defaults = UserDefaults(suiteName: AppTest.settingsSuite) ?? .standard
        if let snapshots { try? FileManager.default.createDirectory(atPath: snapshots, withIntermediateDirectories: true) }
        if args.contains("--synthetic") {
            let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-selftest-\(UUID().uuidString.prefix(8))")
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let file = (folder as NSString).appendingPathComponent("Synthetic.pdf")
            FileManager.default.createFile(atPath: file, contents: Data(SyntheticPdf.make()))
            syntheticPath = file
            let formFile = (folder as NSString).appendingPathComponent("Synthetic Form.pdf")
            FileManager.default.createFile(atPath: formFile, contents: Data(SyntheticPdf.form()))
            syntheticFormPath = formFile
            NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: file), display: true) { _, _, _ in }
            NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: formFile), display: true) { _, _, _ in }
        }
        // Nothing opened at all, or a document that never finishes: say so rather than hang.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1200) {
            MainActor.assumeIsolated {
                if finished < started || started == 0 { write("TIMEOUT: \(finished) of \(started) documents finished") }
                if quit { quitNow() }
            }
        }
    }

    static func documentOpened(_ controller: DocumentWindowController, name: String) {
        guard isRunning, !AppTest.isActive, !CompareTest.isActive else { return } // the app and compare tests' own documents get only their checks
        started += 1
        Task { @MainActor in
            var test = SelfTest(controller: controller, name: name)
            await test.run()
            if restoresRecovery && controller.pdf.session?.isDirty == true {
                var check = EditTest(controller: controller, name: name)
                await check.checkRecovered()
            } else if edits && onlyPrepareForm {
                if controller.pdf.fileURL?.path != syntheticFormPath {
                    var form = PrepareFormTest(controller: controller, name: name)
                    await form.run()
                }
            } else if edits && onlyAccessible {
                if controller.pdf.fileURL?.path != syntheticFormPath {
                    var accessible = AccessibleTest(controller: controller, name: name)
                    await accessible.run()
                }
            } else if edits && onlyPdfA {
                if controller.pdf.fileURL?.path != syntheticFormPath {
                    var pdfa = PdfATest(controller: controller, name: name)
                    await pdfa.run()
                }
            } else if edits && onlyMeasure {
                if controller.pdf.fileURL?.path != syntheticFormPath {
                    var measure = MeasureTest(controller: controller, name: name)
                    await measure.run()
                }
            } else if edits && onlyRedaction {
                var redact = RedactTest(controller: controller, name: name, openedFrom: controller.pdf.fileURL?.path)
                await redact.run()
            } else if edits {
                let openedFrom = controller.pdf.fileURL?.path
                if openedFrom != nil && openedFrom == syntheticPath {
                    // First, while the document is as made: the edits after it add a Fill & Sign check mark, whose
                    // ZapfDingbats a PDF/A copy refuses (as on Windows).
                    var pdfa = PdfATest(controller: controller, name: name)
                    await pdfa.run()
                    var accessible = AccessibleTest(controller: controller, name: name)
                    await accessible.run()
                }
                if openedFrom != syntheticFormPath {
                    var edit = EditTest(controller: controller, name: name)
                    await edit.run()
                }
                var features = FeatureTest(controller: controller, name: name, openedFrom: openedFrom)
                await features.run()
                if openedFrom != syntheticFormPath {
                    var pagesTest = PagesTest(controller: controller, name: name, openedFrom: openedFrom)
                    await pagesTest.run()
                }
                var redact = RedactTest(controller: controller, name: name, openedFrom: openedFrom)
                await redact.run()
                if openedFrom != nil && openedFrom == syntheticPath {
                    var form = PrepareFormTest(controller: controller, name: name)
                    await form.run()
                    // Before signing: a signed document declines the scale's page edits.
                    var measure = MeasureTest(controller: controller, name: name)
                    await measure.run()
                    var sign = SignTest(controller: controller, name: name)
                    await sign.run()
                    var compare = CompareTest()
                    await compare.run()
                }
            }
            done()
        }
    }

    static func failed(_ name: String, _ error: Error) {
        guard isRunning else { return }
        started += 1
        write("== \(name)\nOPEN FAILED (shown as an error, app still running): \(type(of: error))\nRESULT: OPEN-ERROR")
        done()
    }

    private static func done() {
        finished += 1
        guard quit else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated {
                guard finished == started, !closing else { return }
                closing = true
                Task { @MainActor in
                    if edits && !restoresRecovery && !onlyRedaction && !onlyMeasure && !onlyPrepareForm && !onlyPdfA && !onlyAccessible {
                        var app = AppTest()
                        await app.run()
                        await closeAllTest()
                    }
                    quitNow()
                }
            }
        }
    }

    private static var closing = false

    /// Quitting with several documents changed: AppKit's close-all asks each one (here answered from the test): one
    /// answering Cancel stops it and stays open; then Don't Save for all closes every one.
    private static func closeAllTest() async {
        let docs = NSDocumentController.shared.documents.compactMap { $0 as? PdfDocument }
        guard docs.count >= 2 else { return }
        var lines = ["== closing \(docs.count) documents with unsaved changes"]
        for d in docs {
            if let c = d.windowControllers.first as? DocumentWindowController, !d.isDocumentEdited {
                await c.editor.addNote(page: 0, at: PointD(16, 48), text: "Unsaved at quit", color: nil)
            }
            d.testCloseAnswer = .dontSave
        }
        let edited = docs.filter(\.isDocumentEdited).count
        let keeper = docs[docs.count - 1]
        keeper.testCloseAnswer = .cancel
        let probe = CloseProbe()
        NSDocumentController.shared.closeAllDocuments(withDelegate: probe,
                                                      didCloseAllSelector: #selector(CloseProbe.documentController(_:didCloseAll:contextInfo:)),
                                                      contextInfo: nil)
        for _ in 0..<200 where probe.closedAll == nil { try? await Task.sleep(for: .milliseconds(50)) }
        let stopped = probe.closedAll == false && NSDocumentController.shared.documents.contains { $0 === keeper } && keeper.isDocumentEdited
        lines.append("\(stopped ? "PASS" : "FAIL") close all: \(edited) of \(docs.count) edited; the one answering Cancel stayed open and edited")
        keeper.testCloseAnswer = .dontSave
        probe.closedAll = nil
        NSDocumentController.shared.closeAllDocuments(withDelegate: probe,
                                                      didCloseAllSelector: #selector(CloseProbe.documentController(_:didCloseAll:contextInfo:)),
                                                      contextInfo: nil)
        for _ in 0..<200 where probe.closedAll == nil { try? await Task.sleep(for: .milliseconds(50)) }
        let all = probe.closedAll == true && NSDocumentController.shared.documents.isEmpty
        let asked = docs.reduce(0) { $0 + $1.closeQuestions }
        lines.append("\(all ? "PASS" : "FAIL") close all again with Don't Save: every document closed (\(asked) questions answered)")
        let passed: Int = (stopped ? 1 : 0) + (all ? 1 : 0)
        lines.append("RESULT: \(passed == 2 ? "PASS" : "FAIL") (\(passed) passed, \(2 - passed) failed)")
        write(lines.joined(separator: "\n"))
    }

    /// Quits without the save questions: the test's edits are let go (their recovery copies with them).
    private static func quitNow() {
        write("QUIT: \(finished) of \(started) documents finished")
        AppSettings.clearTestSuite(AppTest.settingsSuite)
        for document in NSDocumentController.shared.documents { document.close() }
        NSApp.terminate(nil)
    }

    /// A line from the app itself (an error shown, a document recovered).
    static func note(_ text: String) {
        guard isRunning else { return }
        write("NOTE \(text)")
    }

    /// Each check as it happens, beside the report (to find a step that never ends).
    static func progress(_ text: String) {
        guard let path, let data = (text + "\n").data(using: .utf8) else { return }
        let file = path + ".progress"
        if let handle = FileHandle(forWritingAtPath: file) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: file, contents: data)
        }
    }

    static func write(_ text: String) {
        guard let path, let data = (text + "\n").data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}

/// The checks for one open document.
@MainActor
struct SelfTest {
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
        if !ok { failures += 1 }
    }

    mutating func run() async {
        let engine = controller.engine
        let bytes = (controller.document as? PdfDocument)?.fileBytes ?? []
        lines.append("== \(name) (\(bytes.count) bytes)")
        try? await Task.sleep(for: .milliseconds(600)) // the window shown and fitted

        // Geometry.
        let count = engine.pageCount
        let sizesOk = (0..<count).allSatisfy { i in let g = engine.page(i); return g.width > 0 && g.height > 0 && g.width.isFinite && g.height.isFinite }
        let first = count > 0 ? engine.page(0) : PageGeometry(0, 0, 0, 0)
        check(count > 0 && sizesOk, "geometry: \(count) pages, page 1 \(Int(first.width.rounded())) x \(Int(first.height.rounded())) pt")

        // Every page drawn at three zooms, page 1 at 4x and a region (off the main thread, as the view's renders run).
        let render = await Task.detached { () -> (failed: Int, drawn: Int, seconds: Double, inked: Int) in
            let start = Date()
            var failed = 0, drawn = 0, inked = 0
            for scale in [0.5, 1.0, 2.0] {
                for p in 0..<min(count, 300) {
                    do {
                        let img = try engine.render(p, scale: scale)
                        let g = engine.page(p)
                        let okSize = abs(Double(img.width) - g.width * scale) <= 2 && abs(Double(img.height) - g.height * scale) <= 2
                            && img.pixels.count == img.width * img.height * 3
                        if okSize { drawn += 1 } else { failed += 1 }
                        if scale == 1, img.pixels.contains(where: { $0 < 200 }) { inked += 1 }
                    } catch {
                        failed += 1
                    }
                }
            }
            if count > 0 {
                do {
                    _ = try engine.render(0, scale: 4)
                    _ = try engine.render(0, scale: 2, region: RectD(10, 10, first.width / 2, first.height / 3))
                    drawn += 2
                } catch {
                    failed += 1
                }
            }
            return (failed, drawn, Date().timeIntervalSince(start), inked)
        }.value
        check(render.failed == 0, "render: \(render.drawn) page images at 0.5x/1x/2x (+4x, region), \(render.failed) failed, "
              + "\(render.inked) pages with ink, \(String(format: "%.2f", render.seconds)) s")

        // Text.
        var chars = 0, withText = 0, textFailed = 0
        var word: String?
        var selectable: (page: Int, text: PageText)?
        for p in 0..<count {
            guard let t = try? engine.text(p) else {
                textFailed += 1
                continue
            }
            chars += t.length
            if !t.isEmpty {
                withText += 1
                if selectable == nil { selectable = (p, t) }
                if word == nil { word = Self.pickWord(t.text) }
            }
        }
        check(textFailed == 0, "text: \(chars) characters on \(withText) of \(count) pages, \(textFailed) failed")

        // Find, through the window's own find (all pages, off the main thread).
        if let word {
            let direct = (0..<count).reduce(0) { n, p in n + ((try? engine.text(p))?.find(word, matchCase: false, wholeWord: false).count ?? 0) }
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                controller.onFindFinished = { done.resume() }
                controller.find(word)
            }
            controller.onFindFinished = nil
            let hits = controller.found.count
            let shown = controller.pages.currentMatch != nil
            check(hits >= 1 && hits == direct && shown, "find (a \(word.count)-letter word from the text): \(hits) hits, current match shown: \(shown)")
            controller.step(1)
            controller.step(-1)
            controller.find("")
            check(controller.found.isEmpty && controller.pages.matches.isEmpty, "find cleared")
            let none = "zqxjv\(UUID().uuidString.prefix(6))"
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                controller.onFindFinished = { done.resume() }
                controller.find(none)
            }
            controller.onFindFinished = nil
            check(controller.found.isEmpty, "find of a word not there: 0 hits")
            controller.find("")
        } else {
            lines.append("SKIP find: no text to search (an image-only page?)")
        }

        // Selection and copy (onto a private pasteboard, not the user's).
        if let s = selectable {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.bermudezsystems.InkvoltPdf.selftest"))
            let box = s.text.boxAt(0)
            let caret = s.text.hitTest(box.x + box.width / 4, box.centerY)
            let w = s.text.wordAt(caret)
            controller.pages.select(s.page, w)
            let copied = controller.pages.copySelection(to: pasteboard)
            let back = pasteboard.string(forType: .string) ?? ""
            check(copied && !back.isEmpty && back == s.text.string(w.start, w.end), "select a word and copy: \(back.utf16.count) characters")
            controller.go(s.page)
            controller.pages.selectAll(nil)
            let all = controller.pages.selectedText ?? ""
            check(all.utf16.count == s.text.length, "select all on page \(s.page + 1): \(all.utf16.count) characters")
            controller.pages.clearSelection()
            check(!controller.pages.copySelection(to: pasteboard), "nothing selected: nothing copied")
            pasteboard.releaseGlobally()
        } else {
            lines.append("SKIP selection: no text")
        }

        // Links and outline.
        var links = 0, inside = 0, badLinks = 0
        for p in 0..<count {
            for l in (try? engine.links(p)) ?? [] {
                links += 1
                if l.uri == nil {
                    inside += 1
                    if l.pageIndex < 0 || l.pageIndex >= count { badLinks += 1 }
                }
            }
        }
        check(badLinks == 0, "links: \(links) (\(inside) inside the document), \(badLinks) pointing nowhere")
        let outline = controller.sidebar.outlineCount
        let outlinePages = ((try? engine.outline()) ?? []).allSatisfy { $0.pageIndex < count }
        check(outlinePages, "outline: \(outline) entries")

        // The view: zooms, pages coming in sharp, drawing.
        for (label, zoom) in [("fit", -1.0), ("100%", 1.0), ("200%", 2.0), ("400%", 4.0)] where count > 0 {
            if zoom < 0 { controller.fitWidth(nil) } else { controller.setZoom(zoom) }
            controller.go(count - 1)
            controller.go(count > 1 ? count / 2 : 0)
            let page = controller.pages.currentPage
            let sharp = await waitForSharp(page)
            let drawn = draw()
            check(sharp && drawn, "view at \(label): page \(page + 1) drawn sharp (\(String(format: "%.1f", controller.scrollView.magnification))x)")
        }
        // Very high zoom: tiles of the part shown instead of a giant picture of the whole page.
        if count > 0 {
            controller.setZoom(8)
            controller.go(count > 1 ? count / 2 : 0)
            var t = (wanted: 0, drawn: 0)
            for _ in 0..<150 {
                controller.pages.requestVisible()
                t = controller.pages.tilesReady
                if t.wanted == 0 || t.drawn == t.wanted { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let page = controller.pages.currentPage
            let base = controller.pages.renderer.image(page).map { $0.image.width * $0.image.height } ?? 0
            let biggest = controller.pages.renderer.largestTilePixels
            let tiled = controller.pages.tileScale(for: page) != nil
            let limit = Int(PagesView.wholePagePixels * 1.02)
            let side = PageRenderer.tilePixels + 2
            let drawn = draw()
            check((t.wanted > 0 || !tiled) && t.drawn == t.wanted && biggest <= side * side && base <= limit && drawn,
                  "800%: \(t.drawn) of \(t.wanted) tiles drawn for page \(page + 1) (largest \(biggest) px, whole page \(base) px)")
        }
        controller.fitWidth(nil)
        controller.go(0)

        // A password-protected copy (made here, in memory) and damaged copies: errors, never a crash.
        if !engine.isEncrypted && !bytes.isEmpty {
            do {
                let locked = try PdfSecurity.protect(bytes, nil, userPassword: "self-test", ownerPassword: "self-test-owner")
                var asked = false, wrong = false, opened = 0
                do { _ = try PdfEngine.open(locked) } catch let e as PasswordRequired { asked = !e.wrongPassword }
                do { _ = try PdfEngine.open(locked, password: "nope") } catch let e as PasswordRequired { wrong = e.wrongPassword }
                if let e = try? PdfEngine.open(locked, password: "self-test") {
                    opened = e.pageCount
                    _ = try? e.render(0, scale: 0.5)
                    e.close()
                }
                check(asked && wrong && opened == count, "password copy: asks for it, refuses a wrong one, opens \(opened) pages with it")
            } catch is SignaturesWouldBreak {
                check(true, "password copy: refused for a signed file (protecting it would break its signatures)")
            } catch {
                check(false, "password copy: couldn't be made (\(type(of: error)))")
            }
        }
        if bytes.count > 100 {
            var outcomes: [String] = []
            for (label, damaged) in [("truncated to 60%", Array(bytes.prefix(bytes.count * 6 / 10))),
                                     ("first 1 KB", Array(bytes.prefix(1024))),
                                     ("garbage", Array("%PDF-1.7\nnot a pdf at all".utf8))] {
                do {
                    let e = try PdfEngine.open(damaged)
                    var drawnPages = 0
                    for p in 0..<e.pageCount where (try? e.render(p, scale: 0.3)) != nil { drawnPages += 1 }
                    if e.pageCount > 0 { _ = try? e.text(0) }
                    outcomes.append("\(label): repaired, \(drawnPages) of \(e.pageCount) pages drawn")
                    e.close()
                } catch {
                    outcomes.append("\(label): refused (\(type(of: error)))")
                }
            }
            check(true, "damaged copies (no crash): " + outcomes.joined(separator: "; "))
        }

        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }

    /// Waits (up to 10 s) until the page has an image drawn at the scale the view wants.
    private func waitForSharp(_ page: Int) async -> Bool {
        for _ in 0..<100 {
            controller.pages.requestVisible()
            let want = controller.pages.renderScale(for: page)
            if let image = controller.pages.renderer.image(page), abs(image.scale - want) < 0.001 { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Draws what the view shows into a bitmap (as the screen would).
    private func draw() -> Bool {
        let view = controller.pages
        let rect = view.visibleRect
        guard rect.width > 0, rect.height > 0, let rep = view.bitmapImageRepForCachingDisplay(in: rect) else { return false }
        view.cacheDisplay(in: rect, to: rep)
        return rep.pixelsWide > 0
    }

    /// A word of four or more letters from the page's text, to find (kept in memory only).
    static func pickWord(_ text: String) -> String? {
        var word = ""
        for ch in text {
            if ch.isLetter {
                word.append(ch)
            } else {
                if word.count >= 4 { return word }
                word = ""
            }
        }
        return word.count >= 4 ? word : nil
    }
}
