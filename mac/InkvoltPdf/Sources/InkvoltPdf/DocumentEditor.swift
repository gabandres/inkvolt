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
    /// The author written into new comments: the Mac user's full name.
    let author: String = {
        let full = NSFullUserName()
        return full.isEmpty ? NSUserName() : full
    }()
    /// Called after the comments and links were read again.
    var onChanged: (() -> Void)?
    /// The last edit's outcome (the self-test reads it).
    private(set) var lastOutcome: EditOutcome?
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
    func run(_ label: String, _ edit: @escaping @Sendable ([UInt8], String?) throws -> [UInt8]) async -> Bool {
        guard let session else { return false }
        let window = document.windowControllers.first?.window
        Report.progress("edit \(label) started on \(session.data.count) bytes")
        let result = await session.edit(EditRequest(label, edit), prompts: AppPrompts())
        Report.progress("edit \(label): \(result.outcome)")
        lastOutcome = result.outcome
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

    @discardableResult
    func addNote(page: Int, at p: PointD, text: String, color: AnnotColor?) async -> Bool {
        let author = author
        return await run("Add Note") { data, pw in
            try Annotations.addNote(data, pw, page, p.x, p.y, text, author: author, color: color)
        }
    }

    /// A text box: `box` as given, or (typewriter) a line at `at` sized to the text.
    @discardableResult
    func addFreeText(page: Int, box: RectD, text: String, style: AnnotStyle) async -> Bool {
        let author = author
        return await run("Add Text Box") { data, pw in
            try Annotations.addFreeText(data, pw, page, box, text, style, author: author)
        }
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
        if let c = comment(id) {
            if let g = c.geometry {
                let moved = DrawingGeometry.withFrame(c.subtype, g, frame)
                return await setGeometry(id, moved, label: label)
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
        case "FreeText": return c.isInkvoltPdfStamp ? "Fill & Sign text" : "Text box"
        case "Ink": return c.style?.highlighter == true ? "Highlighter drawing" : "Drawing"
        case "Square": return "Rectangle"
        case "Circle": return "Ellipse"
        case "Line": return c.style.map { $0.endEnding != .none || $0.startEnding != .none } == true ? "Arrow" : "Line"
        case "Polygon": return "Polygon"
        case "PolyLine": return "Polyline"
        case "Stamp": return c.subject == "Image" ? "Image" : "Stamp"
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
        case "Stamp": c.subject == "Image" ? "photo" : "seal"
        default: "text.bubble"
        }
    }

    /// One line for VoiceOver: kind, page, author, text.
    static func spoken(_ c: AnnotationInfo) -> String {
        var s = "\(kindName(c)), page \(c.pageIndex + 1)"
        if let a = c.author, !a.isEmpty { s += ", by \(a)" }
        let text = c.contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { s += ": \(text.prefix(200))" }
        return s
    }

    /// Kinds whose frame can be moved and resized.
    static func movable(_ c: AnnotationInfo) -> Bool { c.geometry != nil || c.subtype == "Stamp" }
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
