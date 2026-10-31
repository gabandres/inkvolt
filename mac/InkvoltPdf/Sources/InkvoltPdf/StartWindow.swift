import AppKit
import PdfCore
import UniformTypeIdentifiers

/// The start page (the Windows app's, as a window of its own): shown when no document is open (at launch, after the last
/// one closes, File › New Window, or a click on the Dock icon). Open a file, the Tools grid (each tool asks for a PDF,
/// opens it and starts the tool, as the Windows cards do; Combine and Create a PDF make a new one), and the recent files
/// with page 1 of each. Files dropped on it open.
@MainActor
final class StartWindowController: NSWindowController, NSWindowDelegate {
    static var shared: StartWindowController?

    /// A Tools card: what it says and what it does.
    enum ToolCard: Int, CaseIterable {
        case fillSign, editContent, exportWord, combine, protect, ocr, organize, create, batch

        var title: String {
            switch self {
            case .fillSign: "Fill & sign"
            case .editContent: "Edit text & images"
            case .exportWord: "Export to Word"
            case .combine: "Combine files"
            case .protect: "Protect"
            case .ocr: "Recognize text (OCR)"
            case .organize: "Organize pages"
            case .create: "Create a PDF"
            case .batch: "Batch"
            }
        }

        var detail: String {
            switch self {
            case .fillSign: "Type on any form, add check marks and your signature"
            case .editContent: "Change the words and pictures already on a page"
            case .exportWord: "Turn a PDF into an editable .docx"
            case .combine: "Merge several files into one PDF, in your order"
            case .protect: "Require a password to open, print or change it"
            case .ocr: "Make a scan searchable and its text copyable"
            case .organize: "Reorder, rotate, delete, insert or extract pages"
            case .create: "From images, the clipboard or a scanner"
            case .batch: "The same actions on many files; presets and watched folders"
            }
        }

        var symbol: String {
            switch self {
            case .fillSign: "signature"
            case .editContent: "pencil.line"
            case .exportWord: "doc.richtext"
            case .combine: "doc.on.doc"
            case .protect: "lock"
            case .ocr: "text.viewfinder"
            case .organize: "square.grid.2x2"
            case .create: "doc.badge.plus"
            case .batch: "square.stack.3d.down.right"
            }
        }

        /// Starts the tool in a document's window (the cards that work on a PDF).
        @MainActor
        func run(in controller: DocumentWindowController) {
            switch self {
            case .fillSign: controller.chooseTool(Self.toolItem(.fillText))
            case .editContent: controller.chooseTool(Self.toolItem(.editContent))
            case .exportWord: controller.exportWord(nil)
            case .protect: controller.protectDocument(nil)
            case .ocr: controller.recognizeText(nil)
            case .organize: if !controller.organizerShown { controller.toggleOrganizer(nil) }
            case .combine, .create, .batch: break
            }
        }

        @MainActor
        private static func toolItem(_ tool: Tool) -> NSMenuItem {
            let item = NSMenuItem(title: tool.title, action: nil, keyEquivalent: "")
            item.tag = tool.rawValue
            return item
        }
    }

    /// The self-test's answers to the Open panels (each one's files, in turn; nil: ask the user).
    static var testPicks: [[URL]] = []
    /// The self-test's recent files (so a snapshot never shows the user's).
    static var testRecent: [URL]?

    let cards: [NSButton]
    private let recentStack = NSStackView()
    private let recentHeader = NSStackView()
    private let noRecent = NSStackView()
    /// The window a tool card last started its tool in (the self-test reads it).
    private(set) var lastToolWindow: DocumentWindowController?
    private var thumbnails: [URL: NSImage] = [:]

