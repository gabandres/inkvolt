import AppKit
import PdfCore

/// A question box: Return sends, Shift-Return starts a new line, with a hint while it is empty.
@MainActor
private final class AiQuestionView: NSTextView {
    var hint = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.placeholderTextColor, .font: font ?? .systemFont(ofSize: NSFont.systemFontSize)]
        (hint as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height), withAttributes: attributes)
    }
}

/// An answer's text: selectable, with page citations as links, as tall as its text in the width it gets.
@MainActor
private final class AiAnswerText: NSTextView {
    private var measuredWidth: CGFloat = 0

    override var intrinsicContentSize: NSSize {
        guard let container = textContainer, let manager = layoutManager else { return super.intrinsicContentSize }
        manager.ensureLayout(for: container)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(manager.usedRect(for: container).height) + 2)
    }

    override func layout() {
        super.layout()
        if bounds.width != measuredWidth {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
    }
}

/// One answer (the Windows `AiAnswerCard`): an "AI-generated, may be wrong" note with the model's name, the text (simple
/// Markdown; "[p. N]" citations link to the pages, `AiAnswerMarkup`), and Copy. Redrawn a few times a second while
/// streaming, not per token.
@MainActor
final class AiAnswerCard: NSView, NSTextViewDelegate {
    private static let pageScheme = "inkvolt-page"

