import AppKit
import PdfCore
import PrintCore
import PrintMac

/// The self-test's scenario for the Windows features the Mac lacked (`--edit`, on the synthetic text document;
/// `--only-parity` runs it alone; mac/docs/PLAN.md, "Windows parity audit"): File › Export To › Pages as Images… (two
/// pages as PNG and one as JPEG into a folder of the test's own, read back, a taken name not replaced); Show in Finder's
/// enabling and Close All over three new documents, each question answered here; Go › Previous View and Next View after
/// a jump and a page turn; View › Highlight Form Fields on the form; Help › Keyboard Shortcuts' rows and filter, the log
/// and Report a Problem's copy of it; an FB2 opened through File › Open's path as a new PDF; File › Scan's black and
/// white offered where listed, a demo page saved at 1 bit. Only counts and states are written.
@MainActor
struct ParityTest {
    /// While it runs, the documents it opens get only its checks (`Report.documentOpened`).
    static var isActive = false
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
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    func menuItem(_ title: String) -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title == title { return item }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    private func settle(_ ms: Int = 150) async { try? await Task.sleep(for: .milliseconds(ms)) }

    mutating func run() async {
        lines.append("== \(name): Windows parity (\(controller.engine.pageCount) pages)")
        Self.isActive = true
        defer { Self.isActive = false }
        await exportImages()
        await showInFinderAndCloseAll()
        await history()
        await highlightFields()
        await shortcutsAndLog()
        await otherFormats()
        await blackAndWhiteScan()
        Report.write(lines.joined(separator: "\n"))
        Report.write("parity: \(failures == 0 ? "PASS" : "FAIL (\(failures))")")
    }

    // MARK: Export Pages as Images

    private mutating func exportImages() async {
        let count = controller.engine.pageCount
        guard count >= 2 else { return check(false, "export images: the document has \(count) page") }
        let item = menuItem(loc("Pages as Images…"))
        check(item.map { controller.validateMenuItem($0) } == true, "export images: File › Export To › Pages as Images… is in the menu and enabled")
        check(CommandBar.group("Convert")?.items.contains { $0.action == "exportImages:" } == true, "export images: Convert › Images… sends it")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-parity-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let stem = ((controller.pdf.session?.displayName ?? "") as NSString).deletingPathExtension
        FileManager.default.createFile(atPath: dir + "/" + PageImageExport.fileName(stem, page: 0, jpeg: false), contents: Data([0]))
        await controller.runExportImages([0, 1], folder: dir, dpi: 72, jpeg: false)
        await controller.runExportImages([1], folder: dir, dpi: 96, jpeg: true)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
        func head(_ file: String) -> [UInt8] { [UInt8]((FileManager.default.contents(atPath: dir + "/" + file) ?? Data()).prefix(3)) }
        let pngs = files.filter { $0.hasSuffix(".png") && head($0) == [0x89, 0x50, 0x4E] }
        let jpegs = files.filter { $0.hasSuffix(".jpg") && head($0) == [0xFF, 0xD8, 0xFF] }
        check(files.count == 4 && pngs.count == 2 && jpegs.count == 1, "export images: 2 PNG and 1 JPEG written beside a taken name (\(files.count) files)")
        check(files.contains { $0.hasSuffix("page 1 (2).png") }, "export images: the taken name kept, the new one numbered")
        if let png = pngs.first(where: { $0.contains("page 2") }), let rep = NSBitmapImageRep(data: FileManager.default.contents(atPath: dir + "/" + png) ?? Data()) {
            let g = controller.engine.page(1)
            check(abs(rep.pixelsWide - Int((g.width).rounded())) <= 1, "export images: 72 dpi is the page's size in points (\(rep.pixelsWide) px)")
        } else {
            check(false, "export images: page 2's PNG read back")
        }
        await settle()
    }

    // MARK: Show in Finder, Close All

