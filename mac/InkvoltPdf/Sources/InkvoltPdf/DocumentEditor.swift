import AppKit
import PdfCore

/// The document's comments and links as last read, and every edit the tools, the inspector and the comments list make:
/// each one goes through the session's edit transaction (one undo step, a protected file's protection kept, a signed
/// file's edit appended), so the UI and the self-test call the same functions.
@MainActor
final class DocumentEditor {
    let document: PdfDocument
    /// Comments (markup annotations, drawings, stamps, pictures) and links of the current bytes.
    private(set) var comments: [AnnotationInfo] = []
    private(set) var links: [LinkInfo] = []
    /// Fill & Sign's text, marks, signatures and pictures (their ids are those of comments above too).
    private(set) var stamps: [TextStamp] = []
    /// The author written into new comments: Settings' author name, else the Mac user's full name.
    var author: String { AppSettings.author }
    /// Called after the comments and links were read again.
    var onChanged: (() -> Void)?
    /// The last edit's outcome, and how many edits have ended (the self-test reads them).
    private(set) var lastOutcome: EditOutcome?
    private(set) var finishedEdits = 0
    /// The engine the comments were read from (they are read once per content).
    private var readFrom: ObjectIdentifier?

    init(document: PdfDocument) {
        self.document = document
        reload()
    }

    var session: DocumentSession? { document.session }

    /// Reads the comments and links of the current bytes.
    func reload() {
        guard let session else { return }
        readFrom = ObjectIdentifier(session.engine)
        comments = ((try? Annotations.read(session.data, session.password)) ?? []).filter { !$0.hidden }
        links = (try? Links.read(session.data, session.password)) ?? []
        let texts = (try? TextStamps.read(session.data, session.password)) ?? []
        stamps = texts + ((try? SignatureStamps.read(session.data, session.password)) ?? [])
        onChanged?()
    }

    func comment(_ id: String?) -> AnnotationInfo? { id.flatMap { id in comments.first { $0.id == id } } }
    func link(_ id: String?) -> LinkInfo? { id.flatMap { id in links.first { $0.id == id } } }

    /// Top-level comments and the replies under each, in page order.
    func replies(to id: String) -> [AnnotationInfo] { comments.filter { $0.replyTo == id } }

    // MARK: The edit transaction

