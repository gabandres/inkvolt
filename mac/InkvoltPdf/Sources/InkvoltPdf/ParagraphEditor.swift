import AppKit
import PdfCore

extension NSAttributedString.Key {
    /// The look a stretch of the paragraph editor's text was given, as asked (the font shown may stand in for it).
    static let inkFamily = NSAttributedString.Key("InkvoltLookFamily")
    static let inkSize = NSAttributedString.Key("InkvoltLookSize")
    static let inkColor = NSAttributedString.Key("InkvoltLookColor")
    static let inkBold = NSAttributedString.Key("InkvoltLookBold")
    static let inkItalic = NSAttributedString.Key("InkvoltLookItalic")
}

/// A text view that pastes plain text (the looks are the bar's to give).
final class PlainPasteTextView: NSTextView {
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
}

/// Edit Text & Images' paragraph editor (roadmap 2.1; the Windows app's paragraph editor in PageViewer.EditContent and
/// PageViewer.ParagraphLooks): the paragraph's text in a rich text view as wide as its box (at a readable scale), its
/// alignment and line step, its stretches in their looks; a look bar over it gives the selection another font (the
/// paragraph's own or one of `ContentEditor.lookFonts()`), a smaller or larger size, bold, italic, one of six colors or
/// the paragraph's own; a live note under it says how many lines the text takes, whether it would run into what follows,
/// which characters come from another font and which fonts the looks are drawn in. Return applies, Shift-Return (or
/// Option-Return) starts a new line, Escape cancels. Each character's look is kept in attributes of its own (the family,
/// size, color, bold and italic asked for), so a family not installed reads back as asked.
@MainActor
final class ParagraphEditor: NSViewController, NSTextViewDelegate {
    let paragraph: TextParagraph
    /// Screen points per page point in the text view.
    private let k: Double
    /// The paragraph's own family, color (as shown: black when too light to read on white), bold and italic.
    private let baseFamily: String
    private let shownColor: Int
    private let baseBold: Bool, baseItalic: Bool
    let textView = PlainPasteTextView()
    private let scroll = NSScrollView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let fontPopup = NSPopUpButton()
    private var heightConstraint: NSLayoutConstraint?
    private let width: CGFloat
    /// The text and looks to write, when Return or Apply is pressed, or the popover closes without Cancel.
    var done: ((_ text: String, _ spans: [TextSpan]) -> Void)?
    weak var popover: NSPopover?
    private(set) var answered = false
    /// The note as last shown (for the self-test's report).
    private(set) var noteText = ""

    /// Colors the bar offers, after the paragraph's own (the Windows bar's).
    static let colors: [(name: String, rgb: Int)] =
        [("Black", 0x000000), ("Dark gray", 0x595959), ("Red", 0xC00000), ("Blue", 0x0070C0), ("Green", 0x00803C), ("Orange", 0xE36C09)]