    private let body = AiAnswerText()
    let noteLabel = NSTextField(wrappingLabelWithString: "")
    let copyButton = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy the answer")!, target: nil, action: nil)
    private let label: NSTextField
    private let warn = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)!)
    private let model: String
    private let pageCount: Int
    private let goTo: (Int) -> Void
    private let scrolled: () -> Void
    private var raw = ""
    private var dirty = false
    private(set) var finished = false
    private var timer: Timer?

    init(model: String, pageCount: Int, goTo: @escaping (Int) -> Void, scrolled: @escaping () -> Void) {
        self.model = model
        self.pageCount = pageCount
        self.goTo = goTo
        self.scrolled = scrolled
        label = NSTextField(labelWithString: "\(AiAnswerMarkup.aiNote) · \(model)")
        super.init(frame: .zero)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        warn.contentTintColor = .systemOrange
        warn.setContentHuggingPriority(.required, for: .horizontal)
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.isBordered = false
        copyButton.toolTip = "Copy the answer"
        copyButton.target = self
        copyButton.action = #selector(copyClicked)
        copyButton.isEnabled = false
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let head = NSStackView(views: [warn, label, spacer, copyButton])
        head.spacing = 6

        body.isEditable = false
        body.isSelectable = true
        body.drawsBackground = false
        body.isAutomaticLinkDetectionEnabled = false
        body.textContainerInset = .zero
        body.textContainer?.lineFragmentPadding = 0
        body.textContainer?.widthTracksTextView = true
        body.isVerticallyResizable = true
        body.isHorizontallyResizable = false
        body.delegate = self
        body.font = .systemFont(ofSize: NSFont.systemFontSize)
        body.string = "…"
        body.setAccessibilityLabel("AI answer")
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.isHidden = true

        let stack = NSStackView(views: [head, body, noteLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        for v in [head, body, noteLabel] as [NSView] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.dirty else { return }
                self.dirty = false
                self.render()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    var text: String { AiText.trim(AiText.withoutThinking(raw).text) }

    /// What the card shows, for the self-test.
    var shownText: String { body.string }
    var note: String? { noteLabel.isHidden ? nil : noteLabel.stringValue }
    var isCopyEnabled: Bool { copyButton.isEnabled }

    /// The page each citation links to, in order.
    var links: [Int] {
        var pages: [Int] = []
        let whole = NSRange(location: 0, length: body.attributedString().length)
        body.attributedString().enumerateAttribute(.link, in: whole) { value, _, _ in
            if let url = value as? URL, url.scheme == Self.pageScheme, let page = Int(url.host ?? "") { pages.append(page) }
        }
        return pages
    }

    /// Adds streamed text.
    func append(_ piece: String) {
        if finished { return }
        raw += piece
        dirty = true
    }

    /// Shows a progress line in place of the text while nothing has arrived yet.
    func progress(_ line: String) {
        if raw.isEmpty && !finished { body.string = line }
    }

    /// Ends the card: the final text (nil keeps what streamed) and a note (cut off, stopped, an error).
    func finish(_ final: String?, note: String?, error: Bool = false) {
        finished = true
        timer?.invalidate()
        timer = nil
        if let final { raw = final }
        render()
        body.isHidden = raw.isEmpty && note != nil
        if error && text.isEmpty {
            label.stringValue = "No answer · \(model)"
            warn.image = NSImage(systemSymbolName: "exclamationmark.octagon", accessibilityDescription: nil)
            warn.contentTintColor = .systemRed
        }
        if let note {
            noteLabel.stringValue = note
            noteLabel.isHidden = false
            if error { noteLabel.textColor = .systemRed }
        }
        copyButton.isEnabled = !text.isEmpty
        setAccessibilityLabel("AI answer, may be wrong: " + (text.isEmpty ? (note ?? "") : text))
        scrolled()
    }

    @objc func copyClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(AiAnswerMarkup.copied(text), forType: .string)
        copyButton.toolTip = "Copied"
    }

    private func render() {
        let parts = AiText.withoutThinking(raw)
        let shown = AiText.trim(parts.text)
        if parts.thinking || shown.isEmpty {
            body.string = parts.thinking ? "Thinking…" : "…"
            return
        }
        let plain = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let out = NSMutableAttributedString()
        for run in AiAnswerMarkup.runs(shown, pageCount: pageCount) {
            var attributes: [NSAttributedString.Key: Any] = [.font: run.bold ? bold : plain, .foregroundColor: NSColor.labelColor]
            if let page = run.page, let url = URL(string: "\(Self.pageScheme)://\(page)") {
                attributes[.link] = url
                attributes[.toolTip] = "Go to page \(page + 1)"
            }
            out.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        body.textStorage?.setAttributedString(out)
        body.invalidateIntrinsicContentSize()
        scrolled()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == Self.pageScheme, let page = Int(url.host ?? "") else { return true } // an answer's text opens nothing else
        goTo(page)
        return true
    }

    /// As a click on the first citation does.
    func followFirstLink() { if let first = links.first { goTo(first) } }
}

/// The pane's background: solid, as Prepare Form's panel, not the inspector's see-through one.
private final class AiPaneView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

/// A flipped view for the conversation, so it grows downward.
private final class AiListView: NSStackView {
    override var isFlipped: Bool { true }
}

/// The AI assistant pane at the right of a document (the Windows `AiPane`): the conversation (questions, summaries,
/// explanations, each answer marked as AI-generated with Copy and page citations linked to the pages), and a box for
/// questions about the document with the pages they are about.
@MainActor
final class AiPane: NSViewController, NSTextViewDelegate {
    let whereBox = AiReachBox(fontSize: NSFont.smallSystemFontSize)
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let scopeField = NSTextField(string: "All")
    let summarizeButton = NSButton(title: "Summarize…", target: nil, action: nil)
    let askButton = NSButton(title: "Ask", target: nil, action: nil)
    let stopButton = NSButton(title: "Stop", target: nil, action: nil)
    let clearButton = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear the conversation")!, target: nil, action: nil)
    let settingsButton = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "AI assistant settings")!, target: nil, action: nil)
    let closeButton = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close the AI assistant")!, target: nil, action: nil)
    private let question = AiQuestionView()
    private let list = AiListView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(wrappingLabelWithString: AiJobs.emptyPane)

    var onClose: (() -> Void)?
    var onClear: (() -> Void)?
    var onStop: (() -> Void)?
    var onSummarize: (() -> Void)?
    var onSettings: (() -> Void)?
    var onAsk: ((String) -> Void)?
    /// A page citation was clicked (0-based page).
    var onPage: ((Int) -> Void)?

    private(set) var items: [NSView] = []

    var questionText: String {
        get { question.string }
        set {
            question.string = newValue
            question.needsDisplay = true
        }
    }

    var answers: [AiAnswerCard] { items.compactMap { $0 as? AiAnswerCard } }
    var isBusy: Bool { !stopButton.isHidden }

    override func loadView() {
        let root = AiPaneView()
        let title = NSTextField(labelWithString: "AI assistant")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        for (button, tip, action) in [
            (settingsButton, "AI assistant settings", #selector(settingsClicked)),
            (clearButton, "Clear the conversation", #selector(clearClicked)),
            (closeButton, "Close the AI assistant", #selector(closeClicked)),
        ] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.toolTip = tip
            button.target = self
            button.action = action
        }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [title, spacer, settingsButton, clearButton, closeButton])

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        list.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        list.translatesAutoresizingMaskIntoConstraints = false
        empty.textColor = .secondaryLabelColor
        empty.isSelectable = false
        empty.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentCompressionResistancePriority(.init(1), for: .vertical)
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        addItem(empty)

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        statusLabel.isSelectable = false
        let pagesLabel = NSTextField(labelWithString: "Pages")
        scopeField.setAccessibilityLabel("Pages the questions are about")
        scopeField.toolTip = "All, or pages such as 1-3, 5"
        scopeField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        summarizeButton.bezelStyle = .accessoryBarAction
        summarizeButton.target = self
        summarizeButton.action = #selector(summarizeClicked)
        let scopeSpacer = NSView()
        scopeSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let scopeRow = NSStackView(views: [pagesLabel, scopeField, scopeSpacer, summarizeButton])

        question.hint = "Ask about this document… (Return sends)"
        question.font = .systemFont(ofSize: NSFont.systemFontSize)
        question.delegate = self
        question.isRichText = false
        question.isAutomaticQuoteSubstitutionEnabled = false
        question.isAutomaticDashSubstitutionEnabled = false
        question.isVerticallyResizable = true
        question.isHorizontallyResizable = false
        question.autoresizingMask = [.width]
        question.textContainer?.widthTracksTextView = true
        question.textContainerInset = NSSize(width: 2, height: 4)
        question.setAccessibilityLabel("Question about this document")
        question.setAccessibilityHelp("Return sends, Shift-Return starts a new line")
        let questionScroll = NSScrollView()
        questionScroll.documentView = question
        questionScroll.hasVerticalScroller = true
        questionScroll.autohidesScrollers = true
        questionScroll.borderType = .bezelBorder
        questionScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true

        askButton.keyEquivalent = "" // Return belongs to the question box
        askButton.bezelColor = .controlAccentColor
        askButton.target = self
        askButton.action = #selector(askClicked)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.isHidden = true
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [buttonSpacer, stopButton, askButton])

        let separator = NSBox()
        separator.boxType = .separator
        let stack = NSStackView(views: [header, whereBox, scroll, separator, statusLabel, scopeRow, questionScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        stack.setHuggingPriority(.init(1), for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        for v in [header, whereBox, scroll, separator, statusLabel, scopeRow, questionScroll, buttons] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor), stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor), stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("AI assistant")
        view = root
    }

    private var laidOutWidth: CGFloat = 0

    /// Labels that wrap are told the pane's width, as it is dragged.
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width - 24
        guard width != laidOutWidth else { return }
        laidOutWidth = width
        statusLabel.preferredMaxLayoutWidth = width
        empty.preferredMaxLayoutWidth = width
        whereBox.label.preferredMaxLayoutWidth = width - 44
        for item in items {
            (item as? AiAnswerCard)?.noteLabel.preferredMaxLayoutWidth = width - 24
            (item as? AiBubble)?.setWidth(width)
        }
    }

    @objc private func settingsClicked() { onSettings?() }
    @objc private func closeClicked() { onClose?() }
    @objc func clearClicked() { onClear?() }
    @objc func stopClicked() { onStop?() }
    @objc func summarizeClicked() { onSummarize?() }

    @objc func askClicked() {
        let q = AiText.trim(question.string)
        if q.isEmpty || isBusy { return }
        onAsk?(q)
    }

    func focusQuestion() { view.window?.makeFirstResponder(question) }

    func clearQuestion() { questionText = "" }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard textView === question, selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { return false } // Shift-Return: a new line
        askClicked()
        return true
    }

    func textDidChange(_ notification: Notification) { question.needsDisplay = true }

    /// Shows where answers come from: model, host, and whether text leaves this Mac (amber when it does).
    func showDestination(_ config: AiConfig?, problem: String?) {
        guard let config else {
            whereBox.show(problem ?? "Not set up", .info)
            return
        }
        whereBox.show("\(config.model) · \(config.endpoint.reachText)", config.endpoint.reach == .internet ? .caution : .calm)
    }

    /// The line above the question box (progress, "Not sent"…); nil hides it. Spoken to VoiceOver.
    func showStatus(_ text: String?) {
        statusLabel.stringValue = text ?? ""
        statusLabel.isHidden = text == nil
        guard let text else { return }
        NSAccessibility.post(element: statusLabel, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func setBusy(_ busy: Bool) {
        stopButton.isHidden = !busy
        askButton.isEnabled = !busy
    }

    func clear() {
        for item in items { item.removeFromSuperview() }
        items = []
        addItem(empty)
    }

    private func addItem(_ view: NSView) {
        if items.first === empty, view !== empty {
            empty.removeFromSuperview()
            items = []
        }
        items.append(view)
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
    }

    /// What the user asked for, in its own bubble.
    func addQuestion(_ text: String) {
        let bubble = AiBubble(text)
        bubble.setWidth(laidOutWidth)
        addItem(bubble)
        scrollToEnd()
    }

    /// Starts an answer card; fill it as the answer streams in.
    func addAnswer(model: String, pageCount: Int) -> AiAnswerCard {
        let card = AiAnswerCard(model: model, pageCount: pageCount, goTo: { [weak self] in self?.onPage?($0) }, scrolled: { [weak self] in self?.scrollToEnd() })
        card.noteLabel.preferredMaxLayoutWidth = laidOutWidth - 24
        addItem(card)
        scrollToEnd()
        return card
    }

    private func scrollToEnd() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.list.layoutSubtreeIfNeeded()
                let height = self.list.frame.height - self.scroll.contentView.bounds.height
                self.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(height, 0)))
                self.scroll.reflectScrolledClipView(self.scroll.contentView)
            }
        }
    }

    /// The pane as text, for the self-test (the Windows `DevState`).
    func stateReport() -> String {
        let shown = items.map { item -> String in
            if let card = item as? AiAnswerCard { return "answer: \(card.text.prefix(60)) links=\(card.links.count)" }
            if let bubble = item as? AiBubble { return "you: \(bubble.text.prefix(60))" }
            return "empty"
        }
        return "where='\(whereBox.label.stringValue)' status='\(statusLabel.stringValue)' busy=\(isBusy) scope='\(scopeField.stringValue)' items=[\(shown.joined(separator: " | "))]"
    }
}

/// A question in the conversation.
@MainActor
final class AiBubble: NSView {
    let text: String
    private let label: NSTextField

    func setWidth(_ width: CGFloat) { label.preferredMaxLayoutWidth = width - 20 }

    init(_ text: String) {
        self.text = text
        label = NSTextField(wrappingLabelWithString: text)
        super.init(frame: .zero)
        label.isSelectable = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 6), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("You: " + text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    }
}
