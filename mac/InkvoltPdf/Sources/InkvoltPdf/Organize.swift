import AppKit
import PdfCore
import UniformTypeIdentifiers

/// Organize pages (the Windows app's `Organize` and organizer view): Pages › Organize Pages shows every page as a card
/// in a grid (select several, drag to move, the commands in a context menu), and the same commands work on the sidebar's
/// thumbnails (several can be selected) or, with neither, the current page. Rotate, delete, duplicate, extract, move,
/// insert from a file (a PDF or pictures) or blank, crop: each one edit through the session's edit transaction (one undo
/// step; a signed file's change appended where it can be).
extension DocumentWindowController {
    private static func pages(_ n: Int) -> String { n == 1 ? "1 page" : "\(n) pages" }

    var organizerShown: Bool { organizer.map { !$0.isHidden } ?? false }

    /// The pages the page commands act on: the organizer's selection, else the sidebar thumbnails' (when several are
    /// selected or the menu was opened on them), else the current page.
    var selectedPages: [Int] {
        if organizerShown, let chosen = organizer?.selectedPages, !chosen.isEmpty { return chosen }
        let side = sidebar.selectedPages
        if !side.isEmpty && (side.count > 1 || sidebar.menuOpen) { return side }
        return engine.pageCount == 0 ? [] : [min(pages.currentPage, engine.pageCount - 1)]
    }

    /// Pages › Organize Pages: the grid of pages in place of the page view (and back).
    @objc func toggleOrganizer(_ sender: Any?) { showOrganizer(!organizerShown) }

    func showOrganizer(_ show: Bool) {
        if show && organizer == nil {
            let grid = OrganizerView(engine: engine)
            grid.onMove = { [weak self] moving, before in
                guard let self else { return }
                Task { await self.movePages(moving, before: before) }
            }
            grid.onDelete = { [weak self] in self?.deletePages(nil) }
            grid.onOpen = { [weak self] page in
                self?.showOrganizer(false)
                self?.go(page)
            }
            grid.menuMaker = { [weak self] in self?.pageMenu() }
            contentStack?.addArrangedSubview(grid)
            grid.widthAnchor.constraint(equalTo: contentStack!.widthAnchor).isActive = true
            organizer = grid
        }
        guard let grid = organizer else { return }
        let current = pages.currentPage
        grid.isHidden = !show
        scrollView.isHidden = show
        toolStrip.isHidden = show
        if show {
            grid.reload(engine: engine)
            grid.select([current])
            window?.makeFirstResponder(grid.grid)
        } else {
            window?.makeFirstResponder(pages)
            pages.requestVisible()
        }
    }

