import AppKit
import PdfCore

/// The self-test's scenario for D7 part e (`--edit` with `--quit`, once every document is done): the app's own windows
/// driven through their controls, on copies of the synthetic documents in a temporary folder (never a real file): the
/// start page (its cards, each tool card opening a copy straight in its tool, the recent list, Combine and Create a PDF);
/// Settings (saved into the self-test's own defaults suite, applied to a document opening, Reset to Defaults); the command
/// palette (searched, a command run); What's New (the bundled notes, shown once after an update); About (version, AGPL,
/// notices); Scan (Inkvolt Print's demo scanners: glass and feeder, a page removed, the PDF made, made searchable); and a
/// copy opened by another app the way Inkvolt Print's "Open in Inkvolt PDF" does. Only counts are written.
@MainActor
struct AppTest {
    static let settingsSuite = "com.bermudezsystems.InkvoltPdf.selftest"
    /// True while the scenario runs (its documents don't start the per-document checks).
    private(set) static var isActive = false

    private var lines: [String] = ["== the app's windows (start page, Settings, command palette, What's New, About, Scan, new PDFs)"]
    private var failures = 0
    private let folder: String

    init() {
        folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-app-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[app] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func url(_ name: String) -> URL { URL(fileURLWithPath: (folder as NSString).appendingPathComponent(name)) }

    /// A copy of the synthetic text document (two pages of text and a scan) under `name`.
    private func copy(_ name: String) -> URL? {
        guard let source = Report.syntheticPath else { return nil }
        let target = url(name)
        try? FileManager.default.removeItem(at: target)
        return (try? FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: target)) == nil ? nil : target
    }

    private func wait(_ seconds: Double = 10, _ done: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 20) {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    private func document(at url: URL) -> PdfDocument? {
        NSDocumentController.shared.documents.first { $0.fileURL?.standardizedFileURL == url.standardizedFileURL } as? PdfDocument
    }

    private func controller(_ document: PdfDocument?) -> DocumentWindowController? { document?.windowControllers.first as? DocumentWindowController }

    private mutating func snapshot(_ window: NSWindow?, _ file: String) {
        guard let dir = Report.snapshots, let view = window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return check(false, "snapshot \(file): no bitmap") }
        view.cacheDisplay(in: view.bounds, to: rep)
        let png = rep.representation(using: .png, properties: [:])
        let ok = (try? png?.write(to: URL(fileURLWithPath: (dir as NSString).appendingPathComponent(file)))) != nil
        check(ok, "snapshot \(file): \(rep.pixelsWide) x \(rep.pixelsHigh) px")
    }

    // MARK: The scenario

    mutating func run() async {
        guard Report.syntheticPath != nil else {
            Report.write("== the app's windows\nSKIP: needs --synthetic (its checks use copies of the synthetic documents only)")
            return
        }
        Self.isActive = true
        defer { Self.isActive = false }
        NSApp.activate()
        await startPage()
        await settings()
        await palette()
        whatsNew()
        about()
        await scan()
        await openFromAnotherApp()
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
        StartWindowController.testRecent = nil
        try? FileManager.default.removeItem(atPath: folder)
    }

    // MARK: Start page