    /// Runs one edit as one undo step named `label`; false when nothing was committed (refused, declined, busy, failed:
    /// a failure is shown).
    @discardableResult
    func run(_ label: String, contentOnly: Bool = false, signaturesWarned: Bool = false,
             newPasswords: (password: String?, openPassword: String?)? = nil, _ edit: @escaping @Sendable ([UInt8], String?) throws -> [UInt8]) async -> Bool {
        guard let session else { return false }
        let window = document.windowControllers.first?.window
        Report.progress("edit \(label) started on \(session.data.count) bytes")
        var request = EditRequest(label, edit)
        request.contentOnly = contentOnly
        request.signaturesWarned = signaturesWarned
        request.newPasswords = newPasswords
        let result = await session.edit(request, prompts: AppPrompts())
        Report.progress("edit \(label): \(result.outcome)")
        lastOutcome = result.outcome
        finishedEdits += 1
        switch result.outcome {
        case .done:
            if readFrom != ObjectIdentifier(session.engine) { reload() } // normally read already, as the content changed
            if let window {
                NSAccessibility.post(element: window, notification: .announcementRequested,
                                     userInfo: [.announcement: "\(label) done", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
            return true
        case .failed:
            document.showError("“\(label)” couldn't be done.", result.error)
        case .busy:
            NSSound.beep()
        case .declined, .noChange:
            break
        }
        return false
    }

    // MARK: Adding

    @discardableResult
    func markText(_ kind: TextMarkupKind, page: Int, rects: [RectD], color: AnnotColor) async -> Bool {
        let author = author
        let label = kind == .highlight ? "Highlight" : kind == .underline ? "Underline" : "Strike Out"
        return await run(label) { data, pw in
            try Annotations.addTextMarkup(data, pw, page, kind, rects, color, note: nil, author: author)
        }
    }

    /// A text mark over text on several pages (a selection across pages): one comment per page, one undo step.
    @discardableResult
    func markText(_ kind: TextMarkupKind, spans: [(page: Int, rects: [RectD])], color: AnnotColor) async -> Bool {
        if spans.count == 1 { return await markText(kind, page: spans[0].page, rects: spans[0].rects, color: color) }
        let author = author
        let label = kind == .highlight ? "Highlight" : kind == .underline ? "Underline" : "Strike Out"
        let marks: [MarkSpan] = spans.map { MarkSpan(page: $0.page, rects: $0.rects) }
        return await run(label) { data, pw in
            var out = data
            for m in marks { out = try Annotations.addTextMarkup(out, pw, m.page, kind, m.rects, color, note: nil, author: author) }
            return out
        }
    }

    @discardableResult
    func addNote(page: Int, at p: PointD, text: String, color: AnnotColor?) async -> Bool {
        let author = author
        return await run("Add Note") { data, pw in
            try Annotations.addNote(data, pw, page, p.x, p.y, text, author: author, color: color)
        }
    }

    /// A text box: `box` as given, or (typewriter) a line at `at` sized to the text; with `callout` (its tip) a callout.
    @discardableResult
    func addFreeText(page: Int, box: RectD, text: String, style: AnnotStyle, callout: [PointD]? = nil) async -> Bool {
        let author = author
        return await run(callout == nil ? "Add Text Box" : "Add Callout") { data, pw in
            try Annotations.addFreeText(data, pw, page, box, text, style, author: author, callout: callout)
        }
    }

    /// A closed polygon or an open polyline through `vertices`.
    @discardableResult
    func addPolygon(page: Int, vertices: [PointD], closed: Bool, style: AnnotStyle) async -> Bool {
        let author = author
        return await run(closed ? "Polygon" : "Polyline") { data, pw in
            try Annotations.addPolygon(data, pw, page, vertices, closed: closed, style, author: author)
        }
    }

    /// A note's or a text mark's new color (drawings change color through `setStyle`).
    @discardableResult
    func setColor(_ id: String, _ color: AnnotColor) async -> Bool {
        await run("Change Color") { data, pw in try Annotations.setColor(data, pw, id, color) }
    }

    /// The box a typewriter line of `text` needs at `at` (its top-left), kept on the page.
    func typewriterBox(_ text: String, at p: PointD, style: AnnotStyle, pageWidth: Double) -> RectD {
        let font = NSFont(name: "Helvetica", size: CGFloat(style.fontSize)) ?? .systemFont(ofSize: CGFloat(style.fontSize))
        let longest = text.components(separatedBy: "\n").map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 40
        let available = max(pageWidth - p.x - 4, 40)
        let width = min(Double(longest) + style.fontSize + 8, available)
        let height = Annotations.freeTextHeight(text, width: width, style)
        return RectD(p.x, p.y, width, height)
    }

    @discardableResult
    func addInk(page: Int, strokes: [[PointD]], style: AnnotStyle) async -> Bool {
        let author = author
        return await run(style.highlighter ? "Highlighter" : "Pen") { data, pw in
            try Annotations.addInk(data, pw, page, strokes, style, author: author)
        }
    }

    @discardableResult
    func addShape(page: Int, kind: ShapeKind, box: RectD, style: AnnotStyle) async -> Bool {
        let author = author
        return await run(kind == .ellipse ? "Ellipse" : "Rectangle") { data, pw in
            try Annotations.addShape(data, pw, page, kind, box, style, author: author)
        }
    }

    @discardableResult
    func addLine(page: Int, from a: PointD, to b: PointD, style: AnnotStyle) async -> Bool {
        let author = author
        return await run(style.endEnding == .none ? "Line" : "Arrow") { data, pw in
            try Annotations.addLine(data, pw, page, a, b, style, author: author)
        }
    }

    /// A stamp of `design` centered on `center`, at its natural size (smaller when the page is narrow).
    @discardableResult
    func addStamp(page: Int, center: PointD, design: StampDesign, pageSize: (width: Double, height: Double)) async -> Bool {
        let natural = RubberStamps.naturalSize(design)
        let k = min(1, pageSize.width * 0.6 / max(natural.width, 1))
        let w = natural.width * k, h = natural.height * k
        let rect = RectD(min(max(center.x - w / 2, 0), max(pageSize.width - w, 0)), min(max(center.y - h / 2, 0), max(pageSize.height - h, 0)), w, h)
        let author = author
        return await run("Stamp") { data, pw in
            try RubberStamps.put(data, pw, page, rect, design, author: author)
        }
    }

    /// A picture centered on `center`, at most 200 pt across (and within the page).
    @discardableResult
    func addImage(page: Int, center: PointD, image: StampImage, pageSize: (width: Double, height: Double)) async -> Bool {
        let longest = Double(max(image.width, image.height))
        let k = min(200 / longest, pageSize.width * 0.8 / Double(image.width), pageSize.height * 0.8 / Double(image.height), 1)
        let w = Double(image.width) * k, h = Double(image.height) * k
        let rect = RectD(min(max(center.x - w / 2, 0), max(pageSize.width - w, 0)), min(max(center.y - h / 2, 0), max(pageSize.height - h, 0)), w, h)
        let author = author
        return await run("Add Image") { data, pw in
            try SignatureStamps.putImage(data, pw, page, rect, image, label: "Image", author: author)
        }
    }

    /// A link over `rect` to `uri` (already normalized) or, without one, to page `target`.
    @discardableResult
    func addLink(page: Int, rect: RectD, uri: String?, target: Int, replacing id: String? = nil) async -> Bool {
        await run(id == nil ? "Add Link" : "Edit Link") { data, pw in
            try Links.put(data, pw, page, rect, uri: uri, targetPage: target, replaceId: id)
        }
    }

    // MARK: Changing

    /// Moves a comment or link to `rect` (its frame, page space): drawings get their geometry mapped, stamps and pictures
    /// are redrawn there, links moved.
    @discardableResult
    func setFrame(_ id: String, page: Int, frame: RectD, label: String) async -> Bool {
        if let s = stamps.first(where: { $0.id == id }) {
            switch s.kind {
            case .signature, .image:
                return await run(label, contentOnly: true) { data, pw in try SignatureStamps.put(data, pw, page, frame, nil, replaceId: id) }
            case .text, .check, .cross:
                let kind = s.kind, text = s.text, size = s.fontSize
                return await run(label, contentOnly: true) { data, pw in
                    try TextStamps.put(data, pw, page, frame, kind, text, size, replaceId: id)
                }
            case .stamp:
                break
            }
        }
        if let c = comment(id) {
            if let g = c.geometry {
                let moved = DrawingGeometry.withFrame(c.subtype, g, frame)
                return await setGeometry(id, moved, label: label)
            }
            if Self.recolorable(c) {
                let dx = frame.x - c.rect.x, dy = frame.y - c.rect.y
                return await run(label) { data, pw in try Annotations.move(data, pw, id, dx: dx, dy: dy) }
            }
            if c.subtype == "Stamp" {
                return await run(label) { data, pw in try RubberStamps.move(data, pw, id, page, frame) }
            }
            return false
        }
        if link(id) != nil {
            return await run(label) { data, pw in try Links.move(data, pw, id, page, frame) }
        }
        return false
    }

    @discardableResult
    func setGeometry(_ id: String, _ geometry: AnnotGeometry, label: String) async -> Bool {
        await run(label) { data, pw in try Annotations.updateGeometry(data, pw, id, geometry) }
    }

    @discardableResult
    func setStyle(_ id: String, _ style: AnnotStyle, label: String = "Change Style") async -> Bool {
        await run(label) { data, pw in try Annotations.updateStyle(data, pw, id, style) }
    }

    @discardableResult
    func setText(_ id: String, _ text: String) async -> Bool {
        await run("Edit Comment") { data, pw in try Annotations.setContents(data, pw, id, text) }
    }

    @discardableResult
    func reply(to id: String, _ text: String) async -> Bool {
        let author = author
        return await run("Reply") { data, pw in try Annotations.addReply(data, pw, id, text, author: author) }
    }

    @discardableResult
    func delete(_ id: String) async -> Bool {
        if let s = stamps.first(where: { $0.id == id }), s.kind != .stamp {
            return await run(Self.removeLabel(s.kind), contentOnly: true) { data, pw in try TextStamps.remove(data, pw, id) }
        }
        if link(id) != nil {
            return await run("Delete Link") { data, pw in try Links.delete(data, pw, id) }
        }
        return await run("Delete Comment") { data, pw in try Annotations.delete(data, pw, id) }
    }

    // MARK: Describing

    /// What a comment is called in lists, VoiceOver and the inspector.
    static func kindName(_ c: AnnotationInfo) -> String {
        if c.replyTo != nil { return "Reply" }
        switch c.subtype {
        case "Highlight": return "Highlight"
        case "Underline": return "Underline"
        case "StrikeOut": return "Strike-out"
        case "Squiggly": return "Squiggly underline"
        case "Text": return "Note"
        case "FreeText": return c.isInkvoltPdfStamp ? "Fill & Sign text" : c.geometry?.callout.isEmpty == false ? "Callout" : "Text box"
        case "Ink": return c.style?.highlighter == true ? "Highlighter drawing" : "Drawing"
        case "Square": return "Rectangle"
        case "Circle": return "Ellipse"
        case "Line": return c.style.map { $0.endEnding != .none || $0.startEnding != .none } == true ? "Arrow" : "Line"
        case "Polygon": return "Polygon"
        case "PolyLine": return "Polyline"
        case "Stamp":
            if c.subject == "Image" { return "Image" }
            if isSignature(c) { return c.contents == "Initials" ? "Initials" : "Signature" }
            return "Stamp"
        default: return c.subtype
        }
    }

    static func symbol(_ c: AnnotationInfo) -> String {
        switch c.subtype {
        case "Highlight": "highlighter"
        case "Underline", "Squiggly": "underline"
        case "StrikeOut": "strikethrough"
        case "Text": c.replyTo != nil ? "arrowshape.turn.up.left" : "note.text"
        case "FreeText": "character.textbox"
        case "Ink": "scribble"
        case "Square": "rectangle"
        case "Circle": "circle"
        case "Line": "line.diagonal"
        case "Polygon", "PolyLine": "pentagon"
        case "Stamp": c.subject == "Image" ? "photo" : isSignature(c) ? "signature" : "seal"
        default: "text.bubble"
        }
    }

    /// A handwritten signature or initials placed by Fill & Sign (by its id).
    static func isSignature(_ c: AnnotationInfo) -> Bool {
        c.id.hasPrefix("InkvoltPdf-signature-") || c.id.hasPrefix("PdfDesk-signature-")
    }

    /// One line for VoiceOver: kind, page, author, text.
    static func spoken(_ c: AnnotationInfo) -> String {
        var s = "\(kindName(c)), page \(c.pageIndex + 1)"
        if let a = c.author, !a.isEmpty { s += ", by \(a)" }
        let text = c.contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { s += ": \(text.prefix(200))" }
        return s
    }

    /// Kinds that can be moved (drawings and stamps are resized too; notes and text marks only move).
    static func movable(_ c: AnnotationInfo) -> Bool { c.geometry != nil || c.subtype == "Stamp" || recolorable(c) }

    /// Notes and text marks: moved with `Annotations.move` and recolored with `Annotations.setColor`.
    static func recolorable(_ c: AnnotationInfo) -> Bool { c.subtype == "Text" || Tool.markupSubtypes.contains(c.subtype) }
}

/// One page's part of a text mark across pages.
struct MarkSpan: Sendable {
    var page: Int
    var rects: [RectD]
}

/// What an edit on a worker hands back besides the bytes (a form's script messages, a recognition's counts).
final class EditBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

// MARK: Forms, Fill & Sign, text recognition, the page's own text and pictures

extension DocumentEditor {
    /// Writes field values (one undo step: "Fill form field"), running the form's keystroke, validate, calculate and
    /// format scripts; what the scripts said comes back (nil when nothing was committed and nothing ran).
    func fillForm(_ values: [String: String], host: FormActionHost?) async -> (committed: Bool, result: FormFillResult?) {
        let label = values.count == 1 ? "Fill form field" : "Fill \(values.count) form fields"
        let box = EditBox<FormFillResult>()
        let host = host.map(SendableHost.init)
        let ok = await run(label, contentOnly: true) { data, pw in
            let r = try FormEditor.fill(data, pw, values, host: host?.host)
            box.value = r
            return r.data
        }
        return (ok, box.value)
    }

    /// Runs a widget's actions for `trigger` (off the main thread); the changes they made are committed as one step.
    func formAction(_ w: FormWidget, _ trigger: FormTrigger, host: FormActionHost) async -> FormActionResult? {
        guard let session else { return nil }
        let data = session.data, pw = session.password
        let h = SendableHost(host)
        let r: FormActionResult? = await Task.detached {
            try? FormEditor.runAction(data, pw, w.fieldName, w.pageIndex, w.annotIndex, trigger, h.host)
        }.value
        guard let r else { return nil }
        if let updated = r.data {
            await run(r.label, contentOnly: true) { d, _ in d == data ? updated : d }
        }
        return r
    }

    @discardableResult
    func resetForm() async -> Bool {
        await run("Reset form", contentOnly: true) { data, pw in try FormEditor.resetForm(data, pw) }
    }

    func importFormData(_ file: [UInt8], host: FormActionHost?) async -> (committed: Bool, result: FormFillResult?) {
        let box = EditBox<FormFillResult>()
        let host = host.map(SendableHost.init)
        let ok = await run("Import form data", contentOnly: true) { data, pw in
            let r = try FormEditor.importData(data, pw, file, host: host?.host)
            box.value = r
            return r.data
        }
        return (ok, box.value)
    }

    /// Fill & Sign text at `rect` (new, or replacing `id`); empty text with an id removes it.
    @discardableResult
    func putFillText(page: Int, rect: RectD, text: String, fontSize: Double, replacing id: String?) async -> Bool {
        if let id, text.isEmpty {
            return await run("Remove text", contentOnly: true) { data, pw in try TextStamps.remove(data, pw, id) }
        }
        return await run(id == nil ? "Add text" : "Edit text", contentOnly: true) { data, pw in
            try TextStamps.put(data, pw, page, rect, .text, text, fontSize, replaceId: id)
        }
    }

    @discardableResult
    func putMark(page: Int, rect: RectD, kind: StampKind) async -> Bool {
        await run(kind == .check ? "Add check mark" : "Add cross", contentOnly: true) { data, pw in
            try TextStamps.put(data, pw, page, rect, kind, "", rect.height)
        }
    }

    @discardableResult
    func removeStamp(_ id: String, kind: StampKind) async -> Bool {
        await run(Self.removeLabel(kind), contentOnly: true) { data, pw in try TextStamps.remove(data, pw, id) }
    }

    static func removeLabel(_ kind: StampKind) -> String {
        switch kind {
        case .check: "Remove check mark"
        case .cross: "Remove cross"
        case .signature: "Remove signature"
        case .image: "Remove image"
        default: "Remove text"
        }
    }

    /// A handwritten signature or initials (a picture, not a digital signature) in `rect`.
    @discardableResult
    func putSignature(page: Int, rect: RectD, image: StampImage, initials: Bool) async -> Bool {
        let label = initials ? "Initials" : "Signature"
        return await run(initials ? "Add initials" : "Add signature", contentOnly: true) { data, pw in
            try SignatureStamps.put(data, pw, page, rect, image, label: label)
        }
    }

    /// Fill & Sign text's box for `text` with its top-left at `p` (Helvetica's widths, as the stamp draws it).
    static func fillTextBox(_ text: String, at p: PointD, fontSize: Double) -> RectD {
        let font = NSFont(name: "Helvetica", size: CGFloat(fontSize)) ?? .systemFont(ofSize: CGFloat(fontSize))
        let lines = text.components(separatedBy: .newlines)
        var width = 0.0
        for line in lines {
            let w = ((line.isEmpty ? " " : line) as NSString).size(withAttributes: [.font: font]).width
            width = max(width, Double(w))
        }
        let height: Double = Double(lines.count) * fontSize * 1.2 + fontSize * 0.25
        return RectD(p.x, p.y, width + fontSize * 0.4, height)
    }

    /// Recognize Text: the pages recognized and given an invisible text layer (one undo step); the counts come back.
    /// Cancelling (`cancel`) commits nothing.
    func recognizeText(pages: [Int], recognizer: @escaping Recognizer, cancel: CancelToken,
                       progress: @escaping @Sendable (Int, Int) -> Void) async -> (outcome: EditOutcome?, report: RecognizeTextReport?) {
        let box = EditBox<RecognizeTextReport>()
        _ = await run("Recognize text") { data, pw in
            let (out, report) = try PageOcr.recognizeText(data, pw, pages: pages, recognizer, cancel: cancel, progress: progress)
            box.value = report
            return out
        }
        return (lastOutcome, box.value)
    }

    @discardableResult
    func replaceText(_ run: TextRun, _ text: String) async -> Bool {
        await self.run("Edit text") { data, pw in try ContentEditor.replaceText(data, pw, run, text) }
    }

    @discardableResult
    func moveImage(_ image: PageImage, to box: RectD) async -> Bool {
        await run("Move picture") { data, pw in try ContentEditor.moveImage(data, pw, image, box) }
    }

    @discardableResult
    func deleteImage(_ image: PageImage) async -> Bool {
        await run("Delete picture") { data, pw in try ContentEditor.deleteImage(data, pw, image) }
    }

    @discardableResult
    func replaceImage(_ image: PageImage, file: [UInt8], name: String) async -> Bool {
        await run("Replace picture") { data, pw in try ContentEditor.replaceImage(data, pw, image, file, name) }
    }
}

/// The app's form host, handed to an edit's worker (the host itself is thread-safe: it hops to the main thread).
struct SendableHost: @unchecked Sendable {
    let host: FormActionHost
    init(_ host: FormActionHost) { self.host = host }
}

/// The questions an edit asks, as sheets-free alerts on the main thread (the edit waits on its worker meanwhile). The
/// self-test declines them.
struct AppPrompts: EditPrompts {
    func askOwnerPassword(wrong: Bool) -> String? {
        ask {
            if Report.isRunning { return nil }
            let alert = NSAlert()
            alert.messageText = wrong ? "That isn't the permissions password." : "This change needs the document's permissions password."
            alert.informativeText = "The file was protected against changes. Type its permissions (owner) password to edit it."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: "Edit")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        }
    }

    func confirmSignatureRewrite(label: String, signatures: Int, reason: String) -> Bool {
        ask {
            if Report.isRunning { return false }
            let alert = NSAlert()
            alert.messageText = "“\(label)” would invalidate \(signatures == 1 ? "the signature" : "\(signatures) signatures")."
            alert.informativeText = "This change can't be added to the signed file without rewriting it, so its digital signatures would no longer verify."
            alert.addButton(withTitle: "Change Anyway")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    private func ask<T: Sendable>(_ f: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { f() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { f() } }
    }
}
