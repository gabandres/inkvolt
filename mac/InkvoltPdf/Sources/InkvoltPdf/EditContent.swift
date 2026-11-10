import AppKit
import PdfCore
import PrintCore
import UniformTypeIdentifiers

/// Edit Text & Images (the Windows app's PageViewer.EditContent and DocumentTab.EditContent), over `ContentEditor`: with
/// the tool on, the page's own text runs and pictures are outlined, and the paragraphs that can be rewritten as one; a
/// click on such a paragraph's text (or between its lines) opens the paragraph editor (`ParagraphEditorController`,
/// roadmap 2.1: the text rewraps in its box, looks for a selection, a warning before it runs into what follows), a click
/// on other text asks for its new wording (characters its font lacks drawn from the closest font on this Mac, and said),
/// a picture is selected with a click, dragged to move it, its handles resize it (Shift keeps its proportions), the arrow
/// keys nudge it (Shift: 10 pt; written once the keys rest for 0.45 s, as Windows), Delete removes it and Replace
/// Picture… swaps it. Each change is one undo step. Not yet: Tab through the runs.
@MainActor
final class ContentEditing: NSObject, NSPopoverDelegate {
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
    /// The paragraph editor shown, and its popover.
    private(set) var paragraphEditor: ParagraphEditorController?
    private var paragraphPopover: NSPopover?
    /// For the self-test: the text and looks a paragraph's editor gets, applied at once (nil: the editor shows).
    var testParagraph: (text: String, spans: [TextSpan]?)?
    /// For the self-test: the answer to "the text runs into what follows" (nil: the alert shows).
    var testOverlapAnswer: Bool?

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
        // The paragraphs that are rewritten as one: their box, faintly.
        for p in c.paragraphs where p.blocked == nil && (p.lines.count > 1 || p.runs.count > 1) {
            let path = NSBezierPath(rect: pages.viewRect(p.box, r).insetBy(dx: -3 * px, dy: -3 * px))
            path.lineWidth = px
            NSColor.systemBlue.withAlphaComponent(0.25).setStroke()
            path.stroke()
        }
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
    /// The paragraph under a point between its lines (one that is edited as one), or nil.
    func paragraph(page: Int, _ p: PointD) -> TextParagraph? { content[page]?.paragraphAt(p.x, p.y, slop: 2) }

    /// The paragraph a run is edited as: its paragraph when that can be rewritten as one and is more than the run alone
    /// (several lines, or a line drawn in pieces); else nil, and the run is edited on its own.
    func editableParagraph(_ run: TextRun) -> TextParagraph? {
        guard let p = content[run.pageIndex]?.paragraphOf(run), p.blocked == nil, p.lines.count > 1 || p.runs.count > 1 else { return nil }
        return p
    }

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

    /// A click on text: its paragraph's editor when it is rewritten as one, else its new wording, asked for over it.
    func editRun(_ run: TextRun) {
        guard let pages, let controller, run.pageIndex < pages.pageRects.count else { return }
        if let p = editableParagraph(run) {
            editParagraph(p)
            return
        }
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

    /// Replaces a run's text when its font, or a font on this Mac, can draw every character (else says which are missing);
    /// characters drawn from another font are said.
    func replace(_ run: TextRun, _ text: String) {
        guard let editor, let controller else { return }
        let check = run.check(text)
        if !check.missing.isEmpty {
            let list = ParagraphEditorController.charList(check.missing)
            controller.notify(loc("Not changed: neither the font “{0}” nor any font on this Mac has {1}.", run.fontName, list))
            return
        }
        pendingEdit = Task {
            let ok = await editor.replaceText(run, text)
            if ok && !check.borrowed.isEmpty {
                controller.notify(ParagraphEditorController.borrowedNote(check.borrowed, run.fontName, check.standIns), canUndo: true)
            } else if ok && check.width - check.oldWidth > 0.5 {
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

    // MARK: Paragraphs

    /// Opens a paragraph's editor over it (the self-test's text and looks applied at once instead).
    func editParagraph(_ p: TextParagraph) {
        guard let pages, p.pageIndex < pages.pageRects.count else { return }
        if let test = testParagraph {
            replace(p, test.text, test.spans)
            return
        }
        closeParagraphEditor()
        let anchor = pages.viewRect(p.box, pages.pageRects[p.pageIndex])
        let editor = ParagraphEditorController(p, width: anchor.width + 40)
        editor.done = { [weak self] text, spans in
            self?.paragraphEditor = nil
            self?.replace(p, text, spans)
        }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentViewController = editor
        popover.delegate = self
        editor.popover = popover
        paragraphEditor = editor
        paragraphPopover = popover
        popover.show(relativeTo: anchor.insetBy(dx: -2, dy: -2), of: pages, preferredEdge: .maxY)
        NSAccessibility.post(element: pages, notification: .announcementRequested,
                             userInfo: [.announcement: loc("Editing the paragraph: type, then press Return. Shift-Return starts a new line, Esc cancels.")])
    }

    func closeParagraphEditor() {
        paragraphPopover?.close()
        paragraphPopover = nil
        paragraphEditor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === paragraphPopover else { return }
        paragraphPopover = nil
        paragraphEditor = nil
    }

    /// Rewrites a paragraph: refused with a notice when a character can't be drawn or a look can't be written; asked first
    /// when it would run into what follows; characters drawn from fonts on this Mac said after.
    func replace(_ p: TextParagraph, _ text: String, _ spans: [TextSpan]?) {
        guard let editor, let controller else { return }
        let check = p.check(text, spans: spans)
        if let problem = check.lookProblem {
            controller.notify(loc("Not changed: {0}.", problem))
            return
        }
        if !check.missing.isEmpty {
            controller.notify(loc("Not changed: neither the font “{0}” nor any font on this Mac has {1}.", p.lead.fontName,
                                  ParagraphEditorController.charList(check.missing)))
            return
        }
        pendingEdit = Task {
            var allow = false
            if check.overlaps != nil {
                guard await self.confirmOverlap(check.lineCount, was: p.lines.count) else {
                    controller.notify(loc("Not changed: shorten the text to keep it in its place."))
                    self.pendingEdit = nil
                    return
                }
                allow = true
            }
            let ok = await editor.replaceParagraph(p, text, spans: spans, allowOverlap: allow)
            if ok && !check.borrowed.isEmpty {
                controller.notify(ParagraphEditorController.borrowedNote(check.borrowed, p.lead.fontName, check.standIns), canUndo: true)
            }
            self.pendingEdit = nil
        }
    }

    /// Asks before new text runs into what follows below it.
    private func confirmOverlap(_ lines: Int, was: Int) async -> Bool {
        if let answer = testOverlapAnswer { return answer }
        guard let window = pages?.window else { return false }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = loc("The text runs into what follows")
        alert.informativeText = loc("The new text takes {0} lines (it had {1}), so its last lines would run into the text or picture below it. Change it anyway? Undo takes it back.",
                                    CoreLanguage.number(lines), CoreLanguage.number(was))
        alert.addButton(withTitle: loc("Change Anyway"))
        alert.addButton(withTitle: loc("Cancel"))
        return await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            alert.beginSheetModal(for: window) { response in done.resume(returning: response == .alertFirstButtonReturn) }
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
