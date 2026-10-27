import AppKit
import PdfCore

/// The app's self-test, for checking a build over SSH where nobody sees the screen:
///   open -a "Inkvolt PDF" a.pdf b.pdf --args --self-test /tmp/report.txt [--quit] [--password pw]
/// For each document opened it runs the reader's paths in the real app (geometry; every page drawn at three zooms; text,
/// find, selection and copy; links and outline; the view drawn and sharpened at several zooms; a password-protected
/// copy; damaged copies) and appends pass/fail lines to the report. Only counts, sizes and timings are written, never a
/// document's text. A file that can't be opened is reported as such. With `--quit` the app quits once every document
/// is done.
@MainActor
enum Report {
    private(set) static var path: String?
    private(set) static var password: String?
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
        write("# Inkvolt PDF self-test, \(Date())")
        // Nothing opened at all, or a document that never finishes: say so rather than hang.
        DispatchQueue.main.asyncAfter(deadline: .now() + 600) {
            MainActor.assumeIsolated {
                if finished < started || started == 0 { write("TIMEOUT: \(finished) of \(started) documents finished") }
                if quit { NSApp.terminate(nil) }
            }
        }
    }

    static func documentOpened(_ controller: DocumentWindowController, name: String) {
        guard isRunning else { return }
        started += 1
        Task { @MainActor in
            var test = SelfTest(controller: controller, name: name)
            await test.run()
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
            MainActor.assumeIsolated { if finished == started { NSApp.terminate(nil) } }
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
