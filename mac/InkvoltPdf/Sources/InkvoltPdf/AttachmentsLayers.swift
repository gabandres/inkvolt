import AppKit
import PdfCore
import UniformTypeIdentifiers

// E9: the sidebar's Attachments and Layers panes (the Windows app's in DocumentTab.Review). Attachments are listed,
// saved (marked as downloaded, as Windows marks them with the Mark of the Web), opened when they are PDFs (a new unsaved
// document), attached and removed, each change one undo step. Layers are shown or hidden for viewing and printing only,
// through a copy drawn by its own engine (the document's bytes and undo history untouched), and saved as the document's
// default as one edit.

/// The Attachments pane: the files, and Attach…, Save…, Open, Remove.
@MainActor
final class AttachmentsPane: NSView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = KeyTableView()
    private let emptyLabel = NSTextField(wrappingLabelWithString: "No attached files. Attach… embeds a file in this PDF.")
    let attachButton = NSButton(title: "Attach…", target: nil, action: nil)
    let saveButton = NSButton(title: "Save…", target: nil, action: nil)
    let openButton = NSButton(title: "Open", target: nil, action: nil)
    let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private(set) var items: [(info: AttachmentInfo, page: String?)] = []

    var onAttach: (() -> Void)?
    var onSave: ((AttachmentInfo) -> Void)?
    var onOpen: ((AttachmentInfo) -> Void)?
    var onRemove: ((AttachmentInfo) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = 38
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.setAccessibilityLabel("Attached files")
        table.onKey = { [weak self] event in
            guard let self, let a = self.selected else { return false }
            switch event.specialKey {
            case .delete, .deleteForward, .backspace:
                self.onRemove?(a)
                return true
            case .carriageReturn, .enter:
                if a.isPdf { self.onOpen?(a) } else { self.onSave?(a) }
                return true
            default:
                return false
            }
        }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        for (button, action) in [(attachButton, #selector(attachClicked)), (saveButton, #selector(saveClicked)),
                                 (openButton, #selector(openClicked)), (removeButton, #selector(removeClicked))] {
            button.target = self
            button.action = action
            button.controlSize = .small
            button.bezelStyle = .push
        }
        openButton.toolTip = "Open an attached PDF as a new document"
        saveButton.toolTip = "Save the attached file (Inkvolt PDF never runs attachments)"
        let buttons = NSStackView(views: [attachButton, saveButton, openButton, removeButton])
        buttons.spacing = 4
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let stack = NSStackView(views: [buttons, emptyLabel, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            emptyLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
        ])
        setAccessibilityLabel("Attachments")
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The files, each with the page label of its annotation (nil: the document's own list).
    func show(_ list: [(info: AttachmentInfo, page: String?)]) {
        let key = selected?.key
        items = list
        table.reloadData()
        if let key, let row = items.firstIndex(where: { $0.info.key == key }) { table.selectRowIndexes([row], byExtendingSelection: false) }
        emptyLabel.isHidden = !items.isEmpty
        updateButtons()
    }

    var selected: AttachmentInfo? { table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow].info : nil }

    func select(_ key: String) {
        guard let row = items.firstIndex(where: { $0.info.key == key }) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    private func updateButtons() {
        saveButton.isEnabled = selected != nil
        removeButton.isEnabled = selected != nil
        openButton.isEnabled = selected?.isPdf == true
    }

    static func sizeText(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let (a, page) = items[row]
        let name = NSTextField(labelWithString: a.fileName)
        name.lineBreakMode = .byTruncatingMiddle
        var detail = [Self.sizeText(a.size)]
        if let page { detail.append("on page \(page)") }
        if let d = a.description, !d.isEmpty { detail.append(d) }
        let info = NSTextField(labelWithString: detail.joined(separator: " · "))
        info.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        info.textColor = .secondaryLabelColor
        info.lineBreakMode = .byTruncatingTail
        let icon = NSImageView(image: NSWorkspace.shared.icon(for: UTType(filenameExtension: (a.fileName as NSString).pathExtension) ?? .data))
        icon.widthAnchor.constraint(equalToConstant: 24).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let texts = NSStackView(views: [name, info])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        let row = NSStackView(views: [icon, texts])
        row.spacing = 6
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel("\(a.fileName), \(detail.joined(separator: ", "))")
        return row
    }

    func tableViewSelectionDidChange(_ notification: Notification) { updateButtons() }

    @objc private func doubleClicked() {
        guard table.clickedRow >= 0, table.clickedRow < items.count else { return }
        let a = items[table.clickedRow].info
        if a.isPdf { onOpen?(a) } else { onSave?(a) }
    }

    @objc private func attachClicked() { onAttach?() }
    @objc private func saveClicked() { if let a = selected { onSave?(a) } }
    @objc private func openClicked() { if let a = selected { onOpen?(a) } }
    @objc private func removeClicked() { if let a = selected { onRemove?(a) } }
}

/// A table that hands its keys to the pane first.
final class KeyTableView: NSTableView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A row of the Layers pane: a layer (a check box) or a label grouping layers.
@MainActor
final class LayerRow: NSObject {
    let label: String
    let layer: LayerInfo?
    var children: [LayerRow]
    var visible: Bool

    init(label: String, layer: LayerInfo?, children: [LayerRow], visible: Bool) {
        self.label = label
        self.layer = layer
        self.children = children
        self.visible = visible
    }
}

/// The Layers pane: the layers in the author's order with a check box each (locked ones can't be changed), Reset and
/// Save as Default.
@MainActor
final class LayersPane: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = NSOutlineView()
    private let note = NSTextField(wrappingLabelWithString: "Showing or hiding a layer changes only what you see and print. Save as Default keeps it in the file.")
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let saveButton = NSButton(title: "Save as Default", target: nil, action: nil)
    private(set) var roots: [LayerRow] = []

    var onToggle: ((LayerInfo, Bool) -> Void)?
    var onReset: (() -> Void)?
    var onSaveDefault: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let column = NSTableColumn(identifier: .init("layer"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Layers")
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        for (button, action) in [(resetButton, #selector(resetClicked)), (saveButton, #selector(saveClicked))] {
            button.target = self
            button.action = action
            button.controlSize = .small
            button.bezelStyle = .push
        }
        resetButton.toolTip = "Show the layers as the document opens with them"
        saveButton.toolTip = "Make what is shown the document's default (an edit you can undo)"
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let buttons = NSStackView(views: [resetButton, saveButton])
        buttons.spacing = 4
        let stack = NSStackView(views: [buttons, note, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 0, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
        ])
        setAccessibilityLabel("Layers")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The tree, and whether the layers differ from the document's default (Reset and Save as Default then apply).
    func show(_ rows: [LayerRow], changed: Bool) {
        roots = rows
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        resetButton.isEnabled = changed
        saveButton.isEnabled = changed
    }

    /// The check box of a layer (the self-test clicks it, as a person would).
    func checkBox(_ name: String) -> NSButton? {
        for row in 0..<outline.numberOfRows {
            guard let item = outline.item(atRow: row) as? LayerRow, item.layer?.name == name else { continue }
            return outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSButton
        }
        return nil
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? LayerRow)?.children ?? roots).count }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? LayerRow)?.children ?? roots)[index] }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !((item as? LayerRow)?.children.isEmpty ?? true) }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let row = item as? LayerRow else { return nil }
        guard let layer = row.layer else {
            let label = NSTextField(labelWithString: row.label)
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            return label
        }
        let box = LayerCheckBox(checkboxWithTitle: row.label, target: self, action: #selector(toggled(_:)))
        box.row = row
        box.state = row.visible ? .on : .off
        box.isEnabled = !layer.locked
        box.toolTip = layer.locked ? "The document locks this layer" : nil
        box.lineBreakMode = .byTruncatingTail
        return box
    }

    @objc private func toggled(_ sender: LayerCheckBox) {
        guard let row = sender.row, let layer = row.layer else { return }
        row.visible = sender.state == .on
        onToggle?(layer, row.visible)
    }

    @objc private func resetClicked() { onReset?() }
    @objc private func saveClicked() { onSaveDefault?() }
}