    private mutating func showInFinderAndCloseAll() async {
        let show = menuItem(loc("Show in Finder"))
        check(show.map { controller.validateMenuItem($0) } == (controller.pdf.session?.filePath != nil),
              "show in Finder: File › Show in Finder enabled only for a saved file")
        let closeAll = menuItem(loc("Close All"))
        check(closeAll?.keyEquivalent == "w" && closeAll?.keyEquivalentModifierMask == [.command, .option], "close all: File › Close All is ⌥⌘W")
        // Three new (unsaved) documents, each question answered by the test: Don't Save closes the first, Cancel on the
        // second stops there and keeps it and the third; then Don't Save for both closes them.
        guard let a = NewDocuments.open(SyntheticPdf.make(), name: "parity-a.pdf"),
              let b = NewDocuments.open(SyntheticPdf.make(), name: "parity-b.pdf"),
              let c = NewDocuments.open(SyntheticPdf.make(), name: "parity-c.pdf"),
              let bc = b.windowControllers.first as? DocumentWindowController else { return check(false, "close all: three new documents opened") }
        await bc.editor.addNote(page: 0, at: PointD(16, 48), text: "Unsaved", color: nil)
        a.testCloseAnswer = .dontSave
        b.testCloseAnswer = .cancel
        c.testCloseAnswer = .dontSave
        let open = { (d: PdfDocument) in NSDocumentController.shared.documents.contains { $0 === d } }
        let stopped = await DocumentWindowController.closeEach([a, b, c])
        check(!stopped && !open(a) && open(b) && open(c), "close all: the first closed, Cancel kept the changed one and the rest")
        b.testCloseAnswer = .dontSave
        let all = await DocumentWindowController.closeEach([b, c])
        check(all && !open(b) && !open(c), "close all: Don't Save closed the others (\(a.closeQuestions + b.closeQuestions + c.closeQuestions) questions)")
        controller.window?.makeKeyAndOrderFront(nil)
        await settle()
    }

    // MARK: Previous View, Next View

    /// Chooses a menu item as a person does: validated, then its action sent along the responder chain.
    @discardableResult
    private func choose(_ title: String) -> Bool {
        guard let item = menuItem(title), let action = item.action else { return false }
        let enabled = controller.validateMenuItem(item)
        if enabled { NSApp.sendAction(action, to: controller, from: item) }
        return enabled
    }

    private mutating func history() async {
        let pages = controller.pages
        let back = menuItem(loc("Previous View")), forward = menuItem(loc("Next View"))
        check(back?.keyEquivalent == "[" && forward?.keyEquivalent == "]" && back?.keyEquivalentModifierMask == .command,
              "history: Go › Previous View ⌘[ and Next View ⌘]")
        controller.go(0, record: false)
        pages.history.clear()
        await settle()
        check(!choose(loc("Previous View")), "history: nothing to go back to at first")
        controller.go(1) // a jump (Go to Page, a link, a bookmark)
        await settle()
        controller.nextPage(nil) // turning a page records nothing
        await settle()
        let jumped = pages.currentPage
        check(choose(loc("Previous View")), "history: Previous View enabled after a jump")
        await settle()
        check(pages.currentPage == 0, "history: Previous View returned to page 1 (on page \(pages.currentPage + 1))")
        check(choose(loc("Next View")), "history: Next View enabled after going back")
        await settle()
        check(pages.currentPage == jumped, "history: Next View came back to page \(jumped + 1) (on page \(pages.currentPage + 1))")
        check(!pages.history.canGoForward && pages.history.canGoBack, "history: nothing ahead, the jump still behind")
        let menu = pages.menu(for: NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1)!)
        if pages.selectedText == nil {
            check(menu?.items.contains { $0.action == #selector(DocumentWindowController.previousView(_:)) } == true,
                  "history: the pages' menu has Previous View and Next View")
        }
        controller.go(0, record: false)
        await settle()
    }

    // MARK: Highlight Form Fields

    private mutating func highlightFields() async {
        let docs = NSDocumentController.shared.documents.compactMap { $0.windowControllers.first as? DocumentWindowController }
        let plain = docs.first { $0.form.widgets.isEmpty }, form = docs.first { !$0.form.widgets.isEmpty }
        guard let item = menuItem(loc("Highlight Form Fields")) else { return check(false, "highlight fields: View › Highlight Form Fields in the menu") }
        if let plain { check(!plain.validateMenuItem(item), "highlight fields: off without form fields") }
        guard let form else { return check(false, "highlight fields: a document with fields open") }
        check(form.validateMenuItem(item) && item.state == .on && form.form.highlights, "highlight fields: on when a form opens, checked")
        form.toggleHighlightFields(nil)
        check(!form.form.highlights && form.validateMenuItem(item) && item.state == .off, "highlight fields: turned off, unchecked")
        form.toggleHighlightFields(nil)
        check(form.form.highlights, "highlight fields: on again")
    }

    // MARK: Keyboard Shortcuts, Open Log Folder

