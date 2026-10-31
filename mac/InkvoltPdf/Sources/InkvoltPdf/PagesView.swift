import AppKit
import PdfCore

/// What the pages view asks of its window: text for a note or text box, where a link leads, the inspector.
@MainActor
protocol PagesHost: AnyObject {
    /// Asks for text in a popover at `rect` (this view's coordinates); `done` gets nil when cancelled.
    func askText(_ title: String, initial: String, at rect: NSRect, done: @escaping (String?) -> Void)
    /// Asks where a link leads (a normalized address, or a page), at `rect`.
    func askLink(at rect: NSRect, done: @escaping (_ uri: String?, _ page: Int) -> Void)
    func showInspector(_ id: String)
    /// The Signature tool was used before a signature was made: offer to make one.
    func askSignature()
    func selectionChanged()
    func toolChanged()
    /// One of the document's links was clicked: go to its page, or open its address (asking first unless it is a web or
    /// mail address).
    func openLink(_ link: PageLink)
    /// The areas marked for redaction changed.
    func redactionsChanged()
}

/// An area marked for redaction (page space), black on the page once the marks are applied.
struct RedactMark: Equatable {
    var page: Int
    var rect: RectD
}

/// All pages of a document stacked top to bottom, one point per PDF point (the scroll view's magnification zooms):
/// each drawn from the engine at the zoom it is shown at, with the find matches, the text selection, and the comment
/// tools over it (previews while drawing, the selected comment's frame and handles).
@MainActor
final class PagesView: NSView, NSUserInterfaceValidations, NSMenuItemValidation {
    static let margin = 20.0, gap = 14.0

    private(set) var engine: PdfEngine
    let renderer: PageRenderer
    /// Each page's frame in this view.
    private(set) var pageRects: [NSRect] = []
    weak var editor: DocumentEditor?
    weak var host: PagesHost?
    /// The form's fields and Edit Text & Images (the window controller owns them).
    weak var form: FormFiller?
    weak var content: ContentEditing?
    /// Prepare Form's fields (the window controller owns it).
    weak var design: PrepareForm?
    /// The signature or initials the Signature tool puts down at the next click.
    var pendingSignature: (image: StampImage, initials: Bool)?

    /// A selection of text, on one page or across several: from a caret (UTF-16, of its page's `PageText`) on the anchor
    /// page to one on the head page; the pages between are selected whole.
    struct TextSelection: Equatable {
        var anchorPage: Int
        var anchor: Int
        var headPage: Int
        var head: Int

        init(page: Int, anchor: Int, head: Int) {
            anchorPage = page
            self.anchor = anchor
            headPage = page
            self.head = head
        }

        private var forward: Bool { anchorPage < headPage || (anchorPage == headPage && anchor <= head) }
        var first: (page: Int, caret: Int) { forward ? (anchorPage, anchor) : (headPage, head) }
        var last: (page: Int, caret: Int) { forward ? (headPage, head) : (anchorPage, anchor) }
        var pages: ClosedRange<Int> { first.page...last.page }
        var isEmpty: Bool { anchorPage == headPage && anchor == head }

        /// The selected carets on `page` (whose text is `length` units long), nil when none of it is selected.
        func range(on page: Int, length: Int) -> (start: Int, end: Int)? {
            guard pages.contains(page) else { return nil }
            let start = page == first.page ? min(first.caret, length) : 0
            let end = page == last.page ? min(last.caret, length) : length
            return end > start ? (start, end) : nil
        }
    }

    private(set) var selection: TextSelection? {
        didSet { if selection != oldValue { needsDisplay = true } }
    }

    /// Find matches per page, and the one shown.
    var matches: [Int: [(start: Int, end: Int)]] = [:] { didSet { needsDisplay = true } }
    var currentMatch: (page: Int, start: Int, end: Int)? { didSet { needsDisplay = true } }
    /// The areas marked for redaction (the Redact tool, a selection, search matches, patterns), until applied or cleared.
    private(set) var redactions: [RedactMark] = [] {
        didSet {
            needsDisplay = true
            host?.redactionsChanged()
        }
    }

    // MARK: Tools state

    var tool: Tool = .text {
        didSet {
            guard tool != oldValue else { return }
            drag = nil
            vertices = nil
            measuring = tool.measureTool.map { MeasureDraft($0) }
            if !tool.selects && tool != .link { select(nil) }
            if tool != .editContent { content?.select(nil) }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
            host?.toolChanged()
        }
    }
    let styles = ToolStyles()
    var stamp: StampDesign = RubberStamps.builtIn[0]
    /// The picture the Image tool puts down next.
    var pendingImage: StampImage?
    /// Waiting for a box to be dragged (a new visible digital signature): called once with it, or nil when Esc cancels.
    var boxPicker: ((_ page: Int, _ rect: RectD?) -> Void)? {
        didSet {
            drag = nil
            window?.invalidateCursorRects(for: self)
        }
    }
    /// The selected comment or link (its id).
    private(set) var selectedId: String?
    /// The edit a press started, until it has committed (the self-test awaits it).
    private(set) var pendingEdit: Task<Void, Never>?

    /// A press in progress.
    enum Drag {
        case text
        case pan(start: NSPoint, origin: NSPoint)
        case move(id: String, page: Int, start: PointD, frame: RectD, by: PointD)
        case resize(id: String, page: Int, handle: Int, frame: RectD, now: RectD)
        case lineEnd(id: String, page: Int, end: Int, points: [PointD])
        case box(page: Int, start: PointD, now: PointD)
        case line(page: Int, start: PointD, now: PointD)
        case ink(page: Int, points: [PointD])
        /// A picture of the page's own content dragged with Edit Text & Images.
        case contentMove(page: Int, start: PointD, box: RectD, by: PointD)
        /// A press on one of the document's links (followed on release, unless the mouse moved away).
        case link(PageLink, page: Int, start: NSPoint)

        var page: Int? {
            switch self {
            case .text, .pan, .link: nil
            case .move(_, let p, _, _, _), .resize(_, let p, _, _, _), .lineEnd(_, let p, _, _), .box(let p, _, _),
                 .line(let p, _, _), .ink(let p, _), .contentMove(let p, _, _, _): p
            }
        }
    }

    private(set) var drag: Drag? { didSet { needsDisplay = true } }
    /// The corners of the polygon (or points of the polyline) being drawn, on one page.
    private(set) var vertices: (page: Int, points: [PointD])? { didSet { needsDisplay = true } }
    /// The measuring tool's measurement under way (nil with any other tool).
    private(set) var measuring: MeasureDraft? { didSet { if measuring != oldValue { needsDisplay = true } } }
    /// The scale at a point of a page (the page's viewport there, else real size), and where a finished measurement goes
    /// (the window controller saves it, or asks the real length for a calibration).
    var measureScaleAt: (@MainActor (Int, PointD) -> MeasureScale)?
    var onMeasured: (@MainActor (MeasureTool, Int, [PointD]) async -> Bool)?
    /// The last drag's preview, kept until its page is drawn again with the edit in it.
    private var ghost: Drag?
    private var shiftDown = false