final class LayerCheckBox: NSButton {
    weak var row: LayerRow?
}

// MARK: The window's commands

extension DocumentWindowController {
    /// Reads the attachments and layers again (at opening and after every change), and shows them.
    func refreshAttachmentsAndLayers() {
        guard let session = pdf.session else { return }
        let data = session.data, password = session.password
        let files = (try? Attachments.list(data, password)) ?? []
        sidebar.attachments.show(files.map { a in (a, a.pageIndex >= 0 ? pageLabel(a.pageIndex) : nil) })
        layerList = (try? Layers.list(data, password)) ?? []
        layerOrder = layerList.isEmpty ? [] : (try? Layers.readOrder(data, password)) ?? []
        // Choices are kept by name: object numbers change when an edit writes the file whole.
        let names = Set(layerList.map(\.name))
        layerChoice = layerChoice.filter { names.contains($0.key) }
        sidebar.showsLayers = !layerList.isEmpty
        showLayerTree()
        // A content change has drawn the pages from the document's new engine: the old layer view is stale (and must
        // not print), so a new one is made from the new bytes.
        layerEngine = nil
        applyLayers()
    }

    private func pageLabel(_ page: Int) -> String { String(page + 1) }

    /// The pane's tree from the author's order; layers the order leaves out still get a row.
    private func showLayerTree() {
        let byId = Dictionary(layerList.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var used = Set<Int>()
        func build(_ nodes: [LayerOrderNode]) -> [LayerRow] {
            nodes.compactMap { n in
                let layer = n.layerId.flatMap { byId[$0] }
                if let layer { used.insert(layer.id) }
                let row = LayerRow(label: layer?.name ?? n.label ?? "", layer: layer, children: build(n.children),
                                   visible: layer.map(isLayerVisible) ?? false)
                return layer != nil || !row.children.isEmpty ? row : nil
            }
        }
        var roots = build(layerOrder)
        roots += layerList.filter { !used.contains($0.id) }.map { LayerRow(label: $0.name, layer: $0, children: [], visible: isLayerVisible($0)) }
        sidebar.layers.show(roots, changed: !layerChoice.isEmpty)
    }

    private func isLayerVisible(_ l: LayerInfo) -> Bool { layerChoice[l.name] ?? l.defaultVisible }

    func wireAttachmentsAndLayers() {
        sidebar.attachments.onAttach = { [weak self] in self?.attachFile() }
        sidebar.attachments.onSave = { [weak self] a in self?.saveAttachment(a) }
        sidebar.attachments.onOpen = { [weak self] a in self?.openAttachment(a) }
        sidebar.attachments.onRemove = { [weak self] a in self?.removeAttachment(a) }
        sidebar.layers.onToggle = { [weak self] layer, visible in self?.setLayerVisible(layer.name, visible) }
        sidebar.layers.onReset = { [weak self] in self?.resetLayers() }
        sidebar.layers.onSaveDefault = { [weak self] in self?.saveLayersAsDefault() }
        refreshAttachmentsAndLayers()
    }

    @objc func showAttachments(_ sender: Any?) {
        if let item = split.splitViewItems.first, item.isCollapsed { item.animator().isCollapsed = false }
        sidebar.show(.attachments)
    }

    @objc func showLayers(_ sender: Any?) {
        guard !layerList.isEmpty else { return NSSound.beep() }
        if let item = split.splitViewItems.first, item.isCollapsed { item.animator().isCollapsed = false }
        sidebar.show(.layers)
    }

    // MARK: Attachments

    /// Attach… : a file the person picks (the self-test passes one), embedded as one edit.
    func attachFile(_ url: URL? = nil, description: String? = nil) {
        guard let url = url ?? pickFileToAttach() else { return }
        Task { _ = await attach(url, description: description) }
    }

    private func pickFileToAttach() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Attach a File"
        panel.prompt = "Attach"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @discardableResult
    func attach(_ url: URL, description: String? = nil) async -> Bool {
        let bytes: [UInt8]
        let modified: Date?
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            if (values.fileSize ?? 0) > 512 * 1024 * 1024 { throw PdfEditError("Files over 512 MB can't be attached.") }
            bytes = try await Task.detached { [UInt8](try Data(contentsOf: url)) }.value
            modified = values.contentModificationDate
        } catch {
            presentProblem("Couldn't read the file", error)
            return false
        }
        let name = url.lastPathComponent
        let ok = await editor.run("Attach \(name)", contentOnly: true) { d, pw in
            try Attachments.add(d, pw, name, bytes, description: description, modified: modified)
        }
        if ok {
            sidebar.show(.attachments)
            notify("Attached \(name).", canUndo: true)
        }
        return ok
    }