    /// The page commands, for the organizer's and the thumbnails' context menus.
    func pageMenu() -> NSMenu {
        let menu = NSMenu(title: "Pages")
        let entries: [(String, Selector)] = [
            ("Rotate Left", #selector(rotatePagesLeft(_:))), ("Rotate Right", #selector(rotatePagesRight(_:))), ("", Selector(("separator"))),
            ("Duplicate", #selector(duplicatePages(_:))), ("Extract Pages…", #selector(extractPages(_:))),
            ("Crop Pages…", #selector(cropPages(_:))), ("", Selector(("separator"))),
            ("Insert Pages from File…", #selector(insertPagesFromFile(_:))), ("Insert Blank Page", #selector(insertBlankPage(_:))),
            ("", Selector(("separator"))), ("Delete", #selector(deletePages(_:))),
        ]
        for (title, action) in entries {
            if title.isEmpty {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Commands (menus)

    @objc func rotatePagesLeft(_ sender: Any?) { pageCommand { await self.rotatePages($0, degrees: -90) } }
    @objc func rotatePagesRight(_ sender: Any?) { pageCommand { await self.rotatePages($0, degrees: 90) } }
    @objc func duplicatePages(_ sender: Any?) { pageCommand { await self.duplicate($0) } }
    @objc func deletePages(_ sender: Any?) {
        let chosen = selectedPages
        guard !chosen.isEmpty else { return NSSound.beep() }
        if chosen.count >= engine.pageCount {
            pdf.showError("A PDF needs at least one page.", PdfEditError("Leave at least one page. To get rid of the whole file, move it to the Trash in the Finder."))
            return
        }
        pageCommand { await self.removePages($0) }
    }

    @objc func insertBlankPage(_ sender: Any?) {
        guard let last = selectedPages.last else { return }
        let g = engine.page(last)
        Task { await self.insertBlank(at: last + 1, count: 1, size: (g.width, g.height)) }
    }

    private func pageCommand(_ run: @escaping @MainActor ([Int]) async -> Bool) {
        let chosen = selectedPages
        guard !chosen.isEmpty else { return NSSound.beep() }
        sidebar.menuOpen = false
        Task { _ = await run(chosen) }
    }

    /// Pages › Extract Pages…: the chosen pages saved as a new PDF (opened in a new tab unless unticked).
    @objc func extractPages(_ sender: Any?) {
        guard let window else { return }
        let chosen = selectedPages
        guard !chosen.isEmpty else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let base = (pdf.name as NSString).deletingPathExtension
        panel.nameFieldStringValue = "\(base) (\(chosen.count == 1 ? "page \(chosen[0] + 1)" : "pages \(PageRange.format(chosen))")).pdf"
        panel.message = "Save \(Self.pages(chosen.count)) (\(PageRange.format(chosen))) as a new PDF."
        let open = NSButton(checkboxWithTitle: "Open the new PDF", target: nil, action: nil)
        open.state = .on
        panel.accessoryView = open
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                if self.extract(chosen, to: url), open.state == .on {
                    NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
                }
            }
        }
    }

    /// Pages › Insert Pages from File…: a PDF's pages (all) or pictures (a page each), before or after the chosen pages.
    @objc func insertPagesFromFile(_ sender: Any?) {
        guard let window else { return }
        let chosen = selectedPages
        let first = chosen.first ?? 0, last = chosen.last ?? max(engine.pageCount - 1, 0)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose a PDF, or pictures (each becomes a page)."
        let place = NSPopUpButton(frame: .zero, pullsDown: false)
        place.addItems(withTitles: ["After page \(last + 1)", "Before page \(first + 1)", "At the start", "At the end"])
        let label = NSTextField(labelWithString: "Insert:")
        let row = NSStackView(views: [label, place])
        row.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        panel.accessoryView = row
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, !panel.urls.isEmpty else { return }
                let at = [last + 1, first, 0, self.engine.pageCount][max(place.indexOfSelectedItem, 0)]
                let urls = panel.urls
                DispatchQueue.main.async { MainActor.assumeIsolated { self.insertFiles(urls, at: at) } }
            }
        }
    }

    /// Reads the files chosen (asking a protected PDF's password) and inserts their pages at `at`.
    func insertFiles(_ urls: [URL], at: Int) {
        guard let source = loadSource(urls) else { return }
        Task { await self.insertPages(source, at: at) }
    }

    /// A PDF (its password asked when it needs one) or pictures made into one; nil when cancelled or unreadable.
    private func loadSource(_ urls: [URL]) -> PdfSource? {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        do {
            if pdfs.isEmpty {
                let images = try urls.map { url in ([UInt8](try Data(contentsOf: url)), url.lastPathComponent) }
                let made = try ImageImport.imagesToPdf(images.map { (bytes: $0.0, name: $0.1) })
                return PdfSource(made, nil, images.count == 1 ? images[0].1 : "\(images.count) pictures")
            }
            let url = pdfs[0]
            let data = [UInt8](try Data(contentsOf: url))
            var password: String?
            var wrong = false
            while PdfSecurity.needsOpenPassword(data) && !PdfSecurity.isOpenPassword(data, password) && (try? PdfEngine.open(data, password: password)) == nil {
                guard let given = PasswordPrompt.ask(file: url.lastPathComponent, wrong: wrong) else { return nil }
                password = given
                wrong = true
            }
            return PdfSource(data, password, url.lastPathComponent)
        } catch {
            pdf.showError("Those pages couldn't be read.", error)
            return nil
        }
    }

    /// Pages › Crop Pages…: margins trimmed off the chosen pages (or their crop removed).
    @objc func cropPages(_ sender: Any?) {
        guard let window else { return }
        let chosen = selectedPages
        guard !chosen.isEmpty else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Crop \(Self.pages(chosen.count))"
        alert.informativeText = "Trims the visible area of \(chosen.count == 1 ? "page \(chosen[0] + 1)" : "pages \(PageRange.format(chosen))"). "
            + "Nothing is deleted; Remove Crop shows the whole page again."
        let units = NSPopUpButton(frame: .zero, pullsDown: false)
        units.addItems(withTitles: ["Inches", "Millimeters", "Points"])
        let fields = ["Top", "Bottom", "Left", "Right"].map { name -> NSTextField in
            let f = NSTextField(string: "0")
            f.setAccessibilityLabel(name)
            f.widthAnchor.constraint(equalToConstant: 70).isActive = true
            return f
        }
        let remove = NSButton(checkboxWithTitle: "Remove crop instead (show the whole page again)", target: nil, action: nil)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Units:"), units, NSGridCell.emptyContentView, NSGridCell.emptyContentView],
            [NSTextField(labelWithString: "Top:"), fields[0], NSTextField(labelWithString: "Bottom:"), fields[1]],
            [NSTextField(labelWithString: "Left:"), fields[2], NSTextField(labelWithString: "Right:"), fields[3]],
        ])
        let stack = NSStackView(views: [grid, remove])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 120)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Crop")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                if remove.state == .on {
                    Task { await self.cropPages(chosen, margins: nil) }
                    return
                }
                let factor: Double = [72.0, 72.0 / 25.4, 1.0][max(units.indexOfSelectedItem, 0)]
                let values: [Double?] = fields.map { Double($0.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) }
                guard values.allSatisfy({ ($0 ?? -1) >= 0 }) else {
                    self.pdf.showError("Margins must be numbers of 0 or more.", nil)
                    return
                }
                let v = values.map { ($0 ?? 0) * factor }
                let m = Margins(v[2], v[0], v[3], v[1])
                guard m != Margins(0, 0, 0, 0) else {
                    self.pdf.showError("Enter at least one margin.", nil)
                    return
                }
                Task { await self.cropPages(chosen, margins: m) }
            }
        }
    }

    // MARK: The edits (the menus, the grid and the self-test call these)

    @discardableResult
    func rotatePages(_ chosen: [Int], degrees: Int) async -> Bool {
        let ok = await editor.run("Rotate \(Self.pages(chosen.count))") { d, pw in try PageEditor.rotate(d, pw, chosen, degrees) }
        if ok { reselect(chosen) }
        return ok
    }

    @discardableResult
    func removePages(_ chosen: [Int]) async -> Bool {
        guard !chosen.isEmpty, chosen.count < engine.pageCount else { return false }
        let ok = await editor.run("Delete \(Self.pages(chosen.count))") { d, pw in try PageEditor.delete(d, pw, chosen) }
        if ok { reselect([min(chosen.min() ?? 0, engine.pageCount - 1)]) }
        return ok
    }

    @discardableResult
    func duplicate(_ chosen: [Int]) async -> Bool {
        let ok = await editor.run("Duplicate \(Self.pages(chosen.count))") { d, pw in try PageEditor.duplicate(d, pw, chosen) }
        // The copy of the last chosen page lands after every earlier copy.
        if ok, let last = chosen.last { reselect([last + chosen.count]) }
        return ok
    }

    /// Moves `chosen` before page `before` (counted before the move; the page count puts them at the end).
    @discardableResult
    func movePages(_ chosen: [Int], before: Int) async -> Bool {
        let count = engine.pageCount
        let order = PageEditor.moveOrder(count, chosen, before)
        guard order != Array(0..<count), let firstMoved = chosen.first, let first = order.firstIndex(of: firstMoved) else { return false }
        let ok = await editor.run("Move \(Self.pages(chosen.count))") { d, pw in try PageEditor.reorder(d, pw, order) }
        if ok { reselect(Array(first..<(first + chosen.count))) }
        return ok
    }

    @discardableResult
    func insertPages(_ source: PdfSource, at: Int, pages sourcePages: [Int]? = nil) async -> Bool {
        let n = sourcePages?.count ?? ((try? PdfEngine.open(source.data, password: source.password))?.pageCount ?? 0)
        let ok = await editor.run("Insert \(Self.pages(n)) from \(source.name)") { d, pw in
            try PageEditor.insert(d, pw, source, sourcePages, at)
        }
        if ok { reselect(Array(at..<(at + n))) }
        return ok
    }

    @discardableResult
    func insertBlank(at: Int, count: Int, size: (width: Double, height: Double)) async -> Bool {
        let ok = await editor.run("Insert \(Self.pages(count))") { d, pw in try PageEditor.insertBlank(d, pw, at, count, size.width, size.height) }
        if ok { reselect(Array(at..<(at + count))) }
        return ok
    }

    /// Crops `chosen` by `margins` (page points, as shown), or removes their crop (nil).
    @discardableResult
    func cropPages(_ chosen: [Int], margins: Margins?) async -> Bool {
        let ok: Bool
        if let margins {
            ok = await editor.run("Crop \(Self.pages(chosen.count))") { d, pw in try PageEditor.crop(d, pw, chosen, margins) }
        } else {
            ok = await editor.run("Remove crop from \(Self.pages(chosen.count))") { d, pw in try PageEditor.uncrop(d, pw, chosen) }
        }
        if ok { reselect(chosen) }
        return ok
    }

    /// Writes `chosen` as a new PDF at `url` (the document itself unchanged); false (and the error shown) when it failed.
    @discardableResult
    func extract(_ chosen: [Int], to url: URL) -> Bool {
        guard let session = pdf.session else { return false }
        do {
            let bytes = try PageEditor.extract(session.data, session.password, chosen)
            try Data(bytes).write(to: url, options: .atomic)
            notify("Extracted \(Self.pages(chosen.count)) to “\(url.lastPathComponent)”.")
            return true
        } catch {
            pdf.showError("The pages couldn't be extracted.", error)
            return false
        }
    }

    /// After an edit, the pages it made or moved stay chosen (in the grid and the thumbnails).
    private func reselect(_ chosen: [Int]) {
        let valid = chosen.filter { $0 >= 0 && $0 < engine.pageCount }
        organizer?.select(valid)
        sidebar.selectPages(valid)
    }
}

