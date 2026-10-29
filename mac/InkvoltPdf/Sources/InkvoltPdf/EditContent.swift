import AppKit
import PdfCore
import UniformTypeIdentifiers

/// Edit Text & Images (the Windows app's PageViewer.EditContent and DocumentTab.EditContent), over D5a's
/// `ContentEditor`: with the tool on, the page's own paragraphs, text runs and pictures are outlined; a click on text
/// (or between the lines of a paragraph) opens its paragraph in the paragraph editor (`ParagraphEditor`: rewrapped in its
/// box in its own font, characters it lacks from the closest font on this Mac, looks for a selection) when the paragraph
/// can be edited as one and has more than one line or run, else asks for the run's new wording (kept only when the run's
/// font has every character); a picture is selected with a click, dragged to move it, Delete removes it and Replace
/// Picture… swaps it. Each change is one undo step. Not yet: resizing a picture, moving it with the arrow keys, Tab
/// through the runs.
@MainActor
final class ContentEditing: NSObject, NSPopoverDelegate {
    private weak var controller: DocumentWindowController?
    /// Each page's runs and pictures, read off the main thread for the current bytes.
    private var content: [Int: PageContent] = [:]
    private var loading: [Int: Task<PageContent, Never>] = [:]
    private(set) var selectedImage: PageImage?
    private(set) var pendingEdit: Task<Void, Never>?
    /// The open paragraph editor, and the popover it is shown in.
    private(set) var paragraphEditor: ParagraphEditor?
    private var paragraphPopover: NSPopover?
    /// The self-test: a paragraph editor is made but not shown (the test drives it), and running into what follows is
    /// confirmed without asking.
    var testParagraphs = false
    /// The last overlap question's answer in the self-test (nil: not asked).
    private(set) var lastOverlapAsked: Bool?

    init(controller: DocumentWindowController) {
        self.controller = controller
        super.init()
    }

    private var pages: PagesView? { controller?.pages }
    private var editor: DocumentEditor? { controller?.editor }

    /// How many times the content changed (the self-test waits for a change to arrive before reading the page again).
    private(set) var generation = 0