    /// Writes an attachment to a file the person picks (the self-test passes a path): atomically, marked as downloaded
    /// so Gatekeeper and other apps treat it with the care a download gets. Inkvolt PDF never opens or runs it.
    func saveAttachment(_ a: AttachmentInfo, to target: URL? = nil) {
        guard let session = pdf.session else { return }
        var url = target
        if url == nil {
            let panel = NSSavePanel()
            panel.title = "Save Attachment"
            panel.nameFieldStringValue = Self.safeFileName(a.fileName)
            guard panel.runModal() == .OK else { return }
            url = panel.url
        }
        guard let url else { return }
        // Writing over a document open here would swap the file under it.
        if NSDocumentController.shared.documents.contains(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
            presentProblem("\(url.lastPathComponent) is open in Inkvolt PDF", PdfEditError("Choose a different name, or close that document first."))
            return
        }
        let data = session.data, password = session.password, source = pdf.fileURL
        Task {
            do {
                let bytes = try await Task.detached { try Attachments.extract(data, password, a.key) }.value
                try Data(bytes).write(to: url, options: .atomic)
                Self.markDownloaded(url, from: source)
                lastSavedAttachment = url
                notify("Saved \(url.lastPathComponent).")
            } catch {
                presentProblem("Couldn't save the attachment", error)
            }
        }
    }

