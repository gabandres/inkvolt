import AppKit
import PdfCore

/// How the document view is split (View › Split View), as on Windows.
enum SplitMode: Equatable {
    case none, topAndBottom, sideBySide
}

/// The panes' container: the main pane's scroll view alone, or both panes with a thin bar between them to drag. Its panes
/// are plain subviews sized by frames (not arranged subviews: those tie a top and bottom split's height to the panes'
/// own, and the stack it sits in then shrinks it to nothing).
@MainActor
final class PaneSplitView: NSSplitView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        arrangesAllSubviews = false
        dividerStyle = .thin
        isVertical = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var panes: [NSView] { subviews }

    func addPane(_ view: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = true
        addSubview(view)
        adjustSubviews()
    }

    func removePane(_ view: NSView) {
        view.removeFromSuperview()
        adjustSubviews()
    }

    /// Two panes at even halves (each time the layout changes, as on Windows): set by frame, since `adjustSubviews`
    /// keeps the panes' proportions and a pane just added has none.
    func evenHalves() {
        layoutSubtreeIfNeeded()
        guard subviews.count == 2 else { return }
        let d = dividerThickness, b = bounds
        if isVertical {
            let w = ((b.width - d) / 2).rounded(.down)
            subviews[0].frame = NSRect(x: 0, y: 0, width: w, height: b.height)
            subviews[1].frame = NSRect(x: w + d, y: 0, width: b.width - w - d, height: b.height)
        } else {
            let h = ((b.height - d) / 2).rounded(.down)
            subviews[0].frame = NSRect(x: 0, y: 0, width: b.width, height: h)
            subviews[1].frame = NSRect(x: 0, y: h + d, width: b.width, height: b.height - h - d)
        }
        needsDisplay = true
    }

    /// The main pane alone fills the view.
    override func layout() {
        super.layout()
        if subviews.count == 1, let only = subviews.first, only.frame != bounds { only.frame = bounds }
    }
}

/// Split view (E13; the Windows app's `DocumentTab.Split.cs`): a second pane on the same document, with its own page,
/// scroll and zoom, so two places can be read at once. The panes share the document and its undo history: every engine
/// the main pane gets (an edit, undo, redo, a reload, the layers shown) goes to the second pane too, so an edit made in
/// one shows in the other at once. The second pane is for reading (the hand, text selection, links, Copy); a tool that
/// changes the document works in the main pane, which becomes the active one when such a tool is picked. Navigation
/// (zoom, the page commands, thumbnails, bookmarks, Find's next match) acts on the active pane, which has an accent
/// frame. Click a pane, or View › Split View › Switch Pane (⌘'), to switch; Remove Split or the × on the second pane
/// closes it. Kept per window while it is open, not saved.
extension DocumentWindowController {
    /// Both panes while split, else the main one.
    var allPanes: [PagesView] { [pages] + (secondPages.map { [$0] } ?? []) }

    /// The pane navigation acts on.
    var activePages: PagesView { secondActive ? secondPages ?? pages : pages }
    var activeScroll: NSScrollView { secondActive ? secondScroll ?? scrollView : scrollView }

    static func isReadingTool(_ tool: Tool) -> Bool { tool.readsOnly }

    /// A tool picked from the strip or the Tools menu: the hand and text selection go to the active pane; anything else
    /// to the main pane, which becomes the active one.
    func pickTool(_ tool: Tool) {
        if secondActive, let second = secondPages, Self.isReadingTool(tool) {
            second.tool = tool
            window?.makeFirstResponder(second)
            return
        }
        activatePane(second: false)
        pages.tool = tool
        window?.makeFirstResponder(pages)
    }

    // MARK: Menu commands

    @objc func splitTopAndBottom(_ sender: Any?) { setSplit(.topAndBottom) }
    @objc func splitSideBySide(_ sender: Any?) { setSplit(.sideBySide) }
    @objc func removeSplit(_ sender: Any?) { setSplit(.none) }

    /// View › Split View › Switch Pane (⌘'): the other pane gets the keyboard and becomes the active one.
    @objc func switchPane(_ sender: Any?) {
        guard secondPages != nil else { return NSSound.beep() }
        activatePane(second: !secondActive)
        window?.makeFirstResponder(activePages)
    }

    /// The split commands' checkmarks (when they can run is the command table's: `DocumentCommands`).
    func markSplitItem(_ item: NSMenuItem) {
        switch item.action {
        case #selector(splitTopAndBottom(_:)): item.state = splitMode == .topAndBottom ? .on : .off
        case #selector(splitSideBySide(_:)): item.state = splitMode == .sideBySide ? .on : .off
        default: break
        }
    }

    // MARK: Splitting