    /// The content changed: everything is read again (a selected picture is found again by its place).
    func invalidate(keeping box: RectD? = nil) {
        generation += 1
        for t in loading.values { t.cancel() }
        loading = [:]
        content = [:]
        let keep = box ?? selectedImage?.box
        let page = selectedImage?.pageIndex
        selectedImage = nil
        if let keep, let page {
            Task { [weak self] in
                guard let self else { return }
                let c = await self.ensure(page)
                self.selectedImage = c.images.first { abs($0.box.x - keep.x) < 1 && abs($0.box.y - keep.y) < 1 }
                self.pages?.needsDisplay = true
            }
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
        // Paragraphs edited as one: a solid frame around the whole paragraph (the open one bolder).
        var framed = Set<Int>()
        for run in c.runs where run.blocked == nil {
            guard let p = Self.editableParagraph(c, run), framed.insert(p.runs[0].id).inserted else { continue }
            let open = paragraphEditor.map { $0.paragraph.pageIndex == page && $0.paragraph.runs[0].id == p.runs[0].id } ?? false
            let path = NSBezierPath(rect: pages.viewRect(p.box.inflate(2), r))
            path.lineWidth = open ? 2 * px : px
            (open ? NSColor.controlAccentColor : NSColor.systemBlue.withAlphaComponent(0.7)).setStroke()
            path.stroke()
        }
        for run in c.runs {
            if run.blocked == nil, let p = Self.editableParagraph(c, run), framed.contains(p.runs[0].id) { continue }
            let path = NSBezierPath(rect: pages.viewRect(run.box, r).insetBy(dx: -px, dy: -px))
            path.lineWidth = px
            path.setLineDash([3 * px, 2 * px], count: 2, phase: 0)
            (run.blocked == nil ? NSColor.systemBlue.withAlphaComponent(0.7) : NSColor.systemGray.withAlphaComponent(0.6)).setStroke()
            path.stroke()
        }
        for image in c.images {
            let selected = isSelected(image)
            let path = NSBezierPath(rect: pages.viewRect(image.box, r))
            path.lineWidth = selected ? 2 * px : px
            if !selected { path.setLineDash([5 * px, 3 * px], count: 2, phase: 0) }
            (selected ? NSColor.controlAccentColor : image.blocked == nil ? NSColor.systemOrange : NSColor.systemGray).setStroke()
            path.stroke()
        }
    }

    // MARK: Pressing

    func image(page: Int, _ p: PointD) -> PageImage? { content[page]?.imageAt(p.x, p.y) }
    /// The text under a point: the run there, else (between a paragraph's lines) the paragraph's first run.
    func run(page: Int, _ p: PointD) -> TextRun? {
        content[page]?.runAt(p.x, p.y, slop: 2) ?? content[page]?.paragraphAt(p.x, p.y)?.runs.first
    }

    /// The paragraph a click on `run` edits as one: it can be, and it has more than one line or run (else the run alone).
    static func editableParagraph(_ c: PageContent, _ run: TextRun) -> TextParagraph? {
        guard let p = c.paragraphOf(run), p.blocked == nil, p.lines.count > 1 || p.runs.count > 1 else { return nil }
        return p
    }

    /// A click on text: its paragraph in the paragraph editor, or the run alone.
    func editText(_ run: TextRun) {
        if let c = content[run.pageIndex], run.blocked == nil, let p = Self.editableParagraph(c, run) {
            openParagraph(p)
        } else {
            editRun(run)
        }
    }

    /// Opens the paragraph editor over a paragraph (in a popover beside it).
    func openParagraph(_ p: TextParagraph) {
        guard let pages, p.pageIndex < pages.pageRects.count else { return }
        paragraphPopover?.close()
        let zoom = Double(pages.enclosingScrollView?.magnification ?? 1)
        let editor = ParagraphEditor(p, scale: min(max(zoom, 1), 2))
        editor.done = { [weak self] text, spans in self?.commitParagraph(p, text, spans) }
        paragraphEditor = editor
        pages.needsDisplay = true
        if testParagraphs {
            _ = editor.view
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = editor
        popover.delegate = self
        editor.popover = popover
        paragraphPopover = popover
        let rect = pages.viewRect(p.box, pages.pageRects[p.pageIndex])
        popover.show(relativeTo: rect.insetBy(dx: -4, dy: -4), of: pages, preferredEdge: .maxY)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let popover = notification.object as? NSPopover, popover === paragraphPopover else { return }
        paragraphPopover = nil
        (popover.contentViewController as? ParagraphEditor)?.closedElsewhere()
        paragraphEditor = nil
        pages?.needsDisplay = true
    }

    /// The paragraph editor's text applied: refused with a note when a character or look can't be written, asked first
    /// when it would run into what follows below, then written as one undo step.
    func commitParagraph(_ p: TextParagraph, _ text: String, _ spans: [TextSpan]) {
        guard let editor, let controller else { return }
        if paragraphPopover == nil {
            paragraphEditor = nil
            pages?.needsDisplay = true
        }
        let check = p.check(text, spans)
        if let lp = check.lookProblem {
            controller.notify("Not changed: \(lp).")
            return
        }
        if !check.missing.isEmpty {
            let list = check.missing.prefix(8).map { $0 == " " ? "space" : "“\($0)”" }.joined(separator: ", ")
            controller.notify("Not changed: neither the font “\(p.lead.fontName)” nor any font on this Mac has \(list).")
            return
        }
        var allow = false
        if check.overlaps != nil {
            if testParagraphs {
                lastOverlapAsked = true
            } else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "The text runs into what follows"
                alert.informativeText = "The new text takes \(check.lineCount) lines (it had \(p.lines.count)), so its last lines would run into the "
                    + "text or picture below it. Change it anyway? Undo takes it back."
                alert.addButton(withTitle: "Change Anyway")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() != .alertFirstButtonReturn { return }
            }
            allow = true
        }
        pendingEdit = Task {
            await editor.replaceParagraph(p, text, allowOverlap: allow, spans: spans)
            self.pendingEdit = nil
        }
    }

    /// Whether `image` (nil: no) is the selected picture.
    func isSelected(_ image: PageImage?) -> Bool {
        guard let image, let s = selectedImage else { return false }
        return s.pageIndex == image.pageIndex && s.id == image.id
    }

    func select(_ image: PageImage?) {
        selectedImage = image
        pages?.needsDisplay = true
        if let image, let pages {
            let what = image.blocked.map { "Picture, can't be changed: it is \($0)" } ?? "Picture selected: drag to move it, Delete removes it"
            NSAccessibility.post(element: pages, notification: .announcementRequested, userInfo: [.announcement: what])
        }
    }

    /// A click on text: its new wording, asked for over it.
    func editRun(_ run: TextRun) {
        guard let pages, let controller, run.pageIndex < pages.pageRects.count else { return }
        if let why = run.blocked {
            controller.notify("This text can't be edited: it is \(why).")
            return
        }
        let anchor = pages.viewRect(run.box, pages.pageRects[run.pageIndex])
        controller.askText("Edit Text", initial: run.text, at: anchor) { [weak self] text in
            guard let self, let text, text != run.text else { return }
            self.replace(run, text)
        }
    }

    /// Replaces a run's text when its font can draw every character (else says which are missing).
    func replace(_ run: TextRun, _ text: String) {
        guard let editor, let controller else { return }
        let check = run.check(text)
        if !check.missing.isEmpty {
            let list = check.missing.prefix(8).map { $0 == " " ? "space" : "“\($0)”" }.joined(separator: ", ")
            controller.notify("Not changed: the font “\(run.fontName)” has no \(list) in this PDF.")
            return
        }
        pendingEdit = Task {
            let ok = await editor.replaceText(run, text)
            if ok && check.width - check.oldWidth > 0.5 {
                controller.notify("Text changed. It is \(Int((check.width - check.oldWidth).rounded())) pt wider than before and doesn't reflow, "
                                  + "so it may overlap what follows.", canUndo: true)
            }
            self.pendingEdit = nil
        }
    }

    /// The selected picture moved to `box`.
    func move(_ image: PageImage, to box: RectD) {
        guard let editor else { return }
        if let why = image.blocked {
            controller?.notify("This picture can't be moved: it is \(why).")
            return
        }
        pendingEdit = Task {
            if await editor.moveImage(image, to: box) { self.invalidate(keeping: box) }
            self.pendingEdit = nil
        }
    }

    @objc func deleteSelected(_ sender: Any?) {
        guard let editor, let image = selectedImage else { return NSSound.beep() }
        if let why = image.blocked {
            controller?.notify("This picture can't be deleted: it is \(why).")
            return
        }
        select(nil)
        pendingEdit = Task {
            await editor.deleteImage(image)
            self.pendingEdit = nil
        }
    }

    @objc func replaceSelected(_ sender: Any?) {
        guard let image = selectedImage, let window = pages?.window else { return NSSound.beep() }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.message = "Choose the picture that takes its place."
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
            if await editor.replaceImage(image, file: file, name: name) { self.invalidate(keeping: image.box) }
            self.pendingEdit = nil
        }
    }

    func settle() async { await pendingEdit?.value }
}
