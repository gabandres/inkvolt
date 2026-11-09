import AppKit
import PdfCore
import PrintCore
import PrintCore
import PrintMac

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
        reportProblem()
        await hoverActions()
        await scan()
        await openFromAnotherApp()
        await convertFiles()
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
        start.showMoreTools(false)
        let calm = start.visibleCardCount
        check(start.isShown && start.cards.count == StartWindowController.ToolCard.allCases.count && start.recentCount == 2 && calm == 4,
              "start page: shown with \(calm) of \(start.cards.count) tool cards in sight and \(start.recentCount) recent files")
        start.showMoreTools(true)
        check(start.visibleCardCount == start.cards.count, "start page › More Tools: all \(start.visibleCardCount) cards shown")
        try? await Task.sleep(for: .milliseconds(500)) // page 1 of each drawn
        snapshot(start.window, "start-page.png")

        // Open a file (the card), then the start page steps aside.
        StartWindowController.testPicks = [[a]]
        start.openClicked()
        let opened = await wait { self.controller(self.document(at: a))?.window?.isVisible == true }
        check(opened && !start.isShown, "start page › Open a file: the PDF opened and the start page stepped aside")
        document(at: a)?.close()

        // Each card that works on a PDF: pick one, it opens straight in that tool.
        // The Compare files card asks for the two versions (Compare Files…; not shown while the self-test runs).
        StartWindowController.show()
        let asked = CompareWindowController.picksAsked
        start.cards[StartWindowController.ToolCard.compare.rawValue].performClick(nil)
        check(CompareWindowController.picksAsked == asked + 1 && start.cards[StartWindowController.ToolCard.compare.rawValue].title.contains(loc("Compare files")),
              "start page › Compare files: asks for the original and the changed version, as File › Compare Files…")

        for card in StartWindowController.ToolCard.allCases where card != .combine && card != .compare && card != .create && card != .batch {
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
            case .combine, .compare, .create, .batch: break
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
                fromImages = NSDocumentController.shared.documents.compactMap { $0 as? PdfDocument }.first { $0.fileURL == nil && $0.name.hasPrefix(loc("Pictures", context: "file name")) }
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
              "Settings: applied at once, stored under the Windows names (in the self-test's own suite), dark look and recovery copies off applied")

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
            && s.language.indexOfSelectedItem == AppLanguage.Choice.allCases.firstIndex(of: .system)
        check(back, "Settings › Reset to Defaults: back at once to how Inkvolt PDF starts, the language to Same as macOS")
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
        let expected = [loc("Zoom In"), loc("Organize Pages"), loc("Word…"), loc("Settings…"), loc("Scan…"), loc("Highlight"), loc("Protect with Password…")]
        let missing = expected.filter { !titles.contains($0) }
        check(p.window?.isVisible == true && p.all.count >= 60 && missing.isEmpty,
              "command palette (⇧⌘K): \(p.all.count) commands listed, \(expected.count - missing.count) of \(expected.count) looked for")
        p.field.stringValue = "export word"
        p.filter(p.field.stringValue)
        check(p.shown.first?.title == loc("Word…") && p.shown.first?.path == loc("File") + " › " + loc("Export To"), "search \"export word\": \(p.shown.count) found, File › Export To › Word first")
        p.filter("zqxj nothing")
        check(p.shown.isEmpty, "search for something no command has: none")
        // Spanish says Image and Picture both "Imagen": the Image tool is found by its own English, never by Picture.
        let isImageTool = { (e: CommandPalette.Entry) in
            e.item.action == #selector(DocumentWindowController.chooseTool(_:)) && e.item.tag == Tool.image.rawValue
        }
        let image = p.all.first(where: isImageTool)?.english ?? "none"
        p.filter("picture")
        let byPicture = p.shown.contains(where: isImageTool)
        let ownEnglish = CoreLanguage.table == nil ? image.isEmpty : image.hasPrefix("Image ") && !image.contains("Picture")
        check(ownEnglish && !byPicture, "the palette's English words are each command's own (the Image tool: \"\(image)\"; \"picture\" finds it: \(byPicture))")
        p.field.stringValue = "zoom in"
        p.filter(p.field.stringValue)
        snapshot(p.window, "command-palette.png")
        let before = c.scrollView.magnification
        p.runSelected()
        _ = await wait(3) { abs(c.scrollView.magnification - before * 1.25) < 0.01 }
        check(p.window?.isVisible != true && abs(c.scrollView.magnification - before * 1.25) < 0.01 && p.lastRun == loc("Zoom In"),
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
        check(shown && visible && text.contains(loc("Version {0}", "1.0.0")) && AppSettings.lastVersionSeen == "1.0.0",
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
        check(a.window?.isVisible == true && a.versionLabel.stringValue.hasPrefix(Shown.head(loc("Version {0}", Shown.gap))) && all.contains("Bermudez Systems LLC")
              && all.contains(loc("Nothing you open leaves this Mac unless you send text to an AI you set up. No account, no tracking, no analytics: documents, text recognition and exports are all done here. Update checks ask Inkvolt PDF's feed on GitHub and send nothing about you."))
              && all.contains("AGPL-3.0"),
              "About: version, copyright, the AGPL notice and \"Nothing you open leaves this Mac\"")
        check(notices.contains("MuPDF") && notices.contains("AGPL-3.0") && notices.contains("Sparkle") && notices.contains("Permission is hereby granted"),
              "About › third-party notices: MuPDF (AGPL-3.0) and Sparkle's MIT license text (\(notices.count) characters)")
        snapshot(a.window, "about.png")
        a.showLicense()
        check(a.notices.string.contains("GNU AFFERO GENERAL PUBLIC LICENSE"), "About › License: the AGPL's full text")
        a.notices.string = AboutWindowController.noticesText()
        a.window?.orderOut(nil)
    }

    // MARK: Report a Problem

    /// Help › Report a Problem… through the menu's own item: the details (version, macOS, settings; the user's name and
    /// this Mac's name masked), Copy, and Copy and Open a GitHub Issue (the address made, no browser in the self-test).
    private mutating func reportProblem() {
        var menuItem: NSMenuItem?
        for top in NSApp.mainMenu?.items ?? [] {
            if let hit = top.submenu?.items.first(where: { $0.title == loc("Report a Problem…") }) { menuItem = hit }
        }
        if let menuItem, let action = menuItem.action { NSApp.sendAction(action, to: nil, from: menuItem) }
        guard let r = ReportProblemWindowController.shared, r.window?.isVisible == true else {
            return check(false, "Report a Problem: the window didn't open")
        }
        let text = r.details.string
        let user = NSUserName()
        check(text.hasPrefix("Inkvolt PDF \(WhatsNew.version)") && text.contains("macOS: ") && text.contains("Dark pages: ")
              && text.contains("(no log yet)") && (user.count < 3 || !text.contains(user)),
              "Help › Report a Problem…: the version, macOS and settings, the user's name masked")
        let board = NSPasteboard(name: .init("com.bermudezsystems.InkvoltPdf.selftest.report"))
        r.details.string = text + "\nAn added line"
        let copied = r.copy(to: board) && board.string(forType: .string)?.hasSuffix("An added line") == true
        r.issueClicked()
        let url = r.openedIssue?.absoluteString ?? ""
        check(copied && url.hasPrefix("https://github.com/gabandres/inkvolt/issues/new?title=") && url.count < 2000
              && board.string(forType: .string)?.hasSuffix("An added line") == true,
              "Report a Problem: Copy takes the details as edited; Copy and Open a GitHub Issue makes the issue's address")
        board.releaseGlobally()
        r.closeClicked()
    }

    // MARK: Form fields' hover actions

    /// A field's hover actions (/AA /E and /X) run as the pointer enters and leaves it, through the page view's own
    /// pointer handling (Windows' SetHoverWidget), on a small form made here: entering runs the enter script, leaving the
    /// exit script, and a hover while another action runs is dropped.
    private mutating func hoverActions() async {
        let w = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R"
        let enter = #"<< /S /JavaScript /JS (this.getField\("a"\).value = "in";) >>"#
        let exit = #"<< /S /JavaScript /JS (this.getField\("a"\).value = "out";) >>"#
        let bytes = SyntheticPdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R 6 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R 6 0 R] /Resources << /Font << /Helv 4 0 R >> >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< \(w) /FT /Tx /T (a) /Rect [72 700 300 722] /DA (/Helv 12 Tf 0 g) >>",
            "<< \(w) /FT /Btn /Ff 65536 /T (hover) /Rect [72 600 200 640] /AA << /E \(enter) /X \(exit) >> >>",
        ])
        guard let document = NewDocuments.open(bytes, name: "Hover form.pdf"), let c = document.windowControllers.first as? DocumentWindowController
        else { return check(false, "hover actions: the form didn't open") }
        defer { document.close() }
        _ = await wait(5) { c.form.widgets.count == 2 && !c.pages.pageRects.isEmpty }
        guard let button = c.form.widgets.first(where: { $0.fieldName == "hover" }), let page = c.pages.pageRects.first else {
            return check(false, "hover actions: the button wasn't read")
        }
        let on = c.pages.viewPoint(PointD(button.rect.centerX, button.rect.centerY), page)
        let off = c.pages.viewPoint(PointD(500, 60), page)
        c.pages.tool = .hand
        c.pages.hoverField(at: on)
        await c.form.settle()
        let entered = c.form.value("a") == "in"
        c.pages.hoverField(at: off)
        await c.form.settle()
        let left = c.form.value("a") == "out"
        c.pages.hoverField(at: on)
        c.pages.hoverField(at: off) // while the enter action runs: dropped
        await c.form.settle()
        let dropped = c.form.value("a") == "in" && c.form.hovered == nil
        check(entered && left && dropped, "form field hover: entering runs its enter action, leaving its exit action; "
              + "a hover while another action runs is dropped")
    }

    // MARK: Scan

    /// Scan's presets: the laser's feeder, grey, 200 dpi, Legal, blank pages kept, saved as "Contracts"; the same name
    /// refused; the preset matched to the flatbed (no feeder, no Legal), saying so; deleted.
    private mutating func scanPresets() async {
        ScanWindowController.show()
        guard let s = ScanWindowController.shared else { return check(false, "Scan presets: not shown") }
        defer {
            ScanWindowController.testPresetName = nil
            s.skipBlank.state = .on
            s.window?.orderOut(nil)
        }
        func choose(_ popup: NSPopUpButton, _ text: String) {
            guard let i = (0..<popup.numberOfItems).first(where: { popup.item(at: $0)?.title.contains(text) == true }) else { return }
            popup.selectItem(at: i)
            popup.sendAction(popup.action, to: popup.target)
        }
        let builtIns = s.presetPopup.numberOfItems == 4 && s.presetPopup.titleOfSelectedItem == loc("No preset")
        choose(s.scannerPopup, DemoScanDevice.laserScanner.name)
        _ = await wait(5) { s.caps?.adf != nil }
        choose(s.sourcePopup, loc("Document feeder"))
        s.colorPopup.selectItem(withTitle: loc("Grayscale"))
        s.resolutionPopup.selectItem(withTitle: loc("{0} dpi", 200))
        choose(s.sizePopup, loc("Legal (8.5 × 14 in)"))
        s.skipBlank.state = .off
        s.ocr.state = .on
        ScanWindowController.testPresetName = "Contracts"
        s.savePresetButton.performClick(nil)
        let saved = s.presets.last
        let choices = saved?.source == .feeder && saved?.color == false && saved?.resolution == 200
        let rest = saved?.pageSize == "legal" && saved?.skipBlank == false && saved?.fileType == .searchablePdf
        let shown = s.presetPopup.titleOfSelectedItem == "Contracts" && s.message.stringValue == loc("Saved the preset \"{0}\".", "Contracts")
        check(builtIns && saved?.name == "Contracts" && choices && rest && shown,
              "Scan presets: Inkvolt Print's three to start with; Save as Preset… keeps the feeder, grey, 200 dpi, Legal, OCR and blank choices")
        let count = s.presets.count
        ScanWindowController.testPresetName = "contracts"
        s.savePresetButton.performClick(nil)
        check(s.presets.count == count && s.message.stringValue == loc("Another preset is already called \"{0}\".", "Contracts"),
              "a second preset of the same name is refused: “\(s.message.stringValue)”")

        // The flatbed: no feeder, a glass too short for Legal; the preset is matched to it and says what had to give.
        choose(s.scannerPopup, DemoScanDevice.flatbed.name)
        _ = await wait(5) { s.caps != nil && s.caps?.adf == nil }
        let said = s.message.stringValue
        let matched = s.sourcePopup.titleOfSelectedItem == loc("Scanner glass") && s.colorPopup.titleOfSelectedItem == loc("Grayscale")
        let noFit = Shown.head(loc("{0} doesn't fit this source: scanning {1}.", loc("Legal (8.5 × 14 in)"), Shown.gap))
        let notes = said.contains(loc("This scanner has no document feeder: scanning from the glass.")) && said.contains(noFit)
        check(matched && notes && s.skipBlank.state == .off && s.resolutionPopup.titleOfSelectedItem == loc("{0} dpi", 200),
              "a preset matched to the flatbed: the glass, grey, 200 dpi, blank pages kept, “\(said.prefix(120))”")
        // Chosen while another scanner connects, then No preset: nothing is applied once it has.
        choose(s.scannerPopup, DemoScanDevice.laserScanner.name)
        choose(s.presetPopup, "Contracts")
        choose(s.presetPopup, loc("No preset"))
        let laserRead = await wait(5) { s.caps?.adf != nil }
        check(laserRead && s.message.stringValue.isEmpty && s.selectedPreset == nil,
              "a preset turned off while the scanner connected isn't applied once it has: “\(s.message.stringValue.prefix(120))”")
        choose(s.presetPopup, "Contracts")
        s.deletePresetButton.performClick(nil)
        check(!s.presets.contains { $0.name == "Contracts" } && s.presetPopup.titleOfSelectedItem == loc("No preset")
              && s.message.stringValue == loc("Deleted the preset \"{0}\".", "Contracts"),
              "Delete Preset: gone from the list, No preset chosen")
    }

    private mutating func scan() async {
        ScanWindowController.useDemoScanners()
        // A printer Inkvolt Print remembers (its hand-off), listed before discovery; the demo laser stays the one chosen.
        let office = SuitePrinter(id: "12345678-1234-4abc-8def-123456789abc", name: "Office MFP", host: "192.0.2.77",
                                  esclRoot: "http://192.0.2.77/eSCL/")
        ScanWindowController.testRemembered = SuitePrinters([office, SuitePrinter(id: "b", name: "Label printer", host: "192.0.2.78")])
        AppSettings.defaults.set("icc:" + DemoScanDevice.laserScanner.id, forKey: AppSettings.Key.scanDevice)
        // Read as Recognize Text reads (its choices: cleaned, suspect words listed), by a stand-in: "recognlzed" on each page.
        ScanWindowController.testReader = OcrTest.StandInReader()
        ScanWindowController.testSpelling = OcrTest.StandInDictionary()
        defer {
            ScanWindowController.testScanners = nil
            ScanWindowController.testRemembered = nil
            ScanWindowController.testReader = nil
            ScanWindowController.testSpelling = nil
        }
        ScanWindowController.show()
        guard let s = ScanWindowController.shared else { return check(false, "Scan: not shown") }
        let connected = await wait(5) { s.caps != nil }
        let titles = s.scannerPopup.itemTitles
        let laser = s.scannerPopup.titleOfSelectedItem == DemoScanDevice.laserScanner.name
        check(connected && s.scanners.count == 3 && titles.first == "Office MFP  (192.0.2.77)" && laser && s.scanButton.isEnabled,
              "Scan: \(s.scanners.count) scanners listed (\(titles.joined(separator: ", "))): the one Inkvolt Print remembers first "
              + "(a printer without eSCL left out), the demo laser chosen and its capabilities read (\(s.sourcePopup.numberOfItems) sources)")
        // The feeder: three pages, the third blank and left out; then one from the glass, removed, and one more.
        if let feeder = (0..<s.sourcePopup.numberOfItems).first(where: { s.sourcePopup.item(at: $0)?.title.contains(loc("Document feeder")) == true }) {
            s.sourcePopup.selectItem(at: feeder)
            s.sourcePopup.sendAction(s.sourcePopup.action, to: s.sourcePopup.target)
        }
        s.ocr.state = .on
        let skipsBlank = s.skipBlank.state == .on
        s.scanButton.performClick(nil)
        _ = await wait(1) { s.isScanning }
        _ = await wait(20) { !s.isScanning }
        let fed = s.pages.count, fedText = s.message.stringValue
        let fedDone = loc("Done: {0} from the feeder{1}.", loc("{0} pages", 2), " (" + loc("{0} blank page left out", 1) + ")")
        check(skipsBlank && fed == 2 && s.lastBlank == 1 && fedText == fedDone
              && s.scanButton.title == loc("Scan More Pages"),
              "Leave out blank pages (on by default): the feeder's blank third page left out, “\(fedText)”")
        s.sourcePopup.selectItem(at: 0)
        s.sourcePopup.sendAction(s.sourcePopup.action, to: s.sourcePopup.target)
        for remove in [true, false] {
            s.scanButton.performClick(nil)
            _ = await wait(1) { s.isScanning }
            _ = await wait(20) { !s.isScanning }
            if remove { s.removeLastButton.performClick(nil) }
        }
        check(s.pages.count == 3 && s.thumbs.arrangedSubviews.count == 3 && s.createButton.isEnabled && s.scanButton.title == loc("Scan Another Page")
              && s.message.stringValue.hasPrefix(Shown.head(loc("Done{0}. For another page, put it on the glass and press Scan Another Page; or press {1}.", "", Shown.gap))),
              "Scan: 2 pages from the feeder, 1 from the glass removed, 1 more: \(s.pages.count) pages")
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
        check(text.contains("Inkvolt") && document?.session?.undoLabel != nil, "Make the text searchable: the pages recognized, their words found")
        // Its suspect words kept in the text layer, counted, and the Suspect Words pane opened on them.
        let said = c?.noticeBar.message ?? ""
        let listed = c?.sidebar.suspectWords.items.count ?? 0
        let toCheck = Shown.tail(loc("{0}; {1} suspect words to check in the sidebar's Suspect Words.", Shown.gap, 3))
        check(said.contains(toCheck) && listed == 3 && c?.sidebar.shownPane == .suspectWords,
              "Scan with OCR: its suspect words counted (“\(said.prefix(90))”) and listed in the Suspect Words pane (\(listed))")
        // The file opened again (as a Batch or scan result is): the pane offers its suspect words left.
        if let bytes = document?.session?.data, let again = NewDocuments.open(bytes, name: "Scan suspect words") {
            let reopened = controller(again)
            let offered = await wait(5) { reopened?.sidebar.showsSuspectWords == true && reopened?.sidebar.suspectWords.items.count == 3 }
            let quick = TextLayer.mayHaveLayer(SyntheticPdf.make()) == false && (try? TextLayer.hasSuspectWords(bytes, nil)) == true
            check(offered && quick, "a file opened with suspect words left offers the Suspect Words pane (a file without a text layer isn't read for one)")
            again.close()
        } else {
            check(false, "a file opened with suspect words left: not opened")
        }

        // Pages › Insert from Scanner… into that document: one page from the glass, inserted before page 1, one undo step.
        if let c {
            c.go(0)
            c.insertFromScanner(nil)
            let insert = ScanWindowController.shared
            let ready = await wait(5) { insert?.caps != nil && insert?.scanButton.isEnabled == true }
            let titled = insert?.window?.title == loc("Insert from Scanner") && insert?.createButton.title == loc("Insert Pages") && insert?.placePopup.isHidden == false
            insert?.ocr.state = .off
            insert?.placePopup.selectItem(at: 1) // before page 1
            insert?.scanButton.performClick(nil)
            _ = await wait(1) { insert?.isScanning == true }
            _ = await wait(20) { insert?.isScanning == false }
            let scanned = insert?.pages.count ?? 0
            insert?.createButton.performClick(nil)
            let inserted = await wait(10) { insert?.lastInserted != nil }
            let label = document?.session?.undoLabel ?? ""
            check(ready && titled && scanned == 1 && inserted && document?.engine?.pageCount == 4 && insert?.lastInserted?.at == 0
                  && label == loc("Insert {0} page from the scanner", 1),
                  "Insert from Scanner: the scan window for the document, 1 page scanned and inserted before page 1 (\(document?.engine?.pageCount ?? 0) pages, “\(label)”)")
            // The page inserted has no text: exported with a stand-in recognizer that marks one suspect word, the message counts it.
            let plain = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("Scan suspect words.txt"))
            let reader: Recognizer = { _, _, _ in
                [OcrWord("Recognized", RectD(72, 72, 120, 14)), OcrWord("w0rds", RectD(200, 72, 60, 14), suspect: .lettersAndDigits)]
            }
            let exported = await c.runExport(.text, to: plain, pages: [0], recognize: true, recognizer: reader)
            let note = c.noticeBar.message
            check(exported?.saved == true && exported?.recognized == 1 && exported?.suspectWords == 1
                  && note.contains(loc("1 suspect word (check it against the PDF)")),
                  "Export to text with OCR: the scanned page recognized, its suspect word counted (“\(note.prefix(110))”)")
            c.window?.undoManager?.undo()
            _ = await wait(5) { document?.engine?.pageCount == 3 }
            ScanWindowController.show()
            check(document?.engine?.pageCount == 3 && insert?.window?.title == loc("Scan") && insert?.createButton.title == loc("Create PDF"),
                  "undone; File › Scan… is a new PDF's scan again")
            insert?.window?.orderOut(nil)
        }
        document?.close()
        await scanPresets()
        let dense = ScanWindowController.withDensity([0xFF, 0xD8, 0xFF, 0xDB, 0x00, 0x02], dpi: 300)
        check(dense.count == 24 && dense[16] == 0x01 && dense[17] == 0x2C, "a scanned JPEG gets the scan's resolution in its JFIF header")
    }

    // MARK: PDF from Office files and web pages (E12)

    /// A saved web page and an Office file opened through the app's own document controller (as File › Open, the Dock or
    /// Finder do): the page printed by WebKit with its scripts off, the Office file through a made-up Word (the script
    /// runner faked, staging in a folder of the test's) and a made-up LibreOffice that each write a copy of the synthetic
    /// document, each a new unsaved document; then the menu items and document types.
    private mutating func convertFiles() async {
        let menu = NSApp.mainMenu?.item(withTitle: loc("File"))?.submenu?.item(withTitle: loc("New PDF"))?.submenu
        let items = [loc("New PDF from Office File…"), loc("New PDF from Web Page…")].filter { menu?.item(withTitle: $0) != nil }
        let types = (Bundle.main.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]]) ?? []
        let utis = Set(types.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] })
        let wanted = ["org.openxmlformats.wordprocessingml.document", "org.openxmlformats.spreadsheetml.sheet",
                      "org.openxmlformats.presentationml.presentation", "public.html"]
        check(items.count == 2 && wanted.allSatisfy(utis.contains),
              "File › New PDF has New PDF from Office File… and from Web Page…; Word, Excel, PowerPoint and web pages are document types")
        check(NSDocumentController.shared is DocumentController, "the app's document controller is the one that converts")

        // A saved web page: its text printed, its script never run.
        let page = url("Saved page.html")
        let html = "<!doctype html><html><head><title>Saved</title></head><body><h1>Inkvolt web capture check</h1>"
            + "<p>Paragraph one of the saved page.</p><script>document.body.innerHTML += '<p>SCRIPT RAN</p>'</script></body></html>"
        try? Data(html.utf8).write(to: page)
        let before = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
        NSDocumentController.shared.openDocument(withContentsOf: page, display: true) { _, _, _ in }
        let made = await wait(60) { NSDocumentController.shared.documents.contains { !before.contains(ObjectIdentifier($0)) } }
        let web = NSDocumentController.shared.documents.first { !before.contains(ObjectIdentifier($0)) } as? PdfDocument
        let webText = Self.text(web)
        check(made && webText.contains("Inkvolt web capture check") && webText.contains("Paragraph one") && !webText.contains("SCRIPT RAN")
              && web?.fileURL == nil && (try? Data(contentsOf: page)) == Data(html.utf8),
              "a saved web page opens as a new unsaved PDF with its text (\(web?.engine?.pageCount ?? 0) pages), its script not run, the page unchanged")
        web?.close()

        // An Office file: through LibreOffice when installed; here a made-up one, as the PdfCore tests use.
        let bin = url("bin")
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let soffice = bin.appendingPathComponent("soffice")
        guard let synthetic = Report.syntheticPath else { return }
        let script = "#!/bin/sh\nprev=\nfor a in \"$@\"; do [ \"$prev\" = \"--outdir\" ] && out=\"$a\"; prev=\"$a\"; input=\"$a\"; done\n"
            + "cp '" + synthetic + #"' "$out/$(basename "$input" | sed 's/\.[^.]*$//').pdf""# + "\n"
        try? Data(script.utf8).write(to: soffice)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: soffice.path)
        defer { Converting.testInstalls = nil }
        let report = url("Quarterly report.docx")

        // 1.10.0: Microsoft's apps aren't driven yet (OfficeInstalls.drivesMicrosoftOffice): what the app finds on this Mac
        // routes every Office file to LibreOffice, whichever of Word, Excel or PowerPoint is installed.
        Converting.testInstalls = nil
        let detected = Converting.installs()
        check(!detected.drivesMicrosoft && detected.driven.isEmpty,
              "Microsoft Office is off for this release: the installs found drive none of Word, Excel and PowerPoint (\(detected.microsoft.count) found)")
        try? Data("PK\u{3}\u{4}a made-up document".utf8).write(to: report)

        // And end to end: Word "installed" (a made-up one that would convert), yet LibreOffice converts and Word gets nothing.
        let group = url("UBF8T346G9.Office")
        try? FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let staging = group.appendingPathComponent(MicrosoftOfficeConverter.stagingFolder, isDirectory: true)
        let untouched = MadeUpWord(pdf: synthetic)
        Converting.testInstalls = OfficeInstalls(soffice: soffice.path, microsoft: [.word], scriptRunner: untouched, staging: staging)
        let offWord = await Converting.openConverted(report)
        // The notices in the run's language (`loc`), so the Spanish run checks the same.
        let byLibreOffice = loc("Made from {0} with {1}. Save it to keep it.", report.lastPathComponent, "LibreOffice")
        check(offWord != nil && Converting.lastNotice == byLibreOffice
              && untouched.calls.value == 0,
              "with Word installed and Office off, LibreOffice converts the file and Word is sent nothing (\(untouched.calls.value) scripts): \(Converting.lastNotice)")
        offWord?.close()

        // The code kept for when Office is turned on, driven only here (drivesMicrosoft: true):
        // Word installed: Word converts it (a made-up runner in place of osascript), and its copy is gone after.
        Converting.testInstalls = OfficeInstalls(soffice: soffice.path, microsoft: [.word], scriptRunner: MadeUpWord(pdf: synthetic), staging: staging, drivesMicrosoft: true)
        let byWord = await Converting.openConverted(report)
        let wordPages = byWord?.engine?.pageCount ?? 0
        let leftInStaging = (try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []
        check(byWord != nil && byWord?.fileURL == nil && wordPages == PdfEngineCount.of(URL(fileURLWithPath: synthetic))
              && Converting.lastNotice.contains("Microsoft Word") && leftInStaging.isEmpty,
              "with Word installed, an Office file opens converted by Word (\(wordPages) pages), its copy in Office's folder removed: \(Converting.lastNotice)")
        byWord?.close()

        // Word installed but Automation denied: LibreOffice converts it, and the notice says why Word didn't.
        Converting.testInstalls = OfficeInstalls(soffice: soffice.path, microsoft: [.word], scriptRunner: MadeUpWord(pdf: synthetic, denies: true), staging: staging, drivesMicrosoft: true)
        let denied = await Converting.openConverted(report)
        check(denied != nil && Converting.lastNotice.hasPrefix(byLibreOffice)
              && Converting.lastNotice.contains(loc("{0} couldn't convert it: {1}", "Microsoft Word", ""))
              && Converting.lastNotice.contains(loc("macOS didn't let Inkvolt PDF use {0}. Turn on {0} under Inkvolt PDF in System Settings › Privacy & Security › Automation, then try again.", "Microsoft Word")),
              "with Word's Automation denied, LibreOffice converts the file and the notice says why Word didn't: \(Converting.lastNotice)")
        denied?.close()

        // Only Excel installed: a Word file falls back to LibreOffice.
        Converting.testInstalls = OfficeInstalls(soffice: soffice.path, microsoft: [.excel], scriptRunner: MadeUpWord(pdf: synthetic), staging: staging, drivesMicrosoft: true)
        let opened = await Converting.openConverted(report)
        let pages = opened?.engine?.pageCount ?? 0
        check(opened != nil && opened?.fileURL == nil && pages == PdfEngineCount.of(URL(fileURLWithPath: synthetic))
              && Converting.lastNotice.contains("LibreOffice") && opened?.displayName.hasPrefix("Quarterly report") == true,
              "without Word, an Office file opens converted by LibreOffice as a new unsaved PDF named after it (\(pages) pages): \(Converting.lastNotice)")
        opened?.close()

        // Nothing installed: said in words, nothing opened.
        Converting.testInstalls = OfficeInstalls()
        let count = NSDocumentController.shared.documents.count
        let none = await Converting.openConverted(report)
        check(none == nil && NSDocumentController.shared.documents.count == count && (Converting.lastMessage?.text.contains("LibreOffice") ?? false),
              "with no converter installed, an Office file opens nothing and the message names LibreOffice")
    }

    /// Word's side of the script, made up: the PDF it would save is a copy of the synthetic document.
    private struct MadeUpWord: OfficeScriptRunner {
        let pdf: String
        var denies = false
        /// How many scripts it was given (a shared count: the runner is copied into the installs).
        let calls = Calls()
        final class Calls: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            var value: Int { lock.withLock { count } }
            func add() { lock.withLock { count += 1 } }
        }
        func run(_ script: String, arguments: [String], timeout: TimeInterval, cancel: CancelToken, appName: String) throws -> ScriptRun {
            calls.add()
            if arguments.isEmpty { return ScriptRun(.exited(0), output: "false") } // the probe: Word wasn't running
            if arguments.count == 2 { return ScriptRun(.exited(0), output: "ok") } // the clean-up
            if denies { return ScriptRun(.exited(1), errors: "execution error: inkvolt:open: Not authorized to send Apple events to Microsoft Word. (-1743)") }
            guard arguments.count == 5, (try? FileManager.default.copyItem(atPath: pdf, toPath: arguments[1])) != nil else {
                return ScriptRun(.exited(1), errors: "execution error: inkvolt:save: made up (1)")
            }
            return ScriptRun(.exited(0), output: "ok")
        }
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

// MARK: PDF from Office files and web pages (E12)

extension AppTest {
    /// The text of every page of an open document.
    fileprivate static func text(_ document: PdfDocument?) -> String {
        guard let engine = document?.engine else { return "" }
        return (0..<engine.pageCount).compactMap { try? engine.text($0).text }.joined(separator: "\n")
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