    /// The quarantine mark macOS puts on downloads (the Mac's form of Windows' Mark of the Web).
    static func markDownloaded(_ url: URL, from source: URL?) {
        var values = URLResourceValues()
        var props: [String: Any] = [kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                                    kLSQuarantineAgentNameKey as String: "Inkvolt PDF"]
        if let source { props[kLSQuarantineOriginURLKey as String] = source }
        values.quarantineProperties = props
        var marked = url
        try? marked.setResourceValues(values)
    }

    /// An attached PDF opened as a new unsaved document (nothing written but its recovery copy). One with its own open
    /// password asks for it (again after a wrong one), as Windows' `OpenAttachment`; Cancel opens nothing.
    func openAttachment(_ a: AttachmentInfo) {
        guard let session = pdf.session else { return }
        let data = session.data, password = session.password
        Task {
            do {
                let bytes = try await Task.detached { try Attachments.extract(data, password, a.key) }.value
                var own: String?
                var wrong = false
                while true {
                    let tried = own
                    do {
                        try await Task.detached { try PdfEngine.open(bytes, password: tried).close() }.value
                        break
                    } catch let e as PasswordRequired {
                        guard let given = Self.askAttachmentPassword(a.fileName, wrong: wrong || e.wrongPassword) else { return }
                        own = given
                        wrong = true
                    }
                }
                NewDocuments.open(bytes, name: Self.safeFileName(a.fileName), password: own)
            } catch {
                presentProblem("Couldn't open \(a.fileName)", error)
            }
        }
    }

    /// The self-test's answers to an attached PDF's password question, in order (the question isn't shown while it runs),
    /// and how many times it was asked.
    static var testAttachmentPasswords: [String] = []
    private(set) static var attachmentPasswordAsked = 0

