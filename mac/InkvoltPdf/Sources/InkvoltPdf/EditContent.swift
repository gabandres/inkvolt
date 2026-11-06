import AppKit
import PdfCore
import PrintCore
import UniformTypeIdentifiers

/// Edit Text & Images (the Windows app's PageViewer.EditContent and DocumentTab.EditContent), over D5a's
/// `ContentEditor`: with the tool on, the page's own text runs and pictures are outlined; a click on text asks for its
/// new wording (kept only when the run's font has every character), a picture is selected with a click, dragged to move
/// it, its handles resize it (Shift keeps its proportions), the arrow keys nudge it (Shift: 10 pt; written once the keys
/// rest for 0.45 s, as Windows), Delete removes it and Replace Picture… swaps it. Each change is one undo step. Not yet:
/// Tab through the runs.
@MainActor
final class ContentEditing: NSObject {
    private weak var controller: DocumentWindowController?
    /// Each page's runs and pictures, read off the main thread for the current bytes.
    private var content: [Int: PageContent] = [:]
    private var loading: [Int: Task<PageContent, Never>] = [:]
    private(set) var selectedImage: PageImage?
    private(set) var pendingEdit: Task<Void, Never>?
    /// Arrow-key moves of the selected picture not written yet (page space), and the timer that writes them.
    private(set) var nudge = PointD(0, 0)
    private var nudgeTimer: Timer?
    /// The selected picture being found again after an edit, and which reading of the content that is.
    private var refinding = false
    private var readings = 0

    init(controller: DocumentWindowController) {
        self.controller = controller
        super.init()
    }

    private var pages: PagesView? { controller?.pages }
    private var editor: DocumentEditor? { controller?.editor }

    /// The content changed: everything is read again (a selected picture is found again by its place).
    func invalidate(keeping box: RectD? = nil, page kept: Int? = nil) {
        for t in loading.values { t.cancel() }
        loading = [:]
        content = [:]
        let keep = box ?? selectedImage?.box
        let page = kept ?? selectedImage?.pageIndex
        selectedImage = nil
        readings += 1
        if let keep, let page {
            refinding = true
            let reading = readings
            Task { [weak self] in
                guard let self else { return }
                let c = await self.ensure(page)
                // A later reading (the moved picture found where it went) wins over this one.
                guard reading == self.readings else { return }
                self.selectedImage = c.images.first { abs($0.box.x - keep.x) < 1 && abs($0.box.y - keep.y) < 1 }
                self.refinding = false
                self.pages?.needsDisplay = true
            }
        } else {
            refinding = false
        }
    }

    /// A page's content, read when first asked for.
    func ensure(_ page: Int) async -> PageContent {
        if let c = content[page] { return c }
        if let t = loading[page] { return await t.value }
        guard let session = editor?.session else { return .empty }
        let data = session.data, pw = session.password
        let task = Task.detached { (try? ContentEditor.read(data, pw, page)) ?? .empty }
        loading[page] = task
        let c = await task.value
        if loading[page] == task {
            content[page] = c
            loading[page] = nil
        }
        return c
    }

    /// The content shown on a page, asked for when not read yet (the page is drawn again when it arrives).
    func shown(_ page: Int) -> PageContent? {
        if let c = content[page] { return c }
        if loading[page] == nil {
            Task { [weak self] in
                _ = await self?.ensure(page)
                guard let self, let pages = self.pages, page < pages.pageRects.count else { return }
                pages.setNeedsDisplay(pages.pageRects[page])
            }
        }
        return nil
    }

    // MARK: Drawing