    private mutating func shortcutsAndLog() async {
        check(menuItem(loc("Keyboard Shortcuts"))?.keyEquivalent == "/", "shortcuts: Help › Keyboard Shortcuts is ⌘/")
        ShortcutsWindowController.show()
        await settle()
        guard let window = ShortcutsWindowController.shared else { return check(false, "shortcuts: the window opened") }
        let rows = window.rows
        let file = loc("File")
        check(rows.contains(ShortcutRow(file, loc("Close All"), "⌥⌘W")) && rows.contains { $0.name == loc("Hand") && $0.keys == "H" },
              "shortcuts: read from the menus, the tools' single keys too (\(rows.count) rows)")
        check(rows.suffix(ShortcutList.fixedRows.count) == ShortcutList.fixedRows[...], "shortcuts: the fixed rows at the end")
        window.filter.stringValue = "zoom"
        window.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        check(!window.shown.isEmpty && window.shown.count < rows.count && window.shown.allSatisfy { "\($0.group) \($0.name)".localizedCaseInsensitiveContains("zoom") },
              "shortcuts: the filter keeps \(window.shown.count) rows for zoom")
        window.close()
        let log = (try? String(contentsOf: AppLog.fileURL, encoding: .utf8)) ?? ""
        check(log.contains("Inkvolt PDF \(WhatsNew.version) started"), "log: the start written to the self-test's own log folder")
        check(menuItem(loc("Open Log Folder")).map { NSApp.delegate?.responds(to: $0.action!) == true } == true, "log: Help › Open Log Folder")
        check(ReportProblemWindowController.report().contains("started (macOS"), "log: Report a Problem copies the log's last lines")
    }

    // MARK: XPS, EPUB, CBZ, FB2, pictures

    private mutating func otherFormats() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-parity-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fb2 = dir.appendingPathComponent("Parity Story.fb2")
        let book = "<FictionBook xmlns=\"http://www.gribuser.ru/xml/fictionbook/2.0\"><body><section><p>Opened from FictionBook</p></section></body></FictionBook>"
        try? Data(book.utf8).write(to: fb2)
        check(Converting.handles(fb2),
              "other formats: an FB2 goes to the conversion, not to a document class")
        let before = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
        let opened: NSDocument? = await withCheckedContinuation { done in
            NSDocumentController.shared.openDocument(withContentsOf: fb2, display: true) { document, _, _ in done.resume(returning: document) }
        }
        let doc = opened as? PdfDocument ?? NSDocumentController.shared.documents.first { !before.contains(ObjectIdentifier($0)) } as? PdfDocument
        let text = doc.flatMap { d in try? d.session.map { s in try (0..<s.engine.pageCount).map { try s.engine.text($0).text }.joined() } } ?? ""
        check(doc?.displayName.hasPrefix("Parity Story") == true && doc?.fileURL == nil && text.contains("Opened from FictionBook"),
              "other formats: Open made a new PDF of the FB2 with its text (\(doc?.displayName ?? "none"))")
        doc?.testCloseAnswer = .dontSave
        if let doc { await DocumentWindowController.closeEach([doc]) }
        controller.window?.makeKeyAndOrderFront(nil)
        await settle()
    }

    // MARK: Black and white in File › Scan

    private mutating func blackAndWhiteScan() async {
        let listing = ScannerCapabilities(makeAndModel: "Example",
                                          platen: InputCaps(minWidth: 300, maxWidth: 2550, minHeight: 300, maxHeight: 3508,
                                                            colorModes: ["RGB24", "Grayscale8", "BlackAndWhite1"], resolutions: [300]),
                                          adf: nil, adfDuplex: false)
        check(ScanChoices.colors(listing, .platen).map(ScanChoices.colorLabel) == [loc("Color"), loc("Grayscale"), loc("Black and white")],
              "black and white: offered where the scanner lists it")
        // Two of the demo laser's pages: the first scanned in black and white, the second in grey.
        var jpegs: [[UInt8]] = []
        do {
            for try await page in DemoScanDevice(DemoScanDevice.laserScanner).scan(ScanRequest(source: .platen, color: .grayscale, resolution: 150)) {
                jpegs.append(page)
                if jpegs.count == 2 { break }
            }
        } catch {}
        guard let first = jpegs.first else { return check(false, "black and white: the demo scanner's pages") }
        let second = jpegs.count > 1 ? jpegs[1] : first
        let scanned = [(jpeg: first, dpi: 150, oneBit: true), (jpeg: second, dpi: 150, oneBit: false)]
        let images = scanned.map { (bytes: $0.jpeg, name: "page.jpg") }
        let pdf = (try? ScanWindowController.makePdf(scanned, images)) ?? []
        let text = String(decoding: pdf, as: UTF8.self)
        let oneBit = text.components(separatedBy: "/BitsPerComponent 1").count - 1, jpeg = text.components(separatedBy: "/DCTDecode").count - 1
        check(oneBit == 1 && jpeg == 1, "black and white: the black-and-white page saved at 1 bit, the grey one as its JPEG (\(pdf.count) bytes)")
    }
}
