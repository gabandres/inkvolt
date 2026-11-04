import AppKit
import PdfCore
import UniformTypeIdentifiers

/// A document's window (a tab when several are open): the sidebar (thumbnails, outline, comments) beside the pages, with
/// the tools strip, the "changed on disk" bar and the find bar over them; zoom, page moves, find, the tools and the
/// comment commands come here through the responder chain.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, PagesHost, NSMenuItemValidation, NSPopoverDelegate {
    let pdf: PdfDocument
    let editor: DocumentEditor
    let pages: PagesView
    let scrollView: NSScrollView
    let sidebar: SidebarController
    let findBar = FindBar()
    let toolStrip = ToolStrip()
    let diskBar = DiskBar()
    let noticeBar = NoticeBar()
    /// The redaction marks' bar, and what the redaction commands keep (Redaction.swift).
    let redactBar = RedactBar()
    let redaction = RedactionState()
    let measure = MeasureState()
    /// The AI assistant's pane, conversation and running request (AiAssistant.swift), and Summarize's page question.
    let ai = AiState()
    var aiSummaryAlert: (alert: NSAlert, field: NSTextField)?
    /// Prepare Form's bar, panel and fields.
    var design: PrepareForm {
        if let made = madeDesign { return made }
        let made = PrepareForm(controller: self)
        madeDesign = made
        return made
    }
    /// Prepare Form if it was ever opened (closing asks it for an arrow-key move not yet written).
    private(set) var madeDesign: PrepareForm?
    /// Read Aloud and its bar (ReadAloud.swift).
    private(set) lazy var readAloud = ReadAloud(controller: self)
    /// The Reading Order and Alt Text pane (ReadingOrder.swift).
    private(set) lazy var readingOrder = ReadingOrderPane(controller: self)
    /// The document's signatures as verified, and a signing in progress (DigitalSigning.swift).
    let signing = SigningState()
    /// The form's fields on the pages, and Edit Text & Images.
    private(set) var form: FormFiller!
    private(set) var content: ContentEditing!
    /// The progress sheet of the recognition or export running, and the last export's report (the self-test reads them).
    var progressSheet: ProgressSheet?
    var lastExport: ExportReport?
    /// A long task started from a menu (the self-test awaits it).
    private(set) var longTask: Task<Void, Never>?
    private var signatureSheet: SignatureSheet?
    let split = NSSplitViewController()
    private var diskTimer: Timer?
    private var ignoredDiskState: String?
    private(set) var inspector: InspectorController?
    private var inspectorPopover: NSPopover?
    private var askPopover: NSPopover?
    /// The page grid (Pages > Organize Pages), made the first time it is shown, and the stack it shows in.
    var organizer: OrganizerView?
    var contentStack: NSStackView?
    /// The Protect with Password sheet while it is open.
    var protectSheet: ProtectSheet?
    /// The self-test: addresses that links opened (nil: open them for real), and its answer to "Open this link?".
    var testOpenedLinks: [String]?
    var testLinkAnswer = false
    /// How many times "Open this link?" was asked.
    private(set) var linkQuestions = 0

    // E9 (AttachmentsLayers.swift): the layers read, the ones the person changed (by name: object numbers change when an
    // edit writes the file whole), the engine drawing them, and what the self-test reads.
    var layerList: [LayerInfo] = []
    var layerOrder: [LayerOrderNode] = []
    var layerChoice: [String: Bool] = [:]
    var layerTicket = 0
    var layerEngine: PdfEngine?
    var layersApplied = 0
    var lastSavedAttachment: URL?
    var lastProblem: String?

    // E13 (SplitView.swift): the panes' split view (the main pane's scroll view alone until View › Split View), the second
    // pane while the view is split, how, and which pane navigation acts on.
    let paneSplit = PaneSplitView()
    var secondPages: PagesView?
    var secondScroll: NSScrollView?
    var secondBox: NSView?
    var splitMode: SplitMode = .none
    var secondActive = false

    /// The engine over the document's current bytes (replaced after every edit, undo, redo and reload).
    var engine: PdfEngine { pages.engine }

    /// Find results across the document, the one shown, and the query they're for.
    private(set) var found: [(page: Int, start: Int, end: Int)] = []
    private(set) var foundIndex = -1
    private var foundQuery = ""
    private var findGeneration = 0
    /// The search under way, stopped when another starts or the bar closes.
    private var findCancel: CancelToken?
    /// Called when a find has finished (the self-test waits on it).
    var onFindFinished: (() -> Void)?
    /// Extract and Split asked once whether to write a protected document's pages without its password (Windows: per tab).
    var unprotectedConfirmed = false
    /// The self-test's answers to the text and link popovers (nil: ask the user).
    var testText: String?
    var testLink: (uri: String?, page: Int)?

    init(document: PdfDocument) {
        pdf = document
        let engine = document.engine!
        editor = DocumentEditor(document: document)
        pages = PagesView(engine: engine)
        scrollView = NSScrollView()
        sidebar = SidebarController(engine: engine) { [weak document] in
            guard let s = document?.session else { return [] }
            return (try? Bookmarks.read(s.data, s.password)) ?? []
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "InkvoltPdfDocument"
        window.minSize = NSSize(width: 560, height: 360)
        window.isRestorable = !Report.isRunning // the self-test's documents never come back at the next launch
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true

        scrollView.contentView = CenteringClipView()
        scrollView.documentView = pages
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.drawsBackground = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification,
                                               object: scrollView)

        let content = NSViewController()
        paneSplit.addPane(scrollView)
        let stack = NSStackView(views: [diskBar, noticeBar, redactBar, findBar, design.bar, readAloud.bar, paneSplit])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        // Just under required: a bar, shown or hidden, never sets the window's minimum width (Prepare Form's bar held
        // every document window at 850 points or more, the markup strip at 1,300; UX review, 2026-11-03).
        for v in [diskBar, noticeBar, redactBar, findBar, design.bar, readAloud.bar, paneSplit] {
            let same = v.widthAnchor.constraint(equalTo: stack.widthAnchor)
            same.priority = v === paneSplit ? .required : .init(999)
            same.isActive = true
            v.setContentCompressionResistancePriority(.init(250), for: .horizontal)
            // A bar's row may clip at its right end in a narrow window rather than widen it.
            for case let row as NSStackView in v.subviews where v !== paneSplit {
                row.setClippingResistancePriority(.defaultLow, for: .horizontal)
            }
        }
        findBar.isHidden = true
        diskBar.isHidden = true
        noticeBar.isHidden = true
        content.view = stack
        contentStack = stack
        findBar.onSearch = { [weak self] query in self?.find(query) }
        findBar.onNext = { [weak self] in self?.step(1) }
        findBar.onPrevious = { [weak self] in self?.step(-1) }
        findBar.onDone = { [weak self] in self?.hideFind() }

        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 200
        side.maximumThickness = 360
        split.addSplitViewItem(side)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        split.addSplitViewItem(design.panelItem)
        split.addSplitViewItem(readingOrder.panelItem)
        sidebar.onGo = { [weak self] page, y in self?.go(page, targetY: y) }
        sidebar.dragSourceId = pdf.recoveryId
        sidebar.canDropPages = { [weak self] in self.map { $0.pdf.session != nil && $0.longTask == nil && $0.progressSheet == nil } ?? false }
        sidebar.onDropPages = { [weak self] source, pages, before in self?.dropPages(source, pages, before: before) }
        sidebar.onDropFiles = { [weak self] urls, before in self?.insertFiles(urls, at: before) }
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 820))
        window.setFrameAutosaveName("InkvoltPdfDocument")
        makeToolbar()

        pages.editor = editor
        pages.host = self
        pages.onActivate = { [weak self] in self?.activatePane(second: false) }
        form = FormFiller(controller: self)
        self.content = ContentEditing(controller: self)
        pages.form = form
        pages.content = self.content
        pages.design = design
        form.reload()
        noticeBar.onUndo = { [weak self] in self?.pdf.undo() }
        wireTools()
        wireRedaction()
        wireComments()
        wireBookmarks()
        sidebar.signatures.onGo = { [weak self] info in self?.goToSignature(info) }
        sidebar.signatures.onSign = { [weak self] field in self?.signDigitally(field: field) }
        verifySignatures(onOpen: true)
        wireAttachmentsAndLayers()
        wireSuspectWords()
        sidebar.pageMenuMaker = { [weak self] in self?.pageMenu() }
        document.onContentChanged = { [weak self] change in self?.contentChanged(change) }
        editor.onChanged = { [weak self] in self?.commentsChanged() }
        commentsChanged()
        toolChanged()
        updateSubtitle()
        Report.documentOpened(self, name: document.name)
        StartWindowController.documentOpened()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Fit the width once the window has its size (pages narrower than the window stay at actual size).
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.pages.setReadingMode(PagesView.ReadingMode(rawValue: AppSettings.readingMode) ?? .continuous)
                self.applyOpeningZoom()
                var page = self.pdf.startPage
                if !Report.isRunning || AppTest.isActive, let path = self.pdf.fileURL?.path {
                    if page == 0, let last = AppSettings.lastPage(path) { page = last }
                    if let turn = AppSettings.lastRotation(path) { self.pages.setViewRotation(turn) }
                }
                if page > 0 { self.go(min(page, self.engine.pageCount - 1)) }
                self.pages.requestVisible()
                self.window?.makeFirstResponder(self.pages)
            }
        }
        diskTimer?.invalidate()
        diskTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkDisk() }
        }
    }

    /// Reopen at last page: the page this file was left at, and the view's turn.
    func rememberPosition() {
        guard let path = pdf.fileURL?.path else { return }
        AppSettings.remember(page: pages.currentPage, rotation: pages.viewRotation, for: path)
    }

    // MARK: Rotate view

    /// View › Rotate View Clockwise (⇧⌘R) and Counterclockwise (⇧⌘L): the active pane's view only, never the file.
    @objc func rotateViewClockwise(_ sender: Any?) { activePages.rotateView(clockwise: true); scrolled() }
    @objc func rotateViewCounterclockwise(_ sender: Any?) { activePages.rotateView(clockwise: false); scrolled() }

    // MARK: Reading modes

    /// View › Single Page (⌘4), Continuous (⌘5), Two Pages (⌘6), Two Pages with Cover (⌘7): the active pane's layout,
    /// kept as the setting new windows open with (as Windows).
    @objc func singlePageMode(_ sender: Any?) { setReadingMode(.single) }
    @objc func continuousMode(_ sender: Any?) { setReadingMode(.continuous) }
    @objc func twoPagesMode(_ sender: Any?) { setReadingMode(.twoPages) }
    @objc func coverMode(_ sender: Any?) { setReadingMode(.cover) }

    func setReadingMode(_ mode: PagesView.ReadingMode) {
        if organizerShown { showOrganizer(false) }
        activePages.setReadingMode(mode)
        AppSettings.readingMode = mode.rawValue
        scrolled()
    }

    /// View › Dark Pages (Night Reading): every window's pages, thumbnails and organizer, kept as a setting.
    @objc func toggleDarkPages(_ sender: Any?) { AppSettings.setDarkPages(!AppSettings.darkPages) }

    func windowWillClose(_ notification: Notification) {
        // Reopen at last page: where this file was left.
        if !Report.isRunning || AppTest.isActive { rememberPosition() }
        progressSheet?.cancelClicked()
        readAloud.stop()
        ai.cancel?.cancel()
        ai.pageTexts.clear()
        form.cancelEditor()
        diskTimer?.invalidate()
        inspectorPopover?.close()
        askPopover?.close()
        pages.renderer.cancelAll()
        secondPages?.renderer.cancelAll()
        sidebar.stop()
        organizer?.stop()
        NotificationCenter.default.removeObserver(self)
    }

    func windowDidBecomeKey(_ notification: Notification) { checkDisk() }

    /// Edit › Undo and Redo: the document's session steps.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { pdf.undoBridge }

    // MARK: Content changes

    /// An edit, undo, redo or reload replaced the engine: the pages, thumbnails, comments and find follow.
    private func contentChanged(_ change: ContentChange) {
        guard let engine = pdf.engine else { return }
        // What was being read may be gone or moved: reading stops, as on Windows.
        if readAloud.isActive { readAloud.stop() }
        editor.reload()
        form.reload()
        content.invalidate()
        pages.reload(engine: engine)
        secondPages?.reload(engine: engine)
        sidebar.reload(engine: engine)
        organizer?.reload(engine: engine)
        design.contentChanged()
        readingOrder.contentChanged()
        if !foundQuery.isEmpty { find(foundQuery) }
        if change == .reload { hideDiskBar() }
        verifySignatures(onOpen: change == .reload)
        refreshAttachmentsAndLayers()
        refreshSuspectWords()
        updateSubtitle()
    }

    private func commentsChanged() {
        sidebar.comments.show(editor.comments, selected: pages.selectedId)
        inspector?.refresh()
        toolChanged() // the strip shows the selected comment's new look
        pages.needsDisplay = true
    }

    // MARK: Tools

    private func wireTools() {
        toolStrip.onTool = { [weak self] tool in
            guard let self else { return }
            self.pickTool(tool)
        }
        toolStrip.onColor = { [weak self] color in self?.applyColor(color) }
        toolStrip.onWidth = { [weak self] width in self?.applyWidth(width) }
        toolStrip.onStampMenu = { [weak self] view, rect in self?.popUp(self?.stampMenu(), view, rect) }
        toolStrip.onImageMenu = { [weak self] view, rect in self?.popUp(self?.imageMenu(), view, rect) }
        toolStrip.onSignatureMenu = { [weak self] view, rect in self?.popUp(self?.signatureMenu(), view, rect) }
        wireMeasuring()
    }

    /// Adds a panel on the right, as the AI assistant's when it is first opened.
    func addSidePanel(_ item: NSSplitViewItem) { split.addSplitViewItem(item) }

    /// Says what just happened in the bar over the pages.
    func notify(_ message: String, canUndo: Bool = false) {
        Report.progress("notice: \(message.prefix(160))")
        noticeBar.show(message, canUndo: canUndo)
    }

    /// Runs a long task started from a menu (one at a time).
    func startLongTask(_ work: @escaping @MainActor () async -> Void) {
        guard longTask == nil else { return NSSound.beep() }
        longTask = Task { @MainActor in
            await work()
            self.longTask = nil
        }
    }

    // MARK: Fill & Sign signatures

    /// The Signature menu, as Windows' Sign menu: the saved signatures and initials to place, ways to add them,
    /// deleting one, Sign Digitally.
    func signatureMenu() -> NSMenu {
        let menu = NSMenu(title: "Signature")
        menu.autoenablesItems = false
        let library = SignatureLibrary.shared
        let saved = library.saved
        for s in saved {
            let item = NSMenuItem(title: s.name, action: #selector(placeSavedSignature(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = s.path
            item.image = SignatureImages.thumbnail(s)
            item.setAccessibilityLabel("Place \(s.name)")
            menu.addItem(item)
        }
        if !saved.isEmpty { menu.addItem(.separator()) }
        let full = library.isFull
        let hasInitials = saved.contains { $0.initials }
        let entries: [(String, Selector, Bool)] = [
            ("Draw Signature…", #selector(drawSignature(_:)), !full), ("Type Signature…", #selector(typeSignature(_:)), !full),
            (hasInitials ? "Draw New Initials…" : "Draw Initials…", #selector(drawInitials(_:)), true),
            (hasInitials ? "Type New Initials…" : "Type Initials…", #selector(typeInitials(_:)), true),
        ]
        for entry in entries {
            let item = NSMenuItem(title: entry.0, action: entry.1, keyEquivalent: "")
            item.target = self
            item.isEnabled = entry.2
            if !entry.2 { item.toolTip = "Up to \(SavedSignatures.maxSignatures) signatures: delete one first." }
            menu.addItem(item)
        }
        if !saved.isEmpty {
            let delete = NSMenuItem(title: "Delete a Saved Signature", action: nil, keyEquivalent: "")
            let sub = NSMenu(title: "Delete a Saved Signature")
            for s in saved {
                let item = NSMenuItem(title: s.name, action: #selector(deleteSavedSignature(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s.path
                item.image = SignatureImages.thumbnail(s)
                sub.addItem(item)
            }
            delete.submenu = sub
            menu.addItem(delete)
        }
        menu.addItem(.separator())
        let sign = NSMenuItem(title: "Sign Digitally…", action: #selector(signDigitally(_:)), keyEquivalent: "")
        sign.target = self
        menu.addItem(sign)
        return menu
    }

    @objc func drawSignature(_ sender: Any?) { showSignatureSheet(initials: false, typing: false) }
    @objc func typeSignature(_ sender: Any?) { showSignatureSheet(initials: false, typing: true) }
    @objc func drawInitials(_ sender: Any?) { showSignatureSheet(initials: true, typing: false) }
    @objc func typeInitials(_ sender: Any?) { showSignatureSheet(initials: true, typing: true) }

    private func savedSignature(_ sender: Any?) -> SavedSignature? {
        guard let path = (sender as? NSMenuItem)?.representedObject as? String else { return nil }
        return SignatureLibrary.shared.saved.first { $0.path == path }
    }

    @objc func placeSavedSignature(_ sender: Any?) {
        guard let s = savedSignature(sender) else { return }
        armSignature(s)
    }

    @objc func deleteSavedSignature(_ sender: Any?) {
        guard let s = savedSignature(sender) else { return }
        deleteSaved(s, ask: !Report.isRunning)
    }

    /// Deletes a saved signature after asking (signatures already placed in documents stay).
    func deleteSaved(_ s: SavedSignature, ask: Bool) {
        if ask {
            let alert = NSAlert()
            alert.messageText = "Delete \(s.name)?"
            alert.informativeText = "It is removed from this Mac. Signatures already placed in documents stay."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        do {
            try SignatureLibrary.shared.delete(s)
        } catch {
            problemAlert("Couldn't delete it", error.localizedDescription)
        }
    }

    private func problemAlert(_ message: String, _ detail: String) {
        if Report.skipsDialogs { return notify("\(message). \(detail)") }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    /// The sheet that makes a signature or initials; once made, it is saved and the next click puts it down.
    @discardableResult
    func showSignatureSheet(initials: Bool, typing: Bool) -> SignatureSheet? {
        guard let window, signatureSheet == nil else { return nil }
        if !initials && SignatureLibrary.shared.isFull {
            problemAlert("No room for another signature", "Up to \(SavedSignatures.maxSignatures) signatures can be saved: delete one first.")
            return nil
        }
        let sheet = SignatureSheet(initials: initials, typing: typing)
        signatureSheet = sheet
        sheet.done = { [weak self] image in
            guard let self else { return }
            self.signatureSheet = nil
            guard let image else { return }
            do {
                if let saved = try SignatureLibrary.shared.save(image, initials: initials) {
                    self.armSignature(saved, image: image)
                } else {
                    self.problemAlert("No room for another signature", "Up to \(SavedSignatures.maxSignatures) signatures can be saved: delete one first.")
                }
            } catch {
                self.problemAlert("Couldn't save the signature", error.localizedDescription)
            }
        }
        if let panel = sheet.window { window.beginSheet(panel) }
        return sheet
    }

    /// The Signature tool with a saved signature (or initials): the next click on a page puts it there.
    func armSignature(_ saved: SavedSignature, image: StampImage? = nil) {
        guard let image = image ?? SignatureLibrary.shared.image(saved) else {
            problemAlert("Couldn't read \(saved.name)", "Its picture can't be read. Delete it and add it again.")
            return
        }
        pages.pendingSignature = (image, saved.initials)
        pages.tool = .signature
        window?.makeFirstResponder(pages)
        notify("Click where the \(saved.initials ? "initials go" : "signature goes"). Drag it with the hand tool to move it; Delete removes it.")
    }

    func askSignature() {
        if let spot = toolStrip.frame(of: .signature) { popUp(signatureMenu(), spot.0, spot.1) }
    }

    // MARK: Form data

    @objc func resetForm(_ sender: Any?) { form.resetForm(sender) }

    // Export Form Data…, Import Form Data… and Fill Forms from CSV…: FormDataActions.swift.

    private func popUp(_ menu: NSMenu?, _ view: NSView, _ rect: NSRect) {
        let y: CGFloat = view.isFlipped ? rect.maxY + 4 : rect.minY - 4
        menu?.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: y), in: view)
    }

    func toolChanged() {
        let tool = pages.tool
        var style = pages.styles.style(tool)
        if tool == .textBox { style.color = style.textColor } // the strip's color is the text's
        revealMarkup(for: tool)
        toolStrip.show(tool, style: style, stamp: pages.stamp.label)
        design.toolChanged()
        updateRedactBar()
        if let id = pages.selectedId, let c = editor.comment(id), DocumentEditor.recolorable(c) {
            toolStrip.showStyle(AnnotStyle(color: c.color ?? .yellow, width: 1), usesWidth: false, usesColor: true)
        } else if let id = pages.selectedId, let style = editor.comment(id)?.style {
            toolStrip.showStyle(style, usesWidth: true, usesColor: true)
        }
    }

    func selectionChanged() {
        sidebar.comments.showSelected(pages.selectedId)
        if let inspector, inspector.id != pages.selectedId { inspectorPopover?.close() }
        toolChanged()
    }

    /// A color from the strip: the selected drawing's (one undo step), else the current tool's next comments.
    func applyColor(_ color: AnnotColor?) {
        guard let color else { return }
        if let id = pages.selectedId, let c = editor.comment(id), DocumentEditor.recolorable(c) {
            Task { await editor.setColor(id, color) }
            return
        }
        if let id = pages.selectedId, let c = editor.comment(id), var style = c.style {
            if c.subtype == "FreeText" && style.color == nil { style.textColor = color } else { style.color = color }
            Task { await editor.setStyle(id, style, label: "Change Color") }
            return
        }
        var style = pages.styles.style(pages.tool)
        if pages.tool == .textBox { style.textColor = color } else { style.color = color }
        pages.styles.set(pages.tool, style)
        toolChanged()
        pages.needsDisplay = true
    }

    func applyWidth(_ width: Double) {
        if let id = pages.selectedId, var style = editor.comment(id)?.style {
            style.width = width
            Task { await editor.setStyle(id, style, label: "Change Width") }
            return
        }
        var style = pages.styles.style(pages.tool)
        style.width = width
        pages.styles.set(pages.tool, style)
        toolChanged()
    }

    /// Tools › a tool (its single key while the pages have the focus).
    @objc func chooseTool(_ sender: NSMenuItem) {
        guard let tool = Tool(rawValue: sender.tag) else { return }
        pickTool(tool)
        if tool == .stamp, let spot = toolStrip.frame(of: .stamp) { popUp(stampMenu(), spot.0, spot.1) }
        if tool == .image && pages.pendingImage == nil { chooseImageFile(nil) }
        if tool == .signature && pages.pendingSignature == nil { askSignature() }
        if tool == .editContent { notify("Click text to change it, or a picture to move, replace or delete it.") }
        if tool.measureTool != nil { notify("\(tool.help).") }
    }

    func stampMenu() -> NSMenu {
        let menu = NSMenu(title: "Stamp")
        let designs = RubberStamps.builtIn + [RubberStamps.approvedBy(editor.author, Date())]
        for (i, design) in designs.enumerated() {
            let title = design.detail == nil ? design.label : "Approved by \(editor.author)"
            let item = NSMenuItem(title: title, action: #selector(stampPicked(_:)), keyEquivalent: "")
            item.tag = i
            item.target = self
            item.state = pages.stamp.label == design.label && pages.stamp.detail == design.detail ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc func stampPicked(_ sender: NSMenuItem) {
        let designs = RubberStamps.builtIn + [RubberStamps.approvedBy(editor.author, Date())]
        guard sender.tag < designs.count else { return }
        pages.stamp = designs[sender.tag]
        pages.tool = .stamp
        toolChanged()
    }

    func imageMenu() -> NSMenu {
        let menu = NSMenu(title: "Image")
        let file = NSMenuItem(title: "Choose Picture…", action: #selector(chooseImageFile(_:)), keyEquivalent: "")
        file.target = self
        let paste = NSMenuItem(title: "Picture from Clipboard", action: #selector(imageFromClipboard(_:)), keyEquivalent: "")
        paste.target = self
        menu.addItem(file)
        menu.addItem(paste)
        return menu
    }

    @objc func chooseImageFile(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a picture, then click where it goes."
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
                self.usePicture(image)
            }
        }
    }

    @objc func imageFromClipboard(_ sender: Any?) {
        guard let image = NSImage(pasteboard: .general) else {
            NSSound.beep()
            return
        }
        usePicture(image)
    }

    /// The Image tool puts `image` down at the next click.
    func usePicture(_ image: NSImage) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil), let stamp = Pictures.stampImage(cg) else {
            pdf.showError("That picture can't be used.", nil)
            return
        }
        pages.pendingImage = stamp
        pages.tool = .image
        window?.makeFirstResponder(pages)
    }

    @objc func highlightText(_ sender: Any?) { markOrChoose(.highlight) }
    @objc func underlineText(_ sender: Any?) { markOrChoose(.underline) }
    @objc func strikeOutText(_ sender: Any?) { markOrChoose(.strikeOut) }

    /// Marks the selected text, or (nothing selected) picks the tool.
    private func markOrChoose(_ kind: TextMarkupKind) {
        if pages.selectedText != nil {
            pages.markSelection(kind)
        } else {
            pages.tool = kind == .highlight ? .highlight : kind == .underline ? .underline : .strikeOut
        }
    }

    /// Tools › Link Selected Text…: one link over the selected lines.
    @objc func linkSelectedText(_ sender: Any?) {
        guard let lines = pages.selectedLines, let first = lines.rects.first else {
            NSSound.beep()
            return
        }
        let anchor = pages.viewRect(first, pages.pageRects[lines.page])
        askLink(at: anchor) { [weak self] uri, target in
            guard let self else { return }
            self.pages.clearSelection()
            self.pages.startEdit {
                await self.editor.run("Add Link") { data, pw in
                    try Links.putOnText(data, pw, lines.page, lines.rects, uri: uri, targetPage: target)
                }
            }
        }
    }

    @objc func openInspector(_ sender: Any?) {
        guard let id = pages.selectedId else {
            NSSound.beep()
            return
        }
        showInspector(id)
    }

    @objc func replyToSelected(_ sender: Any?) {
        guard let id = pages.selectedId else { return }
        askReply(id)
    }

    @objc func showComments(_ sender: Any?) {
        if let item = split.splitViewItems.first, item.isCollapsed { item.animator().isCollapsed = false }
        sidebar.show(.comments)
    }

    @objc func showSignatures(_ sender: Any?) {
        if let item = split.splitViewItems.first, item.isCollapsed { item.animator().isCollapsed = false }
        sidebar.show(.signatures)
    }

    /// The sidebar's Accessibility pane (its segment appears with the first check).
    func showAccessibilityPane() {
        if let item = split.splitViewItems.first, item.isCollapsed { item.animator().isCollapsed = false }
        sidebar.showAccessibility()
    }

    @objc func showBookmarks(_ sender: Any?) {
        if let item = split.splitViewItems.first, item.isCollapsed { item.animator().isCollapsed = false }
        sidebar.show(.bookmarks)
    }

    @objc func nextComment(_ sender: Any?) { pages.selectNext(1) }
    @objc func previousComment(_ sender: Any?) { pages.selectNext(-1) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let split = validateSplitItem(item) { return split }
        switch item.action {
        case #selector(toggleMarkup(_:)):
            item.title = toolStrip.isHidden ? "Show Markup Toolbar" : "Hide Markup Toolbar"
            return pdf.session != nil && !organizerShown
        case #selector(rotateViewClockwise(_:)), #selector(rotateViewCounterclockwise(_:)), #selector(goToPage(_:)):
            return engine.pageCount > 0
        case #selector(singlePageMode(_:)), #selector(continuousMode(_:)), #selector(twoPagesMode(_:)), #selector(coverMode(_:)):
            let modes: [Selector: PagesView.ReadingMode] = [#selector(singlePageMode(_:)): .single, #selector(continuousMode(_:)): .continuous,
                                                            #selector(twoPagesMode(_:)): .twoPages, #selector(coverMode(_:)): .cover]
            item.state = item.action.flatMap { modes[$0] } == activePages.readingMode ? .on : .off
            return engine.pageCount > 0
        case #selector(toggleDarkPages(_:)):
            item.state = AppSettings.darkPages ? .on : .off
            return true
        case #selector(chooseTool(_:)):
            item.state = pages.tool.rawValue == item.tag ? .on : .off
            return true
        case #selector(toggleReadAloud(_:)):
            item.state = readAloud.isActive ? .on : .off
            return engine.pageCount > 0
        case #selector(setMeasuringScale(_:)):
            return pdf.session != nil && engine.pageCount > 0
        case #selector(aiSummarize(_:)):
            return engine.pageCount > 0 && !ai.isBusy
        case #selector(aiAsk(_:)):
            return engine.pageCount > 0
        case #selector(aiExplain(_:)):
            return pages.selectedText != nil && !ai.isBusy
        case #selector(togglePrepareForm(_:)):
            item.state = design.isDesigning ? .on : .off
            return pdf.session != nil
        case #selector(toggleReadingOrder(_:)):
            item.state = readingOrder.isShown ? .on : .off
            return pdf.session != nil && longTask == nil && progressSheet == nil
        case #selector(detectFormFields(_:)):
            return pdf.session != nil && longTask == nil && progressSheet == nil
        case #selector(openInspector(_:)), #selector(replyToSelected(_:)):
            return pages.selectedId != nil
        case #selector(linkSelectedText(_:)):
            return pages.selectedText != nil
        case #selector(reloadFromDisk(_:)):
            return pdf.session?.filePath != nil
        case #selector(resetForm(_:)), #selector(exportFormData(_:)), #selector(importFormData(_:)):
            return !form.widgets.isEmpty
        case #selector(recognizeText(_:)), #selector(exportWord(_:)), #selector(exportExcel(_:)), #selector(exportText(_:)),
             #selector(exportPowerPoint(_:)), #selector(exportHtml(_:)),
             #selector(checkRedaction(_:)), #selector(sanitizeDocument(_:)), #selector(redactByPattern(_:)), #selector(whatsInThisPdf(_:)),
             #selector(checkAccessibility(_:)),
             #selector(reduceFileSize(_:)), #selector(flattenDocument(_:)), #selector(addHeaderFooter(_:)), #selector(addWatermark(_:)),
             #selector(removeHeaderFooter(_:)), #selector(removeWatermark(_:)), #selector(saveAsPdfA(_:)), #selector(saveAsPdfA2a(_:)), #selector(makeAccessible(_:)):
            return longTask == nil && progressSheet == nil && redaction.task == nil
        case #selector(applyRedactions(_:)), #selector(clearRedactionMarks(_:)):
            return !pages.redactions.isEmpty && longTask == nil && progressSheet == nil
        case #selector(redactSelectedText(_:)):
            return pages.selectedText != nil
        case #selector(redactSearchMatches(_:)):
            return !found.isEmpty
        case #selector(toggleOrganizer(_:)):
            item.state = organizerShown ? .on : .off
            return true
        case #selector(deletePages(_:)), #selector(reversePageOrder(_:)):
            return engine.pageCount > 1
        case #selector(signDigitally(_:)):
            return !signing.signing && longTask == nil && progressSheet == nil
        case #selector(showSignatures(_:)):
            return !signing.signatures.isEmpty
        case #selector(showDocumentProperties(_:)):
            return pdf.session != nil
        case #selector(removeProtection(_:)):
            return pdf.session?.hasEncryption == true
        case #selector(protectDocument(_:)):
            item.title = pdf.session?.hasEncryption == true ? "Change Password Protection…" : "Protect with Password…"
            return protectSheet == nil
        default:
            return true
        }
    }

    // MARK: PagesHost (popovers)

    func askText(_ title: String, initial: String, at rect: NSRect, done: @escaping (String?) -> Void) {
        if let testText {
            done(testText)
            return
        }
        let ask = AskController(.text(title), initial: initial, pageCount: engine.pageCount)
        ask.done = done
        present(ask, at: rect)
    }

    func askLink(at rect: NSRect, done: @escaping (_ uri: String?, _ page: Int) -> Void) {
        if let testLink {
            done(testLink.uri, testLink.page)
            return
        }
        let ask = AskController(.link, initial: "", pageCount: engine.pageCount)
        ask.doneLink = done
        present(ask, at: rect)
    }

    private func present(_ ask: AskController, at rect: NSRect) {
        askPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = ask
        popover.delegate = self
        ask.popover = popover
        askPopover = popover
        popover.show(relativeTo: rect.insetBy(dx: -2, dy: -2), of: pages, preferredEdge: .maxY)
    }

    func closePopovers() {
        inspectorPopover?.close()
        askPopover?.close()
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover else { return }
        if popover === askPopover {
            (popover.contentViewController as? AskController)?.cancel()
            askPopover = nil
        }
        if popover === inspectorPopover {
            inspectorPopover = nil
            inspector = nil
        }
    }

    func showInspector(_ id: String) {
        inspectorPopover?.close()
        guard let f = pages.frame(of: id), f.page < pages.pageRects.count else { return }
        let controller = InspectorController(id: id, editor: editor, pageCount: engine.pageCount)
        controller.onGone = { [weak self] in self?.inspectorPopover?.close() }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = self
        inspector = controller
        inspectorPopover = popover
        let rect = pages.viewRect(f.rect, pages.pageRects[f.page]).insetBy(dx: -4, dy: -4)
        pages.scrollToVisible(rect)
        popover.show(relativeTo: rect, of: pages, preferredEdge: .maxX)
    }

    func askReply(_ id: String) {
        guard let f = pages.frame(of: id), f.page < pages.pageRects.count else { return }
        pages.select(id, reveal: true)
        let rect = pages.viewRect(f.rect, pages.pageRects[f.page])
        askText("Reply", initial: "", at: rect) { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            self.pages.startEdit { await self.editor.reply(to: id, text) }
        }
    }

    // MARK: Comments list

    private func wireComments() {
        let list = sidebar.comments
        list.onSelect = { [weak self] id in self?.pages.select(id, reveal: true) }
        list.onReply = { [weak self] id in self?.askReply(id) }
        list.onDelete = { [weak self] id in
            guard let self else { return }
            if self.pages.selectedId == id { self.pages.select(nil) }
            self.pages.startEdit { await self.editor.delete(id) }
        }
        list.onInspect = { [weak self] id in
            self?.pages.select(id, reveal: true)
            self?.showInspector(id)
        }
    }

    // MARK: Changed on disk

    /// Shows the bar when another program changed (or removed) the file since it was opened or saved.
    func checkDisk() {
        guard let session = pdf.session, let path = session.filePath, session.hasChangedOnDisk() else {
            if !diskBar.isHidden { hideDiskBar() }
            return
        }
        let state = Self.diskState(path)
        guard state != ignoredDiskState, diskBar.isHidden else { return }
        let missing = session.isMissingOnDisk()
        diskBar.show(missing ? "“\(session.displayName)” was moved or deleted by another program."
                             : "“\(session.displayName)” was changed by another program.", canReload: !missing)
        diskBar.onReload = { [weak self] in
            guard let self else { return }
            Task { await self.reloadFromDiskNow() }
        }
        diskBar.onIgnore = { [weak self] in
            self?.ignoredDiskState = state
            self?.hideDiskBar()
        }
        NSAccessibility.post(element: diskBar, notification: .announcementRequested, userInfo: [.announcement: diskBar.message])
    }

    private static func diskState(_ path: String) -> String {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (a?[.size] as? NSNumber)?.int64Value ?? -1
        let time = (a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)/\(time)"
    }

    private func hideDiskBar() { diskBar.isHidden = true }

    @objc func reloadFromDisk(_ sender: Any?) {
        Task { await self.reloadFromDiskNow() }
    }

    /// Reads the file again (discarding unsaved changes, after asking), with its password asked when it needs another.
    @discardableResult
    func reloadFromDiskNow() async -> Bool {
        guard let session = pdf.session else { return false }
        if session.isDirty && !Report.isRunning {
            let alert = NSAlert()
            alert.messageText = "Reload “\(session.displayName)” from disk?"
            alert.informativeText = "Your unsaved changes to it will be lost."
            alert.addButton(withTitle: "Reload")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        var password: String?
        var wrong = false
        while true {
            do {
                let done = try await session.reloadFromDiskAsync(password: password)
                if done {
                    pdf.syncFileDate()
                    hideDiskBar()
                }
                return done
            } catch is PasswordRequired {
                guard let given = PasswordPrompt.ask(file: session.displayName, wrong: wrong) else { return false }
                password = given
                wrong = true
            } catch {
                pdf.showError("“\(session.displayName)” couldn't be read again.", error)
                return false
            }
        }
    }

    // MARK: Zoom

    @objc func zoomIn(_ sender: Any?) { zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: 0.8) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }
    @objc func fitWidth(_ sender: Any?) { fitWidth(sender, atMost: 8) }

    /// View › Zoom to Page: the whole current page in the window.
    @objc func fitPage(_ sender: Any?) {
        let pages = activePages
        let available = activeScroll.contentView.frame.size
        let page = pages.currentPage
        guard page >= 0, page < pages.pageRects.count, available.width > 0, available.height > 0 else { return }
        let rect = pages.pageRects[page]
        guard rect.width > 0, rect.height > 0 else { return }
        let height = Double(rect.height) + PagesView.gap
        let across = Double(available.width) / Double(pages.frame.width)
        let down = Double(available.height) / height
        setZoom(min(across, down))
        go(page)
    }

    /// The zoom a document opens at (Settings › Open documents at).
    func applyOpeningZoom() {
        switch AppSettings.zoomMode {
        case "FitPage": fitPage(nil)
        case "ActualSize": setZoom(1)
        default: fitWidth(nil, atMost: 1.5)
        }
    }

    func fitWidth(_ sender: Any?, atMost cap: Double) {
        let available = activeScroll.contentView.frame.width
        guard activePages.frame.width > 0, available > 0 else { return }
        setZoom(min(available / activePages.frame.width, cap))
    }

    private func zoom(by factor: Double) { setZoom(activeScroll.magnification * factor) }

    /// Zooms the active pane keeping the top of its view in place.
    func setZoom(_ zoom: Double) {
        let scrollView = activeScroll
        let clip = scrollView.contentView
        let top = NSPoint(x: clip.bounds.midX, y: clip.bounds.minY)
        let z = min(max(zoom, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.setMagnification(z, centeredAt: top)
        activePages.scrollTo(y: top.y)
        magnified()
    }

    @objc func magnified() {
        for view in allPanes {
            view.needsDisplay = true
            view.requestVisible()
        }
        updateSubtitle()
    }

    // MARK: Pages

    @objc func nextPage(_ sender: Any?) { go(min(activePages.currentPage + 1, engine.pageCount - 1)) }
    @objc func previousPage(_ sender: Any?) { go(max(activePages.currentPage - 1, 0)) }
    @objc func firstPage(_ sender: Any?) { go(0) }
    @objc func lastPage(_ sender: Any?) { go(engine.pageCount - 1) }

    /// Shows page `page` in the active pane, from `targetY` (its space, points from the top) when given, else its top.
    func go(_ page: Int, targetY: Double? = nil) {
        let pages = activePages
        guard page >= 0 && page < pages.pageRects.count else { return }
        pages.prepareToShow(page)
        // A spot down the page only on an upright view (as Windows: a turned view shows the page's top).
        let y = pages.viewRotation == 0 ? targetY : nil
        pages.scrollTo(y: pages.pageRects[page].minY + (y ?? 0) - (y == nil ? PagesView.gap / 2 : 8))
    }

    @objc func scrolled() {
        updateSubtitle()
        sidebar.showCurrent(activePages.currentPage)
        readingOrder.currentPageChanged()
        window?.invalidateCursorRects(for: pages) // the links of the pages now in view
    }

    // MARK: Links

    /// A link in the document was clicked: its page (and place), or its address, opened as on Windows: web and mail
    /// addresses straight away, anything else after asking.
    func openLink(_ link: PageLink) {
        guard let uri = link.uri else {
            guard link.pageIndex >= 0 && link.pageIndex < engine.pageCount else { return NSSound.beep() }
            go(link.pageIndex, targetY: link.targetY)
            return
        }
        guard let url = URL(string: uri.trimmingCharacters(in: .whitespacesAndNewlines)) else { return NSSound.beep() }
        if !Links.isSafe(uri) {
            linkQuestions += 1
            let allowed: Bool
            if testOpenedLinks != nil {
                allowed = testLinkAnswer
            } else {
                let alert = NSAlert()
                alert.messageText = "Open this link?"
                alert.informativeText = "The document wants to open \(uri). Only continue if you trust the document."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Open Link")
                alert.addButton(withTitle: "Cancel")
                allowed = alert.runModal() == .alertFirstButtonReturn
            }
            guard allowed else { return }
        }
        if testOpenedLinks != nil {
            testOpenedLinks?.append(uri)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func updateSubtitle() {
        // The zoom beside the page, as a percentage, only when it isn't 100% (UX review, round 2: it showed nowhere).
        let text = WindowStatus.subtitle(page: activePages.currentPage + 1, pageCount: engine.pageCount, zoom: Double(activeScroll.magnification))
        if window?.subtitle != text { window?.subtitle = text }
    }

    // MARK: Find

    @objc func showFind(_ sender: Any?) {
        findBar.isHidden = false
        window?.makeFirstResponder(findBar.field)
    }

    @objc func findNext(_ sender: Any?) {
        if foundQuery.isEmpty { showFind(sender) } else { step(1) }
    }

    @objc func findPrevious(_ sender: Any?) {
        if foundQuery.isEmpty { showFind(sender) } else { step(-1) }
    }

    func hideFind() {
        findBar.isHidden = true
        find("")
        window?.makeFirstResponder(activePages)
    }

    /// Finds `query` on every page (off the main thread), shows the first match from the current page on.
    func find(_ query: String) {
        findGeneration += 1
        let generation = findGeneration
        findCancel?.cancel()
        findCancel = nil
        foundQuery = query
        found = []
        foundIndex = -1
        for view in allPanes {
            view.matches = [:]
            view.currentMatch = nil
        }
        updateRedactBar()
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            findBar.status = ""
            onFindFinished?()
            return
        }
        findBar.status = "Searching…"
        let engine = engine
        let from = activePages.currentPage
        // A new search (or the bar closed) stops the one under way (above): its pages aren't read for nothing.
        let cancel = CancelToken()
        findCancel = cancel
        Thread.detachNewThread {
            // Pages read on several threads, each with its own MuPDF instance, remembered for the next search (E16).
            // Cancelled: the search that replaced it reports. Any other failure (the document changed meanwhile) finds
            // nothing, as a page that couldn't be read always did.
            let pages: [PdfEngine.PageMatches]
            do {
                pages = try engine.findAll(query, matchCase: false, wholeWord: false, keepText: false, cancel: cancel)
            } catch is CancellationError {
                return
            } catch {
                pages = []
            }
            let results = pages.flatMap { m in m.hits.map { (page: m.page, start: $0.start, end: $0.end) } }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.findGeneration else { return }
                    self.showFound(results, from: from)
                }
            }
        }
    }

    private func showFound(_ results: [(page: Int, start: Int, end: Int)], from page: Int) {
        found = results
        var byPage: [Int: [(start: Int, end: Int)]] = [:]
        for r in results { byPage[r.page, default: []].append((r.start, r.end)) }
        for view in allPanes { view.matches = byPage }
        if results.isEmpty {
            findBar.status = "Not found"
        } else {
            foundIndex = (results.firstIndex { $0.page >= page } ?? 0) - 1
            step(1)
        }
        updateRedactBar()
        onFindFinished?()
    }

    /// The next (or previous) match, wrapping around.
    func step(_ by: Int) {
        guard !found.isEmpty else { return }
        foundIndex = ((foundIndex + by) % found.count + found.count) % found.count
        let m = found[foundIndex]
        for view in allPanes { view.currentMatch = m }
        findBar.status = "\(foundIndex + 1) of \(found.count)"
        let pages = activePages
        pages.prepareToShow(m.page)
        if let text = try? engine.text(m.page), let box = text.rects(m.start, m.end).first, m.page < pages.pageRects.count {
            let shownBox: CGRect = pages.viewRect(box, pages.pageRects[m.page])
            let shown: CGRect = activeScroll.contentView.bounds
            let matchY: CGFloat = shownBox.minY
            let y: CGFloat = matchY - shown.height / 3
            if matchY < shown.minY || shownBox.maxY > shown.maxY { pages.scrollTo(y: y) }
        }
    }
}

/// The find bar over the pages: the query, "n of m", previous and next, Done.
@MainActor
final class FindBar: NSView, NSSearchFieldDelegate {
    let field = NSSearchField()
    private let label = NSTextField(labelWithString: "")
    var onSearch: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onDone: (() -> Void)?
    private var lastQuery = ""

    var status: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    init() {
        super.init(frame: .zero)
        field.placeholderString = "Find in document"
        field.sendsWholeSearchString = true
        field.target = self
        field.action = #selector(search)
        field.delegate = self
        label.textColor = .secondaryLabelColor
        let previous = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Previous")!, target: self, action: #selector(previous))
        let next = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Next")!, target: self, action: #selector(nextMatch))
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        for b in [previous, next] { b.bezelStyle = .accessoryBarAction }
        let stack = NSStackView(views: [field, label, previous, next, done])
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func search() {
        let q = field.stringValue
        if q == lastQuery && !q.isEmpty { onNext?() } else {
            lastQuery = q
            onSearch?(q)
        }
    }

    @objc private func previous() { onPrevious?() }
    @objc private func nextMatch() { onNext?() }
    @objc private func done() {
        lastQuery = ""
        field.stringValue = ""
        onDone?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            done()
            return true
        }
        return false
    }
}

/// The bar over the pages saying another program changed the file: Reload, Ignore.
@MainActor
final class DiskBar: NSView {
    private let label = NSTextField(labelWithString: "")
    private let reload = NSButton(title: "Reload", target: nil, action: nil)
    private let ignore = NSButton(title: "Ignore", target: nil, action: nil)
    var onReload: (() -> Void)?
    var onIgnore: (() -> Void)?
    var message: String { label.stringValue }

    init() {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning")!)
        icon.contentTintColor = .systemOrange
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for b in [reload, ignore] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.target = self
        }
        reload.action = #selector(reloadClicked)
        ignore.action = #selector(ignoreClicked)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [icon, label, spacer, reload, ignore])
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("File changed on disk")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemYellow.withAlphaComponent(0.18).setFill()
        dirtyRect.fill()
    }

    func show(_ text: String, canReload: Bool) {
        label.stringValue = text
        reload.isHidden = !canReload
        isHidden = false
    }

    @objc private func reloadClicked() { onReload?() }
    @objc private func ignoreClicked() { onIgnore?() }
}

/// Pictures for the Image tool: decoded to 8-bit RGB with an alpha plane (dropped when fully opaque), at most 2048 pixels
/// across.
enum Pictures {
    static func stampImage(_ image: CGImage) -> StampImage? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let k = min(1, 2048 / Double(longest))
        let w = max(1, Int((Double(image.width) * k).rounded())), h = max(1, Int((Double(image.height) * k).rounded()))
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        var alpha = [UInt8](repeating: 255, count: w * h)
        var opaque = true
        for i in 0..<(w * h) {
            let a = rgba[i * 4 + 3]
            alpha[i] = a
            if a < 255 { opaque = false }
            for c in 0..<3 {
                let v = Int(rgba[i * 4 + c])
                rgb[i * 3 + c] = a == 0 ? 255 : UInt8(min(255, (v * 255 + Int(a) / 2) / Int(a)))
            }
        }
        return StampImage(w, h, rgb, opaque ? nil : alpha)
    }
}
