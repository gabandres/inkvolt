import AppKit
import PdfCore

/// A document's window (a tab when several are open): the sidebar (thumbnails, outline) beside the pages, with the find
/// bar over them; zoom, page moves and find come here through the responder chain.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let engine: PdfEngine
    let pages: PagesView
    let scrollView: NSScrollView
    let sidebar: SidebarController
    let findBar = FindBar()
    private let split = NSSplitViewController()

    /// Find results across the document, the one shown, and the query they're for.
    private(set) var found: [(page: Int, start: Int, end: Int)] = []
    private(set) var foundIndex = -1
    private var foundQuery = ""
    private var findGeneration = 0
    /// Called when a find has finished (the self-test waits on it).
    var onFindFinished: (() -> Void)?

    init(document: PdfDocument, engine: PdfEngine) {
        self.engine = engine
        pages = PagesView(engine: engine)
        scrollView = NSScrollView()
        sidebar = SidebarController(engine: engine)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "InkvoltPdfDocument"
        window.minSize = NSSize(width: 480, height: 360)
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
        let stack = NSStackView(views: [findBar, scrollView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        findBar.isHidden = true
        content.view = stack
        findBar.onSearch = { [weak self] query in self?.find(query) }
        findBar.onNext = { [weak self] in self?.step(1) }
        findBar.onPrevious = { [weak self] in self?.step(-1) }
        findBar.onDone = { [weak self] in self?.hideFind() }

        let side = NSSplitViewItem(sidebarWithViewController: sidebar)
        side.minimumThickness = 150
        side.maximumThickness = 320
        split.addSplitViewItem(side)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        sidebar.onGo = { [weak self] page, y in self?.go(page, targetY: y) }
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 820))
        window.setFrameAutosaveName("InkvoltPdfDocument")
        updateSubtitle()
        Report.documentOpened(self, name: document.name)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // Fit the width once the window has its size (pages narrower than the window stay at actual size).
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.fitWidth(nil, atMost: 1.5)
                self.pages.requestVisible()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        pages.renderer.cancelAll()
        sidebar.stop()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Zoom

    @objc func zoomIn(_ sender: Any?) { zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { zoom(by: 0.8) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }
    @objc func fitWidth(_ sender: Any?) { fitWidth(sender, atMost: 8) }

    func fitWidth(_ sender: Any?, atMost cap: Double) {
        let available = scrollView.contentView.frame.width
        guard pages.frame.width > 0, available > 0 else { return }
        setZoom(min(available / pages.frame.width, cap))
    }

    private func zoom(by factor: Double) { setZoom(scrollView.magnification * factor) }

    /// Zooms keeping the top of the current view in place.
    func setZoom(_ zoom: Double) {
        let clip = scrollView.contentView
        let top = NSPoint(x: clip.bounds.midX, y: clip.bounds.minY)
        let z = min(max(zoom, scrollView.minMagnification), scrollView.maxMagnification)
        scrollView.setMagnification(z, centeredAt: top)
        pages.scrollTo(y: top.y)
        magnified()
    }

    @objc private func magnified() {
        pages.needsDisplay = true
        pages.requestVisible()
    }

    // MARK: Pages

    @objc func nextPage(_ sender: Any?) { go(min(pages.currentPage + 1, engine.pageCount - 1)) }
    @objc func previousPage(_ sender: Any?) { go(max(pages.currentPage - 1, 0)) }
    @objc func firstPage(_ sender: Any?) { go(0) }
    @objc func lastPage(_ sender: Any?) { go(engine.pageCount - 1) }

    /// Shows page `page`, from `targetY` (its space, points from the top) when given, else its top.
    func go(_ page: Int, targetY: Double? = nil) {
        guard page >= 0 && page < pages.pageRects.count else { return }
        pages.scrollTo(y: pages.pageRects[page].minY + (targetY ?? 0) - (targetY == nil ? PagesView.gap / 2 : 8))
    }

    @objc private func scrolled() {
        updateSubtitle()
        sidebar.showCurrent(pages.currentPage)
    }

    private func updateSubtitle() {
        window?.subtitle = engine.pageCount == 0 ? "No pages" : "Page \(pages.currentPage + 1) of \(engine.pageCount)"
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

    private func hideFind() {
        findBar.isHidden = true
        find("")
        window?.makeFirstResponder(pages)
    }

    /// Finds `query` on every page (off the main thread), shows the first match from the current page on.
    func find(_ query: String) {
        findGeneration += 1
        let generation = findGeneration
        foundQuery = query
        found = []
        foundIndex = -1
        pages.matches = [:]
        pages.currentMatch = nil
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            findBar.status = ""
            onFindFinished?()
            return
        }
        findBar.status = "Searching…"
        let engine = engine
        let from = pages.currentPage
        DispatchQueue.global(qos: .userInitiated).async {
            var all: [(page: Int, start: Int, end: Int)] = []
            for p in 0..<engine.pageCount {
                guard let text = try? engine.text(p) else { continue }
                for h in text.find(query, matchCase: false, wholeWord: false) { all.append((p, h.start, h.end)) }
            }
            let results = all
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
        pages.matches = byPage
        if results.isEmpty {
            findBar.status = "Not found"
        } else {
            foundIndex = (results.firstIndex { $0.page >= page } ?? 0) - 1
            step(1)
        }
        onFindFinished?()
    }

    /// The next (or previous) match, wrapping around.
    func step(_ by: Int) {
        guard !found.isEmpty else { return }
        foundIndex = ((foundIndex + by) % found.count + found.count) % found.count
        let m = found[foundIndex]
        pages.currentMatch = m
        findBar.status = "\(foundIndex + 1) of \(found.count)"
        if let text = try? engine.text(m.page), let box = text.rects(m.start, m.end).first {
            let r = pages.pageRects[m.page]
            let y = r.minY + box.y - scrollView.contentView.bounds.height / 3
            let shown = scrollView.contentView.bounds
            let matchY = r.minY + box.y
            if matchY < shown.minY || matchY + box.height > shown.maxY { pages.scrollTo(y: y) }
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
