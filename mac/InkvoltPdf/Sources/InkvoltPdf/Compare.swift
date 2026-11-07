import AppKit
import PdfCore
import PrintCore
import UniformTypeIdentifiers

/// One side of a comparison: a document's bytes (an open document's, or a file's) and the password that opens it.
struct CompareSide: Sendable {
    var name: String
    var data: [UInt8]
    var password: String?
}

/// File › Compare Files… (the Windows app's `Compare` and `CompareWindow`): pick the original and the changed version
/// (an open document, or a file: a PDF, an Office file made into a PDF by LibreOffice, a picture of a scanned page; Swap),
/// then the Compare window: rows of lined-up pages side by side with one scroll bar, the text differences highlighted on
/// both sides (inserted green, removed red, changed amber, moved violet, reformatted blue, a marker where words went
/// missing on the other side), the list of changes to step through (⌘] and ⌘[, or the arrows), with a box per kind
/// (wording, moves, formatting, looks different) to hide it, and a summary. Scanned pages without text are recognized
/// first (Vision, on this Mac; skippable). Visual overlays the pages (ink only in the original red, only in the changed
/// file blue, shared grey, boxes around what differs), a scan lined up for shift and skew first; what looks different
/// besides the words is checked in the background and listed. Annotated Copy opens a copy of the changed file with every
/// change as a comment, to save and share. Works on its own copies of both documents, so the windows can change or close
/// meanwhile. A page that can't be read is listed as not compared.
@MainActor
final class CompareWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    /// The windows open (they keep themselves alive); the last one made (the self-test reads it).
    private static var shown: [CompareWindowController] = []
    private(set) static var last: CompareWindowController?

    /// The self-test's recognizer for scanned pages; nil: Vision in Recognize Text's language.
    static var testRecognizer: Recognizer?

    /// The list's kinds, each with a box to hide it (`notCompared` is always listed).
    enum ItemGroup: CaseIterable {
        case wording, moves, formatting, looks, notCompared
    }

    struct Item {
        var change: Int?
        var row: Int
        var kind: String
        var text: String
        var color: NSColor
        var group: ItemGroup = .wording
        /// Where it is when the row's pages don't say it (a move: from and to).
        var place: String?
    }

    let oldSide: CompareSide
    let newSide: CompareSide
    private(set) var result: CompareResult?
    private(set) var oldText: [PageText] = []
    private(set) var newText: [PageText] = []
    private var oldScan: [Bool] = [], newScan: [Bool] = []
    private var oldUnread = Set<Int>(), newUnread = Set<Int>()
    private var oldEngine: PdfEngine?
    private var newEngine: PdfEngine?
    /// Every entry, and those shown (the kinds not hidden).
    private(set) var allItems: [Item] = []
    private(set) var items: [Item] = []
    private(set) var hidden = Set<ItemGroup>()
    private(set) var selected: Int?
    /// Rows that look different besides their words (checked after the text), and those areas on the changed pages.
    private(set) var visuallyDifferent: [Int] = []
    private(set) var visualAreas: [CompareVisualArea] = []
    /// What happened to the scans' words: recognized, skipped, not read.
    private(set) var scanNote: String?
    private let cancel = CancelToken()
    /// Compare Without Reading Them: stops the scans' recognition only.
    private let skipToken = CancelToken()
    private(set) var task: Task<Void, Never>?
    private(set) var failure: String?

    let rowsView = CompareRowsView()
    private let scroll = NSScrollView()
    private let table = NSTableView()
    let summary = NSTextField(wrappingLabelWithString: loc("Reading both documents…"))
    let mode = NSSegmentedControl(labels: [loc("Text"), loc("Visual")], trackingMode: .selectOne, target: nil, action: nil)
    private let previous = NSButton(title: loc("Previous"), target: nil, action: nil)
    private let next = NSButton(title: loc("Next"), target: nil, action: nil)
    let copyButton = NSButton(title: loc("Annotated Copy"), target: nil, action: nil)
    let skipButton = NSButton(title: loc("Compare Without Reading Them"), target: nil, action: nil)
    private let position = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    /// The kinds' boxes, shown when the list has more than one kind.
    private let groupBar = NSStackView()
    private(set) var groupBoxes: [ItemGroup: NSButton] = [:]
    /// Zoom out, Fit and zoom in (Windows' Compare window: Ctrl+-, Ctrl+0, Ctrl+=); the pages fit the width at first.
    let zoomOut = NSButton(title: "−", target: nil, action: nil)
    let zoomFit = NSButton(title: loc("Fit"), target: nil, action: nil)
    let zoomIn = NSButton(title: "+", target: nil, action: nil)
    static let minZoom = 0.1, maxZoom = 8.0
    /// Most rows whose text was compared that are also looked at (the check renders each page).
    static let maxLookedAtRows = 2000

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
        window.title = loc("Compare: {0} and {1}", old.name, new.name)
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
        mode.setAccessibilityLabel(loc("Compare by"))
        mode.isEnabled = false
        for (b, action) in [(previous, #selector(previousChange)), (next, #selector(nextChange)), (copyButton, #selector(annotatedCopy)),
                            (skipButton, #selector(skipReading))] {
            b.target = self
            b.action = action
            b.bezelStyle = .rounded
            b.isEnabled = false
        }
        skipButton.isEnabled = true
        skipButton.isHidden = true
        let zooms: [(NSButton, Selector, String, String)] = [(zoomOut, #selector(zoomOutClicked), "-", loc("Zoom out (⌘-)")),
                                                             (zoomFit, #selector(zoomFitClicked), "0", loc("Fit the pages to the window (⌘0)")),
                                                             (zoomIn, #selector(zoomInClicked), "=", loc("Zoom in (⌘=)"))]
        for (b, action, key, tip) in zooms {
            b.target = self
            b.action = action
            b.bezelStyle = .rounded
            b.keyEquivalent = key
            b.keyEquivalentModifierMask = .command
            b.toolTip = tip
        }
        zoomOut.setAccessibilityLabel(loc("Zoom out"))
        zoomIn.setAccessibilityLabel(loc("Zoom in"))
        zoomFit.setAccessibilityLabel(loc("Fit to window"))
        previous.keyEquivalent = "["
        previous.keyEquivalentModifierMask = .command
        next.keyEquivalent = "]"
        next.keyEquivalentModifierMask = .command
        copyButton.toolTip = loc("A copy of the changed document with every change as a comment")
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        summary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let legend = NSTextField(labelWithString: loc("Original: {0}", oldSide.name) + "   " + loc("Changed: {0}", newSide.name))
        legend.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        legend.textColor = .secondaryLabelColor
        legend.lineBreakMode = .byTruncatingMiddle
        let bar = NSStackView(views: [progress, summary, skipButton, mode, zoomOut, zoomFit, zoomIn, previous, position, next, copyButton])
        bar.spacing = 10
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 4, right: 12)

        let shows: [(ItemGroup, String)] = [(.wording, loc("Show wording")), (.moves, loc("Show moves")), (.formatting, loc("Show formatting")),
                                            (.looks, loc("Show looks different"))]
        for (group, label) in shows {
            let box = NSButton(checkboxWithTitle: Self.groupName(group), target: self, action: #selector(groupToggled(_:)))
            box.state = .on
            box.setAccessibilityLabel(label)
            box.isHidden = true
            groupBoxes[group] = box
            groupBar.addArrangedSubview(box)
        }
        groupBar.spacing = 16
        groupBar.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 12)
        groupBar.isHidden = true

        let column = NSTableColumn(identifier: .init("change"))
        column.title = loc("Changes")
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .sourceList
        table.usesAutomaticRowHeights = true
        table.setAccessibilityLabel(loc("Changes"))
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.drawsBackground = false

        scroll.documentView = rowsView
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
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

        let stack = NSStackView(views: [bar, groupBar, legend, split])
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

    static func groupName(_ group: ItemGroup) -> String {
        switch group {
        case .wording: loc("Wording")
        case .moves: loc("Moves")
        case .formatting: loc("Formatting")
        case .looks: loc("Looks different")
        case .notCompared: loc("Not compared")
        }
    }

    // MARK: Comparing

    /// One document's pages as Compare reads them; a page the engine refuses or can't read is empty and counted, so its
    /// row says it wasn't compared.
    nonisolated private static func readPages(_ engine: PdfEngine, _ token: CancelToken, _ report: @escaping @Sendable () async -> Void) async throws
        -> (pages: [ComparePage], unread: Set<Int>) {
        var pages: [ComparePage] = []
        var unread = Set<Int>()
        for p in 0..<engine.pageCount {
            if token.isCancelled { throw CancellationError() }
            do {
                pages.append(try engine.comparePage(p, cancel: token))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                pages.append(.empty)
                unread.insert(p)
            }
            await report()
        }
        return (pages, unread)
    }

    private func start() {
        let old = oldSide, new = newSide, token = cancel
        task = Task { @MainActor in
            do {
                let (a, b) = try await Task.detached { () throws -> (PdfEngine, PdfEngine) in
                    let a = try PdfEngine.open(old.data, password: old.password)
                    do {
                        return (a, try PdfEngine.open(new.data, password: new.password))
                    } catch {
                        a.close()
                        throw error
                    }
                }.value
                (self.oldEngine, self.newEngine) = (a, b)
                let total = a.pageCount + b.pageCount
                let counter = PageCounter()
                let report: @Sendable () async -> Void = {
                    let done = counter.next()
                    if done % 4 == 0 || done == total {
                        await MainActor.run {
                            self.summary.stringValue = loc("Reading the text… page {0} of {1}", CoreLanguage.number(done), CoreLanguage.number(total))
                        }
                    }
                }
                async let readOld = Task.detached { try await Self.readPages(a, token, report) }.value
                async let readNew = Task.detached { try await Self.readPages(b, token, report) }.value
                let (oldRead, newRead) = try await (readOld, readNew)
                (self.oldUnread, self.newUnread) = (oldRead.unread, newRead.unread)
                (self.oldScan, self.newScan) = (oldRead.pages.map(\.isPicture), newRead.pages.map(\.isPicture))

                let recognized = try await self.readScans(a, oldRead.pages, b, newRead.pages)
                let formatting = Pro.allows(.compareOfficeAndScans)
                let oldSource = CompareSource.of(oldRead.pages, recognized: recognized.old, formatting: formatting)
                let newSource = CompareSource.of(newRead.pages, recognized: recognized.new, formatting: formatting)
                (self.oldText, self.newText) = (oldSource.pages, newSource.pages)
                self.summary.stringValue = loc("Comparing…")
                self.result = try await Task.detached { try DocumentCompare.run(oldSource, newSource, cancel: token) }.value
                self.showResult()
                await self.checkVisually()
            } catch is CancellationError {
                self.summary.stringValue = loc("Stopped.")
            } catch {
                self.failure = "\(error)"
                self.summary.stringValue = loc("The documents couldn't be compared: {0}", (error as? PdfEngineError)?.message ?? "\(error)")
            }
            self.skipButton.isHidden = true
            self.progress.stopAnimation(nil)
            self.progress.isHidden = true
            self.task = nil
        }
    }

    /// Recognizes the pages that are pictures with no text, one at a time, on this Mac (Vision; nothing leaves it).
    /// Reading long scans takes minutes, so it can be skipped: those pages are then only compared by how they look.
    private func readScans(_ oldEngine: PdfEngine, _ oldPages: [ComparePage], _ newEngine: PdfEngine, _ newPages: [ComparePage]) async throws
        -> (old: [Int: PageText], new: [Int: PageText]) {
        var read: (old: [Int: PageText], new: [Int: PageText]) = ([:], [:])
        var todo: [(engine: PdfEngine, page: Int, old: Bool)] = []
        for (p, page) in oldPages.enumerated() where page.isPicture && page.text.isEmpty { todo.append((oldEngine, p, true)) }
        for (p, page) in newPages.enumerated() where page.isPicture && page.text.isEmpty { todo.append((newEngine, p, false)) }
        if todo.isEmpty { return read }
        guard Pro.allows(.compareOfficeAndScans) else {
            scanNote = Pro.locked(.compareOfficeAndScans)
            return read
        }
        let language = SavedOcr.language
        let recognize = Self.testRecognizer ?? PageOcr.recognizer(VisionRecognizer(languages: language.map { [$0] }))
        let skip = skipToken
        skipButton.isHidden = false
        defer { skipButton.isHidden = true }
        var done = 0, failed = 0
        for (i, item) in todo.enumerated() {
            if cancel.isCancelled { throw CancellationError() }
            if skip.isCancelled { break }
            summary.stringValue = loc("Reading the scans… page {0} of {1}", CoreLanguage.number(i + 1), CoreLanguage.number(todo.count))
            let engine = item.engine, page = item.page
            let words = await Task.detached { () -> Result<[OcrWord], Error> in Result { try recognize(engine, page, skip) } }.value
            switch words {
            case .success(let w):
                let text = CompareScan.pageTextOf(w)
                if item.old { read.old[page] = text } else { read.new[page] = text }
            case .failure(let error):
                if error is CancellationError { break }
                failed += 1
                Report.progress("compare: a scanned page wasn't read: \(error)")
            }
            if !skip.isCancelled { done += 1 }
        }
        if cancel.isCancelled { throw CancellationError() }
        let unread = todo.count - done + failed
        scanNote = unread == 0 ? loc("The words on scanned pages were recognized, so some differences may be misreadings.")
            : unread == 1 ? loc("{0} scanned page wasn't read.", 1) : loc("{0} scanned pages weren't read.", CoreLanguage.number(unread))
        return read
    }

    @objc func skipReading() {
        skipToken.cancel()
        skipButton.isHidden = true
    }

    private func isScanRow(_ row: CompareRow) -> Bool {
        (row.oldPage.map { oldScan.indices.contains($0) && oldScan[$0] } ?? false) || (row.newPage.map { newScan.indices.contains($0) && newScan[$0] } ?? false)
    }

    private func isUnreadRow(_ row: CompareRow) -> Bool {
        (row.oldPage.map(oldUnread.contains) ?? false) || (row.newPage.map(newUnread.contains) ?? false)
    }

    private func showResult() {
        guard let result, let a = oldEngine, let b = newEngine else { return }
        allItems = result.changes.enumerated().map { i, c in item(i, c, result.rows[c.row]) }
        for (r, row) in result.rows.enumerated() where isUnreadRow(row) {
            let text: String
            if let o = row.oldPage, oldUnread.contains(o) {
                text = loc("Original page {0} couldn't be read, so it wasn't compared.", CoreLanguage.number(o + 1))
            } else {
                text = loc("Changed page {0} couldn't be read, so it wasn't compared.", CoreLanguage.number((row.newPage ?? 0) + 1))
            }
            allItems.append(Item(change: nil, row: r, kind: loc("Not compared"), text: text, color: .systemGray, group: .notCompared))
        }
        allItems = allItems.enumerated().sorted { ($0.element.row, $0.offset) < ($1.element.row, $1.offset) }.map(\.element)
        rowsView.load(result: result, oldText: oldText, newText: newText, old: a, new: b)
        rowsView.scanRows = Set(result.rows.indices.filter { isScanRow(result.rows[$0]) })
        rowsView.unreadRows = Set(result.rows.indices.filter { isUnreadRow(result.rows[$0]) })
        summary.stringValue = summaryText()
        mode.isEnabled = true
        copyButton.isEnabled = true
        refreshItems()
        relayout()
        NSAccessibility.post(element: window as Any, notification: .announcementRequested,
                             userInfo: [.announcement: summary.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        Report.progress("compare: \(result.summary())")
    }

    /// The result, what can't be compared word by word, and what happened to the scans.
    private func summaryText() -> String {
        guard let result else { return "" }
        var parts = [result.summary() + "."]
        if result.pairsWithoutText > 0 {
            parts.append(loc("Pages without text can't be compared word by word: they are checked visually, and Visual shows them overlaid."))
        }
        let unread = oldUnread.count + newUnread.count
        if unread > 0 {
            parts.append(unread == 1 ? loc("{0} page couldn't be read and wasn't compared.", 1)
                : loc("{0} pages couldn't be read and weren't compared.", CoreLanguage.number(unread)))
        }
        if let scanNote { parts.append(scanNote) }
        return parts.joined(separator: " ")
    }

    private func item(_ index: Int, _ c: CompareChange, _ row: CompareRow) -> Item {
        let color = CompareRowsView.markColor(c.kind)
        let m = c.maybeMisread
        switch c.kind {
        case .inserted:
            return Item(change: index, row: c.row, kind: m ? loc("Inserted (may be misread)") : loc("Inserted"), text: c.newText, color: color)
        case .deleted:
            return Item(change: index, row: c.row, kind: m ? loc("Removed (may be misread)") : loc("Removed"), text: c.oldText, color: color)
        case .changed:
            let kind = m ? loc("Changed (may be misread)") : loc("Changed", context: "a change")
            return Item(change: index, row: c.row, kind: kind, text: "\(c.oldText) → \(c.newText)", color: color)
        case .moved:
            var place: String?
            if let from = c.old.first, let to = c.new.first {
                place = from.page == to.page ? loc("on page {0}", CoreLanguage.number(to.page + 1))
                    : loc("page {0} → {1}", CoreLanguage.number(from.page + 1), CoreLanguage.number(to.page + 1))
            }
            return Item(change: index, row: c.row, kind: loc("Moved"), text: c.newText, color: color, group: .moves, place: place)
        case .formatted:
            return Item(change: index, row: c.row, kind: loc("Formatting"), text: "\(c.look?.describe() ?? ""): \(c.newText)", color: color, group: .formatting)
        case .pageInserted:
            return Item(change: index, row: c.row, kind: loc("Page inserted"), text: c.newText.isEmpty ? loc("(no text)") : c.newText, color: color)
        case .pageRemoved:
            return Item(change: index, row: c.row, kind: loc("Page removed"), text: c.oldText.isEmpty ? loc("(no text)") : c.oldText, color: color)
        }
    }

    /// The list as the kinds' boxes say, the pages' marks too.
    private func refreshItems() {
        let keep = selected.flatMap { items.indices.contains($0) ? items[$0].change : nil }
        items = allItems.filter { !hidden.contains($0.group) }
        var kinds = Set<ChangeKind>()
        if hidden.contains(.wording) { kinds.formUnion([.inserted, .deleted, .changed, .pageInserted, .pageRemoved]) }
        if hidden.contains(.moves) { kinds.insert(.moved) }
        if hidden.contains(.formatting) { kinds.insert(.formatted) }
        rowsView.hiddenKinds = kinds
        rowsView.hideLooks = hidden.contains(.looks)
        selected = keep.flatMap { change in items.firstIndex { $0.change == change } }
        table.reloadData()
        if let selected { table.selectRowIndexes([selected], byExtendingSelection: false) }
        updateGroups()
        updateButtons()
    }

    /// Offers a kind's box once the list has some of it, and when there's more than one kind to tell apart.
    private func updateGroups() {
        var present = 0
        for (group, box) in groupBoxes {
            let count = allItems.filter { $0.group == group }.count
            box.isHidden = count == 0
            box.title = "\(Self.groupName(group)) (\(CoreLanguage.number(count)))" // in every language: a name and a value, no words
            if count > 0 { present += 1 }
        }
        groupBar.isHidden = present < 2
    }

    @objc private func groupToggled(_ sender: NSButton) {
        guard let group = groupBoxes.first(where: { $0.value === sender })?.key else { return }
        showGroup(group, sender.state == .on)
    }

    /// Hides or shows one kind in the list and on the pages.
    func showGroup(_ group: ItemGroup, _ show: Bool) {
        if show { hidden.remove(group) } else { hidden.insert(group) }
        groupBoxes[group]?.state = show ? .on : .off
        refreshItems()
    }

    /// What the words don't say: each pair of pages rendered small and overlaid, then what differs is listed. Pages
    /// without text are all looked at. Pages with text only off the text, and only where it stayed in place (text that
    /// reflowed moves everything under it); a scan against a page made by a program is left out, since it differs all
    /// over. Two scans are lined up first.
    private func checkVisually() async {
        guard let result, let a = oldEngine, let b = newEngine else { return }
        var looked = 0
        let token = cancel
        for (r, row) in result.rows.enumerated() {
            guard let o = row.oldPage, let n = row.newPage, !isUnreadRow(row) else { continue }
            if token.isCancelled { return }
            let noText = row.text == .noTextOld || row.text == .noTextNew || row.text == .noTextBoth
            let scan = isScanRow(row)
            if !noText {
                if scan != (oldScan[o] && newScan[n]) { continue }
                if !scan && !VisualAreas.sameLayout(oldText[o], newText[n]) { continue }
                looked += 1
                if looked > Self.maxLookedAtRows { continue }
            }
            // Scans at the scale a changed word still shows at once ink may land a little off (the slack is in points).
            let scale = scan ? VisualCompare.scanCheckScale : 0.7
            let known = rowsView.alignments[r]
            let outcome = await Task.detached { () -> Result<(PageAlignment, VisualDiff), Error> in
                Result {
                    let alignment = scan ? try (known ?? CompareAlign.find(a, o, b, n, cancel: token)) : PageAlignment.none
                    return (alignment, try CompareRowsView.overlayOf(a, o, b, n, scale: scale, alignment: alignment, scan: scan, cancel: token))
                }
            }.value
            let what = noText ? Self.noTextWhat(row.text) : nil
            guard case .success(let (alignment, diff)) = outcome else {
                if token.isCancelled { return }
                if let what { rowsView.rowStates[r] = loc("{0}: couldn't be checked", what) }
                continue
            }
            if scan { rowsView.alignments[r] = alignment }
            let inPoints = diff.regions.map { RectD($0.x / scale, $0.y / scale, $0.width / scale, $0.height / scale) }
            let boxes = noText ? inPoints : VisualAreas.offText(inPoints, oldText[o], newText[n], alignment)
            if let what {
                rowsView.rowStates[r] = boxes.isEmpty ? loc("{0}: looks the same", what) : Self.areasDiffer(boxes.count, what)
            }
            rowsView.needsDisplay = true
            if boxes.isEmpty { continue }
            // An area beyond the changed page's edge has nowhere to be marked: a page's note says so.
            let page = RectD(0, 0, b.page(n).width, b.page(n).height)
            let onPage = boxes.map { alignment.boxToNew($0).intersect(page) }
            visualAreas.append(CompareVisualArea(n, onPage.filter { !$0.isEmpty }, offPage: onPage.filter(\.isEmpty).count))
            visuallyDifferent.append(r)
            let count = boxes.count == 1 ? loc("{0} area", 1) : loc("{0} areas", CoreLanguage.number(boxes.count))
            let share = diff.changedShare.formatted(.percent.precision(.fractionLength(1)).locale(CoreLanguage.locale))
            let text = noText ? loc("{0} ({1} of the page); no text to compare. Visual shows where.", count, share) : loc("{0} besides the text. Visual shows where.", count)
            let at = allItems.firstIndex { $0.row > r } ?? allItems.count
            allItems.insert(Item(change: nil, row: r, kind: loc("Looks different"), text: text, color: .systemPurple, group: .looks), at: at)
            refreshItems()
        }
    }

    private static func noTextWhat(_ text: RowText) -> String {
        switch text {
        case .noTextOld: loc("no text on the original page")
        case .noTextNew: loc("no text on the changed page")
        default: loc("no text")
        }
    }

    private static func areasDiffer(_ n: Int, _ what: String) -> String {
        n == 1 ? loc("{1}: {0} area looks different", 1, what) : loc("{1}: {0} areas look different", CoreLanguage.number(n), what)
    }

    /// Waits for the comparison and the visual check (the self-test).
    func finished() async { await task?.value }

    static func color(_ c: AnnotColor) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }

    // MARK: Showing

    @objc private func resized() { relayout() }

    private func relayout() {
        rowsView.layoutRows(width: scroll.contentView.bounds.width)
    }

    @objc func zoomInClicked() { zoom(by: 1.25) }
    @objc func zoomOutClicked() { zoom(by: 1 / 1.25) }
    @objc func zoomFitClicked() { setZoom(0) }

    /// From the zoom shown (Fit: the scale of the first row in view), by `factor`, within 10 % to 800 %.
    func zoom(by factor: Double) {
        let current = rowsView.zoom > 0 ? rowsView.zoom : rowsView.scale(at: scroll.contentView.bounds.minY)
        setZoom(min(max(current * factor, Self.minZoom), Self.maxZoom))
    }

    /// 0 fits the pages to the window's width; else points to the screen's points. The row in view stays in view.
    func setZoom(_ zoom: Double) {
        let y = scroll.contentView.bounds.minY
        let anchor = rowsView.place(at: y)
        rowsView.zoom = zoom
        relayout()
        zoomFit.title = zoom > 0 ? "\(Int((zoom * 100).rounded())) %" : loc("Fit") // bounded: the zoom buttons keep it within minZoom...maxZoom
        zoomOut.isEnabled = zoom == 0 || zoom > Self.minZoom + 0.0001
        zoomIn.isEnabled = zoom == 0 || zoom < Self.maxZoom - 0.0001
        if let anchor {
            let top = rowsView.top(row: anchor.row, within: anchor.within)
            rowsView.scroll(NSPoint(x: scroll.contentView.bounds.minX, y: top))
        }
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
        position.stringValue = items.isEmpty ? "" : loc("{0} of {1}", CoreLanguage.number(selected.map { $0 + 1 } ?? 0), CoreLanguage.number(items.count))
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let where_ = item.place ?? result.map { r -> String in
            let x = r.rows[item.row]
            let o = x.oldPage.map { $0 + 1 }, n = x.newPage.map { $0 + 1 }
            if let o, let n, o != n { return loc("Page {0} → page {1}", CoreLanguage.number(o), CoreLanguage.number(n)) }
            return (o ?? n).map { loc("Page {0}", CoreLanguage.number($0)) } ?? ""
        } ?? ""
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.backgroundColor = item.color.cgColor
        chip.layer?.cornerRadius = 4
        chip.widthAnchor.constraint(equalToConstant: 8).isActive = true
        chip.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let title = NSTextField(labelWithString: loc("{0}, {1}", item.kind, where_))
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
        cell.setAccessibilityLabel(loc("{0}, {1}: {2}", item.kind, where_, item.text))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row != selected else { return }
        select(item: row)
    }

    // MARK: Annotated copy

    @objc func annotatedCopy() { _ = makeAnnotatedCopy() }

    /// A copy of the changed document with every change as a comment, and what looks different, opened as a new unsaved
    /// document.
    @discardableResult
    func makeAnnotatedCopy() -> PdfDocument? {
        guard let result else { return nil }
        do {
            let areas = visualAreas.reduce(0) { $0 + $1.boxes.count + $1.offPage }
            let looks = areas == 0 ? "" : " " + loc("{0} other areas look different.", CoreLanguage.number(areas))
            let bytes = try CompareReport.annotate(newSide.data, newSide.password, result, newText, oldName: oldSide.name,
                                                   summary: loc("Compared with {0}: {1}", oldSide.name, result.summary()) + looks, visual: visualAreas)
            let stem = (newSide.name as NSString).deletingPathExtension
            let session = try DocumentSession.recover(bytes, originalPath: nil, loc("{0} (compared).pdf", stem), password: newSide.password)
            let document = PdfDocument(recovered: session, page: 0, fileDate: nil)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            return document
        } catch is OwnerPasswordRequired {
            NewDocuments.present(loc("The annotated copy needs the changed document's permissions password."), nil)
        } catch {
            NewDocuments.present(loc("The annotated copy couldn't be made."), error)
        }
        return nil
    }

    func windowWillClose(_ notification: Notification) {
        cancel.cancel()
        skipToken.cancel()
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

    /// How many times Compare Files' question was asked while the self-test ran (it isn't shown then).
    private(set) static var picksAsked = 0

    /// Pictures of scanned pages a side can be.
    static let pictureExtensions = ["png", "jpg", "jpeg", "tif", "tiff", "bmp", "heic"]

    /// File › Compare Files…: the original and the changed version, each an open document or a file; Swap.
    static func pick() {
        if Report.skipsDialogs { return picksAsked += 1 }
        let documents = NSDocumentController.shared.documents.compactMap { $0 as? PdfDocument }.filter { $0.session != nil }
        let alert = NSAlert()
        alert.messageText = loc("Compare Files")
        alert.informativeText = loc("Pick the original and the changed version. An open document is compared as it is now, unsaved changes included. Either one can be a Word, Excel or PowerPoint file (made into a PDF with LibreOffice) or a picture of a scanned page: its words are recognized on this Mac.")
        func popup(_ select: Int) -> NSPopUpButton {
            let p = NSPopUpButton(frame: .zero, pullsDown: false)
            for d in documents { p.addItem(withTitle: d.name) }
            p.menu?.addItem(.separator())
            p.addItem(withTitle: loc("Choose a File…"))
            p.selectItem(at: min(select, max(documents.count - 1, 0)))
            return p
        }
        let original = popup(documents.count > 1 ? 1 : 0), changed = popup(0)
        original.setAccessibilityLabel(loc("Original"))
        changed.setAccessibilityLabel(loc("Changed version"))
        var files: [ObjectIdentifier: URL] = [:]
        let chooser = FileChooser { popup in
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.pdf] + Converting.types(OfficeFiles.panelExtensions(OfficeApp.allCases) + pictureExtensions)
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
        let swap = NSButton(title: loc("Swap"), target: chooser, action: #selector(FileChooser.swap))
        chooser.pair = (original, changed)
        let grid = NSGridView(views: [[NSTextField(labelWithString: loc("Original:")), original], [NSTextField(labelWithString: loc("Changed:")), changed],
                                      [NSGridCell.emptyContentView, swap]])
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        alert.accessoryView = grid
        alert.addButton(withTitle: loc("Compare"))
        alert.addButton(withTitle: loc("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        func side(_ p: NSPopUpButton) -> (side: CompareSide?, url: URL?) {
            let i = p.indexOfSelectedItem
            if i >= 0 && i < documents.count, let s = documents[i].session { return (CompareSide(name: documents[i].name, data: s.data, password: s.password), nil) }
            let title = p.titleOfSelectedItem ?? ""
            return (nil, files[ObjectIdentifier(p)] ?? files.values.first(where: { $0.lastPathComponent == title }))
        }
        let a = side(original), b = side(changed)
        Task { @MainActor in
            guard let old = await resolve(a), let new = await resolve(b) else { return }
            show(old: old, new: new)
        }
    }

    private static func resolve(_ choice: (side: CompareSide?, url: URL?)) async -> CompareSide? {
        if let side = choice.side { return side }
        guard let url = choice.url else { return nil }
        return await fileSide(url)
    }

    /// A file as a side (Windows' `Comparing.LoadFile`): a PDF as it is (its password asked when it has one), an Office
    /// file made into a PDF by LibreOffice, a picture as a page. Nil (after saying why) when it can't be.
    static func fileSide(_ url: URL) async -> CompareSide? {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        if ext != "pdf" && (OfficeFiles.appFor(url.path) != nil || pictureExtensions.contains(ext)) {
            guard Pro.allows(.compareOfficeAndScans) else {
                ProWindowController.show(feature: .compareOfficeAndScans)
                return nil
            }
            if OfficeFiles.appFor(url.path) != nil {
                return await Converting.pdfForCompare(url).map { CompareSide(name: name, data: $0, password: nil) }
            }
            do {
                let bytes = Array(try Data(contentsOf: url))
                let pdf = try await Task.detached { try ImageImport.imagesToPdf([(bytes: bytes, name: name)]) }.value
                return CompareSide(name: name, data: pdf, password: nil)
            } catch {
                NewDocuments.present(loc("Couldn't read {0}", name), error)
                return nil
            }
        }
        guard let data = try? Data(contentsOf: url) else {
            NewDocuments.present(loc("{0} couldn't be read.", name), nil)
            return nil
        }
        let bytes = Array(data)
        var password: String?
        while true {
            do {
                try PdfEngine.open(bytes, password: password).close()
                return CompareSide(name: name, data: bytes, password: password)
            } catch let e as PasswordRequired {
                guard let p = askPassword(name, wrong: e.wrongPassword) else { return nil }
                password = p
            } catch {
                NewDocuments.present(loc("{0} isn't a PDF Inkvolt PDF can read.", name), error)
                return nil
            }
        }
    }

    private static func askPassword(_ name: String, wrong: Bool) -> String? {
        if Report.skipsDialogs { return nil }
        let alert = NSAlert()
        alert.messageText = wrong ? loc("That password doesn't open {0}.", name) : loc("{0} is protected with a password.", name)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.setAccessibleName(loc("Password"))
        alert.accessoryView = field
        alert.addButton(withTitle: loc("Open"))
        alert.addButton(withTitle: loc("Cancel"))
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
            if sender.titleOfSelectedItem == loc("Choose a File…") { choose(sender) }
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

/// Pages read so far, from both documents' reading at once.
private final class PageCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        done += 1
        return done
    }
}

/// The rows of lined-up pages: the original on the left, the changed version on the right, each scaled to its half of
/// the width, with the changes marked; or, in Visual, one overlay per row with boxes around what differs (a scan lined up
/// first). Pages are drawn on demand, off the main thread, and only those near the visible ones keep their pictures.
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
    /// 0: the pages fit the width given; else the scale, the view as wide as the pages need.
    var zoom = 0.0
    var selected: Int? { didSet { needsDisplay = true } }
    var onPick: ((Int) -> Void)?
    /// Kinds whose marks aren't drawn (their box in the window is off), and whether the overlay's boxes are hidden.
    var hiddenKinds = Set<ChangeKind>() { didSet { needsDisplay = true } }
    var hideLooks = false { didSet { needsDisplay = true } }
    /// Rows with a scan on either side (overlaid lined up, with slack), rows with a page that couldn't be read, what the
    /// visual check found for a row without text, and the scans' alignments found so far.
    var scanRows = Set<Int>()
    var unreadRows = Set<Int>()
    var rowStates: [Int: String] = [:] { didSet { needsDisplay = true } }
    var alignments: [Int: PageAlignment] = [:]
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
        // A move's two sides are on different rows: each side is marked on the row its page is on.
        var rowOfOld: [Int: Int] = [:], rowOfNew: [Int: Int] = [:]
        for (r, row) in result.rows.enumerated() {
            if let o = row.oldPage { rowOfOld[o] = r }
            if let n = row.newPage { rowOfNew[n] = r }
        }
        for (i, c) in result.changes.enumerated() where c.kind != .pageInserted && c.kind != .pageRemoved {
            for s in c.old where s.page < oldText.count {
                let r = rowOfOld[s.page] ?? c.row
                for rect in oldText[s.page].rects(s.start, s.end) { oldMarks[r, default: []].append(Mark(rect: rect, kind: c.kind, change: i, caret: false)) }
            }
            for s in c.new where s.page < newText.count {
                let r = rowOfNew[s.page] ?? c.row
                for rect in newText[s.page].rects(s.start, s.end) { newMarks[r, default: []].append(Mark(rect: rect, kind: c.kind, change: i, caret: false)) }
            }
            if let a = c.oldAnchor, a.page < oldText.count, let rect = caret(oldText[a.page], a.start) {
                oldMarks[rowOfOld[a.page] ?? c.row, default: []].append(Mark(rect: rect, kind: c.kind, change: i, caret: true))
            }
            if let a = c.newAnchor, a.page < newText.count, let rect = caret(newText[a.page], a.start) {
                newMarks[rowOfNew[a.page] ?? c.row, default: []].append(Mark(rect: rect, kind: c.kind, change: i, caret: true))
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

    func layoutRows(width viewWidth: Double) {
        guard let result, let old, let new else { return }
        let side = Self.side, gap = Self.gap
        var top = 10.0
        // Zoomed: wide enough for the widest row at that scale (side by side, or one page in Visual), never narrower.
        var width = viewWidth
        if zoom > 0 {
            var maxWidth = 1.0
            for row in result.rows {
                maxWidth = max(maxWidth, row.oldPage.map { old.page($0).width } ?? 0, row.newPage.map { new.page($0).width } ?? 0)
            }
            let needed = visual ? 2 * side + maxWidth * zoom : 2 * side + gap + 2 * maxWidth * zoom
            width = max(viewWidth, needed)
        }
        layouts = result.rows.map { row in
            let og = row.oldPage.map { old.page($0) }, ng = row.newPage.map { new.page($0) }
            let widest = max(og?.width ?? 0, ng?.width ?? 0, 1)
            let l: RowLayout
            if visual && og != nil && ng != nil {
                let scale = zoom > 0 ? zoom : max(0.05, min(2, (width - 2 * side) / widest))
                let h = max(og?.height ?? 0, ng?.height ?? 0) * scale
                let w = widest * scale
                l = RowLayout(top: top, height: Self.header + h + Self.bottom, scale: scale, overlayBox: NSRect(x: (width - w) / 2, y: top + Self.header, width: w, height: h))
            } else {
                let half = zoom > 0 ? widest * zoom : (width - 2 * side - gap) / 2
                let scale = zoom > 0 ? zoom : max(0.05, min(2, half / widest))
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

    /// The scale of the row at `y` (the first one in view), 1 when there are none.
    func scale(at y: Double) -> Double { place(at: y).map { layouts[$0.row].scale } ?? 1 }

    /// The row at `y` and how far down it `y` is (0...1), to keep it in view across a zoom.
    func place(at y: Double) -> (row: Int, within: Double)? {
        guard let i = layouts.lastIndex(where: { $0.top <= y }) ?? (layouts.isEmpty ? nil : 0) else { return nil }
        return (i, max(0, min(1, (y - layouts[i].top) / max(1, layouts[i].height))))
    }

    func top(row: Int, within: Double) -> Double {
        guard layouts.indices.contains(row) else { return 0 }
        return layouts[row].top + within * layouts[row].height
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
            if let m = marks.first(where: { !hiddenKinds.contains($0.kind) && viewRect($0.rect, box, l.scale).insetBy(dx: -2, dy: -2).contains(p) }) {
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
                if hideLooks { continue }
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
                    drawMissing(part == 0 ? loc("Not in the original") : loc("Not in the changed version"), l, part)
                    continue
                }
                wanted.insert(r * 3 + part)
                drawPicture(r * 3 + part, box, l.scale)
                drawMarks((part == 0 ? oldMarks[r] : newMarks[r]) ?? [], box, l.scale)
            }
        }
        request(wanted)
    }

    private func drawMarks(_ marks: [Mark], _ box: NSRect, _ scale: Double) {
        for m in marks where !hiddenKinds.contains(m.kind) {
            let rect = viewRect(m.rect, box, scale)
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

    static func markColor(_ kind: ChangeKind) -> NSColor {
        switch kind {
        case .inserted, .pageInserted: CompareWindowController.color(CompareReport.insertedColor)
        case .deleted, .pageRemoved: CompareWindowController.color(CompareReport.removedColor)
        case .changed: CompareWindowController.color(CompareReport.changedColor)
        case .moved: CompareWindowController.color(CompareReport.movedColor)
        case .formatted: CompareWindowController.color(CompareReport.formattedColor)
        }
    }

    private func drawHeader(_ r: Int, _ row: CompareRow, _ l: RowLayout) {
        let what: String
        if unreadRows.contains(r) {
            what = loc("couldn't be read: not compared")
        } else if let state = rowStates[r] {
            what = state
        } else {
            switch row.text {
            case .compared: what = row.changes == 0 ? loc("no changes") : row.changes == 1 ? loc("1 change") : loc("{0} changes", CoreLanguage.number(row.changes))
            case .noTextOld, .noTextNew, .noTextBoth: what = loc("no text to compare: see Visual")
            case .onlyOld: what = row.pageMoved ? loc("only in the original: its text moved to another page") : loc("removed page")
            case .onlyNew: what = row.pageMoved ? loc("only in the changed file: its text moved from another page") : loc("inserted page")
            }
        }
        let o = row.oldPage.map { $0 + 1 }, n = row.newPage.map { $0 + 1 }
        let label: String
        if let o, let n {
            label = loc("Original page {0}, changed page {1}", CoreLanguage.number(o), CoreLanguage.number(n))
        } else if let o {
            label = loc("Original page {0}", CoreLanguage.number(o))
        } else {
            label = loc("Changed page {0}", CoreLanguage.number(n ?? 0))
        }
        let text = loc("{0}: {1}", label, what) as NSString

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
        var keys: Set<Int> = []
        for r in rows where layouts.indices.contains(r) {
            if layouts[r].overlayBox != nil {
                keys.insert(r * 3 + 2)
            } else {
                keys.insert(r * 3)
                keys.insert(r * 3 + 1)
            }
        }
        request(keys)
    }

    /// The overlay of a row's two pages at `scale`: the changed page brought into the original's place through
    /// `alignment` first, and for a scan, ink allowed to land a little off.
    nonisolated static func overlayOf(_ old: PdfEngine, _ o: Int, _ new: PdfEngine, _ n: Int, scale: Double, alignment: PageAlignment, scan: Bool,
                                      cancel: CancelToken?) throws -> VisualDiff {
        let oldImage = try old.render(o, scale: scale, cancel: cancel)
        var newImage = try new.render(n, scale: scale, cancel: cancel)
        if !alignment.isNone {
            let og = old.page(o), ng = new.page(n)
            let w = Int((max(og.width, ng.width) * scale).rounded(.up)), h = Int((max(og.height, ng.height) * scale).rounded(.up))
            newImage = try CompareAlign.resample(newImage, 0, 0, scale, alignment, w, h, cancel: cancel)
        }
        if scan { return try VisualCompare.overlayScans(oldImage, newImage, scale, cancel: cancel) }
        return try VisualCompare.overlay(oldImage, newImage, cancel: cancel)
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
            let scan = scanRows.contains(r), known = alignments[r]
            pending.insert(key)
            let token = self.token
            queue.async {
                var image: RenderedImage?
                var found: [RectD]?
                var problem: String?
                var aligned: PageAlignment?
                do {
                    if part == 2, let o = row.oldPage, let n = row.newPage {
                        let alignment = scan ? try (known ?? CompareAlign.find(old, o, new, n, cancel: token)) : PageAlignment.none
                        let diff = try Self.overlayOf(old, o, new, n, scale: scale, alignment: alignment, scan: scan, cancel: token)
                        image = diff.image
                        found = diff.regions
                        aligned = scan ? alignment : nil
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
                let done = image, regionsFound = found, failed = problem, alignment = aligned
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.pending.remove(key)
                        if let failed { Report.progress("compare: row \(r) part \(part) not drawn: \(failed)") }
                        if let alignment, self.alignments[r] == nil { self.alignments[r] = alignment }
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