/// The organizer: every page as a card (its picture and number) in a grid that wraps with the window. Click, ⌘-click and
/// ⇧-click choose pages; dragging chosen pages moves them; Delete deletes them; a double-click opens the page in the page
/// view; the context menu has the page commands.
@MainActor
final class OrganizerView: NSScrollView, NSCollectionViewDataSource, NSCollectionViewDelegate {
    static let pageType = NSPasteboard.PasteboardType("com.bermudezsystems.InkvoltPdf.page")
    static let cardWidth = 150.0

    let grid = OrganizerGrid()
    private var engine: PdfEngine
    private let thumbs: PageRenderer
    private var dragging: [Int] = []
    var onMove: (([Int], Int) -> Void)?
    var onDelete: (() -> Void)?
    var onOpen: ((Int) -> Void)?
    var menuMaker: (() -> NSMenu?)?

    init(engine: PdfEngine) {
        self.engine = engine
        thumbs = PageRenderer(engine: engine, label: "inkvolt.pdf.organizer", qos: .utility, keepAtMost: 200)
        super.init(frame: .zero)
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: Self.cardWidth + 16, height: Self.cardWidth * 1.3 + 40)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 16
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        grid.collectionViewLayout = layout
        grid.isSelectable = true
        grid.allowsMultipleSelection = true
        grid.allowsEmptySelection = true
        grid.dataSource = self
        grid.delegate = self
        grid.backgroundColors = [.underPageBackgroundColor]
        grid.register(PageCard.self, forItemWithIdentifier: PageCard.id)
        grid.registerForDraggedTypes([Self.pageType])
        grid.setDraggingSourceOperationMask(.move, forLocal: true)
        grid.owner = self
        grid.setAccessibilityLabel("Pages")
        documentView = grid
        hasVerticalScroller = true
        autohidesScrollers = true
        thumbs.onRendered = { [weak self] page, _ in
            guard let self, page < self.engine.pageCount else { return }
            (self.grid.item(at: IndexPath(item: page, section: 0)) as? PageCard)?.show(self.picture(page))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var pageCount: Int { grid.numberOfItems(inSection: 0) }

    /// The chosen pages, in order.
    var selectedPages: [Int] { grid.selectionIndexPaths.map(\.item).sorted() }

    func select(_ pages: [Int]) {
        let paths = Set(pages.filter { $0 < engine.pageCount }.map { IndexPath(item: $0, section: 0) })
        grid.selectionIndexPaths = paths
        if let first = pages.first, first < engine.pageCount {
            grid.scrollToItems(at: [IndexPath(item: first, section: 0)], scrollPosition: .nearestHorizontalEdge)
        }
    }

    /// The content changed: the cards drawn again from the new engine (old pictures kept meanwhile).
    func reload(engine: PdfEngine) {
        let chosen = selectedPages
        self.engine = engine
        thumbs.engine = engine
        thumbs.invalidate()
        grid.reloadData()
        grid.selectionIndexPaths = Set(chosen.filter { $0 < engine.pageCount }.map { IndexPath(item: $0, section: 0) })
    }

    func stop() { thumbs.cancelAll() }

    private func scale(_ page: Int) -> Double {
        let g = engine.page(page)
        return Self.cardWidth / max(max(g.width, g.height / 1.3), 1) * Double(window?.backingScaleFactor ?? 2)
    }

    private func picture(_ page: Int) -> NSImage? {
        guard let image = thumbs.image(page) else { return nil }
        let g = engine.page(page)
        let k = Self.cardWidth / max(max(g.width, g.height / 1.3), 1)
        return NSImage(cgImage: image.image, size: NSSize(width: g.width * k, height: g.height * k))
    }

    // MARK: Data source

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { engine.pageCount }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let card = collectionView.makeItem(withIdentifier: PageCard.id, for: indexPath) as! PageCard
        let page = indexPath.item
        card.number.stringValue = "\(page + 1)"
        card.view.setAccessibilityLabel("Page \(page + 1)")
        card.show(picture(page))
        if thumbs.image(page)?.scale ?? -1 < 0 { thumbs.request(page, scale: scale(page)) }
        return card
    }

