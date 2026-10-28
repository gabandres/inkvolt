import AppKit
import PdfCore

/// The inspector popover for the selected comment or link: what it is and who made it; for drawings, its color (eight
/// swatches, or any through the color panel), line width, opacity and text size; a comment's text, its replies and a
/// reply field; where a link leads; Delete. Each change is one undo step; the popover follows the comment through edits.
@MainActor
final class InspectorController: NSViewController, NSTextViewDelegate {
    let id: String
    private let editor: DocumentEditor
    private let pageCount: Int
    private let header = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private var textView: NSTextView?
    private var replyField: NSTextField?
    private var urlField: NSTextField?
    private var pageField: NSTextField?
    private(set) var widthSlider: NSSlider?
    private(set) var opacitySlider: NSSlider?
    private(set) var sizeStepper: NSStepper?
    /// Called when the comment is gone (deleted, or undone away).
    var onGone: (() -> Void)?

    init(id: String, editor: DocumentEditor, pageCount: Int) {
        self.id = id
        self.editor = editor
        self.pageCount = pageCount
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.setAccessibilityLabel("Inspector")
        view = stack
        build()
    }

    /// Builds the controls for the comment as it is now.
    func build() {
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        textView = nil
        replyField = nil
        widthSlider = nil
        opacitySlider = nil
        sizeStepper = nil
        header.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        stack.addArrangedSubview(header)
        if let c = editor.comment(id) {
            buildComment(c)
        } else if let l = editor.link(id) {
            buildLink(l)
        } else {
            header.stringValue = "This comment is no longer in the document."
            return
        }
        let delete = NSButton(title: "Delete", target: self, action: #selector(deleteClicked))
        delete.bezelStyle = .rounded
        delete.setAccessibilityLabel("Delete this comment")
        stack.addArrangedSubview(delete)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    private func buildComment(_ c: AnnotationInfo) {
        var title = DocumentEditor.kindName(c)
        if let a = c.author, !a.isEmpty { title += " by \(a)" }
        header.stringValue = title
        if let m = c.modified {
            let date = NSTextField(labelWithString: m.formatted(date: .abbreviated, time: .shortened) + " · page \(c.pageIndex + 1)")
            date.textColor = .secondaryLabelColor
            date.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            stack.addArrangedSubview(date)
        }
        if let style = c.style, c.geometry != nil {
            buildStyle(c, style)
        } else if DocumentEditor.recolorable(c) {
            buildColors()
        }
        if c.subtype != "Stamp" && !c.isInkvoltPdfStamp {
            let label = NSTextField(labelWithString: c.subtype == "FreeText" ? "Text" : "Comment")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            stack.addArrangedSubview(label)
            let scroll = NSTextView.scrollableTextView()
            scroll.borderType = .bezelBorder
            let tv = scroll.documentView as! NSTextView
            tv.string = c.contents
            tv.font = .systemFont(ofSize: NSFont.systemFontSize)
            tv.isRichText = false
            tv.allowsUndo = true
            tv.setAccessibilityLabel(c.subtype == "FreeText" ? "Text" : "Comment text")
            textView = tv
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.widthAnchor.constraint(equalToConstant: 260).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 70).isActive = true
            stack.addArrangedSubview(scroll)
            let save = NSButton(title: "Save Text", target: self, action: #selector(saveText))
            save.bezelStyle = .rounded
            stack.addArrangedSubview(save)
        }
        // Replies, and a field for another.
        let replies = editor.replies(to: c.id)
        if !replies.isEmpty {
            let label = NSTextField(labelWithString: replies.count == 1 ? "1 reply" : "\(replies.count) replies")
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            stack.addArrangedSubview(label)
            for r in replies.prefix(6) {
                let line = NSTextField(wrappingLabelWithString: "\(r.author ?? "Someone"): \(r.contents)")
                line.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
                line.preferredMaxLayoutWidth = 260
                stack.addArrangedSubview(line)
            }
        }
        let field = NSTextField(string: "")
        field.placeholderString = "Reply"
        field.setAccessibilityLabel("Reply")
        field.target = self
        field.action = #selector(replyClicked)
        field.widthAnchor.constraint(equalToConstant: 200).isActive = true
        replyField = field
        let send = NSButton(title: "Reply", target: self, action: #selector(replyClicked))
        send.bezelStyle = .rounded
        stack.addArrangedSubview(NSStackView(views: [field, send]))
    }

    private func buildStyle(_ c: AnnotationInfo, _ style: AnnotStyle) {
        buildColors()
        buildLooks(c, style)
    }

    /// The color swatches (and Other Color…).
    private func buildColors() {
        let colors = NSStackView()
        colors.spacing = 4
        colors.setAccessibilityLabel("Color")
        for (i, entry) in Palette.colors.enumerated() {
            let b = NSButton(image: Palette.swatch(entry.color, size: 18), target: self, action: #selector(swatchClicked(_:)))
            b.isBordered = false
            b.tag = i
            b.setAccessibilityLabel(entry.name)
            b.toolTip = entry.name
            colors.addArrangedSubview(b)
        }
        let other = NSButton(image: NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "Other color")!,
                             target: self, action: #selector(otherColor))
        other.isBordered = false
        other.toolTip = "Other Color…"
        colors.addArrangedSubview(other)
        stack.addArrangedSubview(row("Color", colors))
    }

    private func buildLooks(_ c: AnnotationInfo, _ style: AnnotStyle) {
        let isText = c.subtype == "FreeText"
        if !(isText && style.color == nil) {
            let width = NSSlider(value: style.width, minValue: 0.5, maxValue: 20, target: self, action: #selector(widthChanged(_:)))
            width.isContinuous = false
            width.setAccessibilityLabel(isText ? "Border width" : "Line width")
            width.widthAnchor.constraint(equalToConstant: 160).isActive = true
            widthSlider = width
            stack.addArrangedSubview(row(isText ? "Border" : "Width", width))
        }
        let opacity = NSSlider(value: style.opacity, minValue: 0.1, maxValue: 1, target: self, action: #selector(opacityChanged(_:)))
        opacity.isContinuous = false
        opacity.setAccessibilityLabel("Opacity")
        opacity.widthAnchor.constraint(equalToConstant: 160).isActive = true
        opacitySlider = opacity
        stack.addArrangedSubview(row("Opacity", opacity))
        if isText {
            let stepper = NSStepper()
            stepper.minValue = 6
            stepper.maxValue = 72
            stepper.increment = 1
            stepper.doubleValue = style.fontSize
            stepper.target = self
            stepper.action = #selector(sizeChanged(_:))
            stepper.setAccessibilityLabel("Text size")
            sizeStepper = stepper
            let value = NSTextField(labelWithString: "\(Int(style.fontSize)) pt")
            stack.addArrangedSubview(row("Text size", NSStackView(views: [value, stepper])))
        }
    }

    private func buildLink(_ l: LinkInfo) {
        header.stringValue = "Link to \(l.describe())"
        let url = NSTextField(string: l.uri ?? "")
        url.placeholderString = "Web or email address"
        url.setAccessibilityLabel("Web or email address")
        url.widthAnchor.constraint(equalToConstant: 220).isActive = true
        urlField = url
        stack.addArrangedSubview(row("Address", url))
        let page = NSTextField(string: l.targetPage >= 0 ? "\(l.targetPage + 1)" : "")
        page.placeholderString = "1–\(pageCount)"
        page.setAccessibilityLabel("Page number")
        page.widthAnchor.constraint(equalToConstant: 60).isActive = true
        pageField = page
        stack.addArrangedSubview(row("or page", page))
        let apply = NSButton(title: "Change Link", target: self, action: #selector(applyLink))
        apply.bezelStyle = .rounded
        stack.addArrangedSubview(apply)
    }

    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true
        let r = NSStackView(views: [label, control])
        r.spacing = 8
        return r
    }

    /// Rebuilds after an edit (the comment's new look), or says it's gone.
    func refresh() {
        guard isViewLoaded else { return }
        if editor.comment(id) == nil && editor.link(id) == nil {
            onGone?()
            return
        }
        build()
    }

    // MARK: Changes (the functions the controls call; the self-test calls them too)

    @discardableResult
    func apply(color: AnnotColor) async -> Bool {
        if let c = editor.comment(id), DocumentEditor.recolorable(c) { return await editor.setColor(id, color) }
        guard let c = editor.comment(id), var style = c.style else { return false }
        if c.subtype == "FreeText" && style.color == nil { style.textColor = color } else { style.color = color }
        return await editor.setStyle(id, style, label: "Change Color")
    }

    @discardableResult
    func apply(width: Double) async -> Bool {
        guard var style = editor.comment(id)?.style else { return false }
        style.width = width
        return await editor.setStyle(id, style, label: "Change Width")
    }

    @discardableResult
    func apply(opacity: Double) async -> Bool {
        guard var style = editor.comment(id)?.style else { return false }
        style.opacity = opacity
        return await editor.setStyle(id, style, label: "Change Opacity")
    }

    @discardableResult
    func apply(fontSize: Double) async -> Bool {
        guard var style = editor.comment(id)?.style else { return false }
        style.fontSize = fontSize
        return await editor.setStyle(id, style, label: "Change Text Size")
    }

    @discardableResult
    func apply(text: String) async -> Bool { await editor.setText(id, text) }
    @discardableResult
    func reply(_ text: String) async -> Bool { await editor.reply(to: id, text) }

    @objc private func swatchClicked(_ sender: NSButton) {
        let color = Palette.colors[sender.tag].color
        Task { await apply(color: color) }
    }

    @objc private func otherColor() {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(panelColor(_:)))
        panel.isContinuous = false
        panel.orderFront(nil)
    }

    @objc private func panelColor(_ sender: NSColorPanel) {
        let color = Palette.annot(sender.color)
        Task { await apply(color: color) }
    }

    @objc private func widthChanged(_ sender: NSSlider) {
        let w = (sender.doubleValue * 2).rounded() / 2
        Task { await apply(width: w) }
    }

    @objc private func opacityChanged(_ sender: NSSlider) {
        let o = (sender.doubleValue * 20).rounded() / 20
        Task { await apply(opacity: o) }
    }

    @objc private func sizeChanged(_ sender: NSStepper) {
        let size = sender.doubleValue
        Task { await apply(fontSize: size) }
    }

    @objc private func saveText() {
        guard let text = textView?.string else { return }
        Task { await apply(text: text) }
    }

    @objc private func replyClicked() {
        guard let text = replyField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        replyField?.stringValue = ""
        Task { await reply(text) }
    }

    @objc private func applyLink() {
        guard let l = editor.link(id) else { return }
        let typed = urlField?.stringValue.trimmingCharacters(in: .whitespaces) ?? ""
        var uri: String?
        var target = -1
        if !typed.isEmpty {
            guard let normalized = Links.normalize(typed) else {
                NSSound.beep()
                return
            }
            uri = normalized
        } else if let n = Int(pageField?.stringValue ?? ""), n >= 1, n <= pageCount {
            target = n - 1
        } else {
            NSSound.beep()
            return
        }
        let id = id
        Task { await editor.addLink(page: l.pageIndex, rect: l.rect, uri: uri, target: target, replacing: id) }
    }

    @objc private func deleteClicked() {
        let id = id
        Task { await editor.delete(id) }
    }
}

/// A small popover asking for text (a note, a text box) or where a link leads.
@MainActor
final class AskController: NSViewController {
    private let field: NSTextField
    private let pageField = NSTextField(string: "")
    private let kind: Kind
    private let pageCount: Int
    var done: ((String?) -> Void)?
    var doneLink: ((String?, Int) -> Void)?
    weak var popover: NSPopover?
    private var answered = false

    enum Kind { case text(String), link }

    init(_ kind: Kind, initial: String, pageCount: Int) {
        self.kind = kind
        self.pageCount = pageCount
        field = NSTextField(string: initial)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let title: String
        switch kind {
        case .text(let t):
            title = t
            field.placeholderString = t == "Note" ? "Note text" : "Text"
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
        case .link:
            title = "Link to"
            field.placeholderString = "Web or email address"
            pageField.placeholderString = "or page 1–\(pageCount)"
            pageField.setAccessibilityLabel("Page number")
        }
        field.setAccessibilityLabel(title)
        field.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let ok = NSButton(title: "OK", target: self, action: #selector(okClicked))
        ok.keyEquivalent = "\r"
        ok.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancel, ok])
        var views: [NSView] = [label, field]
        if case .link = kind { views.append(pageField) }
        views.append(buttons)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        view = stack
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    @objc private func okClicked() {
        switch kind {
        case .text:
            finish(field.stringValue, -1)
        case .link:
            let typed = field.stringValue.trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty {
                guard let uri = Links.normalize(typed) else {
                    NSSound.beep()
                    return
                }
                finish(uri, -1)
            } else if let n = Int(pageField.stringValue), n >= 1, n <= pageCount {
                finish(nil, n - 1)
            } else {
                NSSound.beep()
            }
        }
    }

    @objc private func cancelClicked() { cancel() }

    /// Closing the popover any other way cancels.
    func cancel() {
        guard !answered else { return }
        answered = true
        done?(nil)
        popover?.close()
    }

    private func finish(_ text: String?, _ page: Int) {
        answered = true
        if let doneLink {
            doneLink(text, page)
        } else {
            done?(text)
        }
        popover?.close()
    }
}
