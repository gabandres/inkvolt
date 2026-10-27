import AppKit
import PdfCore

/// All pages of a document stacked top to bottom, one point per PDF point (the scroll view's magnification zooms):
/// each drawn from the engine at the zoom it is shown at, with the find matches and the text selection over it.
@MainActor
final class PagesView: NSView, NSUserInterfaceValidations {
    static let margin = 20.0, gap = 14.0

    let engine: PdfEngine
    let renderer: PageRenderer
    /// Each page's frame in this view.
    private(set) var pageRects: [NSRect] = []

    /// A selection of text on one page: UTF-16 carets of its `PageText`.
    struct TextSelection: Equatable {
        var page: Int
        var anchor: Int
        var head: Int
        var range: (start: Int, end: Int) { (min(anchor, head), max(anchor, head)) }
    }

    private(set) var selection: TextSelection? {
        didSet { if selection != oldValue { needsDisplay = true } }
    }

    /// Find matches per page, and the one shown.
    var matches: [Int: [(start: Int, end: Int)]] = [:] { didSet { needsDisplay = true } }
    var currentMatch: (page: Int, start: Int, end: Int)? { didSet { needsDisplay = true } }

    init(engine: PdfEngine) {
        self.engine = engine
        renderer = PageRenderer(engine: engine, label: "inkvolt.pdf.render", qos: .userInitiated, keepAtMost: 12)
        super.init(frame: .zero)
        layoutPages()
        renderer.onRendered = { [weak self] page, _ in
            guard let self, page < self.pageRects.count else { return }
            self.setNeedsDisplay(self.pageRects[page])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    private func layoutPages() {
        let widest = (0..<engine.pageCount).map { engine.page($0).width }.max() ?? 612
        var y = Self.margin
        pageRects = (0..<engine.pageCount).map { i in
            let g = engine.page(i)
            let r = NSRect(x: Self.margin + (widest - g.width) / 2, y: y, width: g.width, height: g.height)
            y += g.height + Self.gap
            return r
        }
        setFrameSize(NSSize(width: widest + 2 * Self.margin, height: max(y - Self.gap + Self.margin, Self.margin * 2)))
    }

    // MARK: Drawing

    /// Pixels per point to draw at: the zoom times the screen's scale, in steps of √2 (so a pinch doesn't redraw every
    /// frame), at most about 40 megapixels a page.
    func renderScale(for page: Int) -> Double {
        let zoom = enclosingScrollView?.magnification ?? 1
        let backing = window?.backingScaleFactor ?? 2
        let raw = max(zoom * backing, 0.05)
        let stepped = pow(2, (log2(raw) * 2).rounded(.up) / 2)
        let g = engine.page(page)
        let cap = (40_000_000 / max(g.width * g.height, 1)).squareRoot()
        return min(stepped, cap)
    }

    /// The pages a rectangle of this view touches.
    func pages(in rect: NSRect) -> ClosedRange<Int>? {
        guard let first = pageRects.firstIndex(where: { $0.maxY >= rect.minY }) else { return nil }
        let last = pageRects.lastIndex(where: { $0.minY <= rect.maxY }) ?? first
        return first <= last ? first...last : nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let range = pages(in: dirtyRect) else { return }
        for i in range {
            let r = pageRects[i]
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowBlurRadius = 4
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
            shadow.set()
            NSColor.white.setFill()
            r.fill()
            NSGraphicsContext.restoreGraphicsState()
            if let image = renderer.image(i) {
                NSImage(cgImage: image.image, size: r.size).draw(in: r, from: .zero, operation: .sourceOver, fraction: 1,
                                                                 respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            }
            drawMarks(i, r)
        }
        requestVisible()
    }

    private func drawMarks(_ page: Int, _ r: NSRect) {
        guard matches[page] != nil || selection?.page == page,
              let text = try? engine.text(page) else { return }
        for m in matches[page] ?? [] {
            let current = currentMatch.map { $0.page == page && $0.start == m.start && $0.end == m.end } ?? false
            (current ? NSColor.systemOrange.withAlphaComponent(0.55) : NSColor.systemYellow.withAlphaComponent(0.4)).setFill()
            for b in text.rects(m.start, m.end) { viewRect(b, r).fill(using: .multiply) }
        }
        if let s = selection, s.page == page {
            NSColor.selectedTextBackgroundColor.withAlphaComponent(0.55).setFill()
            for b in text.rects(s.range.start, s.range.end) { viewRect(b, r).fill(using: .multiply) }
        }
    }

    private func viewRect(_ b: RectD, _ page: NSRect) -> NSRect {
        NSRect(x: page.minX + b.x, y: page.minY + b.y, width: b.width, height: b.height)
    }

    /// Asks for the visible pages at the zoom they're shown at, and lets go of the rest.
    func requestVisible() {
        guard let range = pages(in: visibleRect) else { return }
        for i in range { renderer.request(i, scale: renderScale(for: i)) }
        let lo = max(range.lowerBound - 1, 0), hi = min(range.upperBound + 1, max(pageRects.count - 1, 0))
        renderer.keep(lo...hi)
    }

    // MARK: Pages and points

    /// The page under a point of this view (else the nearest), with the point in that page's space.
    func page(at point: NSPoint) -> (page: Int, x: Double, y: Double)? {
        guard !pageRects.isEmpty else { return nil }
        let i = pageRects.firstIndex { point.y <= $0.maxY + Self.gap / 2 } ?? pageRects.count - 1
        let r = pageRects[i]
        return (i, Double(point.x - r.minX), Double(point.y - r.minY))
    }

    /// The page at the middle of what is shown (the "current" page).
    var currentPage: Int {
        let v = visibleRect
        return page(at: NSPoint(x: v.midX, y: v.minY + min(v.height / 3, 200)))?.page ?? 0
    }

    // MARK: Selection

    override func resetCursorRects() {
        for r in pageRects { addCursorRect(r, cursor: .iBeam) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        guard let hit = page(at: p), let text = try? engine.text(hit.page), !text.isEmpty else {
            selection = nil
            return
        }
        let caret = text.hitTest(hit.x, hit.y)
        switch event.clickCount {
        case 2: select(hit.page, text.wordAt(caret))
        case 3: select(hit.page, text.lineAt(caret))
        default: selection = TextSelection(page: hit.page, anchor: caret, head: caret)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard var s = selection, let text = try? engine.text(s.page) else { return }
        let p = convert(event.locationInWindow, from: nil)
        let r = pageRects[s.page]
        s.head = text.hitTest(Double(p.x - r.minX), Double(p.y - r.minY))
        selection = s
        autoscroll(with: event)
    }

    func select(_ page: Int, _ range: (start: Int, end: Int)) {
        selection = TextSelection(page: page, anchor: range.start, head: range.end)
    }

    func clearSelection() { selection = nil }

    /// The selected text, or nil when nothing is selected.
    var selectedText: String? {
        guard let s = selection, s.anchor != s.head, let text = try? engine.text(s.page) else { return nil }
        return text.string(s.range.start, s.range.end)
    }

    /// Puts the selected text on `pasteboard` (the general one for ⌘C); false when nothing is selected.
    @discardableResult
    func copySelection(to pasteboard: NSPasteboard = .general) -> Bool {
        guard let text = selectedText else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    @objc func copy(_ sender: Any?) { copySelection() }

    /// Select All: the text of the current page.
    @objc override func selectAll(_ sender: Any?) {
        let page = selection?.page ?? currentPage
        guard let text = try? engine.text(page), !text.isEmpty else { return }
        select(page, (0, text.length))
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedText != nil }
        return true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return super.keyDown(with: event) }
        let clip = scroll.contentView
        let page = clip.bounds.height - 40
        var y = clip.bounds.minY
        switch event.specialKey {
        case .pageDown: y += page
        case .pageUp: y -= page
        case .downArrow: y += 40
        case .upArrow: y -= 40
        case .home: y = 0
        case .end: y = frame.height
        default:
            if event.charactersIgnoringModifiers == " " {
                y += event.modifierFlags.contains(.shift) ? -page : page
            } else {
                return super.keyDown(with: event)
            }
        }
        scrollTo(y: y)
    }

    /// Scrolls so `y` (this view's coordinates) is at the top of what is shown.
    func scrollTo(y: Double) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let maxY = max(frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(y, 0), maxY)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }
}

/// Keeps the pages centered across when they are narrower than the window.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposedBounds)
        if let doc = documentView, doc.frame.width < r.width {
            r.origin.x = (doc.frame.width - r.width) / 2
        }
        return r
    }
}
