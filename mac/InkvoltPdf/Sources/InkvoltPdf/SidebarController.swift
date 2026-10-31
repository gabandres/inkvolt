import AppKit
import PdfCore

/// The sidebar: page thumbnails, the document's bookmarks, or its comments. A click goes there. Several thumbnails can
/// be chosen for the page commands (their context menu has them); bookmarks are added, renamed, deleted and dragged into
/// a new order or under another one (the window controller makes each change an edit).
@MainActor
final class SidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let thumbWidth = 110.0
    static let bookmarkType = NSPasteboard.PasteboardType("com.bermudezsystems.InkvoltPdf.bookmark")

    private var engine: PdfEngine
    private let thumbs: PageRenderer
    private let table = ThumbTable()
    private let outlineView = KeyOutlineView()
    private let readBookmarks: @MainActor () -> [Bookmark]
    private let picker = NSSegmentedControl(labels: ["Pages", "Bookmarks", "Comments", "Signatures"], trackingMode: .selectOne, target: nil,
                                            action: nil)
    let comments = CommentsList()
    let signatures = SignaturesPane()
    let accessibility = AccessibilityPane()
    private var tableScroll = NSScrollView()
    private var outlineScroll = NSScrollView()
    private(set) var outline: [OutlineItem] = []
    private var following = false
    private var draggedBookmark: [Int]?

    /// Go to a page, from a y in it when known.
    var onGo: ((Int, Double?) -> Void)?
    /// The page commands' menu, for the thumbnails.
    var pageMenuMaker: (() -> NSMenu?)?
    /// True while the thumbnails' context menu is open (its commands act on the thumbnails chosen).
    var menuOpen = false
    /// Bookmark changes, made into edits by the window controller (paths of indexes from the top level).
    var onAddBookmark: (() -> Void)?
    var onRenameBookmark: (([Int]) -> Void)?
    var onDeleteBookmark: (([Int]) -> Void)?
    var onMoveBookmark: ((_ from: [Int], _ parent: [Int], _ index: Int) -> Void)?

    init(engine: PdfEngine, bookmarks: @escaping @MainActor () -> [Bookmark]) {
        self.engine = engine
        readBookmarks = bookmarks
        thumbs = PageRenderer(engine: engine, label: "inkvolt.pdf.thumbs", qos: .utility, keepAtMost: 120)
        super.init(nibName: nil, bundle: nil)
        outline = OutlineItem.tree(bookmarks())
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Bookmarks in the sidebar (the self-test counts them).
    var outlineCount: Int { outline.reduce(0) { $0 + $1.count } }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.owner = self
        table.setAccessibilityLabel("Page thumbnails")
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true
        tableScroll.drawsBackground = false

        let oc = NSTableColumn(identifier: .init("title"))
        outlineView.addTableColumn(oc)
        outlineView.outlineTableColumn = oc
        outlineView.headerView = nil
        outlineView.style = .sourceList
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.action = #selector(outlineClicked)
        outlineView.registerForDraggedTypes([Self.bookmarkType])
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.setAccessibilityLabel("Bookmarks")
        outlineView.menu = bookmarkMenu()
        outlineView.onKey = { [weak self] event in
            guard let self, let path = self.clickedOrSelectedPath() else { return false }
            switch event.specialKey {
            case .delete, .deleteForward, .backspace:
                self.onDeleteBookmark?(path)
                return true
            case .carriageReturn, .enter:
                self.onRenameBookmark?(path)
                return true
            default:
                return false
            }
        }
        outlineScroll.documentView = outlineView
        outlineScroll.hasVerticalScroller = true
        outlineScroll.drawsBackground = false

        picker.target = self
        picker.action = #selector(pick)
        picker.selectedSegment = 0
        picker.setAccessibilityLabel("Sidebar shows")
        outlineScroll.isHidden = true
        comments.isHidden = true
        signatures.isHidden = true
        accessibility.isHidden = true
        picker.setEnabled(showsSignatures, forSegment: 3)

        let stack = NSStackView(views: [picker, tableScroll, outlineScroll, comments, signatures, accessibility])
        comments.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        signatures.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        accessibility.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        stack.spacing = 6
        view = stack

        thumbs.onRendered = { [weak self] page, _ in
            guard let self, page < self.engine.pageCount else { return }
            self.table.reloadData(forRowIndexes: [page], columnIndexes: [0])
        }
        expandOpen(outline)
    }

    @objc private func pick() {
        tableScroll.isHidden = picker.selectedSegment != 0
        outlineScroll.isHidden = picker.selectedSegment != 1
        comments.isHidden = picker.selectedSegment != 2
        signatures.isHidden = picker.selectedSegment != 3
        accessibility.isHidden = picker.selectedSegment != 4
    }

    /// Shows the Accessibility pane; its segment appears with the first check (a symbol: the four words fill the width).
    func showAccessibility() {
        _ = view
        if picker.segmentCount == 4 {
            picker.segmentCount = 5
            picker.setImage(NSImage(systemSymbolName: "accessibility", accessibilityDescription: "Accessibility"), forSegment: 4)
            picker.setToolTip("Accessibility", forSegment: 4)
            picker.setWidth(28, forSegment: 4)
        }
        show(4)
    }

    /// How many segments the picker has (the self-test reads it).
    var segmentCount: Int {
        _ = view
        return picker.segmentCount
    }

    /// The Signatures segment can be chosen (the document has signature fields); without, the thumbnails come back.
    var showsSignatures = false {
        didSet {
            guard isViewLoaded else { return }
            picker.setEnabled(showsSignatures, forSegment: 3)
            if !showsSignatures && picker.selectedSegment == 3 { show(0) }
        }
    }

    /// Shows the thumbnails (0), the bookmarks (1), the comments (2), the signatures (3) or, after a check, accessibility (4).
    func show(_ segment: Int) {
        _ = view
        picker.selectedSegment = segment
        pick()
    }

    var shownSegment: Int { picker.selectedSegment }

    /// The content changed: thumbnails drawn again from the new engine (old pictures kept meanwhile), the bookmarks read
    /// again.
    func reload(engine: PdfEngine) {
        self.engine = engine
        thumbs.engine = engine
        thumbs.invalidate()
        let chosen = selectedPages
        outline = OutlineItem.tree(readBookmarks())
        guard isViewLoaded else { return }
        table.reloadData()
        selectPages(chosen.filter { $0 < engine.pageCount })
        outlineView.reloadData()
        expandOpen(outline)
    }

    func stop() { thumbs.cancelAll() }

    /// Follows the page shown (without going anywhere); several thumbnails chosen stay chosen.
    func showCurrent(_ page: Int) {
        guard isViewLoaded, page < engine.pageCount, table.selectedRow != page, table.selectedRowIndexes.count <= 1 else { return }
        following = true
        table.selectRowIndexes([page], byExtendingSelection: false)
        table.scrollRowToVisible(page)
        following = false
    }

    /// The thumbnails chosen (page numbers, in order).
    var selectedPages: [Int] {
        guard isViewLoaded else { return [] }
        return table.selectedRowIndexes.map { $0 }.filter { $0 < engine.pageCount }
    }

    /// Chooses these thumbnails (without going to them).
    func selectPages(_ pages: [Int]) {
        guard isViewLoaded, !pages.isEmpty else { return }
        following = true
        table.selectRowIndexes(IndexSet(pages), byExtendingSelection: false)
        table.scrollRowToVisible(pages[0])
        following = false
    }

    /// The thumbnails' context menu: on a thumbnail not chosen, that one is chosen first.
    func thumbMenu(row: Int) -> NSMenu? {
        guard row >= 0 else { return nil }
        if !table.selectedRowIndexes.contains(row) { selectPages([row]) }
        menuOpen = true
        return pageMenuMaker?()
    }

    // MARK: Thumbnails

    func numberOfRows(in tableView: NSTableView) -> Int { engine.pageCount }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let g = engine.page(row)
        return Self.thumbWidth * g.height / max(g.width, 1) + 26
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: ThumbCell.id, owner: nil) as? ThumbCell ?? ThumbCell()
        let g = engine.page(row)
        cell.label.stringValue = "\(row + 1)"
        let scale = Self.thumbWidth / max(g.width, 1) * (view.window?.backingScaleFactor ?? 2)
        if let image = thumbs.image(row) {
            cell.picture.image = NSImage(cgImage: image.image, size: NSSize(width: Self.thumbWidth, height: Self.thumbWidth * g.height / max(g.width, 1)))
            if image.scale < 0 { thumbs.request(row, scale: scale) } // drawn before an edit: again
        } else {
            cell.picture.image = nil
            thumbs.request(row, scale: scale)
        }
        cell.setAccessibilityLabel("Page \(row + 1)")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !following, table.selectedRow >= 0, table.selectedRowIndexes.count == 1 else { return }
        onGo?(table.selectedRow, nil)
    }

    // MARK: Bookmarks

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? OutlineItem)?.children.count ?? outline.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? OutlineItem)?.children[index] ?? outline[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? OutlineItem)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let field = NSTextField(labelWithString: (item as? OutlineItem)?.title ?? "")
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    @objc private func outlineClicked() {
        guard let item = outlineView.item(atRow: outlineView.clickedRow) as? OutlineItem, item.page >= 0 else { return }
        onGo?(item.page, item.targetY)
    }

    private func expandOpen(_ items: [OutlineItem]) {
        for item in items where item.open && !item.children.isEmpty {
            outlineView.expandItem(item)
            expandOpen(item.children)
        }
    }

    /// The bookmark the menu was opened on, else the one selected.
    func clickedOrSelectedPath() -> [Int]? {
        let row = outlineView.clickedRow >= 0 ? outlineView.clickedRow : outlineView.selectedRow
        return (outlineView.item(atRow: row) as? OutlineItem)?.path
    }

    /// The bookmark selected (a new bookmark goes after it).
    var selectedBookmark: [Int]? { (outlineView.item(atRow: outlineView.selectedRow) as? OutlineItem)?.path }

    /// Selects the bookmark at `path` (after an edit), its parents expanded.
    func selectBookmark(_ path: [Int]) {
        guard isViewLoaded else { return }
        var items = outline
        var found: OutlineItem?
        for (depth, i) in path.enumerated() {
            guard i < items.count else { return }
            let item = items[i]
            if depth < path.count - 1 { outlineView.expandItem(item) }
            found = item
            items = item.children
        }
        guard let found else { return }
        let row = outlineView.row(forItem: found)
        if row >= 0 { outlineView.selectRowIndexes([row], byExtendingSelection: false) }
    }

    private func bookmarkMenu() -> NSMenu {
        let menu = NSMenu(title: "Bookmarks")
        let add = NSMenuItem(title: "Add Bookmark", action: #selector(addClicked), keyEquivalent: "")
        let rename = NSMenuItem(title: "Rename…", action: #selector(renameClicked), keyEquivalent: "")
        let delete = NSMenuItem(title: "Delete", action: #selector(deleteClicked), keyEquivalent: "")
        for item in [add, rename, delete] { item.target = self }
        menu.addItem(add)
        menu.addItem(.separator())
        menu.addItem(rename)
        menu.addItem(delete)
        return menu
    }

    @objc private func addClicked() { onAddBookmark?() }
    @objc private func renameClicked() { if let p = clickedOrSelectedPath() { onRenameBookmark?(p) } }
    @objc private func deleteClicked() { if let p = clickedOrSelectedPath() { onDeleteBookmark?(p) } }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let b = item as? OutlineItem else { return nil }
        let p = NSPasteboardItem()
        p.setString(b.key, forType: Self.bookmarkType)
        return p
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                     forItems draggedItems: [Any]) {
        draggedBookmark = (draggedItems.first as? OutlineItem)?.path
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                     operation: NSDragOperation) {
        draggedBookmark = nil
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        guard let from = draggedBookmark else { return [] }
        let parent = (item as? OutlineItem)?.path ?? []
        if parent.count >= from.count && Array(parent.prefix(from.count)) == from { return [] } // into itself
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        guard let from = draggedBookmark else { return false }
        let target = item as? OutlineItem
        let count = target?.children.count ?? outline.count
        return dropBookmark(from, parent: target?.path ?? [], index: index == NSOutlineViewDropOnItemIndex ? count : index)
    }

    /// Dropping the bookmark at `from` as child `index` of `parent` (what a drag ends with): moves it there.
    @discardableResult
    func dropBookmark(_ from: [Int], parent: [Int], index: Int) -> Bool {
        if parent.count >= from.count && Array(parent.prefix(from.count)) == from { return false }
        onMoveBookmark?(from, parent, index)
        return true
    }
}

/// The thumbnails' table: its context menu comes from the sidebar (the page commands).
final class ThumbTable: NSTableView {
    weak var owner: SidebarController?

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return owner?.thumbMenu(row: row)
    }
}

/// A bookmark as the outline view holds it (an object, as NSOutlineView needs), with its path in the tree.
final class OutlineItem: NSObject {
    let title: String
    let page: Int
    let targetY: Double?
    let open: Bool
    let path: [Int]
    let children: [OutlineItem]

    init(_ b: Bookmark, path: [Int]) {
        title = b.title
        page = b.pageIndex
        targetY = b.top
        open = b.open
        self.path = path
        children = b.children.enumerated().map { OutlineItem($0.element, path: path + [$0.offset]) }
    }

    static func tree(_ bookmarks: [Bookmark]) -> [OutlineItem] {
        bookmarks.enumerated().map { OutlineItem($0.element, path: [$0.offset]) }
    }

    /// Names the item on the pasteboard (its path).
    var key: String { path.map(String.init).joined(separator: ".") }

    var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
}

/// A thumbnail row: the page's picture over its number.
final class ThumbCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("thumb")
    let picture = NSImageView()
    let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true
        picture.layer?.borderWidth = 0.5
        picture.layer?.borderColor = NSColor.separatorColor.cgColor
        label.alignment = .center
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [picture, label])
        stack.orientation = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            picture.widthAnchor.constraint(equalToConstant: SidebarController.thumbWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }
}