    private mutating func startPage() async {
        guard let a = copy("Start A.pdf"), let b = copy("Start B.pdf") else { return check(false, "start page: the copies couldn't be made") }
        StartWindowController.testRecent = [a, b]
        StartWindowController.show()
        guard let start = StartWindowController.shared else { return check(false, "start page: not shown") }
        _ = await wait(3) { start.recentCount == 2 }
        check(start.isShown && start.cards.count == StartWindowController.ToolCard.allCases.count && start.recentCount == 2,
              "start page: shown with \(start.cards.count) tool cards and \(start.recentCount) recent files")
        try? await Task.sleep(for: .milliseconds(500)) // page 1 of each drawn
        snapshot(start.window, "start-page.png")

        // Open a file (the card), then the start page steps aside.
        StartWindowController.testPicks = [[a]]
        start.openClicked()
        let opened = await wait { self.controller(self.document(at: a))?.window?.isVisible == true }
        check(opened && !start.isShown, "start page › Open a file: the PDF opened and the start page stepped aside")
        document(at: a)?.close()

        // Each card that works on a PDF: pick one, it opens straight in that tool.
        for card in StartWindowController.ToolCard.allCases where card != .combine && card != .create && card != .batch {
            guard let file = copy("Tool \(card.rawValue).pdf") else { continue }
            StartWindowController.show()
            StartWindowController.testPicks = [[file]]
            start.cards[card.rawValue].performClick(nil)
            let ready = await wait { start.lastToolWindow?.pdf.fileURL?.standardizedFileURL == file.standardizedFileURL }
            let c = start.lastToolWindow
            try? await Task.sleep(for: .milliseconds(200))
            let window = c?.window
            var started = false
            switch card {
            case .fillSign: started = c?.pages.tool == .fillText
            case .editContent: started = c?.pages.tool == .editContent
            case .exportWord, .ocr: started = window?.attachedSheet != nil
            case .protect: started = c?.protectSheet != nil
            case .organize: started = c?.organizerShown == true
            case .combine, .create, .batch: break
            }
            check(ready && started, "start page › \(card.title): a PDF picked, opened straight in the tool")
            if let sheet = window?.attachedSheet { window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            c?.protectSheet?.done?(nil)
            try? await Task.sleep(for: .milliseconds(200))
            document(at: file)?.close()
        }

        // Combine: two files, the second moved first, one PDF with a bookmark each.
        StartWindowController.show()
        start.cards[StartWindowController.ToolCard.combine.rawValue].performClick(nil)
        if let combine = CombineWindowController.shared, let pages = PdfEngineCount.of(a) {
            combine.add([a, b])
            combine.move(IndexSet(integer: 1), to: 0)
            let order = combine.files.map(\.lastPathComponent) == ["Start B.pdf", "Start A.pdf"]
            snapshot(combine.window, "combine.png")
            combine.combineButton.performClick(nil)
            let made = combine.lastCombined
            let count = made?.engine?.pageCount ?? 0
            let marks = made?.session.flatMap { try? Bookmarks.read($0.data, nil) }?.count ?? 0
            check(order && count == 2 * pages && marks == 2 && made?.isDocumentEdited == true,
                  "Combine Files: 2 files reordered by Move, \(count) pages, \(marks) bookmarks, a new unsaved document")
            made?.close()
        } else {
            check(false, "Combine Files: the window didn't open")
        }

        // Create a PDF: from pictures (the card's menu item), from the clipboard.
        let p1 = url("Picture 1.png"), p2 = url("Picture 2.png")
        if PagesTest.writePicture(p1) && PagesTest.writePicture(p2) {
            StartWindowController.testPicks = [[p2, p1]]
            var fromImages: PdfDocument?
            NSApp.sendAction(#selector(AppDelegate.newFromImages(_:)), to: nil, from: nil)
            _ = await wait(5) {
                fromImages = NSDocumentController.shared.documents.compactMap { $0 as? PdfDocument }.first { $0.fileURL == nil && $0.name.hasPrefix("Pictures") }
                return fromImages != nil
            }
            check(fromImages?.engine?.pageCount == 2, "New PDF from Images: 2 pictures, \(fromImages?.engine?.pageCount ?? 0) pages")
            fromImages?.close()
            let board = NSPasteboard(name: NSPasteboard.Name("com.bermudezsystems.InkvoltPdf.selftest.clip"))
            board.clearContents()
            if let data = try? Data(contentsOf: p1) { board.setData(data, forType: .png) }
            let clip = NewDocuments.fromClipboard(board)
            let g = clip?.engine.map { $0.page(0) }
            check(clip?.engine?.pageCount == 1 && (g?.width ?? 0) > 0, "New PDF from Clipboard: 1 page, \(Int(g?.width ?? 0)) x \(Int(g?.height ?? 0)) pt")
            clip?.close()
            board.releaseGlobally()
        } else {
            check(false, "New PDF from Images: the pictures couldn't be written")
        }
        start.window?.orderOut(nil)
    }

    // MARK: Settings

    private mutating func settings() async {
        SettingsWindowController.show(updates: nil)
        guard let s = SettingsWindowController.shared else { return check(false, "Settings: not shown") }
        check(s.window?.isVisible == true && s.theme.indexOfSelectedItem == 0 && s.restore.state == .on && s.recovery.state == .on
              && s.author.stringValue == AppSettings.userName, "Settings: shown with the defaults (author: the Mac user's name)")
        snapshot(s.window, "settings.png")
        s.theme.selectItem(at: 2)
        s.zoom.selectItem(at: 1)
        s.restore.state = .on
        s.recovery.state = .off
        s.author.stringValue = "Self-Test Author"
        s.saveClicked()
        let d = AppSettings.defaults
        let saved = d.string(forKey: "Theme") == "Dark" && d.string(forKey: "ZoomMode") == "FitPage" && d.bool(forKey: "KeepRecoveryCopies") == false
            && d.string(forKey: "AuthorName") == "Self-Test Author" && UserDefaults.standard.string(forKey: "AuthorName") != "Self-Test Author"
        check(saved && NSApp.appearance?.name == .darkAqua && !RecoveryCopies.shared.enabled && AppSettings.author == "Self-Test Author",
              "Settings › Save: stored under the Windows names (in the self-test's own suite), dark look and recovery copies off applied")

        // Applied to a document opening: Fit page, reopened at the page it was left at, comments by the new author.
        if let file = copy("Settings.pdf") {
            AppSettings.remember(page: 1, for: file.path)
            StartWindowController.open(file)
            _ = await wait { self.controller(self.document(at: file))?.window?.isVisible == true }
            try? await Task.sleep(for: .milliseconds(500))
            if let c = controller(document(at: file)) {
                let page = c.pages.currentPage
                let rect = c.pages.pageRects[min(page, c.pages.pageRects.count - 1)]
                let shown = c.scrollView.contentView.bounds
                let whole = rect.height * c.scrollView.magnification <= c.scrollView.contentView.frame.height + 1
                check(page == 1 && whole && shown.height > 0, "a document opens at Fit page (\(String(format: "%.2f", c.scrollView.magnification))x), on page \(page + 1), where it was left")
                await c.editor.addNote(page: 0, at: PointD(20, 40), text: "By the author in Settings", color: nil)
                let mine = c.editor.comments.filter { $0.author == "Self-Test Author" }.count
                check(mine == 1, "a new comment carries Settings' author name (\(mine))")
                c.go(0)
                document(at: file)?.close()
                check(AppSettings.lastPage(file.path) == 0, "closing remembers the page it was left at")
            } else {
                check(false, "a document opens with the settings: it didn't open")
            }
        }

        SettingsWindowController.show(updates: nil)
        s.resetClicked()
        s.saveClicked()
        let back = AppSettings.theme == "System" && AppSettings.zoomMode == "FitWidth" && AppSettings.restorePosition && AppSettings.keepRecoveryCopies
            && AppSettings.authorName.isEmpty && NSApp.appearance == nil && RecoveryCopies.shared.enabled
        check(back, "Settings › Reset to Defaults, Save: back to how Inkvolt PDF starts")
        RecoveryCopies.shared.enabled = true
    }

    // MARK: Command palette

    private mutating func palette() async {
        guard let file = copy("Palette.pdf") else { return }
        StartWindowController.open(file)
        _ = await wait { self.controller(self.document(at: file))?.window?.isVisible == true }
        guard let c = controller(document(at: file)), let window = c.window else { return check(false, "command palette: no document window") }
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        CommandPalette.show(over: window)
        guard let p = CommandPalette.shared else { return check(false, "command palette: not shown") }
        let titles = Set(p.all.map(\.title))
        let expected = ["Zoom In", "Organize Pages", "Word…", "Settings…", "Scan…", "Highlight", "Protect with Password…"]
        let missing = expected.filter { !titles.contains($0) }
        check(p.window?.isVisible == true && p.all.count >= 60 && missing.isEmpty,
              "command palette (⇧⌘K): \(p.all.count) commands listed, \(expected.count - missing.count) of \(expected.count) looked for")
        p.field.stringValue = "export word"
        p.filter(p.field.stringValue)
        check(p.shown.first?.title == "Word…" && p.shown.first?.path == "File › Export To", "search \"export word\": \(p.shown.count) found, File › Export To › Word first")
        p.filter("zqxj nothing")
        check(p.shown.isEmpty, "search for something no command has: none")
        p.field.stringValue = "zoom in"
        p.filter(p.field.stringValue)
        snapshot(p.window, "command-palette.png")
        let before = c.scrollView.magnification
        p.runSelected()
        _ = await wait(3) { abs(c.scrollView.magnification - before * 1.25) < 0.01 }
        check(p.window?.isVisible != true && abs(c.scrollView.magnification - before * 1.25) < 0.01 && p.lastRun == "Zoom In",
              "Return runs the first match (Zoom In: \(String(format: "%.2f", before))x to \(String(format: "%.2f", c.scrollView.magnification))x), the palette closed")
        document(at: file)?.close()
    }

    // MARK: What's New, About

    private mutating func whatsNew() {
        let notes = WhatsNew.notes()
        let first = notes.first
        let original = notes.first { $0.version.description == "1.0.0" }
        check(!(first?.items.isEmpty ?? true) && (original?.items.count ?? 0) >= 5,
              "What's New: the bundled notes read, \(notes.count) version(s), the newest (\(first?.version.description ?? "none")) with "
              + "\(first?.items.count ?? 0) items, 1.0.0 with \(original?.items.count ?? 0)")
        AppSettings.lastVersionSeen = "0.9.0"
        let shown = WhatsNew.showOnce(current: "1.0.0")
        let text = WhatsNewWindowController.shared?.textView.string ?? ""
        let visible = WhatsNewWindowController.shared?.window?.isVisible == true
        snapshot(WhatsNewWindowController.shared?.window, "whats-new.png")
        check(shown && visible && text.contains("Version 1.0.0") && AppSettings.lastVersionSeen == "1.0.0",
              "after an update (0.9.0 to 1.0.0): What's New shown once with 1.0.0's notes, the version seen kept")
        WhatsNewWindowController.shared?.closeClicked()
        let again = WhatsNew.showOnce(current: "1.0.0")
        check(!again && WhatsNewWindowController.shared?.window?.isVisible != true, "the next start: not shown again")
    }

    private mutating func about() {
        AboutWindowController.show()
        guard let a = AboutWindowController.shared, let view = a.window?.contentView else { return check(false, "About: not shown") }
        func labels(_ v: NSView) -> [String] { ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(labels) }
        let all = labels(view).joined(separator: "\n")
        let notices = a.notices.string
        check(a.window?.isVisible == true && a.versionLabel.stringValue.hasPrefix("Version ") && all.contains("Bermudez Systems LLC")
              && all.contains("Nothing you open leaves this Mac") && all.contains("AGPL-3.0"),
              "About: version, copyright, the AGPL notice and \"Nothing you open leaves this Mac\"")
        check(notices.contains("MuPDF") && notices.contains("AGPL-3.0") && notices.contains("Sparkle") && notices.contains("Permission is hereby granted"),
              "About › third-party notices: MuPDF (AGPL-3.0) and Sparkle's MIT license text (\(notices.count) characters)")
        snapshot(a.window, "about.png")
        a.showLicense()
        check(a.notices.string.contains("GNU AFFERO GENERAL PUBLIC LICENSE"), "About › License: the AGPL's full text")
        a.notices.string = AboutWindowController.noticesText()
        a.window?.orderOut(nil)
    }

    // MARK: Scan

    private mutating func scan() async {
        ScanWindowController.useDemoScanners()
        ScanWindowController.testRecognizer = { _, _, _ in [OcrWord("Scanned", RectD(72, 72, 120, 24))] }
        defer {
            ScanWindowController.testScanners = nil
            ScanWindowController.testRecognizer = nil
        }
        ScanWindowController.show()
        guard let s = ScanWindowController.shared else { return check(false, "Scan: not shown") }
        let connected = await wait(5) { s.caps != nil }
        check(connected && s.scanners.count == 2 && s.scanButton.isEnabled,
              "Scan: \(s.scanners.count) scanners listed, the first one's capabilities read (\(s.sourcePopup.numberOfItems) sources)")
        // The feeder: three pages; the last one removed; then one more from the glass.
        if let feeder = (0..<s.sourcePopup.numberOfItems).first(where: { s.sourcePopup.item(at: $0)?.title.contains("feeder") == true }) {
            s.sourcePopup.selectItem(at: feeder)
            s.sourcePopup.sendAction(s.sourcePopup.action, to: s.sourcePopup.target)
        }
        s.ocr.state = .on
        s.scanButton.performClick(nil)
        _ = await wait(1) { s.isScanning }
        _ = await wait(20) { !s.isScanning }
        let fed = s.pages.count
        s.removeLastButton.performClick(nil)
        s.sourcePopup.selectItem(at: 0)
        s.sourcePopup.sendAction(s.sourcePopup.action, to: s.sourcePopup.target)
        s.scanButton.performClick(nil)
        _ = await wait(1) { s.isScanning }
        _ = await wait(20) { !s.isScanning }
        check(fed == 3 && s.pages.count == 3 && s.thumbs.arrangedSubviews.count == 3 && s.createButton.isEnabled,
              "Scan: 3 pages from the feeder, the last removed, 1 from the glass: \(s.pages.count) pages")
        snapshot(s.window, "scan.png")
        let page = s.pages.first
        let pixels = page.flatMap { NSBitmapImageRep(data: Data($0.jpeg))?.pixelsWide } ?? 0
        let expected = Double(pixels) * 72 / Double(page?.dpi ?? 300)
        let remembered = AppSettings.defaults.string(forKey: "ScanSource") == "Platen" && AppSettings.defaults.integer(forKey: "ScanResolution") > 0
        s.createButton.performClick(nil)
        let made = await wait(10) { s.lastCreated != nil }
        let document = s.lastCreated
        let c = controller(document)
        let width = document?.engine.map { $0.page(0).width } ?? 0
        check(made && document?.engine?.pageCount == 3 && abs(width - expected) < 1 && document?.isDocumentEdited == true && remembered,
              "Create PDF: a new unsaved document of \(document?.engine?.pageCount ?? 0) pages, page 1 \(Int(width.rounded())) pt wide (scanned at its resolution), choices remembered")
        _ = await wait(2) { c?.longTask != nil }
        _ = await wait(30) { c?.longTask == nil }
        let text = (try? document?.engine?.text(0))?.text ?? ""
        check(text.contains("Scanned") && document?.session?.undoLabel != nil, "Make the text searchable: the pages recognized, their words found")
        document?.close()
        let dense = ScanWindowController.withDensity([0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x02], dpi: 300)
        check(dense.count == 24 && dense[16] == 0x01 && dense[17] == 0x2C, "a scanned JPEG gets the scan's resolution in its JFIF header")
    }

    // MARK: Open in Inkvolt PDF (from another app)

    /// Opens a copy through Launch Services with this app, as Inkvolt Print's "Open in Inkvolt PDF" does.
    private mutating func openFromAnotherApp() async {
        let types = (Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []
        let pdf = types.contains { ($0["LSItemContentTypes"] as? [String])?.contains("com.adobe.pdf") == true }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "") != nil
        check(pdf && found, "Open in Inkvolt PDF: PDF is a document type, and Launch Services finds the app by its bundle ID")
        guard let file = copy("From Inkvolt Print.pdf") else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open([file], withApplicationAt: Bundle.main.bundleURL, configuration: configuration) { _, _ in }
        let opened = await wait(15) { self.controller(self.document(at: file))?.window?.isVisible == true }
        check(opened, "a PDF handed over by another app (NSWorkspace, as Inkvolt Print does) opens in a window")
        document(at: file)?.close()
    }
}

/// Page counts of the test's copies.
enum PdfEngineCount {
    static func of(_ url: URL) -> Int? {
        guard let data = FileManager.default.contents(atPath: url.path), let engine = try? PdfEngine.open([UInt8](data)) else { return nil }
        defer { engine.close() }
        return engine.pageCount
    }
}
