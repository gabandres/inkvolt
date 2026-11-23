import AppKit
import PdfCore
import PrintCore

/// Rulers, guides, a grid and snapping (roadmap 4.19; the Windows app's `PageViewer.Layout` and `DocumentTab.Layout`):
/// PdfCore's `LayoutAids` says what the rulers mark and where a guide dragged from one lands, `PageGuides` (on the
/// document's session, never written into the PDF) keeps the guides, and `Snapper` what a point or box snaps to. This
/// draws them, passes the pointer in, and gives the tools that place things (Prepare Form, drawing, stamps and signatures,
/// measuring, moving comments) their snapping. ⌥ held: no snapping.

/// A ruler along the top or the left of the pages, counting from the current page's top-left as shown, in
/// `AppSettings.rulerUnit`. A press on it starts a new guide, dragged onto a page.
final class PageRuler: NSRulerView {
    weak var pages: PagesView?
    private let top: Bool

    init(scrollView: NSScrollView, top: Bool) {
        self.top = top
        super.init(scrollView: scrollView, orientation: top ? .horizontalRuler : .verticalRuler)
        ruleThickness = 20
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        setAccessibilityLabel(top ? loc("Horizontal ruler") : loc("Vertical ruler"))
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    override var requiredThickness: CGFloat { 20 }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        (top ? NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1) : NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height)).fill()
        guard let pages, !pages.pageRects.isEmpty else { return }
        let page = min(pages.currentPage, pages.pageRects.count - 1)
        let r = pages.pageRects[page]
        let visible = pages.visibleRect
        let zoom = Double(1 / pages.onePixel)
        let unit = pages.rulerUnit(page)
        let from = Double(top ? max(visible.minX - r.minX, 0) : max(visible.minY - r.minY, 0))
        let to = Double(top ? min(visible.maxX, r.maxX) - r.minX : min(visible.maxY, r.maxY) - r.minY)
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular)
        NSColor.secondaryLabelColor.set()
        for t in LayoutAids.ticks(from, to, zoom, unit) {
            let at = convert(NSPoint(x: r.minX + CGFloat(t.at), y: r.minY + CGFloat(t.at)), from: pages)
            let length: CGFloat = t.level == 0 ? 12 : t.level == 1 ? 7 : 4
            let tick = top ? NSRect(x: at.x, y: bounds.maxY - length, width: 1, height: length)
                : NSRect(x: bounds.maxX - length, y: at.y, width: length, height: 1)
            tick.fill()
            if let label = t.label {
                let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor])
                if top {
                    text.draw(at: NSPoint(x: at.x + 2, y: bounds.minY + 1))
                } else {
                    text.draw(at: NSPoint(x: 1, y: at.y + (isFlipped ? 1 : -11)))
                }
            }
        }
    }

    /// A press makes a guide that follows the pointer until it is let go over a page (elsewhere: none).
    override func mouseDown(with event: NSEvent) {
        guard let pages, let window else { return }
        var e: NSEvent? = event
        while let current = e, current.type != .leftMouseUp {
            pages.previewGuide(top: top, at: pages.convert(current.locationInWindow, from: nil))
            e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
        }
        pages.previewGuide(top: top, at: nil)
        if let up = e { pages.dropGuide(top: top, at: pages.convert(up.locationInWindow, from: nil)) }
    }
}

extension PagesView {
    private static let guideColor = NSColor(srgbRed: 0, green: 0.66, blue: 0.91, alpha: 1)
    private static let snapColor = NSColor(srgbRed: 0.88, green: 0.19, blue: 0.75, alpha: 1)

    /// The unit the rulers count in on a page: Ruler Units, else the page's measuring scale, else the region's.
    func rulerUnit(_ page: Int) -> RulerUnit {
        RulerUnit.for(AppSettings.rulerUnit, measureScaleAt?(page, PointD(1, 1)), metric: Locale.current.measurementSystem == .metric)
    }

    /// How near (page points) the pointer must come to snap, or to pick up a guide.
    var snapReach: Double { LayoutAids.snapPixels * Double(onePixel) }