    func draw(_ page: Int, _ r: NSRect) {
        guard let pages, let c = shown(page) else { return }
        let px = pages.onePixel
        for run in c.runs {
            let path = NSBezierPath(rect: pages.viewRect(run.box, r).insetBy(dx: -px, dy: -px))
            path.lineWidth = px
            path.setLineDash([3 * px, 2 * px], count: 2, phase: 0)
            (run.blocked == nil ? NSColor.systemBlue.withAlphaComponent(0.7) : NSColor.systemGray.withAlphaComponent(0.6)).setStroke()
            path.stroke()
        }
        for image in c.images {
            let selected = isSelected(image)
            let box = selected ? shownBox(image) : image.box
            let path = NSBezierPath(rect: pages.viewRect(box, r))
            path.lineWidth = selected ? 2 * px : px
            if !selected { path.setLineDash([5 * px, 3 * px], count: 2, phase: 0) }
            (selected ? NSColor.controlAccentColor : image.blocked == nil ? NSColor.systemOrange : NSColor.systemGray).setStroke()
            path.stroke()
            if selected && image.blocked == nil {
                for h in 0...7 {
                    let p = pages.viewPoint(DrawingGeometry.handlePoint(box, h), r)
                    let size = 6 * px
                    let square = NSBezierPath(rect: NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size))
                    NSColor.white.setFill()
                    square.fill()
                    square.lineWidth = px
                    square.stroke()
                }
            }
        }
    }

    /// Where the selected picture shows: its box moved by the arrow keys so far.
    func shownBox(_ image: PageImage) -> RectD {
        isSelected(image) ? RectD(image.box.x + nudge.x, image.box.y + nudge.y, image.box.width, image.box.height) : image.box
    }

    /// The selected picture's resize handle under a page point (`reach` in page points), nil when none.
    func handle(page: Int, _ p: PointD, reach: Double) -> Int? {
        guard let image = selectedImage, image.pageIndex == page, image.blocked == nil else { return nil }
        let box = shownBox(image)
        return (0...7).first { h in
            let q = DrawingGeometry.handlePoint(box, h)
            return abs(q.x - p.x) <= reach && abs(q.y - p.y) <= reach
        }
    }

    // MARK: Arrow keys

    /// The arrow keys move the selected picture by (dx, dy) (page space), kept on its page; written once they rest.
    func nudgeSelected(_ dx: Double, _ dy: Double) {
        guard let image = selectedImage, let controller else { return }
        if let why = image.blocked {
            controller.notify(loc("This picture can't be moved: {0}.", why))
            return
        }
        let g = controller.engine.page(image.pageIndex)
        let d = DrawingGeometry.clampMove(shownBox(image), dx, dy, g.width, g.height)
        nudge = PointD(nudge.x + d.dx, nudge.y + d.dy)
        nudgeTimer?.invalidate()
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushNudge() }
        }
        pages?.needsDisplay = true
    }

    var hasPendingNudge: Bool { nudgeTimer != nil }

    /// Writes the arrow-key moves made so far (before anything else acts on the picture, and before closing). While the
    /// last move is still being written, or the picture found again after it, it tries again shortly.
    func flushNudge() {
        nudgeTimer?.invalidate()
        nudgeTimer = nil
        guard abs(nudge.x) + abs(nudge.y) >= 0.01 else { return nudge = PointD(0, 0) }
        if pendingEdit != nil || refinding {
            nudgeTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushNudge() }
            }
            return
        }
        let by = nudge
        nudge = PointD(0, 0)
        guard let image = selectedImage else { return }
        move(image, to: RectD(image.box.x + by.x, image.box.y + by.y, image.box.width, image.box.height))
    }

    // MARK: Pressing

    func image(page: Int, _ p: PointD) -> PageImage? { content[page]?.imageAt(p.x, p.y) }
    func run(page: Int, _ p: PointD) -> TextRun? { content[page]?.runAt(p.x, p.y, slop: 2) }

    /// Whether `image` (nil: no) is the selected picture.
    func isSelected(_ image: PageImage?) -> Bool {
        guard let image, let s = selectedImage else { return false }
        return s.pageIndex == image.pageIndex && s.id == image.id
    }

    func select(_ image: PageImage?) {
        if !isSelected(image) {
            flushNudge()
            // A move that couldn't be written yet (the last one still being written) goes with the old selection.
            if hasPendingNudge {
                nudgeTimer?.invalidate()
                nudgeTimer = nil
                nudge = PointD(0, 0)
            }
        }
        selectedImage = image
        pages?.needsDisplay = true
        if let image, let pages {
            let what = image.blocked.map { loc("Picture, can't be changed: {0}", $0) }
                ?? loc("Picture selected: drag to move it or its handles to resize it, arrow keys move it, Delete removes it")
            NSAccessibility.post(element: pages, notification: .announcementRequested, userInfo: [.announcement: what])
        }
    }

    /// A click on text: its new wording, asked for over it.
    func editRun(_ run: TextRun) {
        guard let pages, let controller, run.pageIndex < pages.pageRects.count else { return }
        if let why = run.blocked {
            controller.notify(loc("This text can't be edited: {0}.", why))
            return
        }
        let anchor = pages.viewRect(run.box, pages.pageRects[run.pageIndex])
        controller.askText(loc("Edit Text"), initial: run.text, at: anchor) { [weak self] text in
            guard let self, let text, text != run.text else { return }
            self.replace(run, text)
        }
    }

    /// Replaces a run's text when its font can draw every character (else says which are missing).
    func replace(_ run: TextRun, _ text: String) {
        guard let editor, let controller else { return }
        let check = run.check(text)
        if !check.missing.isEmpty {
            let list = check.missing.prefix(8).map { $0 == " " ? loc("space") : "“\($0)”" }.joined(separator: ", ")
            controller.notify(loc("Not changed: the font “{0}” has no {1} in this PDF.", run.fontName, list))
            return
        }
        pendingEdit = Task {
            let ok = await editor.replaceText(run, text)
            if ok && check.width - check.oldWidth > 0.5 {
                // The widths come from the PDF's font: one too wide to count is said without its number.
                if let wider = Int(exactly: (check.width - check.oldWidth).rounded()) {
                    controller.notify(loc("Text changed. It is {0} pt wider than before and doesn't reflow, so it may overlap what follows.", CoreLanguage.number(wider)), canUndo: true)
                } else {
                    controller.notify(loc("Text changed. It is wider than before and doesn't reflow, so it may overlap what follows."), canUndo: true)
                }
            }
            self.pendingEdit = nil
        }
    }

    /// The selected picture moved to `box`.
    func move(_ image: PageImage, to box: RectD) {
        guard let editor else { return }
        if let why = image.blocked {
            controller?.notify(loc("This picture can't be moved: {0}.", why))
            return
        }
        pendingEdit = Task {
            // The document's own change notice has read everything again already (dropping the selection): the picture is
            // found again where it went.
            if await editor.moveImage(image, to: box) { self.invalidate(keeping: box, page: image.pageIndex) }
            self.pendingEdit = nil
        }
    }

    @objc func deleteSelected(_ sender: Any?) {
        guard let editor, let image = selectedImage else { return NSSound.beep() }
        // Arrow-key moves still waiting are dropped with the picture.
        nudgeTimer?.invalidate()
        nudgeTimer = nil
        nudge = PointD(0, 0)
        if let why = image.blocked {
            controller?.notify(loc("This picture can't be deleted: {0}.", why))
            return
        }
        select(nil)
        pendingEdit = Task {
            await editor.deleteImage(image)
            self.pendingEdit = nil
        }
    }

    @objc func replaceSelected(_ sender: Any?) {
        flushNudge()
        guard let image = selectedImage, let window = pages?.window else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.message = loc("Choose the picture that takes its place.")
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
                self.replace(image, with: [UInt8](data), name: url.lastPathComponent)
            }
        }
    }

    func replace(_ image: PageImage, with file: [UInt8], name: String) {
        guard let editor else { return }
        pendingEdit = Task {
            if await editor.replaceImage(image, file: file, name: name) { self.invalidate(keeping: image.box, page: image.pageIndex) }
            self.pendingEdit = nil
        }
    }

    /// Waits for the moves and edits started so far, arrow-key moves included (the self-test).
    func settle() async {
        for _ in 0..<100 {
            if hasPendingNudge { flushNudge() }
            await pendingEdit?.value
            if !hasPendingNudge && pendingEdit == nil && !refinding { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}
