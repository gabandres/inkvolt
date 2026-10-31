import AppKit
import PdfCore

/// A table of pieces whose keys move them: ⌥↑/⌥↓ within the page, ⌥Page Up/⌥Page Down to the page before or after, Page
/// Up/Page Down shows the page before or after, Return or F2 goes to the selected piece's alternate text.
final class ReadingOrderTable: NSTableView {
    var onMove: ((Int) -> Void)?
    var onMoveToPage: ((Int) -> Void)?
    var onShowPage: ((Int) -> Void)?
    var onEditText: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch (event.specialKey, mods) {
        case (.upArrow?, .option): onMove?(-1)
        case (.downArrow?, .option): onMove?(1)
        case (.pageUp?, .option): onMoveToPage?(-1)
        case (.pageDown?, .option): onMoveToPage?(1)
        case (.pageUp?, []): onShowPage?(-1)
        case (.pageDown?, []): onShowPage?(1)
        case (.carriageReturn?, []), (.enter?, []), (.f2?, []):
            if onEditText?() != true { super.keyDown(with: event) }
        default: super.keyDown(with: event)
        }
    }
}

/// Tools › Reading Order and Alt Text (the Windows app's `DocumentTab.ReadingOrder`): the plan Make Accessible writes
/// (`AutoTag`), page by page, as a list in reading order in a panel beside the pages and as numbered boxes on them
/// (`PagesView.readingBoxes`). A piece moves by drag, the buttons or ⌥↑/⌥↓, and to the page before or after with ⌥Page
/// Up/⌥Page Down (read there, its content staying where it is); a picture gets its alternate text typed or is marked
/// decorative, a formula says how it is read. Everything works from the keyboard: Page Up/Page Down shows the page before or
/// after, Return or F2 goes to the selected piece's alternate text and Esc back to the list. Apply Changes writes the tags
/// again as one undo step. Looking at the order and at alternate text is free; moving pieces and applying them asks the Pro
/// check. The words and rules are `ReadingOrder` in the package.
@MainActor
final class ReadingOrderPane: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private static let pieceType = NSPasteboard.PasteboardType("com.bermudezsystems.InkvoltPdf.piece")
    private weak var controller: DocumentWindowController?

    private(set) var plan: TagPlan?
    /// The document the plan was made for (or written into); another one makes it stale.
    private var planFor: [UInt8]?
    /// The plan is in the document as it is now (nothing to apply).
    private(set) var written = false
    /// The person has confirmed the plan's title and language (Make Accessible's sheet).
    private var confirmed = false
    private var updating = false
    /// The page the list shows, and the piece selected (its index in the plan).
    private(set) var page = 0
    private(set) var selected: Int?
    private(set) var state = ReadingOrderState()

    let panelController = NSViewController()
    private(set) var panelItem: NSSplitViewItem!
    let summaryLabel = NSTextField(wrappingLabelWithString: "")
    let table = ReadingOrderTable()
    let upButton = NSButton(title: "Up", target: nil, action: nil)
    let downButton = NSButton(title: "Down", target: nil, action: nil)
    let pageBeforeButton = NSButton(title: "Page Before", target: nil, action: nil)
    let pageAfterButton = NSButton(title: "Page After", target: nil, action: nil)
    let figureGroup = NSStackView()
    let altLabel = NSTextField(labelWithString: "")
    let altField = NSTextField()
    let decorativeBox = NSButton(checkboxWithTitle: "Decorative: nothing a reader needs", target: nil, action: nil)
    let applyButton = NSButton(title: "Apply Changes", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)

    init(controller: DocumentWindowController) {
        self.controller = controller
        super.init()
        build()
        panelItem = NSSplitViewItem(inspectorWithViewController: panelController)
        panelItem.minimumThickness = 280
        panelItem.maximumThickness = 420
        panelItem.isCollapsed = true
    }

    var isShown: Bool { !panelItem.isCollapsed }

    private var session: DocumentSession? { controller?.pdf.session }

    /// The plan is for the document as it is now.
    var isCurrent: Bool { plan != nil && planFor != nil && planFor == session?.data }

    private var selectedItem: ReadingOrderItem? { state.items.first { $0.index == selected } }

    /// What the selected piece is, in words (the self-test reads it).
    var selectedItemKind: String { selectedItem?.kind ?? "" }

    // MARK: Showing

    /// Opens the pane: the plan written last, else one read from the pages now (written with Apply Changes).
    func show() async {
        guard let controller, session != nil, await controller.settleForTags() else { return }
        if !isCurrent {
            guard let read = await controller.readTagPlan() else { return }
            plan = read
            planFor = session?.data
            written = false
            confirmed = false
            selected = nil
        }
        reveal()
        controller.window?.makeFirstResponder(table)
    }

    /// After Make Accessible wrote `plan`: the pane shows it.
    func showWritten(_ plan: TagPlan) {
        self.plan = plan
        planFor = session?.data
        written = true
        confirmed = true
        reveal()
    }

    private func reveal() {
        panelItem.isCollapsed = false
        page = controller?.pages.currentPage ?? 0
        fill()
    }

    func hide() {
        controller?.pages.readingBoxes = []
        panelItem.isCollapsed = true
    }

    /// An edit, undo or redo replaced the document: the plan's places may not match the pages any more.
    func contentChanged() {
        guard plan != nil, !isCurrent else { return }
        written = false
        if isShown { fill() }
    }

    /// The viewer moved to another page: the list follows.
    func currentPageChanged() {
        guard isShown, let current = controller?.pages.currentPage, current != page else { return }
        page = current
        if selectedItem == nil { selected = nil }
        fill()
    }

    /// The list for the current page, the boxes on every page, the summary and the buttons.
    private func fill(keepEditor: Bool = false) {
        guard let plan else { return }
        let stale = !isCurrent
        state = ReadingOrder.state(plan, page: page, selected: selected, stale: stale, written: written)
        updating = true
        table.reloadData()
        if let row = state.items.firstIndex(where: { $0.index == selected }) {
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        updating = false
        if !keepEditor { showSelectedPiece() }
        controller?.pages.readingBoxes = state.boxes
        summaryLabel.stringValue = state.summary
        upButton.isEnabled = state.editable && selected != nil
        downButton.isEnabled = state.editable && selected != nil
        table.isEnabled = state.editable
        pageBeforeButton.isEnabled = state.canMoveToPageBefore && selected != nil
        pageAfterButton.isEnabled = state.canMoveToPageAfter && selected != nil
        applyButton.isEnabled = state.canApply
        altField.isEnabled = state.editable && selectedItem?.block.decorative != true
        decorativeBox.isEnabled = state.editable
    }

    /// A picture's alternate text (or decorative), a formula's (what a screen reader says for it: its text to begin with).
    private func showSelectedPiece() {
        guard let item = selectedItem, item.block.kind == .figure || item.block.kind == .formula else {
            figureGroup.isHidden = true
            return
        }
        let formula = item.block.kind == .formula
        figureGroup.isHidden = false
        updating = true
        altField.stringValue = item.block.alt ?? (formula ? item.block.text : "")
        updating = false
        decorativeBox.state = item.block.decorative ? .on : .off
        decorativeBox.isHidden = formula
        let name = formula ? "How formula \(item.number) is read" : "Alternate text for picture \(item.number)"
        altLabel.stringValue = name
        altField.setAccessibilityLabel(name)
    }

    private func setPlan(_ new: TagPlan, select: Int?, keepEditor: Bool = false) {
        plan = new
        written = false
        selected = select
        fill(keepEditor: keepEditor)
    }

    private func announce(_ text: String) {
        Report.progress("reading order: \(text.prefix(80))")
        guard let window = controller?.window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested, userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Moving

    /// ⌥↑ (-1) or ⌥↓ (1) on the selected piece.
    func moveSelected(_ by: Int) {
        guard let plan, let item = selectedItem, state.editable, controller?.proAllows(.readingOrder) == true else { return }
        let moved = AutoTag.move(plan, item.index, by)
        if moved == plan { return }
        setPlan(moved, select: item.index + (by < 0 ? -1 : 1))
        focusList()
        announce("Moved to place \(selectedItem?.number ?? 0)")
    }

    /// Reads the selected piece with the page before (-1: after its last piece) or after (1: before its first), and shows that page.
    func moveSelectedToPage(_ by: Int) {
        guard let plan, let item = selectedItem, state.editable, controller?.proAllows(.readingOrder) == true,
              let moved = ReadingOrder.movedToPage(plan, item.index, by) else { return }
        self.plan = moved.plan
        written = false
        selected = moved.index
        page = moved.page
        if controller?.pages.currentPage != moved.page { controller?.go(moved.page) }
        page = moved.page
        fill()
        focusList()
        announce("Read with page \(moved.page + 1), place \(selectedItem?.number ?? 0)")
    }

    /// Shows another page's pieces (Page Up/Page Down in the list), the first one selected.
    func showPage(_ by: Int) {
        guard let plan, let controller else { return }
        let target = page + by
        guard target >= 0, target < plan.pages else { return }
        selected = ReadingOrder.firstPiece(plan, page: target)
        page = target
        if controller.pages.currentPage != target { controller.go(target) }
        page = target
        fill()
        focusList()
        announce("Page \(target + 1): \(state.items.count) \(state.items.count == 1 ? "piece" : "pieces")")
    }

    /// Selects a piece of the list, by its row (the self-test too).
    func selectRow(_ row: Int) {
        guard state.items.indices.contains(row) else { return }
        table.selectRowIndexes([row], byExtendingSelection: false)
    }

    /// Keyboard focus on the list.
    func focusList() { controller?.window?.makeFirstResponder(table) }

    /// Return or F2 on a picture or formula: its text (or Decorative, when it is decorative).
    private func editText() -> Bool {
        guard !figureGroup.isHidden, let window = controller?.window else { return false }
        window.makeFirstResponder(altField.isEnabled ? altField : decorativeBox)
        return true
    }

    func setAltText(_ text: String) {
        guard let plan, let item = selectedItem, item.block.kind == .figure || item.block.kind == .formula else { return }
        setPlan(AutoTag.with(plan, item.index) { $0.alt = text }, select: item.index, keepEditor: true)
    }

    func setDecorative(_ on: Bool) {
        guard let plan, let item = selectedItem, item.block.kind == .figure else { return }
        setPlan(AutoTag.with(plan, item.index) { $0.decorative = on }, select: item.index)
    }

    /// Writes the tags from the plan as it is now (title and language asked first when they never were).
    @discardableResult
    func apply() async -> Bool {
        guard let controller, let plan, isCurrent, controller.proAllows(.readingOrder) else { return false }
        return await controller.writeTags(plan, ask: !confirmed)
    }

    // MARK: Actions

    @objc private func upClicked() { moveSelected(-1) }
    @objc private func downClicked() { moveSelected(1) }
    @objc private func pageBeforeClicked() { moveSelectedToPage(-1) }
    @objc private func pageAfterClicked() { moveSelectedToPage(1) }
    @objc private func decorativeClicked() { setDecorative(decorativeBox.state == .on) }
    @objc private func doneClicked() { hide() }

    @objc private func applyClicked() {
        controller?.startLongTask { [weak self] in await self?.apply() }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !updating, (obj.object as? NSTextField) === altField else { return }
        setAltText(altField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        // Esc in the alternate text goes back to the piece in the list.
        guard control === altField, selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        focusList()
        return true
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { state.items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = state.items[row]
        let cell = tableView.makeView(withIdentifier: PieceCell.identifier, owner: nil) as? PieceCell ?? PieceCell()
        cell.show(item)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updating else { return }
        let row = table.selectedRow
        selected = state.items.indices.contains(row) ? state.items[row].index : nil
        fill()
        // Shows where it is: the page scrolled to it when the piece isn't on the page shown.
        if let item = selectedItem, let controller, item.block.readWith == nil, item.block.page < controller.pages.pageRects.count, item.block.page != controller.pages.currentPage {
            controller.go(item.block.page, targetY: item.block.box.y)
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard state.editable else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(state.items[row].index), forType: Self.pieceType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let plan, let text = info.draggingPasteboard.string(forType: Self.pieceType), let from = Int(text), !state.items.isEmpty,
              controller?.proAllows(.readingOrder) == true else { return false }
        let source = state.items.firstIndex { $0.index == from } ?? 0
        // Dropped above a row: onto that row going up, onto the one before it going down.
        let target = state.items[max(0, min(state.items.count - 1, row > source ? row - 1 : row))].index
        if target == from { return false }
        setPlan(ReadingOrder.dropped(plan, from, onto: target), select: target)
        return true
    }

    // MARK: Building

    private func build() {
        let title = NSTextField(labelWithString: "Reading Order")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.setAccessibilityLabel("Summary")

        let column = NSTableColumn(identifier: .init("piece"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowSizeStyle = .custom
        table.rowHeight = 40
        table.usesAutomaticRowHeights = false
        table.dataSource = self
        table.delegate = self
        table.registerForDraggedTypes([Self.pieceType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Pieces in reading order")
        table.onMove = { [weak self] in self?.moveSelected($0) }
        table.onMoveToPage = { [weak self] in self?.moveSelectedToPage($0) }
        table.onShowPage = { [weak self] in self?.showPage($0) }
        table.onEditText = { [weak self] in self?.editText() ?? false }
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)

        let moves: [(NSButton, String, String, Selector)] = [
            (upButton, "arrow.up", "Move up in the order (⌥↑)", #selector(upClicked)),
            (downButton, "arrow.down", "Move down in the order (⌥↓)", #selector(downClicked)),
            (pageBeforeButton, "arrow.up.to.line", "Read with the page before (⌥Page Up)", #selector(pageBeforeClicked)),
            (pageAfterButton, "arrow.down.to.line", "Read with the page after (⌥Page Down)", #selector(pageAfterClicked)),
        ]
        for (button, symbol, help, action) in moves {
            button.target = self
            button.action = action
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.bezelStyle = .rounded
            button.toolTip = help
            button.setAccessibilityLabel(help)
        }
        let moveRow = NSStackView(views: moves.map(\.0))
        moveRow.orientation = .horizontal
        moveRow.spacing = 6

        altLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        altField.delegate = self
        altField.usesSingleLineMode = false
        altField.cell?.wraps = true
        altField.cell?.isScrollable = false
        altField.lineBreakMode = .byWordWrapping
        altField.placeholderString = "Say what the picture shows"
        altField.heightAnchor.constraint(equalToConstant: 64).isActive = true
        decorativeBox.target = self
        decorativeBox.action = #selector(decorativeClicked)
        figureGroup.orientation = .vertical
        figureGroup.alignment = .leading
        figureGroup.spacing = 4
        for v in [altLabel, altField, decorativeBox] { figureGroup.addArrangedSubview(v) }
        altField.widthAnchor.constraint(equalTo: figureGroup.widthAnchor).isActive = true
        figureGroup.isHidden = true

        applyButton.target = self
        applyButton.action = #selector(applyClicked)
        doneButton.target = self
        doneButton.action = #selector(doneClicked)
        let endRow = NSStackView(views: [applyButton, NSView(), doneButton])
        endRow.orientation = .horizontal

        let stack = NSStackView(views: [title, summaryLabel, scroll, moveRow, figureGroup, endRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        for v in [summaryLabel, scroll, figureGroup, endRow] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        }
        stack.setAccessibilityLabel("Reading order")
        stack.translatesAutoresizingMaskIntoConstraints = false
        let solid = SolidPanelView()
        solid.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: solid.leadingAnchor), stack.trailingAnchor.constraint(equalTo: solid.trailingAnchor),
            stack.topAnchor.constraint(equalTo: solid.topAnchor), stack.bottomAnchor.constraint(equalTo: solid.bottomAnchor),
        ])
        panelController.view = solid
    }
}

/// The pane's background: solid, as Prepare Form's panel (the labels read on it whatever is behind).
private final class SolidPanelView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// A piece in the list: its number and what it is, then the start of its text.
private final class PieceCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("piece")
    private let kind = NSTextField(labelWithString: "")
    private let preview = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        kind.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        preview.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        preview.textColor = .secondaryLabelColor
        for label in [kind, preview] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let stack = NSStackView(views: [kind, preview])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ item: ReadingOrderItem) {
        kind.stringValue = "\(item.number). \(item.kind)"
        kind.textColor = item.needsAlt ? .systemRed : .labelColor
        preview.stringValue = item.preview
        preview.isHidden = item.preview.isEmpty
        setAccessibilityLabel(item.spoken)
    }
}

extension DocumentWindowController {
    /// Tools › Reading Order and Alt Text: shows the pane, or hides it.
    @objc func toggleReadingOrder(_ sender: Any?) {
        if readingOrder.isShown { return readingOrder.hide() }
        startLongTask { await self.readingOrder.show() }
    }
}