    /// What a page snaps to now: its guides, the grid (shown and on) and other objects' edges and middles (Prepare Form's
    /// `fields`, as shown, else the form fields, comments, stamps and signatures), without `without` (fields by id) and
    /// `objectId` (the comment being moved). Nil: snapping is off, or ⌥ is held. Prepare Form passes its fields in: the
    /// designer is being changed while it asks.
    func snapper(_ page: Int, without: Set<String> = [], objectId: String? = nil,
                 fields: [(id: String, page: Int, rect: RectD)]? = nil) -> Snapper? {
        if NSEvent.modifierFlags.contains(.option) { return nil }
        let onGuides = AppSettings.snapToGuides ? guides?.on(page) : nil
        let grid = AppSettings.showGrid && AppSettings.snapToGrid ? AppSettings.gridStep : 0
        var objects: [RectD]?
        if AppSettings.snapToObjects {
            if let fields {
                objects = fields.filter { $0.page == page && !without.contains($0.id) }.map(\.rect)
            } else {
                let comments = (editor?.comments ?? []).filter { $0.pageIndex == page && $0.id != objectId && $0.replyTo == nil }.map(\.rect)
                let fields = (form?.widgets ?? []).filter { $0.pageIndex == page }.map(\.rect)
                objects = comments + fields
            }
        }
        return Snapper.for(onGuides, objects, gridStep: grid, reach: snapReach)
    }

    /// A point a tool places (a drawn box's corner, a line's end, a measuring point, a stamp's middle), snapped; what it
    /// snapped to shows until the press ends.
    func snapped(_ page: Int, _ p: PointD) -> PointD {
        guard let s = snapper(page) else {
            showSnapLines(page, [])
            return p
        }
        let q = s.point(p)
        showSnapLines(page, s.lines)
        return q
    }

    /// A comment being moved, snapped by its edges or middle (it never snaps to its own old box).
    func snappedMove(_ page: Int, _ r: RectD, id: String) -> RectD {
        guard let s = snapper(page, objectId: id) else {
            showSnapLines(page, [])
            return r
        }
        let moved = s.move(r)
        showSnapLines(page, s.lines)
        return moved
    }

    func showSnapLines(_ page: Int, _ lines: [SnapLine]) {
        let shown = lines.isEmpty ? nil : (page: page, lines: lines)
        if shown?.page != snapShown?.page || shown?.lines != snapShown?.lines { snapShown = shown }
    }

    // MARK: Guides

    /// The guide under a page point (within reach), for the hand and select tools to pick up.
    func guideNear(_ page: Int, _ p: PointD) -> Guide? { guides?.at(page, p, snapReach) }

    /// A guide being dragged from a ruler, shown at `at` (this view's coordinates; nil: none).
    func previewGuide(top: Bool, at: NSPoint?) {
        guidePreview = at.map { (top, $0) }
    }

    /// A guide let go at `at` (this view's coordinates) over a page: added there (a line across the screen from the top
    /// ruler, down it from the left one).
    func dropGuide(top: Bool, at: NSPoint) {
        guard let hit = page(at: at), let guides else { return }
        let r = pageRects[hit.page]
        let g = engine.page(hit.page)
        let viewPos = Double(top ? at.y - r.minY : at.x - r.minX)
        guard let guide = LayoutAids.fromRuler(hit.page, topRuler: top, viewPos, g.width, g.height, viewRotation) else { return }
        if guides.add(guide, g.width, g.height) { host?.guidesChanged() }
        needsDisplay = true
    }

    /// The self-test's ruler drag: a guide from the top (or left) ruler at `viewPos` points of the page as shown.
    @discardableResult
    func testAddGuide(_ page: Int, top: Bool, _ viewPos: Double) -> Bool {
        guard page < pageRects.count else { return false }
        let r = pageRects[page]
        let at = top ? NSPoint(x: r.midX, y: r.minY + CGFloat(viewPos)) : NSPoint(x: r.minX + CGFloat(viewPos), y: r.midY)
        let before = guides?.all.count ?? 0
        dropGuide(top: top, at: at)
        return (guides?.all.count ?? 0) > before
    }

    /// A guide dragged with the hand or select tool, let go: moved, or gone when dropped off its page.
    func endGuideDrag(_ g: Guide, page: Int, at: Double) {
        guard let guides else { return }
        let size = engine.page(page)
        _ = guides.move(g, at, size.width, size.height)
        host?.guidesChanged()
        needsDisplay = true
    }

    // MARK: Drawing

