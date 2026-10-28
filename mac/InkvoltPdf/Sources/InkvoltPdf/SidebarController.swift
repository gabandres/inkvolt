import AppKit
import PdfCore

/// The sidebar: page thumbnails, the document's outline (bookmarks), or its comments. A click goes there.
@MainActor
final class SidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    static let thumbWidth = 110.0

    private var engine: PdfEngine
    private let thumbs: PageRenderer
    private let table = NSTableView()
    private let outlineView = NSOutlineView()
    private let picker = NSSegmentedControl(labels: ["Pages", "Outline", "Comments"], trackingMode: .selectOne, target: nil, action: nil)
    let comments = CommentsList()
    private var tableScroll = NSScrollView()
    private var outlineScroll = NSScrollView()
    private(set) var outline: [OutlineItem] = []
    private var following = false

    /// Go to a page, from a y in it when known.
    var onGo: ((Int, Double?) -> Void)?

    init(engine: PdfEngine) {
        self.engine = engine
        thumbs = PageRenderer(engine: engine, label: "inkvolt.pdf.thumbs", qos: .utility, keepAtMost: 120)
        super.init(nibName: nil, bundle: nil)
        outline = ((try? engine.outline()) ?? []).map(OutlineItem.init)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Outline entries in the sidebar (the self-test counts them).
    var outlineCount: Int { outline.reduce(0) { $0 + $1.count } }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("page"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
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
        outlineScroll.documentView = outlineView
        outlineScroll.hasVerticalScroller = true
        outlineScroll.drawsBackground = false

        picker.target = self
        picker.action = #selector(pick)
        picker.selectedSegment = 0
        picker.setEnabled(!outline.isEmpty, forSegment: 1)
        picker.setAccessibilityLabel("Sidebar shows")
        outlineScroll.isHidden = true
        comments.isHidden = true

        let stack = NSStackView(views: [picker, tableScroll, outlineScroll, comments])
        comments.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.orientation = .vertical
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 0, right: 0)
        stack.spacing = 6
        view = stack

        thumbs.onRendered = { [weak self] page, _ in
            guard let self, page < self.engine.pageCount else { return }
            self.table.reloadData(forRowIndexes: [page], columnIndexes: [0])
        }
    }

    @objc private func pick() {
        tableScroll.isHidden = picker.selectedSegment != 0
        outlineScroll.isHidden = picker.selectedSegment != 1
        comments.isHidden = picker.selectedSegment != 2
    }

    /// Shows the thumbnails (0), the outline (1) or the comments (2).
    func show(_ segment: Int) {
        _ = view
        picker.selectedSegment = segment
        pick()
    }

    var shownSegment: Int { picker.selectedSegment }

    /// The content changed: thumbnails drawn again from the new engine (old pictures kept meanwhile), the outline read
    /// again.
    func reload(engine: PdfEngine) {
        self.engine = engine
        thumbs.engine = engine
        thumbs.invalidate()
        outline = ((try? engine.outline()) ?? []).map(OutlineItem.init)
        guard isViewLoaded else { return }
        picker.setEnabled(!outline.isEmpty, forSegment: 1)
        table.reloadData()
        outlineView.reloadData()
    }

    func stop() { thumbs.cancelAll() }

    /// Follows the page shown (without going anywhere).
    func showCurrent(_ page: Int) {
        guard isViewLoaded, page < engine.pageCount, table.selectedRow != page else { return }
        following = true
        table.selectRowIndexes([page], byExtendingSelection: false)
        table.scrollRowToVisible(page)
        following = false
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
        guard !following, table.selectedRow >= 0 else { return }
        onGo?(table.selectedRow, nil)
    }

    // MARK: Outline

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
}

/// An outline entry as the outline view holds it (an object, as NSOutlineView needs).
final class OutlineItem: NSObject {
    let title: String
    let page: Int
    let targetY: Double?
    let children: [OutlineItem]

    init(_ node: OutlineNode) {
        title = node.title
        page = node.pageIndex
        targetY = node.targetY
        children = node.children.map(OutlineItem.init)
    }

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
