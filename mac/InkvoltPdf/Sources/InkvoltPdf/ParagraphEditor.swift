import AppKit
import PdfCore
import PrintCore

/// The paragraph editor of Edit Text & Images (roadmap 2.1; the Windows app's paragraph editor in PageViewer.EditContent
/// and PageViewer.ParagraphLooks): a popover over the paragraph with a rich text view of its text, a look bar above it
/// (font, A− and A+, bold, italic, the paragraph's own color and six others) that changes the selection's look, and a note
/// under it saying live what the new text would do (its lines, what it would run into, characters drawn from fonts on
/// this Mac, the faces a look is drawn in). Return applies, Shift-Return (or Option-Return) starts a new line, Esc
/// cancels. Mac difference: the text is shown at a readable size, not at the page's, in its family when this Mac has it;
/// Windows lays its editor over the paragraph at the page's zoom.
@MainActor
final class ParagraphEditorController: NSViewController, NSTextViewDelegate {
    let paragraph: TextParagraph
    /// The text and looks to write; nil when cancelled.
    var done: ((String, [TextSpan]) -> Void)?
    weak var popover: NSPopover?

    private(set) var textView = NSTextView()
    private(set) var note = NSTextField(wrappingLabelWithString: "")
    private(set) var fonts = NSPopUpButton()
    private var finished = false
    private let width: CGFloat
    /// The text view's own undo (typing, looks): the document's undo manager takes only document edits.
    private let typingUndo = UndoManager()
    /// The note's layout after typing: a moment after the last key, off the main thread (a long paragraph takes time).
    private var noteTask: Task<Void, Never>?

    /// The size the paragraph's own text is shown at.
    private static let shownSize: CGFloat = 14

    /// The look each character was given, as an attribute (the look bar sets it; typing carries it, as a word processor does).
    private static let lookKey = NSAttributedString.Key("InkvoltLook")

    private final class LookBox: NSObject {
        let look: TextLook
        init(_ look: TextLook) { self.look = look }
    }

    /// Colors the bar offers, after the paragraph's own.
    static var colors: [(name: String, rgb: Int)] {
        [(loc("black"), 0x000000), (loc("dark gray"), 0x595959), (loc("red"), 0xC00000), (loc("blue"), 0x0070C0),
         (loc("green"), 0x00803C), (loc("orange"), 0xE36C09)]
    }