    func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                        forRepresentedObjectAt indexPath: IndexPath) {
        let visible = collectionView.indexPathsForVisibleItems().map(\.item)
        if let lo = visible.min(), let hi = visible.max() { thumbs.keep(max(lo - 10, 0)...(hi + 10)) }
    }

    // MARK: Dragging to move

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let item = NSPasteboardItem()
        item.setString("\(indexPath.item)", forType: Self.pageType)
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                        forItemsAt indexPaths: Set<IndexPath>) {
        dragging = indexPaths.map(\.item).sorted()
    }

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        guard !dragging.isEmpty, draggingInfo.draggingSource as? NSCollectionView === grid else { return [] }
        if dropOperation.pointee == .on { dropOperation.pointee = .before }
        return .move
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo, indexPath: IndexPath,
                        dropOperation: NSCollectionView.DropOperation) -> Bool {
        defer { dragging = [] }
        return drop(dragging, before: indexPath.item)
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                        dragOperation operation: NSDragOperation) {
        dragging = []
    }

    /// Dropping `pages` before card `before` (what a drag ends with): moves them.
    @discardableResult
    func drop(_ pages: [Int], before: Int) -> Bool {
        guard !pages.isEmpty else { return false }
        onMove?(pages, min(max(before, 0), engine.pageCount))
        return true
    }

    // MARK: Keys, clicks, menu (from the grid)

    func keyDown(_ event: NSEvent) -> Bool {
        switch event.specialKey {
        case .delete, .deleteForward, .backspace:
            onDelete?()
            return true
        case .carriageReturn, .enter:
            if let page = selectedPages.first { onOpen?(page) }
            return true
        default:
            return false
        }
    }

    func doubleClicked(_ page: Int) { onOpen?(page) }

    func menu(at page: Int?) -> NSMenu? {
        if let page, !selectedPages.contains(page) { select([page]) }
        return selectedPages.isEmpty ? nil : menuMaker?()
    }
}

