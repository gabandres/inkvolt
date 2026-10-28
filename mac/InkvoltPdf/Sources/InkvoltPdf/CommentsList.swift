import AppKit
import PdfCore

/// The sidebar's Comments list: every comment of the document by page, replies under their comment, filtered by kind and
/// author. Clicking one goes to it and selects it on the page; Reply… and Delete act on the one selected (Delete and
/// Return work from the keyboard too, and double-click opens the inspector).
@MainActor
final class CommentsList: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private let outline = KeyOutlineView()
    private let scroll = NSScrollView()
    private let kindFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let authorFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let empty = NSTextField(labelWithString: "No comments")
    private let replyButton = NSButton(title: "Reply…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private var top: [CommentItem] = []
    private var all: [AnnotationInfo] = []
    private var following = false

    var onSelect: ((String) -> Void)?
    var onReply: ((String) -> Void)?
    var onDelete: ((String) -> Void)?
    var onInspect: ((String) -> Void)?

    init() {
        super.init(frame: .zero)
        let column = NSTableColumn(identifier: .init("comment"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .custom
        outline.usesAutomaticRowHeights = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(doubleClicked)
        outline.setAccessibilityLabel("Comments")
        outline.onKey = { [weak self] key in self?.key(key) ?? false }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        for b in [kindFilter, authorFilter] {
            b.controlSize = .small
            b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            b.target = self
            b.action = #selector(filtered)
        }
        kindFilter.setAccessibilityLabel("Show comments of kind")
        authorFilter.setAccessibilityLabel("Show comments by")
        for b in [replyButton, deleteButton] {
            b.controlSize = .small
            b.bezelStyle = .rounded
            b.target = self
        }
        replyButton.action = #selector(replyClicked)
        deleteButton.action = #selector(deleteClicked)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center

        let filters = NSStackView(views: [kindFilter, authorFilter])
        filters.distribution = .fillEqually
        filters.spacing = 4
        let buttons = NSStackView(views: [replyButton, deleteButton])
        buttons.spacing = 6
        let stack = NSStackView(views: [filters, empty, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 8, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            filters.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 6),
            filters.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6),
            scroll.leadingAnchor.constraint(equalTo: stack.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            empty.leadingAnchor.constraint(equalTo: stack.leadingAnchor), empty.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        updateButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `comments` (keeping the filters, the selection and what is expanded where they still apply).
    func show(_ comments: [AnnotationInfo], selected: String?) {
        all = comments
        let kinds = ["All Kinds"] + Array(Set(comments.filter { $0.replyTo == nil }.map(DocumentEditor.kindName))).sorted()
        let authors = ["All Authors"] + Array(Set(comments.compactMap { $0.author }.filter { !$0.isEmpty })).sorted()
        refill(kindFilter, kinds)
        refill(authorFilter, authors)
        rebuild()
        showSelected(selected)
    }

    private func refill(_ button: NSPopUpButton, _ titles: [String]) {
        let current = button.titleOfSelectedItem
        button.removeAllItems()
        button.addItems(withTitles: titles)
        if let current, titles.contains(current) { button.selectItem(withTitle: current) } else { button.selectItem(at: 0) }
    }

    /// Filters by kind (`nil`: all) and author, as the pop-up menus do.
    func filter(kind: String?, author: String?) {
        if let kind { kindFilter.selectItem(withTitle: kind) } else { kindFilter.selectItem(at: 0) }
        if let author { authorFilter.selectItem(withTitle: author) } else { authorFilter.selectItem(at: 0) }
        rebuild()
    }

    @objc private func filtered() { rebuild() }

    private func rebuild() {
        let kind = kindFilter.indexOfSelectedItem > 0 ? kindFilter.titleOfSelectedItem : nil
        let author = authorFilter.indexOfSelectedItem > 0 ? authorFilter.titleOfSelectedItem : nil
        let ids = Set(all.map(\.id))
        func item(_ c: AnnotationInfo) -> CommentItem {
            CommentItem(c, all.filter { $0.replyTo == c.id }.map(item))
        }
        // Top level: comments that reply to nothing still in the document.
        func isTop(_ c: AnnotationInfo) -> Bool {
            guard let parent = c.replyTo else { return true }
            return !ids.contains(parent)
        }
        func matchesKind(_ c: AnnotationInfo) -> Bool { kind == nil || DocumentEditor.kindName(c) == kind }
        func matchesAuthor(_ c: AnnotationInfo) -> Bool {
            guard let author else { return true }
            if c.author == author { return true }
            return all.contains { $0.replyTo == c.id && $0.author == author }
        }
        let shown: [AnnotationInfo] = all.filter { isTop($0) && matchesKind($0) && matchesAuthor($0) }
        top = shown.sorted(by: Self.inPageOrder).map(item)
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        empty.isHidden = !top.isEmpty
        empty.stringValue = all.isEmpty ? "No comments" : "No comments match"
        updateButtons()
    }

    private static func inPageOrder(_ a: AnnotationInfo, _ b: AnnotationInfo) -> Bool {
        if a.pageIndex != b.pageIndex { return a.pageIndex < b.pageIndex }
        if a.rect.y != b.rect.y { return a.rect.y < b.rect.y }
        return a.rect.x < b.rect.x
    }

    /// Rows shown (comments and replies), for the self-test.
    var rowCount: Int { outline.numberOfRows }
    var topCount: Int { top.count }

    /// Selects the row of `id` without going anywhere.
    func showSelected(_ id: String?) {
        following = true
        defer { following = false }
        guard let id, let item = find(id, in: top) else {
            outline.deselectAll(nil)
            updateButtons()
            return
        }
        let row = outline.row(forItem: item)
        if row >= 0 {
            outline.selectRowIndexes([row], byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
        updateButtons()
    }

    private func find(_ id: String, in items: [CommentItem]) -> CommentItem? {
        for i in items {
            if i.info.id == id { return i }
            if let f = find(id, in: i.children) { return f }
        }
        return nil
    }

    private var selectedId: String? { (outline.item(atRow: outline.selectedRow) as? CommentItem)?.info.id }

    private func updateButtons() {
        replyButton.isEnabled = selectedId != nil
        deleteButton.isEnabled = selectedId != nil
    }

    @objc private func replyClicked() { selectedId.map { onReply?($0) } }
    @objc private func deleteClicked() { selectedId.map { onDelete?($0) } }
    @objc private func doubleClicked() { selectedId.map { onInspect?($0) } }

    private func key(_ event: NSEvent) -> Bool {
        guard let id = selectedId else { return false }
        switch event.specialKey {
        case .delete, .deleteForward, .backspace:
            onDelete?(id)
            return true
        case .carriageReturn, .enter:
            onInspect?(id)
            return true
        default:
            return false
        }
    }

    // MARK: Outline

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? CommentItem)?.children.count ?? top.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? CommentItem)?.children[index] ?? top[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? CommentItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let c = (item as? CommentItem)?.info else { return nil }
        let cell = outlineView.makeView(withIdentifier: CommentCell.id, owner: nil) as? CommentCell ?? CommentCell()
        cell.show(c)
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
        guard !following, let id = selectedId else { return }
        onSelect?(id)
    }
}

/// A comment as the outline holds it (an object, as NSOutlineView needs).
final class CommentItem: NSObject {
    let info: AnnotationInfo
    let children: [CommentItem]

    init(_ info: AnnotationInfo, _ children: [CommentItem]) {
        self.info = info
        self.children = children
    }
}

/// An outline view that hands Delete and Return to its owner first.
final class KeyOutlineView: NSOutlineView {
    var onKey: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKey?(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A comment row: its kind's symbol, "Kind · author · p. n", and its text under it.
final class CommentCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("comment")
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        detail.cell?.truncatesLastVisibleLine = true
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        let text = NSStackView(views: [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        textField = title
        imageView = icon
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            icon.widthAnchor.constraint(equalToConstant: 16),
        ])
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ c: AnnotationInfo) {
        icon.image = NSImage(systemSymbolName: DocumentEditor.symbol(c), accessibilityDescription: nil)
        icon.contentTintColor = c.color.map(Palette.ns) ?? .secondaryLabelColor
        var parts = [DocumentEditor.kindName(c)]
        if let a = c.author, !a.isEmpty { parts.append(a) }
        parts.append("p. \(c.pageIndex + 1)")
        title.stringValue = parts.joined(separator: " · ")
        let text = c.contents.trimmingCharacters(in: .whitespacesAndNewlines)
        detail.stringValue = text
        detail.isHidden = text.isEmpty
        setAccessibilityLabel(DocumentEditor.spoken(c))
    }
}