    init(_ paragraph: TextParagraph, width: CGFloat) {
        self.paragraph = paragraph
        self.width = min(max(width, 380), 640)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var lead: TextRun { paragraph.lead }

    override func loadView() {
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 4
        bar.setAccessibilityLabel(loc("Look of the selected text"))
        fonts.addItem(withTitle: loc("The paragraph's own font"))
        fonts.menu?.addItem(.separator())
        for f in ContentEditor.lookFonts() { fonts.addItem(withTitle: f) }
        fonts.target = self
        fonts.action = #selector(chooseFont(_:))
        fonts.toolTip = loc("Font of the selected text")
        fonts.setAccessibilityLabel(loc("Font of the selected text"))
        fonts.widthAnchor.constraint(equalToConstant: 170).isActive = true
        bar.addArrangedSubview(fonts)
        bar.addArrangedSubview(button("A−", loc("Smaller (1 point)"), #selector(smaller(_:))))
        bar.addArrangedSubview(button("A+", loc("Larger (1 point)"), #selector(larger(_:))))
        let bold = button("B", loc("Bold"), #selector(toggleBold(_:)))
        bold.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        bar.addArrangedSubview(bold)
        let italic = button("I", loc("Italic"), #selector(toggleItalic(_:)))
        italic.font = NSFontManager.shared.convert(.systemFont(ofSize: NSFont.systemFontSize), toHaveTrait: .italicFontMask)
        bar.addArrangedSubview(italic)
        bar.addArrangedSubview(swatch(Self.nsColor(lead.color), loc("Color: {0}", loc("the paragraph's own")), tag: -1))
        for (i, c) in Self.colors.enumerated() { bar.addArrangedSubview(swatch(Self.nsColor(c.rgb), loc("Color: {0}", c.name), tag: i)) }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 160))
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel(loc("Paragraph text"))
        textView.setAccessibilityHelp(loc("Edits this paragraph in its own font; the text rewraps in the paragraph's box. The bar above gives the selected text another font, size, color, bold or italic. Return applies, Shift-Return starts a new line, Escape cancels."))
        textView.textStorage?.setAttributedString(attributed(paragraph.text, paragraph.spans))
        textView.typingAttributes = attributes(.plain)
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 170).isActive = true

        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = width
        note.setAccessibilityLabel(loc("What the new text would do"))

        let tip = NSTextField(wrappingLabelWithString: loc("Type, then press Return. Shift-Return starts a new line. Esc cancels. The bar above changes the selection's look."))
        tip.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        tip.textColor = .tertiaryLabelColor
        tip.preferredMaxLayoutWidth = width

        let cancel = NSButton(title: loc("Cancel"), target: self, action: #selector(cancelEdit(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: loc("Apply"), target: self, action: #selector(applyEdit(_:)))
        apply.bezelColor = .controlAccentColor
        let buttons = NSStackView(views: [NSView(), cancel, apply])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [bar, scroll, note, tip, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        for v in [scroll, note, tip, buttons] { v.widthAnchor.constraint(equalToConstant: width).isActive = true }
        view = stack
        updateNote()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
    }

    private func button(_ title: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .smallSquare
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }

    private func swatch(_ color: NSColor, _ tip: String, tag: Int) -> NSButton {
        let b = NSButton(title: "", target: self, action: #selector(chooseColor(_:)))
        b.bezelStyle = .smallSquare
        b.tag = tag
        b.toolTip = tip
        b.setAccessibilityLabel(tip)
        b.wantsLayer = true
        b.layer?.backgroundColor = color.cgColor
        b.layer?.borderColor = NSColor.separatorColor.cgColor
        b.layer?.borderWidth = 1
        b.widthAnchor.constraint(equalToConstant: 18).isActive = true
        b.heightAnchor.constraint(equalToConstant: 18).isActive = true
        return b
    }

    private static func nsColor(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    // MARK: Looks as attributes

    /// What a look shows as: its family (when this Mac has it; else the paragraph's when it has that), bold and italic as
    /// they come out, its size against the paragraph's, its color.
    private func attributes(_ look: TextLook) -> [NSAttributedString.Key: Any] {
        let family = look.font ?? FontNames.family(lead.fontName)
        let scale = (look.size ?? paragraph.fontSize) / max(1, paragraph.fontSize)
        let size = max(6, min(72, Self.shownSize * scale))
        var font = NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size) ?? .systemFont(ofSize: size)
        if look.bold ?? lead.bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if look.italic ?? lead.italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let color = Self.nsColor(look.color ?? lead.color)
        return [.font: font, .foregroundColor: color, Self.lookKey: LookBox(look)]
    }

    private func attributed(_ text: String, _ spans: [TextSpan]) -> NSAttributedString {
        let s = NSMutableAttributedString(string: text, attributes: attributes(.plain))
        let length = text.utf16.count
        for span in spans {
            let lo = max(0, span.start), hi = min(length, span.end)
            if lo < hi { s.setAttributes(attributes(span.look), range: NSRange(location: lo, length: hi - lo)) }
        }
        return s
    }

    /// The text and its looks as typed.
    func content() -> (text: String, spans: [TextSpan]) {
        let storage = textView.textStorage ?? NSTextStorage()
        var spans: [TextSpan] = []
        storage.enumerateAttribute(Self.lookKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let look = (value as? LookBox)?.look, !look.isPlain else { return }
            spans.append(TextSpan(range.location, range.length, look))
        }
        return (textView.string, spans)
    }

    /// Gives the selection (or what is typed next, with nothing selected) a look changed by `change`.
    private func restyle(_ change: (TextLook) -> TextLook) {
        let range = textView.selectedRange()
        guard let storage = textView.textStorage else { return }
        if range.length == 0 {
            let look = (textView.typingAttributes[Self.lookKey] as? LookBox)?.look ?? .plain
            textView.typingAttributes = attributes(change(look))
            return
        }
        var runs: [(NSRange, TextLook)] = []
        storage.enumerateAttribute(Self.lookKey, in: range) { value, r, _ in runs.append((r, (value as? LookBox)?.look ?? .plain)) }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        for (r, look) in runs { storage.setAttributes(attributes(change(look)), range: r) }
        storage.endEditing()
        textView.didChangeText()
        updateNote()
    }

    /// The look at the start of the selection (or the typing look).
    private var currentLook: TextLook {
        let range = textView.selectedRange()
        if range.length == 0 { return (textView.typingAttributes[Self.lookKey] as? LookBox)?.look ?? .plain }
        return (textView.textStorage?.attribute(Self.lookKey, at: range.location, effectiveRange: nil) as? LookBox)?.look ?? .plain
    }

    @objc func chooseFont(_ sender: Any?) {
        let index = fonts.indexOfSelectedItem
        let family = index <= 0 ? nil : fonts.titleOfSelectedItem
        restyle { look in
            var l = look
            l.font = family.flatMap { $0.caseInsensitiveCompare(FontNames.family(self.lead.fontName)) == .orderedSame ? nil : $0 }
            return l
        }
    }

    private func resize(_ by: Double) {
        let own = paragraph.fontSize
        restyle { look in
            var l = look
            let size = ((look.size ?? own) + by).rounded()
            let clamped = min(max(size, 4), 144)
            l.size = abs(clamped - own) < 0.05 ? nil : clamped
            return l
        }
    }

    @objc func smaller(_ sender: Any?) { resize(-1) }
    @objc func larger(_ sender: Any?) { resize(+1) }

    @objc func toggleBold(_ sender: Any?) {
        let now = !(currentLook.bold ?? lead.bold)
        restyle { look in
            var l = look
            l.bold = now == self.lead.bold ? nil : now
            return l
        }
    }

    @objc func toggleItalic(_ sender: Any?) {
        let now = !(currentLook.italic ?? lead.italic)
        restyle { look in
            var l = look
            l.italic = now == self.lead.italic ? nil : now
            return l
        }
    }

    @objc func chooseColor(_ sender: NSButton) {
        let rgb: Int? = sender.tag < 0 ? nil : Self.colors[sender.tag].rgb
        restyle { look in
            var l = look
            l.color = rgb == self.lead.color ? nil : rgb
            return l
        }
    }

    // MARK: The note

    func undoManager(for view: NSTextView) -> UndoManager? { typingUndo }

    func textDidChange(_ notification: Notification) { scheduleNote() }

    /// Lays the text out again for the note once typing rests for a moment, off the main thread; a newer key wins.
    private func scheduleNote() {
        noteTask?.cancel()
        let (text, spans) = content()
        let p = paragraph
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            if Task.isCancelled { return }
            let check = await Task.detached(priority: .userInitiated) { p.check(text, spans: spans) }.value
            if Task.isCancelled { return }
            self?.showNote(check)
        }
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        let family = currentLook.font
        if let family, let i = fonts.itemTitles.firstIndex(of: family) { fonts.selectItem(at: i) } else { fonts.selectItem(at: 0) }
    }

    /// Characters for a note: “@”, “#” (a space as "space"), at most ten.
    static func charList(_ chars: [String]) -> String {
        let shown = chars.prefix(10).map { c -> String in
            if c == " " { return loc("space") }
            if let u = c.unicodeScalars.first, [.control, .privateUse, .unassigned].contains(u.properties.generalCategory) {
                return String(format: "U+%04X", u.value)
            }
            return "“\(c)”"
        }
        return shown.joined(separator: ", ") + (chars.count > 10 ? " …" : "")
    }

    /// What the text as typed would do, said under it (now: the look bar's changes, the self-test).
    func updateNote() {
        noteTask?.cancel()
        let (text, spans) = content()
        showNote(paragraph.check(text, spans: spans))
    }

    private func showNote(_ check: ParagraphCheck) {
        var color = NSColor.secondaryLabelColor
        var said: String
        if !check.missing.isEmpty {
            said = loc("Neither the font “{0}” nor any font on this Mac has {1}, so those can't be typed here.", lead.fontName, Self.charList(check.missing))
            color = .systemRed
        } else {
            let lines: String
            if check.lineCount == paragraph.lines.count {
                lines = check.lineCount == 1 ? loc("{0} line (as before)", CoreLanguage.number(1)) : loc("{0} lines (as before)", CoreLanguage.number(check.lineCount))
            } else {
                let was = CoreLanguage.number(paragraph.lines.count)
                lines = check.lineCount == 1 ? loc("{0} line (was {1})", CoreLanguage.number(1), was) : loc("{0} lines (was {1})", CoreLanguage.number(check.lineCount), was)
            }
            if let problem = check.lookProblem {
                said = loc("{0}, but {1}.", lines, problem)
                color = .systemRed
            } else if check.overlaps != nil {
                said = loc("{0}: it would run into what follows below. You'll be asked before it is written.", lines)
                color = .systemOrange
            } else {
                said = loc("{0}, in the paragraph's box. Return applies, Shift-Return starts a new line.", lines)
            }
            // Characters the paragraph's font lacks: never drawn from another font silently.
            if !check.borrowed.isEmpty {
                said += "\n" + Self.borrowedNote(check.borrowed, lead.fontName, check.standIns)
            }
            if !check.faces.isEmpty {
                said += "\n" + loc("Drawn in {0} where the look asks for it (fonts on this Mac, embedded as used).", check.faces.joined(separator: ", "))
            }
        }
        note.stringValue = said
        note.textColor = color
        note.setAccessibilityValue(said)
    }

    static func borrowedNote(_ borrowed: [String], _ font: String, _ standIns: [String]) -> String {
        let fonts = standIns.joined(separator: loc(" and "))
        return borrowed.count == 1
            ? loc("{0} isn't in this PDF's copy of “{1}”: drawn in {2}, the closest font on this Mac.", charList(borrowed), font, fonts)
            : loc("{0} aren't in this PDF's copy of “{1}”: drawn in {2}, the closest font on this Mac.", charList(borrowed), font, fonts)
    }

    // MARK: Keys and buttons

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else {
                applyEdit(nil)
            }
            return true
        case #selector(NSResponder.insertLineBreak(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEdit(nil)
            return true
        default:
            return false
        }
    }

    @objc func applyEdit(_ sender: Any?) {
        guard !finished else { return }
        finished = true
        noteTask?.cancel()
        let (text, spans) = content()
        popover?.close()
        done?(text, spans)
        done = nil
    }

    @objc func cancelEdit(_ sender: Any?) {
        finished = true
        noteTask?.cancel()
        done = nil
        popover?.close()
    }

    // MARK: For the self-test

    /// Selects `word` (its first time in the text); false when it isn't there.
    func select(_ word: String) -> Bool {
        let s = textView.string as NSString
        let r = s.range(of: word)
        if r.location == NSNotFound { return false }
        textView.setSelectedRange(r)
        return true
    }

    func type(_ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }
}
