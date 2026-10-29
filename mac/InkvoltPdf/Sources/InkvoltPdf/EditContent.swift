import AppKit
import PdfCore
import UniformTypeIdentifiers

/// Edit Text & Images (the Windows app's PageViewer.EditContent and DocumentTab.EditContent), over D5a's
/// `ContentEditor`: with the tool on, the page's own text runs and pictures are outlined; a click on text asks for its
/// new wording (kept only when the run's font has every character), a picture is selected with a click, dragged to move
/// it, Delete removes it and Replace Picture… swaps it. Each change is one undo step. Not yet: resizing a picture,
/// moving it with the arrow keys, Tab through the runs.
@MainActor
final class ContentEditing: NSObject {
    private weak var controller: DocumentWindowController?
    /// Each page's runs and pictures, read off the main thread for the current bytes.
    private var content: [Int: PageContent] = [:]
    private var loading: [Int: Task<PageContent, Never>] = [:]
    private(set) var selectedImage: PageImage?
    private(set) var pendingEdit: Task<Void, Never>?

    init(controller: DocumentWindowController) {
        self.controller = controller
        super.init()
    }

    private var pages: PagesView? { controller?.pages }
    private var editor: DocumentEditor? { controller?.editor }

    /// The content changed: everything is read again (a selected picture is found again by its place).
    func invalidate(keeping box: RectD? = nil) {
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
        for run in c.runs {
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
    func run(page: Int, _ p: PointD) -> TextRun? { content[page]?.runAt(p.x, p.y, slop: 2) }

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