/// The organizer's collection view: hands keys, double-clicks and the context menu to its owner.
final class OrganizerGrid: NSCollectionView {
    weak var owner: OrganizerView?

    override func keyDown(with event: NSEvent) {
        if owner?.keyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) {
            owner?.doubleClicked(path.item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let path = indexPathForItem(at: convert(event.locationInWindow, from: nil))
        return owner?.menu(at: path?.item)
    }
}

/// A page card: the page's picture over its number, outlined when chosen.
final class PageCard: NSCollectionViewItem {
    static let id = NSUserInterfaceItemIdentifier("pageCard")
    let picture = NSImageView()
    let number = NSTextField(labelWithString: "")

    override func loadView() {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        picture.imageScaling = .scaleProportionallyUpOrDown
        number.alignment = .center
        number.textColor = .secondaryLabelColor
        for v in [picture, number] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        NSLayoutConstraint.activate([
            picture.topAnchor.constraint(equalTo: box.topAnchor, constant: 6),
            picture.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            picture.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            picture.bottomAnchor.constraint(equalTo: number.topAnchor, constant: -4),
            number.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            number.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            number.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.image)
        view = box
    }

    func show(_ image: NSImage?) { picture.image = image }

    override var isSelected: Bool {
        didSet {
            view.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor : nil
            view.setAccessibilitySelected(isSelected)
        }
    }
}