    init(_ p: TextParagraph, scale: Double) {
        paragraph = p
        k = scale
        let lead = p.lead
        baseFamily = FontNames.family(lead.fontName)
        shownColor = (lead.color >> 16 & 0xFF) + (lead.color >> 8 & 0xFF) + (lead.color & 0xFF) > 600 ? 0 : lead.color
        baseBold = lead.bold
        baseItalic = lead.italic
        width = CGFloat(min(max(p.box.width * scale, 260), 900))
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Looks

    private static func color(_ rgb: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    /// The font the editor shows for a look: the family when installed (its bold or italic face), else Helvetica.
    private func displayFont(_ family: String, _ size: Double, _ bold: Bool, _ italic: Bool) -> NSFont {
        let fm = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let s = CGFloat(max(1, size * k))
        if let f = fm.font(withFamily: family, traits: traits, weight: 5, size: s) { return f }
        let plain = fm.font(withFamily: family, traits: [], weight: 5, size: s) ?? NSFont(name: "Helvetica", size: s) ?? .systemFont(ofSize: s)
        return fm.convert(plain, toHaveTrait: traits)
    }

    private func attributes(_ family: String, _ size: Double, _ color: Int, _ bold: Bool, _ italic: Bool) -> [NSAttributedString.Key: Any] {
        [.inkFamily: family, .inkSize: size, .inkColor: color, .inkBold: bold, .inkItalic: italic,
         .font: displayFont(family, size, bold, italic), .foregroundColor: Self.color(color), .paragraphStyle: paragraphStyle]
    }

    private lazy var paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        switch paragraph.align {
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        case .justified: style.alignment = .justified
        case .left: style.alignment = .left
        }
        style.minimumLineHeight = CGFloat(max(1, paragraph.lineStep * k))
        style.firstLineHeadIndent = CGFloat(paragraph.firstIndent * k)
        return style
    }()

    /// A look laid over the paragraph's own.
    private func attributes(_ look: TextLook?) -> [NSAttributedString.Key: Any] {
        attributes(look?.font ?? baseFamily, look?.size ?? paragraph.fontSize, look?.color ?? shownColor, look?.bold ?? baseBold,
                   look?.italic ?? baseItalic)
    }

    /// The paragraph's text with its stretches in their looks.
    private func initialText() -> NSAttributedString {
        let units = Array(paragraph.text.utf16)
        var looks = [TextLook?](repeating: nil, count: units.count)
        for s in paragraph.spans {
            var i = max(0, s.start)
            while i < min(units.count, s.end) {
                looks[i] = s.look
                i += 1
            }
        }
        let out = NSMutableAttributedString()
        var i = 0
        while i < units.count {
            var j = i + 1
            while j < units.count && looks[j] == looks[i] { j += 1 }
            out.append(NSAttributedString(string: String(decoding: units[i..<j], as: UTF16.self), attributes: attributes(looks[i])))
            i = j
        }
        return out
    }

    /// The editor's text (line breaks as "\n") and the stretches whose look differs from the paragraph's own.
    func content() -> (text: String, spans: [TextSpan]) {
        guard let storage = textView.textStorage else { return ("", []) }
        let ns = storage.string as NSString
        var text = ""
        var spans: [TextSpan] = []
        storage.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            let family = attrs[.inkFamily] as? String ?? baseFamily
            let size = attrs[.inkSize] as? Double ?? paragraph.fontSize
            let color = attrs[.inkColor] as? Int ?? shownColor
            let bold = attrs[.inkBold] as? Bool ?? baseBold
            let italic = attrs[.inkItalic] as? Bool ?? baseItalic
            let look = TextLook(font: family.caseInsensitiveCompare(baseFamily) == .orderedSame ? nil : family,
                                size: abs(size - paragraph.fontSize) > 0.3 ? size : nil, color: color == shownColor ? nil : color,
                                bold: bold != baseBold ? bold : nil, italic: italic != baseItalic ? italic : nil)
            var piece = ns.substring(with: range)
            for sep in ["\r", "\u{2028}", "\u{2029}"] { piece = piece.replacingOccurrences(of: sep, with: "\n") }
            let at = text.utf16.count, length = piece.utf16.count
            if !look.isPlain && length > 0 {
                if let last = spans.last, last.end == at, last.look == look {
                    spans[spans.count - 1].length += length
                } else {
                    spans.append(TextSpan(at, length, look))
                }
            }
            text += piece
        }
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, last.properties.isWhitespace { scalars.removeLast() }
        var trimmedText = ""
        trimmedText.unicodeScalars.append(contentsOf: scalars)
        let n = trimmedText.utf16.count
        let kept = spans.filter { $0.start < n }.map { TextSpan($0.start, min($0.length, n - $0.start), $0.look) }
        return (trimmedText, kept)
    }

    // MARK: The view