    /// A page's grid, guides and what a press snapped to.
    func drawLayout(_ page: Int, _ r: NSRect) {
        let px = onePixel
        let g = engine.page(page)
        if AppSettings.showGrid {
            let grid = LayoutAids.grid(g.width, g.height, AppSettings.gridStep)
            NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 0.22).setFill()
            for x in grid.xs { line(page, r, .x, x, px).fill() }
            for y in grid.ys { line(page, r, .y, y, px).fill() }
        }
        for guide in guides?.on(page) ?? [] {
            Self.guideColor.setFill()
            line(page, r, guide.axis, guide.at, px).fill()
        }
        if case .guide(let guide, let p, let at)? = drag, p == page, at >= 0 {
            Self.guideColor.withAlphaComponent(0.6).setFill()
            line(page, r, guide.axis, at, px).fill()
        }
        if let shown = snapShown, shown.page == page {
            Self.snapColor.setFill()
            for l in shown.lines { line(page, r, l.axis, l.at, px).fill() }
        }
        if let preview = guidePreview, let hit = self.page(at: preview.at), hit.page == page {
            Self.guideColor.withAlphaComponent(0.6).setFill()
            (preview.top ? NSRect(x: r.minX, y: preview.at.y, width: r.width, height: px)
                : NSRect(x: preview.at.x, y: r.minY, width: px, height: r.height)).fill()
        }
    }

    /// A one-pixel line across the page shown in `r` at a page x (`.x`) or y, turned with the view.
    private func line(_ page: Int, _ r: NSRect, _ axis: GuideAxis, _ at: Double, _ px: CGFloat) -> NSRect {
        let g = engine.page(page)
        let box = axis == .x ? RectD(at, 0, 0, g.height) : RectD(0, at, g.width, 0)
        let v = viewRect(box, r)
        return v.width < v.height ? NSRect(x: v.minX, y: v.minY, width: px, height: v.height) : NSRect(x: v.minX, y: v.minY, width: v.width, height: px)
    }
}

// MARK: The window: settings, menu commands, guides following their pages

extension DocumentWindowController {
    /// The rulers on the pages' scroll view, made the first time they show.
    func applyLayoutAids() {
        if AppSettings.showRulers && !(scrollView.horizontalRulerView is PageRuler) {
            let top = PageRuler(scrollView: scrollView, top: true)
            let left = PageRuler(scrollView: scrollView, top: false)
            top.pages = pages
            left.pages = pages
            scrollView.horizontalRulerView = top
            scrollView.verticalRulerView = left
            scrollView.hasHorizontalRuler = true
            scrollView.hasVerticalRuler = true
        }
        scrollView.rulersVisible = AppSettings.showRulers
        pages.guides = pdf.session?.guides
        refreshRulers()
        pages.needsDisplay = true
    }

    func refreshRulers() {
        guard scrollView.rulersVisible else { return }
        scrollView.horizontalRulerView?.needsDisplay = true
        scrollView.verticalRulerView?.needsDisplay = true
    }

    /// Every open document window, after a setting changed.
    private func layoutSettingChanged(_ change: () -> Void) {
        change()
        for w in NSApp.windows {
            (w.windowController as? DocumentWindowController)?.applyLayoutAids()
        }
    }

    /// The View menu's checkmarks for the settings above.
    func markLayoutItem(_ item: NSMenuItem) {
        let on: Bool
        switch item.action {
        case #selector(toggleRulers(_:)): on = AppSettings.showRulers
        case #selector(toggleGrid(_:)): on = AppSettings.showGrid
        case #selector(toggleSnapToGuides(_:)): on = AppSettings.snapToGuides
        case #selector(toggleSnapToGrid(_:)): on = AppSettings.snapToGrid
        case #selector(toggleSnapToObjects(_:)): on = AppSettings.snapToObjects
        default: return
        }
        item.state = on ? .on : .off
    }

    /// View › Rulers.
    @objc func toggleRulers(_ sender: Any?) { layoutSettingChanged { AppSettings.showRulers.toggle() } }
    /// View › Grid.
    @objc func toggleGrid(_ sender: Any?) { layoutSettingChanged { AppSettings.showGrid.toggle() } }
    @objc func toggleSnapToGuides(_ sender: Any?) { layoutSettingChanged { AppSettings.snapToGuides.toggle() } }
    @objc func toggleSnapToGrid(_ sender: Any?) { layoutSettingChanged { AppSettings.snapToGrid.toggle() } }
    @objc func toggleSnapToObjects(_ sender: Any?) { layoutSettingChanged { AppSettings.snapToObjects.toggle() } }

    /// View › Guides and Snapping › Ruler Units: the next unit (the page's scale or the region's, inches, millimeters,
    /// centimeters, points), the rulers shown.
    @objc func nextRulerUnit(_ sender: Any?) {
        layoutSettingChanged {
            let choices = RulerUnit.choices
            let i = choices.firstIndex(of: AppSettings.rulerUnit) ?? 0
            AppSettings.rulerUnit = choices[(i + 1) % choices.count]
            AppSettings.showRulers = true
        }
        let unit = pages.rulerUnit(pages.currentPage).name
        notify(loc("Rulers in {0}.", AppSettings.rulerUnit == "auto" ? loc("{0}, the page's scale or your region's", unit) : unit))
    }