    init(engine: PdfEngine) {
        self.engine = engine
        renderer = PageRenderer(engine: engine, label: "inkvolt.pdf.render", qos: .userInitiated, keepAtMost: 12)
        super.init(frame: .zero)
        layoutPages()
        renderer.onRendered = { [weak self] page, _ in
            guard let self, page < self.pageRects.count else { return }
            if self.ghost?.page == page { self.ghost = nil }
            self.setNeedsDisplay(self.pageRects[page])
        }
        renderer.onTile = { [weak self] page, rect in
            guard let self, page < self.pageRects.count else { return }
            self.setNeedsDisplay(self.viewRect(rect, self.pageRects[page]))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Pages")
        // The pointer's moves, for the measuring tools' value so far (AppKit keeps the area on the visible part).
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }

    /// The content changed (an edit, undo, redo, reload): the new engine, pages laid out again if their sizes changed,
    /// and every page drawn again (the old pictures stay until the new ones arrive).
    func reload(engine: PdfEngine) {
        self.engine = engine
        renderer.engine = engine
        let old = pageRects
        layoutPages()
        if old != pageRects { window?.invalidateCursorRects(for: self) }
        linkCache = [:]
        if let s = selection, max(s.anchorPage, s.headPage) >= engine.pageCount { selection = nil }
        if redactions.contains(where: { $0.page >= engine.pageCount }) { redactions.removeAll { $0.page >= engine.pageCount } }
        renderer.invalidate()
        if let id = selectedId, editor?.comment(id) == nil && editor?.link(id) == nil { select(nil) }
        needsDisplay = true
        requestVisible()
    }

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

    /// A whole page is drawn as one picture of at most this many pixels; beyond it, tiles cover what is shown.
    static let wholePagePixels = 16_000_000.0

    /// Pixels per point the zoom wants: the zoom times the screen's scale, in steps of √2 (so a pinch doesn't redraw
    /// every frame).
    private func wantedScale() -> Double {
        let zoom: Double = Double(enclosingScrollView?.magnification ?? 1)
        let backing: Double = Double(window?.backingScaleFactor ?? 2)
        let raw = max(zoom * backing, 0.05)
        return pow(2, (log2(raw) * 2).rounded(.up) / 2)
    }

    /// Pixels per point the whole page is drawn at: the zoom's, at most `wholePagePixels` a page.
    func renderScale(for page: Int) -> Double {
        let g = engine.page(page)
        let cap = (Self.wholePagePixels / max(g.width * g.height, 1)).squareRoot()
        return min(wantedScale(), cap)
    }

    /// The scale tiles are drawn at when the zoom wants more than the whole page's picture has (nil: no tiles).
    func tileScale(for page: Int) -> Double? {
        let want = wantedScale()
        return want > renderScale(for: page) + 0.001 ? want : nil
    }

    /// The tiles the visible part of the pages needs, and how many of them are drawn (the self-test waits on it).
    private(set) var wantedTiles: [PageRenderer.TileKey] = []
    var tilesReady: (wanted: Int, drawn: Int) { (wantedTiles.count, renderer.freshTiles(wantedTiles)) }

    /// The pages a rectangle of this view touches.
    func pages(in rect: NSRect) -> ClosedRange<Int>? {
        guard let first = pageRects.firstIndex(where: { $0.maxY >= rect.minY }) else { return nil }
        let last = pageRects.lastIndex(where: { $0.minY <= rect.maxY }) ?? first
        return first <= last ? first...last : nil
    }

    /// The place outlined for a moment (`flash`).
    private(set) var flashed: (page: Int, box: RectD)?
    private var flashTask: Task<Void, Never>?

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
            if let scale = tileScale(for: i) {
                for tile in renderer.tiles(i, scale: scale) {
                    let box = viewRect(tile.rect, r)
                    guard box.intersects(dirtyRect) else { continue }
                    NSImage(cgImage: tile.image, size: box.size).draw(in: box, from: .zero, operation: .copy, fraction: 1,
                                                                      respectFlipped: true, hints: nil)
                }
            }
            drawMarks(i, r)
            drawRedactions(i, r)
            if tool == .prepareForm { design?.draw(i, r) } else { form?.draw(i, r) }
            if tool == .editContent { content?.draw(i, r) }
            drawEditing(i, r)
            if let flashed, flashed.page == i {
                NSColor.systemOrange.setStroke()
                let outline = NSBezierPath(rect: viewRect(flashed.box, r).insetBy(dx: -2, dy: -2))
                outline.lineWidth = 2
                outline.stroke()
            }
        }
        requestVisible()
    }

    /// Outlines a place for a moment (a finding chosen in the Accessibility pane; Windows' `Viewer.Flash`).
    func flash(_ page: Int, _ box: RectD) {
        flashed = (page, box)
        needsDisplay = true
        flashTask?.cancel()
        flashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.flashed = nil
            self.needsDisplay = true
        }
    }

    private func drawMarks(_ page: Int, _ r: NSRect) {
        guard matches[page] != nil || selection?.pages.contains(page) == true,
              let text = try? engine.text(page) else { return }
        for m in matches[page] ?? [] {
            let current = currentMatch.map { $0.page == page && $0.start == m.start && $0.end == m.end } ?? false
            (current ? NSColor.systemOrange.withAlphaComponent(0.55) : NSColor.systemYellow.withAlphaComponent(0.4)).setFill()
            for b in text.rects(m.start, m.end) { viewRect(b, r).fill(using: .multiply) }
        }
        if let s = selection, let range = s.range(on: page, length: text.length) {
            let color: NSColor = tool.marksText ? Palette.ns(styles.style(tool).color ?? .yellow) : .selectedTextBackgroundColor
            color.withAlphaComponent(0.55).setFill()
            for b in text.rects(range.start, range.end) { viewRect(b, r).fill(using: .multiply) }
        }
    }

    /// The areas marked for redaction: dark, with a red edge (as Windows draws them), so what is under shows through.
    private func drawRedactions(_ page: Int, _ r: NSRect) {
        let px = onePixel
        for m in redactions where m.page == page {
            let box = viewRect(m.rect, r)
            NSColor.black.withAlphaComponent(0.45).setFill()
            box.fill(using: .sourceOver)
            let edge = NSBezierPath(rect: box)
            edge.lineWidth = 1.5 * px
            NSColor.systemRed.setStroke()
            edge.stroke()
        }
    }

    /// Marks areas for redaction (each once).
    func addRedactions(_ marks: [RedactMark]) {
        var all = redactions
        for m in marks where !m.rect.isEmpty && !all.contains(m) { all.append(m) }
        if all != redactions { redactions = all }
    }

    func removeRedaction(at index: Int) {
        guard redactions.indices.contains(index) else { return }
        redactions.remove(at: index)
    }

    func clearRedactions() {
        if !redactions.isEmpty { redactions = [] }
    }

    /// The selected text's lines marked for redaction (grown by half a point, as on Windows); how many marks.
    @discardableResult
    func redactSelection() -> Int {
        let marks: [RedactMark] = selectedSpans.flatMap { span -> [RedactMark] in
            guard let text = try? engine.text(span.page) else { return [] }
            return text.rects(span.start, span.end).map { RedactMark(page: span.page, rect: $0.inflate(0.5)) }
        }
        addRedactions(marks)
        if !marks.isEmpty { selection = nil }
        return marks.count
    }

    func viewRect(_ b: RectD, _ page: NSRect) -> NSRect {
        NSRect(x: page.minX + b.x, y: page.minY + b.y, width: b.width, height: b.height)
    }

    func viewPoint(_ p: PointD, _ page: NSRect) -> NSPoint { NSPoint(x: page.minX + p.x, y: page.minY + p.y) }

    /// One screen point in this view's units (the handles and strokes keep their size at any zoom).
    var onePixel: CGFloat { 1 / max(enclosingScrollView?.magnification ?? 1, 0.05) }

    /// Links (with the Link tool), the selected comment's frame and handles, and the preview of a press.
    private func drawEditing(_ page: Int, _ r: NSRect) {
        guard let editor else { return }
        let px = onePixel
        if tool == .link {
            for l in editor.links where l.pageIndex == page && l.id != selectedId {
                let path = NSBezierPath(rect: viewRect(l.rect, r))
                path.lineWidth = px
                path.setLineDash([4 * px, 3 * px], count: 2, phase: 0)
                NSColor.systemBlue.withAlphaComponent(0.8).setStroke()
                path.stroke()
            }
        }
        if let ghost, ghost.page == page { drawPreview(ghost, r) }
        if let drag, drag.page == page { drawPreview(drag, r) }
        if let v = vertices, v.page == page, let first = v.points.first {
            let style = styles.style(tool)
            Palette.ns(style.color ?? .red).withAlphaComponent(0.8).setStroke()
            let path = NSBezierPath()
            path.move(to: viewPoint(first, r))
            for p in v.points.dropFirst() { path.line(to: viewPoint(p, r)) }
            path.lineWidth = CGFloat(style.width)
            path.lineJoinStyle = .round
            path.stroke()
            for p in v.points {
                let dot = viewPoint(p, r)
                let size: CGFloat = 5 * px
                NSBezierPath(ovalIn: NSRect(x: dot.x - size / 2, y: dot.y - size / 2, width: size, height: size)).fill()
            }
        }
        if let m = measuring, m.isActive, m.page == page { drawMeasure(m, r) }
        if drag == nil, let id = selectedId, let frame = frame(of: id), frame.page == page {
            drawSelection(frame.rect, r, handles: handles(of: id), lineEnds: lineEnds(of: id))
        }
    }

    /// The measurement under way (the Windows viewer's look): its segments, a light fill and the closing edge dashed for
    /// an area, a dot per point clicked, and the value so far in a dark box by the pointer, all the same size at any zoom.
    private func drawMeasure(_ m: MeasureDraft, _ r: NSRect) {
        guard !m.points.isEmpty else { return }
        let px = onePixel
        var pts = m.points
        if let h = m.hover { pts.append(h) }
        let screen = pts.map { viewPoint($0, r) }
        let color = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        if m.tool == .area && screen.count >= 3 {
            let shape = NSBezierPath()
            shape.move(to: screen[0])
            for p in screen.dropFirst() { shape.line(to: p) }
            shape.close()
            color.withAlphaComponent(0.19).setFill()
            shape.fill()
            let closing = NSBezierPath()
            closing.move(to: screen[screen.count - 1])
            closing.line(to: screen[0])
            closing.lineWidth = px
            closing.setLineDash([4 * px, 3 * px], count: 2, phase: 0)
            color.setStroke()
            closing.stroke()
        }
        color.setStroke()
        let path = NSBezierPath()
        path.move(to: screen[0])
        for p in screen.dropFirst() { path.line(to: p) }
        path.lineWidth = 1.5 * px
        path.stroke()
        for p in screen.prefix(m.points.count) {
            let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 3 * px, y: p.y - 3 * px, width: 6 * px, height: 6 * px))
            NSColor.white.setFill()
            dot.fill()
            dot.lineWidth = 1.5 * px
            dot.stroke()
        }
        let scale = measureScaleAt?(m.page, m.points[0]) ?? .default
        let text = m.value(scale) as NSString
        guard text.length > 0, let last = screen.last else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12 * px), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        let at = NSPoint(x: last.x + 14 * px, y: last.y + 14 * px)
        let box = NSRect(x: at.x - 6 * px, y: at.y - 3 * px, width: size.width + 12 * px, height: size.height + 6 * px)
        NSColor(white: 0.125, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4 * px, yRadius: 4 * px).fill()
        text.draw(at: at, withAttributes: attributes)
    }

    private func drawSelection(_ frame: RectD, _ r: NSRect, handles: [Int], lineEnds: [PointD]) {
        let px = onePixel
        let box = viewRect(frame, r).insetBy(dx: -2 * px, dy: -2 * px)
        let path = NSBezierPath(rect: box)
        path.lineWidth = px
        NSColor.controlAccentColor.setStroke()
        if lineEnds.isEmpty { path.stroke() }
        let size: CGFloat = 7 * px
        var points: [NSPoint] = handles.map { h in
            let p = DrawingGeometry.handlePoint(RectD(Double(box.minX), Double(box.minY), Double(box.width), Double(box.height)), h)
            return NSPoint(x: p.x, y: p.y)
        }
        points += lineEnds.map { viewPoint($0, r) }
        for p in points {
            let handle = NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
            NSColor.white.setFill()
            handle.fill()
            let outline = NSBezierPath(rect: handle)
            outline.lineWidth = px
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
        }
    }

    private func drawPreview(_ drag: Drag, _ r: NSRect) {
        let px = onePixel
        let style = styles.style(tool)
        let stroke = Palette.ns(style.color ?? .red).withAlphaComponent(CGFloat(style.highlighter ? 0.5 : max(style.opacity, 0.3)))
        stroke.setStroke()
        switch drag {
        case .text, .pan, .link:
            return
        case .box(_, let a, let b) where boxPicker != nil:
            let rect = viewRect(DrawingGeometry.dragBox(a, b, square: false), r)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            rect.fill(using: .sourceOver)
            NSColor.controlAccentColor.setStroke()
            outline(rect, px)
        case .box(_, let a, let b) where tool == .redact:
            let rect = viewRect(DrawingGeometry.dragBox(a, b, square: false), r)
            NSColor.black.withAlphaComponent(0.45).setFill()
            rect.fill(using: .sourceOver)
            NSColor.systemRed.setStroke()
            outline(rect, px)
        case .contentMove(_, _, let box, let by):
            outline(viewRect(RectD(box.x + by.x, box.y + by.y, box.width, box.height), r), px)
        case .move(let id, _, _, let frame, let by):
            let moved = RectD(frame.x + by.x, frame.y + by.y, frame.width, frame.height)
            outline(viewRect(moved, r), px)
            if let c = editor?.comment(id), let g = c.geometry {
                drawGeometry(c.subtype, DrawingGeometry.translate(g, by.x, by.y), c.style, r)
            }
        case .resize(let id, _, _, _, let now):
            outline(viewRect(now, r), px)
            if let c = editor?.comment(id), let g = c.geometry {
                drawGeometry(c.subtype, DrawingGeometry.withFrame(c.subtype, g, now), c.style, r)
            }
        case .lineEnd(let id, _, _, let points):
            if let c = editor?.comment(id) { drawGeometry("Line", AnnotGeometry(paths: [points]), c.style, r) }
        case .box(_, let a, let b) where tool == .callout:
            let tip = viewPoint(a, r), end = viewPoint(b, r)
            let leader = NSBezierPath()
            leader.move(to: tip)
            leader.line(to: end)
            leader.lineWidth = CGFloat(style.width)
            leader.stroke()
            outline(NSRect(x: end.x, y: end.y - 12, width: 144, height: 24), px)
        case .box(_, let a, let b):
            let box = DrawingGeometry.dragBox(a, b, square: shiftDown && (tool == .rectangle || tool == .ellipse))
            let rect = viewRect(box, r)
            let path = tool == .ellipse ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
            path.lineWidth = tool == .textBox || tool == .link ? px : CGFloat(style.width)
            if tool == .textBox || tool == .link { path.setLineDash([4 * px, 3 * px], count: 2, phase: 0) }
            path.stroke()
        case .line(_, let a, let b):
            let end = shiftDown ? DrawingGeometry.snapAngle(a, b) : b
            let path = NSBezierPath()
            path.move(to: viewPoint(a, r))
            path.line(to: viewPoint(end, r))
            path.lineWidth = CGFloat(style.width)
            path.lineCapStyle = .round
            path.stroke()
            if tool == .arrow { arrowHead(a, end, r, CGFloat(style.width)) }
        case .ink(_, let points):
            guard points.count > 1 else { return }
            let path = NSBezierPath()
            path.move(to: viewPoint(points[0], r))
            for p in points.dropFirst() { path.line(to: viewPoint(p, r)) }
            path.lineWidth = CGFloat(style.width)
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
    }

    private func outline(_ rect: NSRect, _ px: CGFloat) {
        let path = NSBezierPath(rect: rect)
        path.lineWidth = px
        path.setLineDash([4 * px, 3 * px], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    /// A drawing's outline at a new place or size, while it is moved or resized.
    private func drawGeometry(_ subtype: String, _ g: AnnotGeometry, _ style: AnnotStyle?, _ r: NSRect) {
        let color = Palette.ns(style?.color ?? .red).withAlphaComponent(0.6)
        color.setStroke()
        let width = CGFloat(max(style?.width ?? 1, 1))
        switch subtype {
        case "Square", "Circle", "FreeText":
            let rect = viewRect(g.box, r)
            let path = subtype == "Circle" ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
            path.lineWidth = width
            path.stroke()
        default:
            for points in g.paths where points.count > 1 {
                let path = NSBezierPath()
                path.move(to: viewPoint(points[0], r))
                for p in points.dropFirst() { path.line(to: viewPoint(p, r)) }
                path.lineWidth = width
                path.lineCapStyle = .round
                path.stroke()
            }
        }
    }

    private func arrowHead(_ a: PointD, _ b: PointD, _ r: NSRect, _ width: CGFloat) {
        let angle = atan2(b.y - a.y, b.x - a.x)
        let length = Double(max(width * 4, 8))
        let tip = viewPoint(b, r)
        let path = NSBezierPath()
        for side in [-0.5, 0.5] {
            let x: Double = b.x - length * cos(angle + side)
            let y: Double = b.y - length * sin(angle + side)
            path.move(to: tip)
            path.line(to: viewPoint(PointD(x, y), r))
        }
        path.lineWidth = width
        path.lineCapStyle = .round
        path.stroke()
    }

    /// Asks for the visible pages at the zoom they're shown at, and lets go of the rest.
    func requestVisible() {
        guard let range = pages(in: visibleRect) else { return }
        var tiles: [PageRenderer.TileKey] = []
        for i in range {
            renderer.request(i, scale: renderScale(for: i))
            guard let scale = tileScale(for: i) else { continue }
            let r = pageRects[i]
            let shown = visibleRect.intersection(r)
            guard !shown.isEmpty else { continue }
            let region = RectD(Double(shown.minX - r.minX), Double(shown.minY - r.minY), Double(shown.width), Double(shown.height))
            let g = engine.page(i)
            tiles += renderer.requestTiles(i, scale: scale, region: region, size: (g.width, g.height))
        }
        wantedTiles = tiles
        renderer.keepTiles(Set(tiles))
        let lo = max(range.lowerBound - 1, 0), hi = min(range.upperBound + 1, max(pageRects.count - 1, 0))
        renderer.keep(lo...hi)
    }

    // MARK: Links

    private var linkCache: [Int: [PageLink]] = [:]

    /// The document's own links on a page (the engine reads them once per content).
    func pageLinks(_ page: Int) -> [PageLink] {
        if let cached = linkCache[page] { return cached }
        let links = (try? engine.links(page)) ?? []
        linkCache[page] = links
        return links
    }

    /// The link under a page point, if any (the topmost).
    func pageLink(page: Int, _ p: PointD) -> PageLink? {
        pageLinks(page).last { $0.area.contains(p.x, p.y) }
    }

    // MARK: Pages and points

    /// The page under a point of this view (else the nearest), with the point in that page's space.
    func page(at point: NSPoint) -> (page: Int, x: Double, y: Double)? {
        guard !pageRects.isEmpty else { return nil }
        let i = pageRects.firstIndex { point.y <= $0.maxY + Self.gap / 2 } ?? pageRects.count - 1
        let r = pageRects[i]
        return (i, Double(point.x - r.minX), Double(point.y - r.minY))
    }

    /// A point of this view in page `page`'s space, kept on the page.
    func pagePoint(_ point: NSPoint, on page: Int) -> PointD {
        let r = pageRects[page]
        let x = min(max(Double(point.x - r.minX), 0), Double(r.width))
        let y = min(max(Double(point.y - r.minY), 0), Double(r.height))
        return PointD(x, y)
    }

    /// The page at the middle of what is shown (the "current" page).
    var currentPage: Int {
        let v = visibleRect
        return page(at: NSPoint(x: v.midX, y: v.minY + min(v.height / 3, 200)))?.page ?? 0
    }

    // MARK: Comments: frames, handles, hits

    /// The frame a comment or link shows when selected (page space).
    func frame(of id: String) -> (page: Int, rect: RectD)? {
        if let c = editor?.comment(id) {
            if let g = c.geometry { return (c.pageIndex, DrawingGeometry.frame(c.subtype, g)) }
            return (c.pageIndex, c.rect)
        }
        if let l = editor?.link(id) { return (l.pageIndex, l.rect) }
        return nil
    }

    /// The resize handles a selected comment offers: none for notes and text marks, the corners for stamps and pictures
    /// (which keep their proportions), the two ends of a line, all eight for the rest.
    func handles(of id: String) -> [Int] {
        if let c = editor?.comment(id) {
            if c.subtype == "Line" { return [] }
            if c.subtype == "Stamp" {
                return [DrawingGeometry.topLeft, DrawingGeometry.topRight, DrawingGeometry.bottomRight, DrawingGeometry.bottomLeft]
            }
            return c.geometry == nil ? [] : Array(0...7)
        }
        return editor?.link(id) == nil ? [] : Array(0...7)
    }

    func lineEnds(of id: String) -> [PointD] {
        guard let c = editor?.comment(id), c.subtype == "Line", let path = c.geometry?.paths.first, path.count == 2 else { return [] }
        return path
    }

    /// The comment (or, with the Link tool, the link) under a page point: the selected one first, then the topmost.
    func hit(page: Int, _ p: PointD) -> String? {
        guard let editor else { return nil }
        let tolerance = Double(4 * onePixel)
        if tool == .link {
            if let id = selectedId, let l = editor.link(id), l.pageIndex == page, l.rect.inflate(tolerance).contains(p.x, p.y) { return id }
            return editor.links.last { $0.pageIndex == page && $0.rect.inflate(tolerance).contains(p.x, p.y) }?.id
        }
        func hits(_ c: AnnotationInfo) -> Bool {
            guard c.pageIndex == page else { return false }
            if tool == .text && Tool.markupSubtypes.contains(c.subtype) { return false } // text tool: those are text to select
            if let g = c.geometry { return DrawingGeometry.hit(c.subtype, g, c.style, p, tolerance) }
            if !c.quadRects.isEmpty { return c.quadRects.contains { $0.inflate(tolerance).contains(p.x, p.y) } }
            return c.rect.inflate(tolerance).contains(p.x, p.y)
        }
        if let id = selectedId, let c = editor.comment(id), hits(c) { return id }
        return editor.comments.last(where: hits)?.id
    }

    /// The handle (or line end) of the selected comment under a view point.
    private func handle(at point: NSPoint) -> (page: Int, handle: Int)? {
        guard let id = selectedId, let f = frame(of: id), f.page < pageRects.count else { return nil }
        let r = pageRects[f.page]
        let reach: CGFloat = 6 * onePixel
        let ends = lineEnds(of: id)
        for (i, e) in ends.enumerated() {
            let v = viewPoint(e, r)
            if abs(v.x - point.x) <= reach && abs(v.y - point.y) <= reach { return (f.page, 100 + i) }
        }
        let px = onePixel
        let box = viewRect(f.rect, r).insetBy(dx: -2 * px, dy: -2 * px)
        let frame = RectD(Double(box.minX), Double(box.minY), Double(box.width), Double(box.height))
        for h in handles(of: id) {
            let p = DrawingGeometry.handlePoint(frame, h)
            if abs(CGFloat(p.x) - point.x) <= reach && abs(CGFloat(p.y) - point.y) <= reach { return (f.page, h) }
        }
        return nil
    }

    /// Selects a comment or link (nil: none) and shows it.
    func select(_ id: String?, reveal: Bool = false) {
        if id != nil { selection = nil }
        guard id != selectedId || reveal else { return }
        selectedId = id
        needsDisplay = true
        if reveal, let id, let f = frame(of: id), f.page < pageRects.count {
            let rect = viewRect(f.rect, pageRects[f.page]).insetBy(dx: -40, dy: -40)
            scrollToVisible(rect)
        }
        host?.selectionChanged()
        if let id, let c = editor?.comment(id) {
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: "Selected " + DocumentEditor.spoken(c)])
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    // MARK: Cursor

    override func resetCursorRects() {
        if tool == .prepareForm {
            design?.addCursorRects(to: self)
            return
        }
        let cursor: NSCursor
        switch tool {
        case .text, .highlight, .underline, .strikeOut: cursor = .iBeam
        case .hand: cursor = .openHand
        default: cursor = .crosshair
        }
        for r in pageRects { addCursorRect(r, cursor: cursor) }
        if tool.selects, let range = pages(in: visibleRect) {
            for i in range {
                for l in pageLinks(i) { addCursorRect(viewRect(l.area, pageRects[i]), cursor: .pointingHand) }
            }
        }
        if tool.fillsFields, let form {
            for w in form.fillable where w.pageIndex < pageRects.count {
                addCursorRect(viewRect(w.rect, pageRects[w.pageIndex]), cursor: w.kind == .text ? .iBeam : .pointingHand)
            }
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        shiftDown = event.modifierFlags.contains(.shift)
        let point = convert(event.locationInWindow, from: nil)
        if tool == .prepareForm {
            designDown(event, point)
            return
        }
        if let h = handle(at: point), let id = selectedId {
            startHandleDrag(id, h.page, h.handle)
            return
        }
        guard let hit = page(at: point) else { return }
        let p = pagePoint(point, on: hit.page)
        if boxPicker != nil {
            drag = .box(page: hit.page, start: p, now: p)
            return
        }
        if tool == .editContent {
            contentDown(hit.page, p)
            return
        }
        // The selected comment comes first, even over a form field (else a press there fills the field).
        if tool.selects, event.clickCount == 1, let id = selectedId, self.hit(page: hit.page, p) == id, let f = frame(of: id), canMove(id) {
            drag = .move(id: id, page: f.page, start: p, frame: f.rect, by: PointD(0, 0))
            return
        }
        if tool.fillsFields, let form, let w = form.widget(page: hit.page, p) {
            select(nil)
            form.activate(w)
            return
        }
        if form?.focused != nil { form?.clearFocus() }
        if tool.selects || tool == .link, let id = self.hit(page: hit.page, p) {
            select(id)
            if event.clickCount == 2 {
                host?.showInspector(id)
                return
            }
            if let f = frame(of: id), canMove(id) {
                drag = .move(id: id, page: f.page, start: p, frame: f.rect, by: PointD(0, 0))
            }
            return
        }
        select(nil)
        if tool.selects, event.clickCount == 1, let link = pageLink(page: hit.page, p) {
            selection = nil
            drag = .link(link, page: hit.page, start: point)
            return
        }
        switch tool {
        case .hand:
            if let clip = enclosingScrollView?.contentView {
                drag = .pan(start: event.locationInWindow, origin: clip.bounds.origin)
                NSCursor.closedHand.push()
            }
        case .text, .highlight, .underline, .strikeOut:
            startTextSelection(event, hit)
        case .textBox, .rectangle, .ellipse, .link, .callout:
            drag = .box(page: hit.page, start: p, now: p)
        case .polygon, .polyline:
            addVertex(hit.page, p, clicks: event.clickCount)
        case .line, .arrow:
            drag = .line(page: hit.page, start: p, now: p)
        case .pen, .highlighter:
            drag = .ink(page: hit.page, points: [p])
        case .note, .stamp, .image, .fillText, .fillCheck, .fillCross, .fillDate, .signature:
            drag = .box(page: hit.page, start: p, now: p)
        case .editContent, .prepareForm:
            return
        case .measureDistance, .measurePerimeter, .measureArea, .measureCalibrate:
            measureDown(hit.page, p, clicks: event.clickCount, shift: shiftDown)
        case .redact:
            // A click on a mark unmarks it; a drag marks an area.
            if let i = redactions.lastIndex(where: { $0.page == hit.page && $0.rect.contains(p.x, p.y) }) {
                removeRedaction(at: i)
                return
            }
            drag = .box(page: hit.page, start: p, now: p)
        }
    }

    /// Edit Text & Images: a picture is selected (and dragged), text is changed.
    /// A press in Edit Text & Images. Text on a picture wins, except over the selected picture, so it can be dragged
    /// (as on Windows): a picture lying over or under a line of text doesn't take the click meant for the text.
    private func contentDown(_ page: Int, _ p: PointD) {
        guard let content else { return }
        select(nil)
        let image = content.image(page: page, p)
        if let run = content.run(page: page, p), !content.isSelected(image) {
            content.select(nil)
            content.editRun(run)
            return
        }
        content.select(image)
        if let image, image.blocked == nil { drag = .contentMove(page: page, start: p, box: image.box, by: PointD(0, 0)) }
    }

    private func canMove(_ id: String) -> Bool {
        if let c = editor?.comment(id) { return DocumentEditor.movable(c) }
        return editor?.link(id) != nil
    }

    private func startHandleDrag(_ id: String, _ page: Int, _ handle: Int) {
        if handle >= 100 {
            drag = .lineEnd(id: id, page: page, end: handle - 100, points: lineEnds(of: id))
        } else if let f = frame(of: id) {
            drag = .resize(id: id, page: page, handle: handle, frame: f.rect, now: f.rect)
        }
    }

    private func startTextSelection(_ event: NSEvent, _ hit: (page: Int, x: Double, y: Double)) {
        guard let text = try? engine.text(hit.page), !text.isEmpty else {
            selection = nil
            return
        }
        let caret = text.hitTest(hit.x, hit.y)
        drag = .text
        switch event.clickCount {
        case 2: select(hit.page, text.wordAt(caret))
        case 3: select(hit.page, text.lineAt(caret))
        default: selection = TextSelection(page: hit.page, anchor: caret, head: caret)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        shiftDown = event.modifierFlags.contains(.shift)
        let point = convert(event.locationInWindow, from: nil)
        if tool == .prepareForm && drag == nil {
            design?.dragged(point, shift: shiftDown)
            return
        }
        guard let current = drag else { return }
        switch current {
        case .link(_, let page, let start):
            // Moved away from the link: a text selection (or a pan with the hand) from where the press began.
            guard abs(point.x - start.x) + abs(point.y - start.y) > 4 * onePixel else { return }
            if tool == .hand, let clip = enclosingScrollView?.contentView {
                drag = .pan(start: event.locationInWindow, origin: clip.bounds.origin)
                NSCursor.closedHand.push()
            } else if let text = try? engine.text(page), !text.isEmpty {
                let r = pageRects[page]
                let caret = text.hitTest(Double(start.x - r.minX), Double(start.y - r.minY))
                selection = TextSelection(page: page, anchor: caret, head: caret)
                drag = .text
            } else {
                drag = nil
            }
        case .text:
            guard var s = selection, let spot = page(at: point) else { return }
            if let text = try? engine.text(spot.page), !text.isEmpty {
                s.head = text.hitTest(spot.x, spot.y)
            } else {
                s.head = 0
            }
            s.headPage = spot.page
            selection = s
        case .pan(let start, let origin):
            guard let clip = enclosingScrollView?.contentView else { return }
            let k = onePixel
            let dx: CGFloat = (event.locationInWindow.x - start.x) * k
            let dy: CGFloat = (event.locationInWindow.y - start.y) * k
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: NSPoint(x: origin.x - dx, y: origin.y + dy), size: clip.bounds.size)).origin)
            enclosingScrollView?.reflectScrolledClipView(clip)
            return
        case .move(let id, let page, let start, let frame, _):
            let p = pagePoint(point, on: page)
            let g = engine.page(page)
            let d = DrawingGeometry.clampMove(frame, p.x - start.x, p.y - start.y, g.width, g.height)
            drag = .move(id: id, page: page, start: start, frame: frame, by: PointD(d.dx, d.dy))
        case .resize(let id, let page, let handle, let frame, _):
            let p = pagePoint(point, on: page)
            let keep = editor?.comment(id)?.subtype == "Stamp" || shiftDown
            drag = .resize(id: id, page: page, handle: handle, frame: frame,
                           now: DrawingGeometry.resize(frame, handle, p, minSize: 4, keepAspect: keep))
        case .lineEnd(let id, let page, let end, var points):
            var p = pagePoint(point, on: page)
            if shiftDown { p = DrawingGeometry.snapAngle(points[1 - end], p) }
            points[end] = p
            drag = .lineEnd(id: id, page: page, end: end, points: points)
        case .box(let page, let start, _):
            drag = .box(page: page, start: start, now: pagePoint(point, on: page))
        case .line(let page, let start, _):
            drag = .line(page: page, start: start, now: pagePoint(point, on: page))
        case .ink(let page, var points):
            points.append(pagePoint(point, on: page))
            drag = .ink(page: page, points: points)
        case .contentMove(let page, let start, let box, _):
            let p = pagePoint(point, on: page)
            let g = engine.page(page)
            let d = DrawingGeometry.clampMove(box, p.x - start.x, p.y - start.y, g.width, g.height)
            drag = .contentMove(page: page, start: start, box: box, by: PointD(d.dx, d.dy))
        }
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        shiftDown = event.modifierFlags.contains(.shift)
        if tool == .prepareForm && drag == nil {
            design?.released()
            return
        }
        guard let finished = drag else { return }
        drag = nil
        if case .pan = finished { NSCursor.pop() }
        if case .text = finished {
            if let kind = tool.markupKind { markSelection(kind) }
            return
        }
        if case .link(let link, _, _) = finished {
            host?.openLink(link)
            return
        }
        commit(finished, click: event.clickCount)
    }

    /// A press in Prepare Form: the designer selects, moves, resizes or starts a new field; an empty spot scrolls, as with
    /// the hand tool.
    private func designDown(_ event: NSEvent, _ point: NSPoint) {
        guard let design, let hit = page(at: point) else { return }
        if design.press(hit.page, pagePoint(point, on: hit.page), clicks: event.clickCount) == .pan, let clip = enclosingScrollView?.contentView {
            drag = .pan(start: event.locationInWindow, origin: clip.bounds.origin)
            NSCursor.closedHand.push()
        }
    }

    /// Turns a finished press into its edit.
    private func commit(_ finished: Drag, click: Int) {
        guard let editor, let page = finished.page else { return }
        let g = engine.page(page)
        let size = (width: g.width, height: g.height)
        if let picker = boxPicker, case .box(_, let a, let b) = finished {
            boxPicker = nil
            var box = DrawingGeometry.dragBox(a, b, square: false)
            if box.width < 20 || box.height < 10 {
                // A click: a box of the usual size (3.6 : 1), kept on the page.
                box = RectD(min(max(b.x - 90, 0), max(size.width - 180, 0)), min(max(b.y - 25, 0), max(size.height - 50, 0)), 180, 50)
            }
            picker(page, box)
            return
        }
        let style = styles.style(tool)
        let tool = self.tool
        switch finished {
        case .text, .pan, .link:
            return
        case .contentMove(_, _, let box, let by):
            guard abs(by.x) + abs(by.y) >= 0.5, let image = content?.selectedImage else { return }
            ghost = finished
            content?.move(image, to: RectD(box.x + by.x, box.y + by.y, box.width, box.height))
        case .move(let id, let page, _, let frame, let by):
            guard abs(by.x) + abs(by.y) >= 0.5 else { return }
            ghost = finished
            let moved = RectD(frame.x + by.x, frame.y + by.y, frame.width, frame.height)
            startEdit { await editor.setFrame(id, page: page, frame: moved, label: "Move") }
        case .resize(let id, let page, _, let frame, let now):
            guard now != frame else { return }
            ghost = finished
            startEdit { await editor.setFrame(id, page: page, frame: now, label: "Resize") }
        case .lineEnd(let id, _, _, let points):
            ghost = finished
            startEdit { await editor.setGeometry(id, AnnotGeometry(paths: [points]), label: "Reshape") }
        case .box(let page, let a, let b):
            let dragged = abs(b.x - a.x) > 3 || abs(b.y - a.y) > 3
            let box = DrawingGeometry.dragBox(a, b, square: shiftDown && (tool == .rectangle || tool == .ellipse))
            switch tool {
            case .callout:
                // Pressed at what it points to, released where the text goes (as on Windows).
                let width = 144.0
                let tip = a
                askCalloutText(page, tip: tip, end: dragged && abs(b.x - a.x) + abs(b.y - a.y) > 8 ? b : nil, width: width, style: style)
            case .rectangle, .ellipse:
                guard dragged else { return }
                ghost = finished
                let kind: ShapeKind = tool == .ellipse ? .ellipse : .rectangle
                startEdit { await editor.addShape(page: page, kind: kind, box: box, style: style) }
            case .textBox:
                let typewriter = !dragged
                let boxStyle = typewriter ? AnnotStyle.typewriter(fontSize: style.fontSize, textColor: style.textColor) : style
                let anchor = viewRect(dragged ? box : RectD(b.x, b.y, 1, 1), pageRects[page])
                host?.askText("Text", initial: "", at: anchor) { [weak self] text in
                    guard let self, let text, !text.isEmpty else { return }
                    let target = typewriter ? editor.typewriterBox(text, at: b, style: boxStyle, pageWidth: size.width) : box
                    self.startEdit { await editor.addFreeText(page: page, box: target, text: text, style: boxStyle) }
                }
            case .link:
                let rect = dragged ? box : RectD(max(b.x - 40, 0), max(b.y - 7, 0), 80, 14)
                guard rect.width >= 2 && rect.height >= 2 else { return }
                host?.askLink(at: viewRect(rect, pageRects[page])) { [weak self] uri, target in
                    guard let self else { return }
                    self.startEdit { await editor.addLink(page: page, rect: rect, uri: uri, target: target) }
                }
            case .note:
                let at = PointD(min(b.x, size.width - 20), min(b.y, size.height - 20))
                host?.askText("Note", initial: "", at: viewRect(RectD(at.x, at.y, 20, 20), pageRects[page])) { [weak self] text in
                    guard let self, let text else { return }
                    self.startEdit { await editor.addNote(page: page, at: at, text: text, color: style.color) }
                }
            case .stamp:
                let design = stamp
                startEdit { await editor.addStamp(page: page, center: b, design: design, pageSize: size) }
            case .image:
                guard let image = pendingImage else {
                    NSSound.beep()
                    return
                }
                startEdit { await editor.addImage(page: page, center: b, image: image, pageSize: size) }
            case .fillText, .fillCheck, .fillCross, .fillDate:
                fillIn(tool, page: page, at: b)
            case .signature:
                guard let pending = pendingSignature else {
                    NSSound.beep()
                    host?.askSignature()
                    return
                }
                let s = SignatureLibrary.size(pending.image, initials: pending.initials)
                let x: Double = min(max(b.x - s.width / 2, 0), max(size.width - s.width, 0))
                let y: Double = min(max(b.y - s.height / 2, 0), max(size.height - s.height, 0))
                let rect = RectD(x, y, s.width, s.height)
                startEdit { await editor.putSignature(page: page, rect: rect, image: pending.image, initials: pending.initials) }
            case .redact:
                guard dragged, box.width >= 1, box.height >= 1 else { return }
                addRedactions([RedactMark(page: page, rect: box)])
            default:
                return
            }
        case .line(let page, let a, let b):
            let end = shiftDown ? DrawingGeometry.snapAngle(a, b) : b
            guard abs(end.x - a.x) + abs(end.y - a.y) > 3 else { return }
            ghost = .line(page: page, start: a, now: end)
            var lineStyle = style
            if tool == .arrow && lineStyle.endEnding == .none { lineStyle.endEnding = .openArrow }
            let finalStyle = lineStyle
            startEdit { await editor.addLine(page: page, from: a, to: end, style: finalStyle) }
        case .ink(let page, let points):
            guard points.count > 1 else { return }
            ghost = finished
            let thinned = DrawingGeometry.simplify(points, Double(0.6 * onePixel))
            startEdit { await editor.addInk(page: page, strokes: [thinned], style: style) }
        }
    }

    /// A measuring tool's click: a point (Shift: straight or at 45° from the last), and the measurement handed over once it
    /// is finished.
    private func measureDown(_ page: Int, _ p: PointD, clicks: Int, shift: Bool) {
        guard var m = measuring else { return }
        let done = m.click(page: page, p, clicks: clicks, shift: shift)
        measuring = m
        if let done { finishMeasure(m.tool, done) }
    }

    private func finishMeasure(_ tool: MeasureTool, _ done: (page: Int, points: [PointD])) {
        guard let onMeasured else { return }
        startEdit { await onMeasured(tool, done.page, done.points) }
    }

    /// The pointer over the pages: the measurement under way follows it.
    override func mouseMoved(with event: NSEvent) {
        guard var m = measuring, m.isActive, m.page < pageRects.count else { return super.mouseMoved(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        m.move(page: m.page, pagePoint(point, on: m.page), shift: event.modifierFlags.contains(.shift))
        measuring = m
    }

    /// For the self-test: the measuring tool's state, and the points of a measurement as if clicked (the Windows dev
    /// script's `measure`).
    var measureInProgress: String? {
        guard let m = measuring else { return nil }
        return m.described(measureScaleAt?(m.page, m.points.first ?? PointD(0, 0)) ?? .default)
    }

    /// The Polygon and Polyline tools: each click adds a corner; a double-click, a click on the first corner (polygon) or
    /// Return finishes it; Esc drops it.
    private func addVertex(_ page: Int, _ p: PointD, clicks: Int) {
        guard var v = vertices, v.page == page else {
            vertices = (page, [p])
            return
        }
        if clicks >= 2 {
            finishVertices()
            return
        }
        if tool == .polygon, v.points.count >= 3, let first = v.points.first,
           abs(first.x - p.x) + abs(first.y - p.y) <= Double(8 * onePixel) {
            finishVertices()
            return
        }
        v.points.append(p)
        vertices = v
    }

    /// Adds the polygon or polyline drawn so far (a polygon needs three corners, a polyline two points).
    func finishVertices() {
        guard let v = vertices, let editor else { return }
        vertices = nil
        let closed = tool == .polygon
        var points = v.points
        if let last = points.last, points.count >= 2, abs(last.x - points[points.count - 2].x) + abs(last.y - points[points.count - 2].y) < 0.5 {
            points.removeLast() // the double-click's second press
        }
        guard points.count >= (closed ? 3 : 2) else { return NSSound.beep() }
        let style = styles.style(tool)
        startEdit { await editor.addPolygon(page: v.page, vertices: points, closed: closed, style: style) }
    }

    /// The callout's text, then the callout: its box beside the tip (where the drag ended, else up and to the right).
    private func askCalloutText(_ page: Int, tip: PointD, end: PointD?, width: Double, style: AnnotStyle) {
        guard let editor else { return }
        let g = engine.page(page)
        let anchor = viewRect(RectD(end?.x ?? tip.x + 36, end?.y ?? tip.y - 36, 1, 1), pageRects[page])
        host?.askText("Callout", initial: "", at: anchor) { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            let height = Annotations.freeTextHeight(text, width: width, style)
            var x: Double, y: Double
            if let end {
                x = end.x >= tip.x ? end.x : end.x - width
                y = end.y - height / 2
            } else {
                x = tip.x + 36
                y = tip.y - 36 - height
            }
            x = min(max(x, 0), max(g.width - width, 0))
            y = min(max(y, 0), max(g.height - height, 0))
            let box = RectD(x, y, width, height)
            self.startEdit { await editor.addFreeText(page: page, box: box, text: text, style: style, callout: [tip]) }
        }
    }

    /// Fill & Sign's text and marks: a click on one of them changes (text) or removes (a mark) it, elsewhere a new one.
    private func fillIn(_ tool: Tool, page: Int, at b: PointD) {
        guard let editor else { return }
        let fontSize = 11.0
        let existing = editor.stamps.last { s in
            s.pageIndex == page && (s.kind == .text || s.kind == .check || s.kind == .cross) && s.rect.inflate(2).contains(b.x, b.y)
        }
        if let s = existing {
            if s.kind == .text {
                host?.askText("Text", initial: s.text, at: viewRect(s.rect, pageRects[page])) { [weak self] text in
                    guard let self, let text, text != s.text else { return }
                    let rect = DocumentEditor.fillTextBox(text, at: PointD(s.rect.x, s.rect.y), fontSize: s.fontSize)
                    self.startEdit { await editor.putFillText(page: page, rect: rect, text: text, fontSize: s.fontSize, replacing: s.id) }
                }
            } else {
                startEdit { await editor.removeStamp(s.id, kind: s.kind) }
            }
            return
        }
        switch tool {
        case .fillCheck, .fillCross:
            let side = 12.0
            let rect = RectD(b.x - side / 2, b.y - side / 2, side, side)
            let kind: StampKind = tool == .fillCheck ? .check : .cross
            startEdit { await editor.putMark(page: page, rect: rect, kind: kind) }
        case .fillDate:
            let text = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            let rect = DocumentEditor.fillTextBox(text, at: PointD(b.x, max(b.y - fontSize * 0.6, 0)), fontSize: fontSize)
            startEdit { await editor.putFillText(page: page, rect: rect, text: text, fontSize: fontSize, replacing: nil) }
        default:
            // The text's top-left at the pointer, nudged up so its baseline sits where the click was.
            let top = PointD(b.x, max(b.y - fontSize * 0.6, 0))
            host?.askText("Text", initial: "", at: viewRect(RectD(top.x, top.y, 1, fontSize), pageRects[page])) { [weak self] text in
                guard let self, let text, !text.isEmpty else { return }
                let rect = DocumentEditor.fillTextBox(text, at: top, fontSize: fontSize)
                self.startEdit { await editor.putFillText(page: page, rect: rect, text: text, fontSize: fontSize, replacing: nil) }
            }
        }
    }

    /// Runs an edit started here; `pendingEdit` until it is done.
    func startEdit(_ edit: @escaping @MainActor () async -> Bool) {
        pendingEdit = Task { @MainActor in
            let ok = await edit()
            if !ok {
                ghost = nil
                needsDisplay = true
            }
            pendingEdit = nil
        }
    }

    // MARK: Text selection

    func select(_ page: Int, _ range: (start: Int, end: Int)) {
        selection = TextSelection(page: page, anchor: range.start, head: range.end)
        if selectedId != nil { select(nil) }
    }

    func clearSelection() { selection = nil }

    /// The selected text on each page it covers (page order), empty when nothing is selected.
    var selectedSpans: [(page: Int, start: Int, end: Int)] {
        guard let s = selection, !s.isEmpty else { return [] }
        var spans: [(page: Int, start: Int, end: Int)] = []
        for p in s.pages where p < engine.pageCount {
            guard let text = try? engine.text(p), let r = s.range(on: p, length: text.length) else { continue }
            spans.append((p, r.start, r.end))
        }
        return spans
    }

    /// The selected text (pages joined by a line break), or nil when nothing is selected.
    var selectedText: String? {
        let parts: [String] = selectedSpans.compactMap { span in (try? engine.text(span.page))?.string(span.start, span.end) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Highlights, underlines or strikes out the selected text, on every page it covers as one undo step (the menu
    /// commands, and the text tools on release).
    func markSelection(_ kind: TextMarkupKind) {
        let marks: [(page: Int, rects: [RectD])] = selectedSpans.compactMap { span in
            guard let text = try? engine.text(span.page) else { return nil }
            let rects = text.rects(span.start, span.end)
            return rects.isEmpty ? nil : (span.page, rects)
        }
        guard let editor, !marks.isEmpty else {
            NSSound.beep()
            return
        }
        let tool: Tool = kind == .highlight ? .highlight : kind == .underline ? .underline : .strikeOut
        let color = styles.style(tool).color ?? .yellow
        selection = nil
        startEdit { await editor.markText(kind, spans: marks, color: color) }
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
        let page = selection?.headPage ?? currentPage
        guard let text = try? engine.text(page), !text.isEmpty else { return }
        select(page, (0, text.length))
    }

    /// Edit › Delete: the selected comment or link.
    @objc func delete(_ sender: Any?) { deleteSelected() }

    func deleteSelected() {
        guard let editor, let id = selectedId else { return }
        select(nil)
        startEdit { await editor.delete(id) }
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return selectedText != nil }
        if item.action == #selector(delete(_:)) { return selectedId != nil }
        return true
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { validateUserInterfaceItem(menuItem) }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if tool == .editContent, let content, let spot = page(at: point), let image = content.image(page: spot.page, pagePoint(point, on: spot.page)) {
            content.select(image)
            let replace = NSMenuItem(title: "Replace Picture…", action: #selector(ContentEditing.replaceSelected(_:)), keyEquivalent: "")
            replace.target = content
            let delete = NSMenuItem(title: "Delete Picture", action: #selector(ContentEditing.deleteSelected(_:)), keyEquivalent: "")
            delete.target = content
            menu.addItem(replace)
            menu.addItem(delete)
            return menu
        }
        if let spot = page(at: point), let id = hit(page: spot.page, pagePoint(point, on: spot.page)) ?? linkAt(spot.page, pagePoint(point, on: spot.page)) {
            select(id)
            menu.addItem(withTitle: "Inspector…", action: #selector(DocumentWindowController.openInspector(_:)), keyEquivalent: "")
            if editor?.comment(id) != nil {
                menu.addItem(withTitle: "Reply…", action: #selector(DocumentWindowController.replyToSelected(_:)), keyEquivalent: "")
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Delete", action: #selector(delete(_:)), keyEquivalent: "")
            return menu
        }
        if selectedText != nil {
            menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            if AppSettings.ai.enabled {
                menu.addItem(withTitle: "Explain with AI", action: #selector(DocumentWindowController.aiExplain(_:)), keyEquivalent: "")
            }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Highlight", action: #selector(DocumentWindowController.highlightText(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Underline", action: #selector(DocumentWindowController.underlineText(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Strike Out", action: #selector(DocumentWindowController.strikeOutText(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "Link Selected Text…", action: #selector(DocumentWindowController.linkSelectedText(_:)), keyEquivalent: "")
            menu.addItem(.separator())
            menu.addItem(withTitle: "Redact", action: #selector(DocumentWindowController.redactSelectedText(_:)), keyEquivalent: "")
            return menu
        }
        return nil
    }

    private func linkAt(_ page: Int, _ p: PointD) -> String? {
        editor?.links.last { $0.pageIndex == page && $0.rect.contains(p.x, p.y) }?.id
    }

    /// The selected text's line boxes (for Link Selected Text).
    var selectedLines: (page: Int, rects: [RectD])? {
        guard let span = selectedSpans.first, let text = try? engine.text(span.page) else { return nil }
        return (span.page, text.rects(span.start, span.end))
    }

    // MARK: Keys

    /// ⌘D duplicates the selected field in Prepare Form (it adds a bookmark otherwise, as the menu says).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if tool == .prepareForm, window?.firstResponder === self, event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           event.charactersIgnoringModifiers == "d", design?.duplicateSelected() == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let picker = boxPicker, event.keyCode == 53 { // Esc: no box
            boxPicker = nil
            picker(0, nil)
            return
        }
        if tool == .prepareForm, design?.handleKey(event) == true { return }
        if form?.handleKey(event) == true || handleContentKey(event) || handleEditingKey(event) || handleToolKey(event) { return }
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

    /// Delete, arrows (nudge; Shift: 10 pt), Return (inspector), Esc (deselect, then back to selecting text), Tab and
    /// Shift-Tab (next and previous comment).
    private func handleEditingKey(_ event: NSEvent) -> Bool {
        let shift = event.modifierFlags.contains(.shift)
        if event.keyCode == 48 { // Tab: through the form's fields (else the comments)
            if selectedId == nil, let form, form.hasFields { return form.focusNext(shift ? -1 : 1) }
            guard let editor, !editor.comments.isEmpty else { return false }
            selectNext(shift ? -1 : 1)
            return true
        }
        if var m = measuring, m.isActive {
            // Return finishes (or goes on without enough points), Delete takes the last point back, Esc drops it.
            switch event.specialKey {
            case .carriageReturn, .enter:
                if let done = m.finish() { finishMeasure(m.tool, done) }
                measuring = m
                return true
            case .delete, .backspace:
                m.removeLast()
                measuring = m
                return true
            default:
                if event.keyCode == 53 {
                    m.cancel()
                    measuring = m
                    return true
                }
            }
        }
        if vertices != nil {
            switch event.specialKey {
            case .carriageReturn, .enter:
                finishVertices()
                return true
            default:
                if event.keyCode == 53 {
                    vertices = nil
                    return true
                }
            }
        }
        if event.keyCode == 53 { // Esc
            if drag != nil {
                drag = nil
            } else if selectedId != nil {
                select(nil)
            } else if tool != .text {
                tool = .text
            } else {
                return false
            }
            return true
        }
        guard let id = selectedId else { return false }
        switch event.specialKey {
        case .delete, .deleteForward, .backspace:
            deleteSelected()
            return true
        case .carriageReturn, .enter:
            host?.showInspector(id)
            return true
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard canMove(id), let f = frame(of: id) else { return false }
            let step = shift ? 10.0 : 1.0
            var dx = 0.0, dy = 0.0
            switch event.specialKey {
            case .leftArrow: dx = -step
            case .rightArrow: dx = step
            case .upArrow: dy = -step
            default: dy = step
            }
            let g = engine.page(f.page)
            let d = DrawingGeometry.clampMove(f.rect, dx, dy, g.width, g.height)
            let moved = RectD(f.rect.x + d.dx, f.rect.y + d.dy, f.rect.width, f.rect.height)
            if let editor { startEdit { await editor.setFrame(id, page: f.page, frame: moved, label: "Move") } }
            return true
        default:
            return false
        }
    }

    /// Edit Text & Images: Delete removes the selected picture, Esc lets go of it.
    private func handleContentKey(_ event: NSEvent) -> Bool {
        guard tool == .editContent, let content, content.selectedImage != nil else { return false }
        switch event.specialKey {
        case .delete, .deleteForward, .backspace:
            content.deleteSelected(nil)
            return true
        default:
            if event.keyCode == 53 {
                content.select(nil)
                return true
            }
            return false
        }
    }

    /// A tool's single key (H, T, P, R…): only here, while the pages have the focus, so typing in a field never picks a
    /// tool. The Tools menu shows the keys but leaves them to the focused view (`ToolsMenu`).
    private func handleToolKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let chars = event.charactersIgnoringModifiers?.lowercased(),
              let picked = Tool.allCases.first(where: { $0.key == chars }),
              let controller = window?.windowController as? DocumentWindowController else { return false }
        let item = NSMenuItem()
        item.tag = picked.rawValue
        controller.chooseTool(item)
        return true
    }

    /// Selects the next (or previous) comment in page order, wrapping around, and shows it.
    func selectNext(_ by: Int) {
        guard let editor, !editor.comments.isEmpty else { return }
        let list = editor.comments
        let index = selectedId.flatMap { id in list.firstIndex { $0.id == id } }
        let start = index ?? (by > 0 ? -1 : list.count)
        let next = ((start + by) % list.count + list.count) % list.count
        select(list[next].id, reveal: true)
    }

    /// Scrolls so `y` (this view's coordinates) is at the top of what is shown.
    func scrollTo(y: Double) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let maxY = max(frame.height - clip.bounds.height, 0)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: min(max(y, 0), maxY)))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    // MARK: VoiceOver

    /// The comments of the pages in view, as elements VoiceOver can reach and press (pressing selects one).
    override func accessibilityChildren() -> [Any]? {
        guard let editor, let range = pages(in: visibleRect) else { return [] }
        return editor.comments.filter { range.contains($0.pageIndex) }.compactMap { c -> CommentElement? in
            guard let f = frame(of: c.id), f.page < pageRects.count else { return nil }
            let element = CommentElement(id: c.id, view: self)
            element.setAccessibilityLabel(DocumentEditor.spoken(c))
            element.setAccessibilityFrameInParentSpace(viewRect(f.rect, pageRects[f.page]))
            element.setAccessibilitySelected(c.id == selectedId)
            return element
        }
    }
}

extension Tool {
    static let markupSubtypes: Set<String> = ["Highlight", "Underline", "StrikeOut", "Squiggly"]
}

/// A comment on the page for VoiceOver: pressing it selects it.
final class CommentElement: NSAccessibilityElement {
    let id: String
    private weak var view: PagesView?

    @MainActor
    init(id: String, view: PagesView) {
        self.id = id
        self.view = view
        super.init()
        setAccessibilityParent(view)
        setAccessibilityRole(.button)
        setAccessibilityRoleDescription("comment")
    }

    override func accessibilityPerformPress() -> Bool {
        let id = id, view = view
        MainActor.assumeIsolated {
            view?.window?.makeFirstResponder(view)
            view?.select(id, reveal: true)
        }
        return true
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