    /// Splits the view (or changes how), or closes the split with `.none`.
    func setSplit(_ mode: SplitMode) {
        guard mode != splitMode else { return }
        if mode != .none && organizerShown { showOrganizer(false) }
        if mode == .none {
            closeSecondPane()
            splitMode = .none
            updatePaneFrames()
            window?.makeFirstResponder(pages)
            updateSubtitle()
            return
        }
        let opening = secondPages == nil
        if opening { openSecondPane() }
        splitMode = mode
        paneSplit.isVertical = mode == .sideBySide
        paneSplit.evenHalves()
        if opening, let second = secondPages, let scroll = secondScroll {
            // The new pane starts where the main pane is, at its zoom, so it can be moved on from there.
            let page = pages.currentPage
            scroll.magnification = scrollView.magnification
            second.layoutSubtreeIfNeeded()
            if page < second.pageRects.count { second.scrollTo(y: second.pageRects[page].minY - PagesView.gap / 2) }
            activatePane(second: true)
            window?.makeFirstResponder(second)
            second.requestVisible()
        }
        updatePaneFrames()
        pages.requestVisible()
    }

    private func openSecondPane() {
        let second = PagesView(engine: engine)
        second.setViewRotation(pages.viewRotation) // starts turned and laid out as the main pane; its own after
        second.setReadingMode(pages.readingMode)
        second.readingOnly = true
        second.host = self
        second.tool = .text
        second.setAccessibilityLabel("Pages, second pane")
        second.onActivate = { [weak self] in self?.activatePane(second: true) }
        second.onWritingTool = { [weak self] tool in self?.pickTool(tool) }
        if let layerEngine { second.draw(with: layerEngine) }
        second.matches = pages.matches
        second.currentMatch = pages.currentMatch

        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.documentView = second
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = scrollView.minMagnification
        scroll.maxMagnification = scrollView.maxMagnification
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.drawsBackground = true
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(secondScrolled), name: NSView.boundsDidChangeNotification,
                                               object: scroll.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(magnified), name: NSScrollView.didEndLiveMagnifyNotification,
                                               object: scroll)

        // The second pane's × (Remove Split), over its top right corner.
        let box = NSView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(scroll)
        let close = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close the split") ?? NSImage(),
                             target: self, action: #selector(removeSplit(_:)))
        close.isBordered = false
        close.toolTip = "Close the split (View › Split View › Remove Split)"
        close.setAccessibilityLabel("Close the split")
        close.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(close)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: box.topAnchor), scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            close.topAnchor.constraint(equalTo: box.topAnchor, constant: 8), close.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -22),
        ])
        paneSplit.addPane(box)
        secondPages = second
        secondScroll = scroll
        secondBox = box
    }

    private func closeSecondPane() {
        guard let box = secondBox else { return }
        if let scroll = secondScroll {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: scroll.contentView)
            NotificationCenter.default.removeObserver(self, name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)
        }
        secondPages?.renderer.cancelAll()
        paneSplit.removePane(box)
        secondPages = nil
        secondScroll = nil
        secondBox = nil
        secondActive = false
        sidebar.showCurrent(pages.currentPage)
    }

    @objc private func secondScrolled() {
        if secondActive { scrolled() }
        if let second = secondPages { window?.invalidateCursorRects(for: second) }
    }

    /// Makes a pane the active one (navigation acts on it; it has the accent frame).
    func activatePane(second: Bool) {
        let wanted = second && secondPages != nil
        guard wanted != secondActive else { return }
        secondActive = wanted
        updatePaneFrames()
        sidebar.showCurrent(activePages.currentPage)
        updateSubtitle()
    }

    /// The active pane's accent frame, only while split.
    func updatePaneFrames() {
        let split = secondPages != nil
        for (scroll, active) in [(scrollView, !secondActive), (secondScroll, secondActive)] {
            guard let scroll else { continue }
            let frame = PaneFrameView.of(scroll)
            frame.state = split ? (active ? .active : .inactive) : .none
        }
    }

    /// What the self-test reads: the split, the active pane, each pane's page and zoom.
    var splitState: String {
        guard let second = secondPages, let scroll = secondScroll else { return "split=none" }
        return "split=\(splitMode) active=\(secondActive ? "second" : "main") main: page=\(pages.currentPage + 1) zoom=\(Int(scrollView.magnification * 100))% "
            + "second: page=\(second.currentPage + 1) zoom=\(Int(scroll.magnification * 100))%"
            + " [frames: split \(Int(paneSplit.frame.width))×\(Int(paneSplit.frame.height)) main \(Int(scrollView.frame.width))×\(Int(scrollView.frame.height))"
            + " second \(Int(scroll.frame.width))×\(Int(scroll.frame.height)) in \(Int(secondBox?.frame.width ?? 0))×\(Int(secondBox?.frame.height ?? 0))]"
    }
}

/// A pane's frame while the view is split: the accent color around the active pane. Drawn over the scroll view, never
/// in the way of the mouse.
@MainActor
final class PaneFrameView: NSView {
    enum State { case none, inactive, active }
    var state: State = .none { didSet { if state != oldValue { needsDisplay = true } } }

    /// The frame view of a pane's scroll view, made the first time.
    static func of(_ scroll: NSScrollView) -> PaneFrameView {
        if let made = scroll.subviews.first(where: { $0 is PaneFrameView }) as? PaneFrameView { return made }
        let view = PaneFrameView(frame: scroll.bounds)
        view.autoresizingMask = [.width, .height]
        view.setAccessibilityElement(false)
        scroll.addSubview(view, positioned: .above, relativeTo: nil)
        return view
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard state == .active else { return }
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.stroke()
    }
}