    private static func askAttachmentPassword(_ file: String, wrong: Bool) -> String? {
        attachmentPasswordAsked += 1
        if Report.skipsDialogs { return testAttachmentPasswords.isEmpty ? nil : testAttachmentPasswords.removeFirst() }
        return PasswordPrompt.ask(file: file, wrong: wrong)
    }

    func removeAttachment(_ a: AttachmentInfo) {
        Task {
            if await editor.run("Remove attachment \(a.fileName)", contentOnly: true, { d, pw in try Attachments.remove(d, pw, a.key) }) {
                notify("Removed \(a.fileName).", canUndo: true)
            }
        }
    }

    /// Embedded names come from the file: no folders, no control characters, no "." or "..", never empty.
    static func safeFileName(_ name: String) -> String {
        let last = (name.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let clean = String(last.unicodeScalars.map { $0 == ":" || $0 == "/" || CharacterSet.controlCharacters.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        let trimmed = clean.replacingOccurrences(of: #"[. ]+$"#, with: "", options: .regularExpression)
        return trimmed.isEmpty || trimmed.hasPrefix(".") && trimmed.allSatisfy({ $0 == "." }) ? "attachment" : trimmed
    }

    private func presentProblem(_ title: String, _ error: Error) {
        let text = (error as? PdfEditError)?.message ?? error.localizedDescription
        Report.progress("problem: \(title): \(text.prefix(160))")
        if Report.skipsDialogs {
            lastProblem = title
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    // MARK: Layers

    /// Shows or hides a layer (by name) for viewing and printing; the file isn't changed.
    func setLayerVisible(_ name: String, _ visible: Bool) {
        guard let layer = layerList.first(where: { $0.name == name }), !layer.locked else { return }
        if visible == layer.defaultVisible { layerChoice[name] = nil } else { layerChoice[name] = visible }
        showLayerTree()
        applyLayers()
    }

    func resetLayers() {
        layerChoice = [:]
        showLayerTree()
        applyLayers()
    }

    /// The chosen layers drawn by an engine over a copy with that default configuration; none: the document's own.
    func applyLayers() {
        layerTicket += 1
        let ticket = layerTicket
        guard let session = pdf.session else { return }
        let visibility = Dictionary(layerList.compactMap { l in layerChoice[l.name].map { (l.id, $0) } }, uniquingKeysWith: { a, _ in a })
        guard !visibility.isEmpty else {
            if layerEngine != nil { setLayerEngine(nil) }
            return
        }
        let data = session.data, password = session.password, pageCount = engine.pageCount
        Task {
            let made: PdfEngine?
            do {
                made = try await Task.detached {
                    let bytes = try Layers.withVisibility(data, password, visibility)
                    return try PdfEngine.open(bytes)
                }.value
            } catch {
                if ticket == layerTicket { notify("Couldn't change the layers: \((error as? PdfEditError)?.message ?? error.localizedDescription)") }
                return
            }
            guard ticket == layerTicket, pdf.session?.data == data, let made, made.pageCount == pageCount else { return }
            setLayerEngine(made)
        }
    }

    private func setLayerEngine(_ other: PdfEngine?) {
        layerEngine = other
        pages.draw(with: other)
        secondPages?.draw(with: other)
        sidebar.drawThumbnails(with: other)
        layersApplied += 1
    }

    /// Makes the layers shown the document's default: one edit.
    func saveLayersAsDefault() {
        guard !layerChoice.isEmpty else { return }
        let visibility = Dictionary(layerList.compactMap { l in layerChoice[l.name].map { (l.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let choice = layerChoice
        layerChoice = [:] // the saved defaults are what shows now
        Task {
            if await editor.run("Save layer visibility", { d, pw in try Layers.setDefaultVisibility(d, pw, visibility) }) {
                notify("The layers shown are now the document's default.", canUndo: true)
            } else {
                layerChoice = choice
                showLayerTree()
            }
        }
    }
}