    static func show() {
        let controller = shared ?? StartWindowController()
        shared = controller
        controller.refreshRecent()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// A document opened: the start page steps aside.
    static func documentOpened() {
        shared?.window?.orderOut(nil)
    }

    /// A document closed: with none left, the start page comes back (not while the self-test or a quit closes them).
    static func documentClosed() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard NSDocumentController.shared.documents.isEmpty, !Report.isRunning, !AppDelegate.isTerminating else { return }
                show()
            }
        }
    }

    var isShown: Bool { window?.isVisible == true }

    init() {
        cards = ToolCard.allCases.map { CardButton(title: $0.title, detail: $0.detail, symbol: $0.symbol, height: 66) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 640), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Inkvolt PDF"
        window.minSize = NSSize(width: 640, height: 480)
        window.isRestorable = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        for (i, card) in cards.enumerated() {
            card.tag = i
            card.target = self
            card.action = #selector(cardClicked(_:))
        }
        window.contentView = makeContent()
        window.setFrameAutosaveName("InkvoltPdfStart")
        if !window.setFrameUsingName("InkvoltPdfStart") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func makeContent() -> NSView {
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let name = NSTextField(labelWithString: "Inkvolt PDF")
        name.font = .systemFont(ofSize: 24, weight: .semibold)
        let caption = NSTextField(labelWithString: "Read, search, print and organize PDFs. Nothing you open leaves this Mac unless you send it.")
        caption.textColor = .secondaryLabelColor
        let titles = NSStackView(views: [name, caption])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 2
        let header = NSStackView(views: [icon, titles])
        header.spacing = 16

        let open = CardButton(title: "Open a file", detail: "A PDF, or drop files here or on Inkvolt PDF in the Dock", symbol: "folder", height: 64)
        open.target = self
        open.action = #selector(openClicked)

        let toolsTitle = sectionTitle("Tools")
        let rows = stride(from: 0, to: cards.count, by: 4).map { Array(cards[$0..<min($0 + 4, cards.count)]) as [NSView] }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for card in cards { card.widthAnchor.constraint(equalToConstant: 190).isActive = true }

        let clear = NSButton(title: "Clear List", target: self, action: #selector(clearRecent))
        clear.bezelStyle = .accessoryBarAction
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        recentHeader.setViews([sectionTitle("Recent"), spacer, clear], in: .leading)
        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 8
        let empty = NSTextField(labelWithString: "Files you open will appear here.")
        empty.textColor = .secondaryLabelColor
        let tip = NSTextField(wrappingLabelWithString: "New here? Press ⇧⌘K and type what you want to do: fill, sign, edit text, export to Word, "
            + "protect, scan. Every command is in the menus too.")
        tip.preferredMaxLayoutWidth = 640
        noRecent.setViews([empty, tip], in: .leading)
        noRecent.orientation = .vertical
        noRecent.alignment = .leading
        noRecent.spacing = 12

        let stack = NSStackView(views: [header, open, toolsTitle, grid, recentHeader, recentStack, noRecent])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(28, after: header)
        stack.setCustomSpacing(24, after: open)
        stack.setCustomSpacing(24, after: grid)
        stack.edgeInsets = NSEdgeInsets(top: 32, left: 40, bottom: 32, right: 40)
        open.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        recentHeader.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        let drop = DropView()
        drop.onDrop = { urls in StartWindowController.openDropped(urls) }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let flipped = FlippedView()
        flipped.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        flipped.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = flipped
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(greaterThanOrEqualTo: stack.widthAnchor),
            flipped.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor),
        ])
        drop.addSubview(scroll)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: drop.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: drop.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: drop.topAnchor), scroll.bottomAnchor.constraint(equalTo: drop.bottomAnchor),
        ])
        return drop
    }

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        return label
    }

    // MARK: Recent files

    var recentURLs: [URL] {
        let all = Self.testRecent ?? NSDocumentController.shared.recentDocumentURLs
        return Array(all.filter { FileManager.default.fileExists(atPath: $0.path) }.prefix(12))
    }

    /// The recent list as cards (page 1 of each, drawn in the background), four to a row.
    func refreshRecent() {
        let urls = recentURLs
        recentHeader.isHidden = urls.isEmpty
        noRecent.isHidden = !urls.isEmpty
        let buttons = urls.map { url -> NSButton in
            let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
            let card = CardButton(title: url.lastPathComponent, detail: folder, symbol: "doc.richtext", height: 92)
            card.image = thumbnails[url] ?? NSWorkspace.shared.icon(forFile: url.path)
            card.toolTip = url.path
            card.target = self
            card.action = #selector(recentClicked(_:))
            card.identifier = NSUserInterfaceItemIdentifier(url.path)
            card.menu = recentMenu(url)
            return card
        }
        var rows: [NSView] = []
        for start in stride(from: 0, to: buttons.count, by: 4) {
            let row = NSStackView(views: Array(buttons[start..<min(start + 4, buttons.count)]))
            row.spacing = 8
            row.distribution = .fillEqually
            for b in row.arrangedSubviews { b.widthAnchor.constraint(equalToConstant: 190).isActive = true }
            rows.append(row)
        }
        recentStack.setViews(rows, in: .top)
        for url in urls where thumbnails[url] == nil { loadThumbnail(url) }
    }

    var recentCount: Int { recentStack.arrangedSubviews.reduce(0) { $0 + (($1 as? NSStackView)?.arrangedSubviews.count ?? 0) } }

    private func loadThumbnail(_ url: URL) {
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) { () -> RenderedImage? in
                guard let data = FileManager.default.contents(atPath: url.path), let engine = try? PdfEngine.open([UInt8](data)) else { return nil }
                defer { engine.close() }
                guard engine.pageCount > 0 else { return nil }
                let g = engine.page(0)
                let scale = min(56 / max(g.width, 1), 72 / max(g.height, 1)) * 2
                return try? engine.render(0, scale: scale)
            }.value
            guard let self, let image, let cg = PageRenderer.cgImage(image) else { return }
            let picture = NSImage(cgImage: cg, size: NSSize(width: Double(cg.width) / 2, height: Double(cg.height) / 2))
            self.thumbnails[url] = picture
            for case let row as NSStackView in self.recentStack.arrangedSubviews {
                for case let card as NSButton in row.arrangedSubviews where card.identifier?.rawValue == url.path { card.image = picture }
            }
        }
    }

    private func recentMenu(_ url: URL) -> NSMenu {
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open", action: #selector(recentMenuOpen(_:)), keyEquivalent: "")
        let show = NSMenuItem(title: "Show in Finder", action: #selector(recentMenuShow(_:)), keyEquivalent: "")
        for item in [open, show] {
            item.target = self
            item.representedObject = url
            menu.addItem(item)
        }
        return menu
    }

    @objc private func recentClicked(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        Self.open(URL(fileURLWithPath: path))
    }

    @objc private func recentMenuOpen(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { Self.open(url) }
    }

    @objc private func recentMenuShow(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func clearRecent() {
        if Self.testRecent != nil { Self.testRecent = [] } else { NSDocumentController.shared.clearRecentDocuments(nil) }
        refreshRecent()
    }

    // MARK: Opening

    @objc func openClicked() {
        if Report.isRunning, !Self.testPicks.isEmpty {
            for url in Self.testPicks.removeFirst() { Self.open(url) }
            return
        }
        NSDocumentController.shared.openDocument(nil)
    }

    /// An Open panel, or the self-test's next answer: the files chosen, nil when cancelled.
    static func pick(_ panel: NSOpenPanel) -> [URL]? {
        if Report.isRunning { return testPicks.isEmpty ? nil : testPicks.removeFirst() }
        return panel.runModal() == .OK && !panel.urls.isEmpty ? panel.urls : nil
    }

    /// Opens `url` (or brings its window forward), then hands its window to `then` once it's shown.
    static func open(_ url: URL, then: (@MainActor (DocumentWindowController) -> Void)? = nil) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, _ in
            MainActor.assumeIsolated {
                guard let then, let pdf = document as? PdfDocument else { return }
                Task { @MainActor in
                    // The window fits its pages just after it's shown; then the tool starts.
                    for _ in 0..<60 {
                        if let c = pdf.windowControllers.first as? DocumentWindowController, c.window?.isVisible == true {
                            try? await Task.sleep(for: .milliseconds(300))
                            then(c)
                            return
                        }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
        }
    }

    /// Files dropped on the start page: PDFs open; pictures become a new PDF.
    static func openDropped(_ urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        let images = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
        for url in pdfs { open(url) }
        if !images.isEmpty { NewDocuments.fromImages(images) }
    }

    @objc func cardClicked(_ sender: NSButton) {
        guard let card = ToolCard(rawValue: sender.tag) else { return }
        switch card {
        case .combine:
            _ = CombineWindowController.show()
        case .batch:
            BatchWindowController.show()
        case .create:
            let menu = NSMenu()
            for (title, action) in [("From Images…", #selector(AppDelegate.newFromImages(_:))),
                                    ("From the Clipboard", #selector(AppDelegate.newFromClipboard(_:))),
                                    ("From a Scanner…", #selector(AppDelegate.scan(_:)))] {
                menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        default:
            runOnFile(card)
        }
    }

    /// A card that works on a PDF: asks for one, opens it and starts the tool there.
    func runOnFile(_ card: ToolCard) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Choose a PDF: \(card.title)"
        guard let url = Self.pick(panel)?.first else { return }
        Self.open(url) { [weak self] controller in
            self?.lastToolWindow = controller
            card.run(in: controller)
        }
    }
}

/// A card: a symbol (or picture) beside a bold title and a line of detail; a button for VoiceOver.
final class CardButton: NSButton {
    convenience init(title: String, detail: String, symbol: String, height: Double) {
        self.init(frame: .zero)
        bezelStyle = .flexiblePush
        setButtonType(.momentaryPushIn)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 20, weight: .regular))
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        alignment = .left
        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byWordWrapping
        let text = NSMutableAttributedString(string: title + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 13), .paragraphStyle: para])
        text.append(NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                                                   .paragraphStyle: para]))
        attributedTitle = text
        (cell as? NSButtonCell)?.wraps = true
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        setAccessibilityLabel(title)
        setAccessibilityHelp(detail)
        toolTip = detail
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }
}

/// Takes files dropped on it.
final class DropView: NSView {
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

/// A document view that starts at the top.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