    override func loadView() {
        let title = NSTextField(labelWithString: "Edit Paragraph")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        fontPopup.addItem(withTitle: "\(baseFamily) (its own)")
        fontPopup.lastItem?.representedObject = baseFamily
        fontPopup.menu?.addItem(.separator())
        for f in ContentEditor.lookFonts() where f.caseInsensitiveCompare(baseFamily) != .orderedSame {
            fontPopup.addItem(withTitle: f)
            fontPopup.lastItem?.representedObject = f
        }
        fontPopup.target = self
        fontPopup.action = #selector(pickFont(_:))
        fontPopup.setAccessibilityLabel("Font of the selected text")
        fontPopup.toolTip = "Font of the selected text (fonts on this Mac, embedded as used)"

        func button(_ title: String, _ action: Selector, _ help: String) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = help
            b.setAccessibilityLabel(help)
            return b
        }
        let smaller = button("A−", #selector(smaller(_:)), "Smaller")
        let larger = button("A+", #selector(larger(_:)), "Larger")
        let bold = button("B", #selector(toggleBold(_:)), "Bold")
        bold.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let italic = button("I", #selector(toggleItalic(_:)), "Italic")
        italic.font = NSFontManager.shared.convert(.systemFont(ofSize: NSFont.systemFontSize), toHaveTrait: .italicFontMask)
        var swatches: [NSView] = []
        for (i, c) in ([("Its own color", shownColor)] + Self.colors).enumerated() {
            let b = NSButton(title: "", target: self, action: #selector(pickColor(_:)))
            b.tag = i
            b.bezelStyle = .texturedRounded
            b.image = Self.swatch(c.1, own: i == 0)
            b.imagePosition = .imageOnly
            b.toolTip = c.0
            b.setAccessibilityLabel(c.0)
            swatches.append(b)
        }
        let bar = NSStackView(views: [fontPopup, smaller, larger, bold, italic] + swatches)
        bar.spacing = 4

        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 2, height: 3)
        textView.textContainer?.widthTracksTextView = true
        textView.backgroundColor = .white
        textView.insertionPointColor = .black
        textView.delegate = self
        textView.setAccessibilityLabel("Paragraph text")
        textView.setAccessibilityHelp("Edits this paragraph in its own font; the text rewraps in the paragraph's box. The bar above gives the selected "
                                      + "text another font, size, color, bold or italic. Return applies, Shift-Return starts a new line, Escape cancels.")
        textView.textStorage?.setAttributedString(initialText())
        textView.typingAttributes = attributes(nil)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 60)
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: width + 6).isActive = true
        let h = scroll.heightAnchor.constraint(equalToConstant: 60)
        h.isActive = true
        heightConstraint = h

        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = width
        note.setAccessibilityLabel("Paragraph note")

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.bezelStyle = .rounded
        let apply = NSButton(title: "Apply", target: self, action: #selector(applyClicked(_:)))
        apply.bezelStyle = .rounded
        let buttons = NSStackView(views: [cancel, apply])

        let stack = NSStackView(views: [title, bar, scroll, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        view = stack
        fitHeight()
        updateNote()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(textView)
        textView.selectAll(nil)
    }

    private static func swatch(_ rgb: Int, own: Bool) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            color(rgb).setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            if own {
                NSColor.white.setStroke()
                let p = NSBezierPath()
                p.move(to: NSPoint(x: 4, y: 7))
                p.line(to: NSPoint(x: 10, y: 7))
                p.lineWidth = 1.5
                p.stroke()
            }
            return true
        }
    }

    /// The text view as tall as its text (at most 360 points; it scrolls past that).
    private func fitHeight() {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let h = min(max(lm.usedRect(for: tc).height + 8, 40), 360)
        heightConstraint?.constant = h
    }

    // MARK: The note

    /// Characters for a note: “@”, “#” (a space as "space"), at most ten.
    private static func charList(_ chars: [String]) -> String {
        chars.prefix(10).map { c -> String in
            if c == " " { return "space" }
            let cp = c.unicodeScalars.first!
            let cat = cp.properties.generalCategory
            return cat == .control || cat == .privateUse ? String(format: "U+%04X", cp.value) : "“\(c)”"
        }.joined(separator: ", ") + (chars.count > 10 ? " …" : "")
    }

    func updateNote() {
        let (text, spans) = content()
        let check = paragraph.check(text, spans)
        let p = paragraph
        var s: String
        var color = NSColor.secondaryLabelColor
        if !check.missing.isEmpty {
            s = "Neither the font “\(p.lead.fontName)” nor any font on this Mac has \(Self.charList(check.missing)), so those can't be typed here."
            color = .systemRed
        } else {
            let lines = check.lineCount == 1 ? "1 line" : "\(check.lineCount) lines"
            let was = check.lineCount == p.lines.count ? "as before" : "was \(p.lines.count)"
            if let lp = check.lookProblem {
                s = "\(lines) (\(was)), but \(lp)."
                color = .systemRed
            } else if check.overlaps != nil {
                s = "\(lines) (\(was)): it would run into what follows below. You'll be asked before it is written."
                color = .systemOrange
            } else {
                s = "\(lines) (\(was)), in the paragraph's box. Return applies, Shift-Return starts a new line."
            }
            // Characters the paragraph's font lacks: never drawn from another font silently.
            if !check.borrowed.isEmpty {
                s += "\n\(Self.charList(check.borrowed)) \(check.borrowed.count == 1 ? "isn't" : "aren't") in this PDF's copy of “\(p.lead.fontName)”: "
                    + "drawn in \(check.standIns.joined(separator: " and ")), the closest font on this Mac."
            }
            if !check.faces.isEmpty {
                s += "\nDrawn in \(check.faces.joined(separator: ", ")) where the look asks for it (fonts on this Mac, embedded as used)."
            }
        }
        noteText = s
        note.stringValue = s
        note.textColor = color
        note.setAccessibilityValue(s)
    }

    func textDidChange(_ notification: Notification) {
        fitHeight()
        updateNote()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertText("\n", replacementRange: textView.selectedRange())
            } else {
                applyClicked(nil)
            }
            return true
        }
        if selector == #selector(NSResponder.insertLineBreak(_:)) || selector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            cancelClicked(nil)
            return true
        }
        return false
    }

    // MARK: The look bar

    /// The selected text's ranges (the typing attributes when nothing is selected: nil).
    private var selection: [NSRange]? {
        let ranges = textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        return ranges.isEmpty ? nil : ranges
    }

    /// Changes the look of the selection (or of what is typed next) by `change`, then shows the fonts again.
    private func restyle(_ change: (inout [NSAttributedString.Key: Any]) -> Void) {
        guard let storage = textView.textStorage else { return }
        func refreshed(_ a: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var m = a
            change(&m)
            let fam = m[.inkFamily] as? String ?? baseFamily, size = m[.inkSize] as? Double ?? paragraph.fontSize
            let color = m[.inkColor] as? Int ?? shownColor, bold = m[.inkBold] as? Bool ?? baseBold, italic = m[.inkItalic] as? Bool ?? baseItalic
            return attributes(fam, size, color, bold, italic)
        }
        guard let ranges = selection else {
            textView.typingAttributes = refreshed(textView.typingAttributes)
            return
        }
        if textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: nil) {
            storage.beginEditing()
            for range in ranges {
                storage.enumerateAttributes(in: range) { attrs, r, _ in storage.setAttributes(refreshed(attrs), range: r) }
            }
            storage.endEditing()
            textView.didChangeText()
        }
        fitHeight()
        updateNote()
    }

    /// Whether every selected character (or what is typed next) has `key` on.
    private func allOn(_ key: NSAttributedString.Key, _ base: Bool) -> Bool {
        guard let ranges = selection, let storage = textView.textStorage else { return textView.typingAttributes[key] as? Bool ?? base }
        var all = true
        for range in ranges {
            storage.enumerateAttribute(key, in: range) { v, _, _ in if !((v as? Bool) ?? base) { all = false } }
        }
        return all
    }

    @objc func toggleBold(_ sender: Any?) {
        let on = !allOn(.inkBold, baseBold)
        restyle { $0[.inkBold] = on }
    }

    @objc func toggleItalic(_ sender: Any?) {
        let on = !allOn(.inkItalic, baseItalic)
        restyle { $0[.inkItalic] = on }
    }

    @objc func smaller(_ sender: Any?) { resize(-1) }
    @objc func larger(_ sender: Any?) { resize(1) }

    /// Each selected stretch a point smaller or larger (at least 1 point).
    func resize(_ points: Double) {
        let base = paragraph.fontSize
        restyle { a in a[.inkSize] = max(1, ((a[.inkSize] as? Double ?? base) + points).rounded()) }
    }

    @objc func pickFont(_ sender: NSPopUpButton) {
        guard let family = sender.selectedItem?.representedObject as? String else { return }
        setFamily(family)
    }

    /// The selection in `family` (the paragraph's own family takes the look off).
    func setFamily(_ family: String) { restyle { $0[.inkFamily] = family } }

    @objc func pickColor(_ sender: NSButton) {
        let all = [shownColor] + Self.colors.map(\.rgb)
        guard sender.tag >= 0 && sender.tag < all.count else { return }
        setColor(all[sender.tag])
    }

    func setColor(_ rgb: Int) { restyle { $0[.inkColor] = rgb } }

    /// Selects UTF-16 offsets of the text (the self-test's way of choosing a stretch).
    func select(_ range: NSRange) { textView.setSelectedRange(range) }

    /// Replaces the whole text, typed in the look before it (the self-test's typing).
    func type(_ text: String) {
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        if textView.shouldChangeText(in: all, replacementString: text) {
            textView.textStorage?.replaceCharacters(in: all, with: NSAttributedString(string: text, attributes: attributes(nil)))
            textView.didChangeText()
        }
        fitHeight()
        updateNote()
    }

    // MARK: Answering

    @objc func applyClicked(_ sender: Any?) {
        guard !answered else { return }
        answered = true
        let (text, spans) = content()
        popover?.close()
        done?(text, spans)
    }

    @objc func cancelClicked(_ sender: Any?) {
        guard !answered else { return }
        answered = true
        popover?.close()
    }

    /// The popover closed by a click elsewhere: the text is applied, as on Windows.
    func closedElsewhere() {
        if !answered { applyClicked(nil) }
    }
}