    /// The self-test's answer to Grid Spacing… (an index of `LayoutAids.gridSteps`).
    static var testGridStep: Int?

    /// View › Guides and Snapping › Grid Spacing…: a line every ¼ inch, ½ inch, 1 inch, 5 mm, 1 cm or 10 points.
    @objc func chooseGridSpacing(_ sender: Any?) {
        let labels = [loc("¼ inch"), loc("½ inch"), loc("1 inch"), loc("5 mm"), loc("1 cm"), loc("10 points")]
        let steps = LayoutAids.gridSteps
        func apply(_ i: Int) {
            guard steps.indices.contains(i) else { return }
            layoutSettingChanged {
                AppSettings.gridStep = steps[i]
                AppSettings.showGrid = true
            }
        }
        if let i = Self.testGridStep {
            Self.testGridStep = nil
            apply(i)
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = loc("Grid spacing")
        alert.informativeText = loc("Shapes, fields, stamps and measuring points snap to the grid while it shows and Snap to Grid is on. Hold ⌥ for no snapping.")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 200, height: 26), pullsDown: false)
        popup.addItems(withTitles: labels)
        popup.selectItem(at: steps.firstIndex { abs($0 - AppSettings.gridStep) < 0.01 } ?? 0)
        popup.setAccessibilityLabel(loc("A line every"))
        alert.accessoryView = popup
        alert.addButton(withTitle: loc("OK"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { if response == .alertFirstButtonReturn { apply(popup.indexOfSelectedItem) } }
        }
    }

    /// View › Guides and Snapping › Clear Guides: every page's.
    @objc func clearGuides(_ sender: Any?) {
        guard let guides = pdf.session?.guides else { return }
        let n = guides.clear()
        pages.needsDisplay = true
        guidesChanged()
        if n > 0 { notify(n == 1 ? loc("{0} guide cleared.", CoreLanguage.number(1)) : loc("{0} guides cleared.", CoreLanguage.number(n))) }
    }

    /// The guides were added to, moved or cleared: each page's identity is read (off the main thread), so the guides follow
    /// their pages through later edits.
    func guidesChanged() {
        window?.toolbar?.validateVisibleItems()
        guard let session = pdf.session, !session.guides.all.isEmpty else {
            guideKeys = nil
            return
        }
        let engine = ObjectIdentifier(session.engine)
        if guideKeys?.engine == engine { return }
        let data = session.data, password = session.password
        // A read still running for an earlier guide is stopped, not only its answer dropped (a huge file reads for long).
        guideKeying?.cancel()
        let cancel = CancelToken()
        guideKeying = cancel
        Task { @MainActor [weak self] in
            guard let keys = try? await Task.detached(operation: { try PageGuides.keys(data, password, cancel: cancel) }).value else { return }
            guard let self, let now = self.pdf.session, ObjectIdentifier(now.engine) == engine else { return }
            self.guideKeys = (engine, keys)
        }
    }

    /// The pages may have moved, turned or been replaced: each page's guides follow it (`PageGuides.remap`); a page that is
    /// gone or changed takes them with it; when the pages couldn't be told apart, they all go.
    func remapGuides(_ change: ContentChange) {
        guard let session = pdf.session else { return }
        pages.guides = session.guides
        if session.guides.all.isEmpty {
            guideKeys = nil
            return
        }
        let engine = ObjectIdentifier(session.engine)
        // A form value or Fill & Sign edit leaves the pages as they were.
        if change.contentOnly, let k = guideKeys {
            guideKeys = (engine, k.keys)
            return
        }
        let before = guideKeys
        guideTicket += 1
        let ticket = guideTicket
        let data = session.data, password = session.password
        // The reads of an earlier version are stopped: their answers would be dropped (the ticket, the engine).
        guideKeying?.cancel()
        guideKeying = nil
        guideRemapping?.cancel()
        let cancel = CancelToken()
        guideRemapping = cancel
        Task { @MainActor [weak self] in
            let keys = try? await Task.detached(operation: { try PageGuides.keys(data, password, cancel: cancel) }).value
            guard let self, ticket == self.guideTicket, let now = self.pdf.session else { return }
            if let before, let keys { now.guides.remap(before.keys, keys) } else { now.guides.pagesChanged() }
            self.guideKeys = keys.map { (engine, $0) }
            self.pages.needsDisplay = true
            self.secondPages?.needsDisplay = true
        }
    }
}
