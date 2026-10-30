import AppKit
import PdfCore
import UniformTypeIdentifiers

/// One side of a comparison: a document's bytes (an open document's, or a file's) and the password that opens it.
struct CompareSide: Sendable {
    var name: String
    var data: [UInt8]
    var password: String?
}

/// File › Compare Files… (the Windows app's `Compare` and `CompareWindow`): pick the original and the changed version
/// (an open document, or any PDF; Swap), then the Compare window: rows of lined-up pages side by side with one scroll
/// bar, the text differences highlighted on both sides (inserted green, removed red, changed amber, a marker where words
/// went missing on the other side), the list of changes to step through (⌘] and ⌘[, or the arrows) and a summary;
/// Visual overlays the pages (ink only in the original red, only in the changed file blue, shared grey, boxes around
/// what differs) for drawings and scans; pages without text are checked visually in the background. Annotated Copy
/// opens a copy of the changed file with every change as a comment, to save and share. Works on its own copies of both
/// documents, so the windows can change or close meanwhile.
@MainActor
final class CompareWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// The windows open (they keep themselves alive); the last one made (the self-test reads it).
    private static var shown: [CompareWindowController] = []
    private(set) static var last: CompareWindowController?

    struct Item {
        var change: Int?
        var row: Int
        var kind: String
        var text: String
        var color: NSColor
    }

    let oldSide: CompareSide
    let newSide: CompareSide
    private(set) var result: CompareResult?
    private(set) var oldText: [PageText] = []
    private(set) var newText: [PageText] = []
    private var oldEngine: PdfEngine?
    private var newEngine: PdfEngine?
    private(set) var items: [Item] = []
    private(set) var selected: Int?
    /// Rows without text that look different side by side (checked after the text).
    private(set) var visuallyDifferent: [Int] = []
    private let cancel = CancelToken()
    private(set) var task: Task<Void, Never>?
    private(set) var failure: String?

    let rowsView = CompareRowsView()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    let summary = NSTextField(wrappingLabelWithString: "Reading both documents…")
    let mode = NSSegmentedControl(labels: ["Text", "Visual"], trackingMode: .selectOne, target: nil, action: nil)
    private let previous = NSButton(title: "Previous", target: nil, action: nil)
    private let next = NSButton(title: "Next", target: nil, action: nil)
    let copyButton = NSButton(title: "Annotated Copy", target: nil, action: nil)
    private let position = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()

    @discardableResult
    static func show(old: CompareSide, new: CompareSide) -> CompareWindowController {
        let c = CompareWindowController(old: old, new: new)
        shown.append(c)
        last = c
        c.showWindow(nil)
        c.start()
        return c
    }

    init(old: CompareSide, new: CompareSide) {
        oldSide = old
        newSide = new
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 820), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Compare: \(old.name) and \(new.name)"
        window.minSize = NSSize(width: 700, height: 420)
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
        build()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        mode.selectedSegment = 0
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel("Compare by")
        mode.isEnabled = false
        for (b, action) in [(previous, #selector(previousChange)), (next, #selector(nextChange)), (copyButton, #selector(annotatedCopy))] {
            b.target = self
            b.action = action
            b.bezelStyle = .rounded
            b.isEnabled = false
        }
        previous.keyEquivalent = "["
        previous.keyEquivalentModifierMask = .command
        next.keyEquivalent = "]"
        next.keyEquivalentModifierMask = .command
        copyButton.toolTip = "A copy of the changed document with every change as a comment"
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let legend = NSTextField(labelWithString: "Original: \(oldSide.name)   Changed: \(newSide.name)")
        legend.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        legend.textColor = .secondaryLabelColor
        legend.lineBreakMode = .byTruncatingMiddle
        let bar = NSStackView(views: [progress, summary, mode, previous, position, next, copyButton])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 12)

        let column = NSTableColumn(identifier: .init("change"))
        column.title = "Changes"
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .sourceList
        table.usesAutomaticRowHeights = true
        table.setAccessibilityLabel("Changes")
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false

        scroll.documentView = rowsView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.drawsBackground = true
        rowsView.onPick = { [weak self] change in self?.select(change: change, scroll: false) }

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(listScroll)
        split.addArrangedSubview(scroll)
        listScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        listScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true

        let stack = NSStackView(views: [bar, legend, split])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        for v in [bar, split] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        legend.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
        window?.contentView = stack
        split.setPosition(270, ofDividerAt: 0)
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: scroll.contentView)
        scroll.contentView.postsFrameChangedNotifications = true
    }

    // MARK: Comparing

    private func start() {
        let old = oldSide, new = newSide, token = cancel
        task = Task { @MainActor in
            do {
                let read = try await Task.detached { () throws -> (PdfEngine, PdfEngine, [PageText], [PageText], CompareResult) in
                    let a = try PdfEngine.open(old.data, password: old.password)
                    let b = try PdfEngine.open(new.data, password: new.password)
                    let ta = try (0..<a.pageCount).map { try a.text($0, cache: false, cancel: token) }
                    let tb = try (0..<b.pageCount).map { try b.text($0, cache: false, cancel: token) }
                    return (a, b, ta, tb, try DocumentCompare.run(ta, tb, cancel: token))
                }.value
                (self.oldEngine, self.newEngine, self.oldText, self.newText, self.result) = read
                self.showResult()
                await self.checkScans()
            } catch is CancellationError {
                self.summary.stringValue = "Stopped."
            } catch {
                self.failure = "\(error)"
                self.summary.stringValue = "The documents couldn't be compared: \((error as? PdfEngineError)?.message ?? "\(error)")"
            }
            self.progress.stopAnimation(nil)
            self.progress.isHidden = true
            self.task = nil
        }
    }

    private func showResult() {
        guard let result, let a = oldEngine, let b = newEngine else { return }
        summary.stringValue = result.summary()
        items = result.changes.enumerated().map { i, c in
            let (kind, text): (String, String) = switch c.kind {
            case .inserted: ("Inserted", c.newText)
            case .deleted: ("Removed", c.oldText)
            case .changed: ("Changed", "\(c.oldText) → \(c.newText)")
            case .pageInserted: ("Page inserted", c.newText.isEmpty ? "(no text)" : c.newText)
            case .pageRemoved: ("Page removed", c.oldText.isEmpty ? "(no text)" : c.oldText)
            }
            return Item(change: i, row: c.row, kind: kind, text: text, color: CompareRowsView.markColor(c.kind))
        }
        rowsView.load(result: result, oldText: oldText, newText: newText, old: a, new: b)
        mode.isEnabled = true
        copyButton.isEnabled = true
        table.reloadData()
        relayout()
        updateButtons()
        NSAccessibility.post(element: window as Any, notification: .announcementRequested,
                             userInfo: [.announcement: result.summary(), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        Report.progress("compare: \(result.summary())")
    }

    /// Pages without text, compared by their pixels: the ones that differ are listed.
    private func checkScans() async {
        guard let result, let a = oldEngine, let b = newEngine else { return }
        let rows = result.rows.enumerated().filter { [.noTextOld, .noTextNew, .noTextBoth].contains($0.element.text) }
        let token = cancel
        for (r, row) in rows {
            guard let o = row.oldPage, let n = row.newPage, !token.isCancelled else { continue }
            let differs = (try? await Task.detached { () throws -> Bool in
                let diff = try VisualCompare.overlay(try a.render(o, scale: 0.5, cancel: token), try b.render(n, scale: 0.5, cancel: token), cancel: token)
                return !diff.regions.isEmpty
            }.value) ?? false
            if differs {
                visuallyDifferent.append(r)
                items.append(Item(change: nil, row: r, kind: "Looks different", text: "Page \(o + 1) and page \(n + 1) have no text to compare; their pictures differ (see Visual)",
                                  color: .systemPurple))
            }
        }
        items.sort { $0.row < $1.row }
        table.reloadData()
        if !visuallyDifferent.isEmpty {
            summary.stringValue = result.summary() + "; \(visuallyDifferent.count) page\(visuallyDifferent.count == 1 ? "" : "s") without text look different"
        }
        updateButtons()
    }

    /// Waits for the comparison and the scans' check (the self-test).
    func finished() async { await task?.value }

    static func color(_ c: AnnotColor) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }

    // MARK: Showing

    @objc private func resized() { relayout() }

    private func relayout() {
        rowsView.layoutRows(width: scroll.contentView.bounds.width)
    }

    @objc private func modeChanged() { setVisual(mode.selectedSegment == 1) }

    func setVisual(_ visual: Bool) {
        mode.selectedSegment = visual ? 1 : 0
        rowsView.visual = visual
        relayout()
        if let selected, items.indices.contains(selected) { reveal(items[selected]) }
    }

    @objc func nextChange() { step(1) }
    @objc func previousChange() { step(-1) }

    func step(_ delta: Int) {
        guard !items.isEmpty else { return NSSound.beep() }
        let i = selected.map { ($0 + delta + items.count) % items.count } ?? (delta > 0 ? 0 : items.count - 1)
        select(item: i)
    }

    private func select(item i: Int, scrollTo: Bool = true) {
        selected = i
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
        rowsView.selected = items[i].change
        if scrollTo { reveal(items[i]) }
        updateButtons()
    }

    /// A highlight clicked on a page.
    private func select(change: Int, scroll: Bool) {
        guard let i = items.firstIndex(where: { $0.change == change }) else { return }
        select(item: i, scrollTo: scroll)
    }

    private func reveal(_ item: Item) {
        let rect = rowsView.spot(change: item.change, row: item.row)
        rowsView.scrollToVisible(rect.insetBy(dx: 0, dy: -80))
    }

    private func updateButtons() {
        previous.isEnabled = !items.isEmpty
        next.isEnabled = !items.isEmpty
        position.stringValue = items.isEmpty ? "" : "\(selected.map { $0 + 1 } ?? 0) of \(items.count)"
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let where_ = result.map { r -> String in
            let x = r.rows[item.row]
            let pages = [x.oldPage.map { "page \($0 + 1)" }, x.newPage.map { "page \($0 + 1)" }].compactMap { $0 }
            return pages.count == 2 && pages[0] == pages[1] ? pages[0].capitalizedFirst : pages.joined(separator: " → ").capitalizedFirst
        } ?? ""
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = item.color.cgColor
        chip.layer?.cornerRadius = 4
        chip.widthAnchor.constraint(equalToConstant: 8).isActive = true
        chip.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let title = NSTextField(labelWithString: "\(item.kind), \(where_)")
        title.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        let text = NSTextField(wrappingLabelWithString: item.text.count > 160 ? String(item.text.prefix(160)) + "…" : item.text)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.maximumNumberOfLines = 3
        let col = NSStackView(views: [title, text])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 1
        let cell = NSStackView(views: [chip, col])
        cell.alignment = .top
        cell.edgeInsets = NSEdgeInsets(top: 3, left: 2, bottom: 3, right: 4)
        cell.setAccessibilityLabel("\(item.kind), \(where_): \(item.text)")
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row != selected else { return }
        select(item: row)
    }

    // MARK: Annotated copy

    @objc func annotatedCopy() { _ = makeAnnotatedCopy() }

    /// A copy of the changed document with every change as a comment, opened as a new unsaved document.
    @discardableResult
    func makeAnnotatedCopy() -> PdfDocument? {
        guard let result else { return nil }
        do {
            let bytes = try CompareReport.annotate(newSide.data, newSide.password, result, newText, oldName: oldSide.name,
                                                   summary: "Compared with \(oldSide.name): \(result.summary())")
            let stem = (newSide.name as NSString).deletingPathExtension
            let session = try DocumentSession.recover(bytes, originalPath: nil, "\(stem) (compared).pdf", password: newSide.password)
            let document = PdfDocument(recovered: session, page: 0, fileDate: nil)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            return document
        } catch is OwnerPasswordRequired {
            NewDocuments.present("The annotated copy needs the changed document's permissions password.", nil)
        } catch {
            NewDocuments.present("The annotated copy couldn't be made.", error)
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        cancel.cancel()
        rowsView.stop()
        let a = oldEngine, b = newEngine
        Task { @MainActor in
            await self.task?.value
            a?.close()
            b?.close()
            Self.shown.removeAll { $0 === self }
        }
    }

    // MARK: Picking the files

    /// File › Compare Files…: the original and the changed version, each an open document or a file; Swap.
    static func pick() {
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? PdfDocument }.filter { $0.session != nil }
        let alert = NSAlert()
        alert.messageText = "Compare Files"
        alert.informativeText = "Pick the original and the changed version. An open document is compared as it is now, unsaved changes included."
        func popup(_ select: Int) -> NSPopUpButton {
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            for d in documents { p.addItem(withTitle: d.name) }
            p.menu?.addItem(.separator())
            p.addItem(withTitle: "Choose a File…")
            p.selectItem(at: min(select, max(documents.count - 1, 0)))
            return p
        }
        let original = popup(documents.count > 1 ? 1 : 0), changed = popup(0)
        original.setAccessibilityLabel("Original")
        changed.setAccessibilityLabel("Changed version")
        var files: [ObjectIdentifier: URL] = [:]
        let chooser = FileChooser { popup in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf]
            guard let url = StartWindowController.pick(panel)?.first else {
                popup.selectItem(at: 0)
                return
            }
            files[ObjectIdentifier(popup)] = url
            if let same = popup.item(withTitle: url.lastPathComponent) { popup.menu?.removeItem(same) }
            popup.insertItem(withTitle: url.lastPathComponent, at: documents.count)
            popup.selectItem(at: documents.count)
        }
        for p in [original, changed] {
            p.target = chooser
            p.action = #selector(FileChooser.picked(_:))
            p.widthAnchor.constraint(equalToConstant: 300).isActive = true
        }
        let swap = NSButton(title: "Swap", target: chooser, action: #selector(FileChooser.swap))
        chooser.pair = (original, changed)
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Original:"), original], [NSTextField(labelWithString: "Changed:"), changed],
                                      [NSGridCell.emptyContentView, swap]])
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Compare")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        func side(_ p: NSPopUpButton) -> CompareSide? {
            let i = p.indexOfSelectedItem
            if i >= 0 && i < documents.count, let s = documents[i].session { return CompareSide(name: documents[i].name, data: s.data, password: s.password) }
            let title = p.titleOfSelectedItem ?? ""
            guard let url = files[ObjectIdentifier(p)] ?? files.values.first(where: { $0.lastPathComponent == title }) else { return nil }
            return fileSide(url)
        }
        guard let a = side(original), let b = side(changed) else { return }
        show(old: a, new: b)
    }

    /// A PDF file as a side, its password asked when it has one.
    static func fileSide(_ url: URL) -> CompareSide? {
        guard let data = try? Data(contentsOf: url) else {
            NewDocuments.present("\(url.lastPathComponent) couldn't be read.", nil)
            return nil
        }
        let bytes = Array(data)
        var password: String?
        while true {
            do {
                try PdfEngine.open(bytes, password: password).close()
                return CompareSide(name: url.lastPathComponent, data: bytes, password: password)
            } catch let e as PasswordRequired {
                guard let p = askPassword(url.lastPathComponent, wrong: e.wrongPassword) else { return nil }
                password = p
            } catch {
                NewDocuments.present("\(url.lastPathComponent) isn't a PDF Inkvolt PDF can read.", error)
                return nil
            }
        }
    }

    private static func askPassword(_ name: String, wrong: Bool) -> String? {
        if Report.isRunning { return nil }
        let alert = NSAlert()
        alert.messageText = wrong ? "That password doesn't open \(name)." : "\(name) is protected with a password."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// The pickers' "Choose a File…" and Swap.
    @MainActor
    private final class FileChooser: NSObject {
        let choose: (NSPopUpButton) -> Void
        var pair: (NSPopUpButton, NSPopUpButton)?
        init(_ choose: @escaping (NSPopUpButton) -> Void) { self.choose = choose }

        @objc func picked(_ sender: NSPopUpButton) {
            if sender.titleOfSelectedItem == "Choose a File…" { choose(sender) }
        }

        @objc func swap() {
            guard let (a, b) = pair else { return }
            let (ia, ib) = (a.indexOfSelectedItem, b.indexOfSelectedItem)
            let (ta, tb) = (a.titleOfSelectedItem, b.titleOfSelectedItem)
            if let tb, a.item(withTitle: tb) == nil { a.insertItem(withTitle: tb, at: max(0, a.numberOfItems - 2)) }
            if let ta, b.item(withTitle: ta) == nil { b.insertItem(withTitle: ta, at: max(0, b.numberOfItems - 2)) }
            if let tb { a.selectItem(withTitle: tb) } else { a.selectItem(at: ib) }
            if let ta { b.selectItem(withTitle: ta) } else { b.selectItem(at: ia) }
        }
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The rows of lined-up pages: the original on the left, the changed version on the right, each scaled to its half of
/// the width, with the changes marked; or, in Visual, one overlay per row with boxes around what differs. Pages are
/// drawn on demand, off the main thread, and only those near the visible ones keep their pictures.
@MainActor
final class CompareRowsView: NSView {
    private static let side = 16.0, gap = 16.0, header = 26.0, bottom = 14.0

    private struct Mark {
        var rect: RectD
        var kind: ChangeKind
        var change: Int
        var caret: Bool
    }

    private struct RowLayout {
        var top: Double
        var height: Double
        var scale: Double
        var oldBox: NSRect?
        var newBox: NSRect?
        var overlayBox: NSRect?
    }

    var visual = false
    var selected: Int? { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    private var result: CompareResult?
    private var old: PdfEngine?
    private var new: PdfEngine?
    private var oldMarks: [Int: [Mark]] = [:], newMarks: [Int: [Mark]] = [:]
    private var layouts: [RowLayout] = []
    /// Pictures by row and part (0 old, 1 new, 2 overlay), with the scale they were drawn at; overlay regions by row.
    private var pictures: [Int: (image: CGImage, scale: Double)] = [:]
    private var regions: [Int: [RectD]] = [:]
    private var pending = Set<Int>()
    private let token = CancelToken()
    private let queue = DispatchQueue(label: "inkvolt.pdf.compare", qos: .userInitiated)

    override var isFlipped: Bool { true }

    /// The overlay regions found so far (the self-test reads them).
    var overlayRegions: [Int: [RectD]] { regions }

    func load(result: CompareResult, oldText: [PageText], newText: [PageText], old: PdfEngine, new: PdfEngine) {
        self.result = result
        self.old = old
        self.new = new
        for (i, c) in result.changes.enumerated() {
            for s in c.old where s.page < oldText.count {
                for r in oldText[s.page].rects(s.start, s.end) { oldMarks[result.changes[i].row, default: []].append(Mark(rect: r, kind: c.kind, change: i, caret: false)) }
            }
            for s in c.new where s.page < newText.count {
                for r in newText[s.page].rects(s.start, s.end) { newMarks[result.changes[i].row, default: []].append(Mark(rect: r, kind: c.kind, change: i, caret: false)) }
            }
            if let a = c.oldAnchor, a.page < oldText.count, let r = caret(oldText[a.page], a.start) {
                oldMarks[c.row, default: []].append(Mark(rect: r, kind: c.kind, change: i, caret: true))
            }
            if let a = c.newAnchor, a.page < newText.count, let r = caret(newText[a.page], a.start) {
                newMarks[c.row, default: []].append(Mark(rect: r, kind: c.kind, change: i, caret: true))
            }
        }
    }

    /// A thin box where words went missing on this side.
    private func caret(_ text: PageText, _ at: Int) -> RectD? {
        let rects = at > 0 ? text.rects(at - 1, at) : text.rects(at, min(text.length, at + 1))
        guard let r = rects.first else { return nil }
        return RectD((at > 0 ? r.right : r.x) - 1, r.y, 2.5, r.height)
    }

    func stop() { token.cancel() }

    func layoutRows(width: Double) {
        guard let result, let old, let new else { return }
        let side = Self.side, gap = Self.gap
        var top = 10.0
        layouts = result.rows.map { row in
            let og = row.oldPage.map { old.page($0) }, ng = row.newPage.map { new.page($0) }
            let widest = max(og?.width ?? 0, ng?.width ?? 0, 1)
            let l: RowLayout
            if visual && og != nil && ng != nil {
                let scale = max(0.05, min(2, (width - 2 * side) / widest))
                let h = max(og?.height ?? 0, ng?.height ?? 0) * scale
                let w = widest * scale
                l = RowLayout(top: top, height: Self.header + h + Self.bottom, scale: scale, overlayBox: NSRect(x: (width - w) / 2, y: top + Self.header, width: w, height: h))
            } else {
                let half = (width - 2 * side - gap) / 2
                let scale = max(0.05, min(2, half / widest))
                let h = max(og?.height ?? 0, ng?.height ?? 0) * scale
                let ob = og.map { NSRect(x: side, y: top + Self.header, width: $0.width * scale, height: $0.height * scale) }
                let nb = ng.map { NSRect(x: side + half + gap, y: top + Self.header, width: $0.width * scale, height: $0.height * scale) }
                l = RowLayout(top: top, height: Self.header + h + Self.bottom, scale: scale, oldBox: ob, newBox: nb)
            }
            top += l.height
            return l
        }
        pictures = pictures.filter { key, pic in
            let r = key / 3
            return r < layouts.count && abs(pic.scale - layouts[r].scale) < 0.01 && (key % 3 == 2) == visual
        }
        setFrameSize(NSSize(width: width, height: top + 10))
        needsDisplay = true
    }

    /// Where a change is shown (view coordinates), else its row.
    func spot(change: Int?, row: Int) -> NSRect {
        guard layouts.indices.contains(row) else { return .zero }
        let l = layouts[row]
        if let change, !visual {
            for (marks, box) in [(newMarks[row] ?? [], l.newBox), (oldMarks[row] ?? [], l.oldBox)] {
                if let m = marks.first(where: { $0.change == change }), let box { return viewRect(m.rect, box, l.scale) }
            }
        }
        return NSRect(x: 0, y: l.top, width: bounds.width, height: min(l.height, 300))
    }

    private func viewRect(_ r: RectD, _ box: NSRect, _ scale: Double) -> NSRect {
        NSRect(x: box.minX + r.x * scale, y: box.minY + r.y * scale, width: r.width * scale, height: r.height * scale)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let row = layouts.firstIndex(where: { p.y >= $0.top && p.y < $0.top + $0.height }), !visual else { return }
        let l = layouts[row]
        for (marks, box) in [(newMarks[row] ?? [], l.newBox), (oldMarks[row] ?? [], l.oldBox)] {
            guard let box else { continue }
            if let m = marks.first(where: { viewRect($0.rect, box, l.scale).insetBy(dx: -2, dy: -2).contains(p) }) {
                selected = m.change
                onPick?(m.change)
                return
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        dirtyRect.fill()
        guard let result else { return }
        let visible = visibleRect.insetBy(dx: 0, dy: -400)
        var wanted = Set<Int>()
        for (r, l) in layouts.enumerated() where l.top < visible.maxY && l.top + l.height > visible.minY {
            let row = result.rows[r]
            drawHeader(r, row, l)
            if let box = l.overlayBox {
                wanted.insert(r * 3 + 2)
                drawPicture(r * 3 + 2, box, l.scale)
                NSColor.systemPurple.setStroke()
                for g in regions[r] ?? [] {
                    // Regions are pixels of the overlay at its render scale.
                    let k = l.scale / (pictures[r * 3 + 2]?.scale ?? l.scale)
                    let rect = NSRect(x: box.minX + g.x * k, y: box.minY + g.y * k, width: g.width * k, height: g.height * k).insetBy(dx: -3, dy: -3)
                    let path = NSBezierPath(rect: rect)
                    path.lineWidth = 2
                    path.stroke()
                }
                continue
            }
            for (part, box) in [(0, l.oldBox), (1, l.newBox)] {
                guard let box else {
                    drawMissing(part == 0 ? "Not in the original" : "Not in the changed version", l, part)
                    continue
                }
                wanted.insert(r * 3 + part)
                drawPicture(r * 3 + part, box, l.scale)
                for m in (part == 0 ? oldMarks[r] : newMarks[r]) ?? [] {
                    let rect = viewRect(m.rect, box, l.scale)
                    let color = Self.markColor(m.kind)
                    if m.caret {
                        color.setFill()
                        rect.fill()
                    } else {
                        color.withAlphaComponent(m.change == selected ? 0.55 : 0.35).setFill()
                        rect.fill(using: .sourceOver)
                    }
                    if m.change == selected {
                        NSColor.controlAccentColor.setStroke()
                        NSBezierPath(rect: rect.insetBy(dx: -2, dy: -2)).stroke()
                    }
                }
            }
        }
        request(wanted)
    }

    static func markColor(_ kind: ChangeKind) -> NSColor {
        switch kind {
        case .inserted, .pageInserted: CompareWindowController.color(CompareReport.insertedColor)
        case .deleted, .pageRemoved: CompareWindowController.color(CompareReport.removedColor)
        case .changed: CompareWindowController.color(CompareReport.changedColor)
        }
    }

    private func drawHeader(_ r: Int, _ row: CompareRow, _ l: RowLayout) {
        let what: String
        switch row.text {
        case .compared: what = row.changes == 0 ? "no changes" : row.changes == 1 ? "1 change" : "\(row.changes) changes"
        case .noTextOld, .noTextNew, .noTextBoth: what = "no text to compare: see Visual"
        case .onlyOld: what = "removed page"
        case .onlyNew: what = "inserted page"
        }
        let label = [row.oldPage.map { "Original page \($0 + 1)" }, row.newPage.map { "changed page \($0 + 1)" }].compactMap { $0 }.joined(separator: ", ")
        let text = "\(label.prefix(1).uppercased() + label.dropFirst()): \(what)" as NSString
        text.draw(at: NSPoint(x: Self.side, y: l.top + 5), withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                                                                             .foregroundColor: NSColor.secondaryLabelColor])
    }

    private func drawMissing(_ message: String, _ l: RowLayout, _ part: Int) {
        let half = (bounds.width - 2 * Self.side - Self.gap) / 2
        let rect = NSRect(x: Self.side + Double(part) * (half + Self.gap), y: l.top + Self.header, width: half, height: max(40, l.height - Self.header - Self.bottom))
        NSColor.separatorColor.setStroke()
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        path.setLineDash([4, 4], count: 2, phase: 0)
        path.stroke()
        (message as NSString).draw(at: NSPoint(x: rect.minX + 12, y: rect.minY + 12),
                                   withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.secondaryLabelColor])
    }

    private func drawPicture(_ key: Int, _ box: NSRect, _ scale: Double) {
        NSColor.white.setFill()
        box.fill()
        if let pic = pictures[key], let ctx = NSGraphicsContext.current?.cgContext {
            ctx.saveGState()
            ctx.translateBy(x: box.minX, y: box.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(pic.image, in: CGRect(x: 0, y: 0, width: box.width, height: box.height))
            ctx.restoreGState()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: box).stroke()
    }

    /// Draws these rows' pictures (for the mode shown) whether or not they are in view (the self-test, whose window may
    /// be on a locked screen).
    func want(rows: [Int]) {
        request(Set(rows.filter { layouts.indices.contains($0) }.flatMap { r in layouts[r].overlayBox != nil ? [r * 3 + 2] : [r * 3, r * 3 + 1] }))
    }

    /// Draws the pictures wanted that are missing (or at another scale); drops those far from view.
    private func request(_ wanted: Set<Int>) {
        for key in pictures.keys where !wanted.contains(key) && pictures.count > 24 { pictures[key] = nil }
        guard let result, let old, let new, !token.isCancelled else { return }
        let backing = Double(window?.backingScaleFactor ?? 2)
        for key in wanted.sorted() where pictures[key] == nil && !pending.contains(key) {
            let r = key / 3, part = key % 3
            let row = result.rows[r]
            let scale = min(layouts[r].scale * backing, 3)
            pending.insert(key)
            let token = self.token
            queue.async {
                var image: RenderedImage?
                var found: [RectD]?
                var problem: String?
                do {
                    if part == 2, let o = row.oldPage, let n = row.newPage {
                        let diff = try VisualCompare.overlay(try old.render(o, scale: scale, cancel: token), try new.render(n, scale: scale, cancel: token),
                                                             cancel: token)
                        image = diff.image
                        found = diff.regions
                    } else if part == 0, let o = row.oldPage {
                        image = try old.render(o, scale: scale, cancel: token)
                    } else if part == 1, let n = row.newPage {
                        image = try new.render(n, scale: scale, cancel: token)
                    }
                } catch is CancellationError {
                    // the window closed
                } catch {
                    problem = "\(error)"
                }
                let done = image, regionsFound = found, failed = problem
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.pending.remove(key)
                        if let failed { Report.progress("compare: row \(r) part \(part) not drawn: \(failed)") }
                        guard let done, let cg = PageRenderer.cgImage(done) else { return }
                        self.pictures[key] = (cg, scale)
                        if let regionsFound { self.regions[r] = regionsFound }
                        self.needsDisplay = true
                    }
                }
            }
        }
    }
}
