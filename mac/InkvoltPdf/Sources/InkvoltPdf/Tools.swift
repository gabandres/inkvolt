import AppKit
import PdfCore

/// What a press on the pages does: the reading tools (hand, select text) and the comment tools, each with the single
/// key that picks it while the pages have the focus (the Windows app's keys where it has one).
enum Tool: Int, CaseIterable {
    case hand, text, highlight, underline, strikeOut, note, textBox, pen, highlighter, rectangle, ellipse, line, arrow, stamp, image, link
    case fillText, fillCheck, fillCross, fillDate, signature, editContent

    var title: String {
        switch self {
        case .hand: "Hand"
        case .text: "Select Text"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strike Out"
        case .note: "Note"
        case .textBox: "Text Box"
        case .pen: "Pen"
        case .highlighter: "Highlighter Pen"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .stamp: "Stamp"
        case .image: "Image"
        case .link: "Link"
        case .fillText: "Add Text"
        case .fillCheck: "Check Mark"
        case .fillCross: "Cross"
        case .fillDate: "Date"
        case .signature: "Signature"
        case .editContent: "Edit Text & Images"
        }
    }

    /// The single key that picks the tool ("" for none).
    var key: String {
        switch self {
        case .hand: "h"
        case .text: "t"
        case .highlight: "y"
        case .underline: "u"
        case .strikeOut: "k"
        case .note: "o"
        case .textBox: "b"
        case .pen: "p"
        case .highlighter: "m"
        case .rectangle: "r"
        case .ellipse: "e"
        case .line: "l"
        case .arrow: "w"
        case .stamp: "s"
        case .image: "i"
        case .link: "n"
        case .fillText: "a"
        case .fillCheck: "c"
        case .fillCross: "x"
        case .fillDate: "d"
        case .signature: "g"
        case .editContent: "j"
        }
    }

    var symbol: String {
        switch self {
        case .hand: "hand.raised"
        case .text: "character.cursor.ibeam"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .note: "note.text"
        case .textBox: "character.textbox"
        case .pen: "pencil.tip"
        case .highlighter: "paintbrush.pointed"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .stamp: "seal"
        case .image: "photo"
        case .link: "link"
        case .fillText: "character.cursor.ibeam"
        case .fillCheck: "checkmark"
        case .fillCross: "xmark"
        case .fillDate: "calendar"
        case .signature: "signature"
        case .editContent: "pencil.and.outline"
        }
    }

    /// What VoiceOver and the tooltip say about it.
    var help: String {
        switch self {
        case .hand: "Hand: scroll the pages, select a comment to move or resize it"
        case .text: "Select text, or a comment"
        case .highlight, .underline, .strikeOut: "\(title): drag over text"
        case .note: "Note: click where it goes"
        case .textBox: "Text box: click to type a line, drag for a box"
        case .pen, .highlighter: "\(title): draw freehand"
        case .rectangle, .ellipse: "\(title): drag; Shift for a square or circle"
        case .line, .arrow: "\(title): drag; Shift for 45° steps"
        case .stamp: "Stamp: pick one, then click where it goes"
        case .image: "Image: pick a picture, then click where it goes"
        case .link: "Link: drag a box, then choose a web address or a page"
        case .fillText: "Add text: click where it goes; click Fill & Sign text to change it"
        case .fillCheck: "Check mark: click where it goes; click one to remove it"
        case .fillCross: "Cross: click where it goes; click one to remove it"
        case .fillDate: "Date: click where today's date goes"
        case .signature: "Signature: draw or type one, then click where it goes"
        case .editContent: "Edit text and images: click text to change it, or a picture to move, replace or delete it"
        }
    }

    /// Tools that select and edit existing comments with a press.
    var selects: Bool { self == .hand || self == .text }
    var marksText: Bool { self == .highlight || self == .underline || self == .strikeOut }
    /// Fill & Sign's tools that put text or a mark (and change or remove one with a click).
    var fillsIn: Bool { self == .fillText || self == .fillCheck || self == .fillCross || self == .fillDate }
    /// Tools a press on a form field fills the field with (drawing and comment tools draw over fields instead).
    var fillsFields: Bool { selects || fillsIn || self == .signature }

    var markupKind: TextMarkupKind? {
        switch self {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        default: nil
        }
    }

    /// The tool strip's groups.
    static let groups: [[Tool]] = [
        [.hand, .text],
        [.highlight, .underline, .strikeOut, .note, .textBox],
        [.pen, .highlighter, .rectangle, .ellipse, .line, .arrow],
        [.stamp, .image, .link],
        [.fillText, .fillCheck, .fillCross, .fillDate, .signature],
        [.editContent],
    ]
}

/// The palette offered for comments: eight swatches (as the Windows style bar), and any other through the color panel.
enum Palette {
    static let colors: [(name: String, color: AnnotColor)] = [
        ("Red", AnnotColor(0.9, 0.1, 0.1)), ("Orange", AnnotColor(1, 0.55, 0)), ("Yellow", AnnotColor(1, 0.85, 0.1)),
        ("Green", AnnotColor(0.15, 0.65, 0.2)), ("Blue", AnnotColor(0.1, 0.4, 0.9)), ("Purple", AnnotColor(0.55, 0.25, 0.8)),
        ("Black", AnnotColor(0, 0, 0)), ("White", AnnotColor(1, 1, 1)),
    ]

    static func ns(_ c: AnnotColor) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: 1)
    }

    static func annot(_ c: NSColor) -> AnnotColor {
        let s = c.usingColorSpace(.sRGB) ?? c
        let r = (Double(s.redComponent) * 1000).rounded() / 1000
        let g = (Double(s.greenComponent) * 1000).rounded() / 1000
        let b = (Double(s.blueComponent) * 1000).rounded() / 1000
        return AnnotColor(r, g, b)
    }

    /// A round swatch image for menus and buttons.
    static func swatch(_ c: AnnotColor, size: CGFloat = 14) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1))
            ns(c).setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
        return image
    }

    static func name(_ c: AnnotColor?) -> String {
        guard let c else { return "None" }
        return colors.first { abs($0.color.r - c.r) + abs($0.color.g - c.g) + abs($0.color.b - c.b) < 0.02 }?.name ?? "Custom"
    }
}

/// How each tool draws its next comment: color, width and opacity, remembered per tool (as on Windows).
@MainActor
final class ToolStyles {
    private var styles: [Tool: AnnotStyle] = [:]

    func style(_ tool: Tool) -> AnnotStyle {
        if let s = styles[tool] { return s }
        switch tool {
        case .highlight, .note: return AnnotStyle(color: .yellow, width: 1)
        case .underline: return AnnotStyle(color: AnnotColor(0.15, 0.65, 0.2), width: 1)
        case .strikeOut: return AnnotStyle(color: .red, width: 1)
        case .highlighter: return .marker()
        case .arrow: return .arrow(.red)
        case .textBox: return .textBox()
        case .link, .editContent: return AnnotStyle(color: AnnotColor(0.1, 0.4, 0.9), width: 1)
        case .fillText, .fillCheck, .fillCross, .fillDate, .signature: return AnnotStyle(color: AnnotColor(0, 0, 0), width: 1)
        default: return .pen(.red)
        }
    }

    func set(_ tool: Tool, _ style: AnnotStyle) { styles[tool] = style }
}

/// The tools strip over the pages (as Preview's markup bar): the tools in groups, the color and line width for the
/// current tool, and the stamp in use. Every control has a VoiceOver label and a tooltip with its key.
@MainActor
final class ToolStrip: NSView {
    private var controls: [NSSegmentedControl] = []
    let colorButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let widthButton = NSPopUpButton(frame: .zero, pullsDown: false)
    let stampLabel = NSTextField(labelWithString: "")
    var onTool: ((Tool) -> Void)?
    var onColor: ((AnnotColor?) -> Void)?
    var onWidth: ((Double) -> Void)?
    /// The stamp and image segments ask for their choice right under them.
    var onStampMenu: ((NSView, NSRect) -> Void)?
    var onImageMenu: ((NSView, NSRect) -> Void)?
    var onSignatureMenu: ((NSView, NSRect) -> Void)?
    static let widths: [Double] = [0.5, 1, 2, 3, 5, 8, 14]

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Tools")
        var views: [NSView] = []
        for (g, group) in Tool.groups.enumerated() {
            let control = NSSegmentedControl()
            control.segmentCount = group.count
            control.trackingMode = .selectOne
            control.segmentStyle = .texturedRounded
            control.tag = g
            for (i, tool) in group.enumerated() {
                let image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)
                control.setImage(image, forSegment: i)
                control.setImageScaling(.scaleProportionallyDown, forSegment: i)
                control.setWidth(30, forSegment: i)
                control.setToolTip("\(tool.help) (\(tool.key.uppercased()))", forSegment: i)
                if tool == .stamp || tool == .image || tool == .signature { control.setShowsMenuIndicator(true, forSegment: i) }
            }
            control.target = self
            control.action = #selector(picked(_:))
            control.setAccessibilityLabel(["Reading tools", "Text comments", "Drawing tools", "Stamps, images and links", "Fill & Sign",
                                           "Edit page content"][g])
            controls.append(control)
            views.append(control)
        }

        colorButton.bezelStyle = .texturedRounded
        colorButton.setAccessibilityLabel("Color")
        colorButton.toolTip = "Color for the current tool or the selected comment"
        let colorMenu = NSMenu()
        colorMenu.addItem(withTitle: "", action: nil, keyEquivalent: "") // the pull-down's own title item
        for (i, entry) in Palette.colors.enumerated() {
            let item = NSMenuItem(title: entry.name, action: #selector(colorPicked(_:)), keyEquivalent: "")
            item.image = Palette.swatch(entry.color)
            item.tag = i
            item.target = self
            colorMenu.addItem(item)
        }
        colorMenu.addItem(.separator())
        let other = NSMenuItem(title: "Other Color…", action: #selector(otherColor(_:)), keyEquivalent: "")
        other.target = self
        colorMenu.addItem(other)
        colorButton.menu = colorMenu

        widthButton.bezelStyle = .texturedRounded
        widthButton.setAccessibilityLabel("Line width")
        widthButton.toolTip = "Line width for the current tool or the selected comment"
        for w in Self.widths { widthButton.addItem(withTitle: w < 1 ? "\(w) pt" : "\(Int(w)) pt") }
        widthButton.target = self
        widthButton.action = #selector(widthPicked)

        stampLabel.textColor = .secondaryLabelColor
        stampLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stampLabel.setAccessibilityLabel("Stamp in use")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: views + [colorButton, widthButton, stampLabel, spacer])
        stack.spacing = 10
        stack.setCustomSpacing(16, after: controls[controls.count - 1])
        // A narrow window drops the stamp's name, then the width and color, before any tool.
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: stampLabel)
        stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 600), for: widthButton)
        stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 700), for: colorButton)
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 10, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor), separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }

    /// Shows `tool` as the chosen one, with its color and width.
    func show(_ tool: Tool, style: AnnotStyle, stamp: String?) {
        for (g, group) in Tool.groups.enumerated() {
            controls[g].selectedSegment = group.firstIndex(of: tool) ?? -1
        }
        let plain: Set<Tool> = [.hand, .text, .stamp, .image, .fillText, .fillCheck, .fillCross, .fillDate, .signature, .editContent]
        showStyle(style, usesWidth: !plain.contains(tool) && ![.highlight, .underline, .strikeOut, .note].contains(tool),
                  usesColor: !plain.contains(tool))
        stampLabel.stringValue = tool == .stamp ? (stamp ?? "") : ""
    }

    func showStyle(_ style: AnnotStyle, usesWidth: Bool, usesColor: Bool) {
        let color = style.color ?? style.textColor
        colorButton.item(at: 0)?.image = Palette.swatch(color, size: 16)
        colorButton.item(at: 0)?.title = ""
        colorButton.setAccessibilityValue(Palette.name(color))
        colorButton.isEnabled = usesColor
        let nearest = Self.widths.enumerated().min { abs($0.element - style.width) < abs($1.element - style.width) }?.offset ?? 2
        widthButton.selectItem(at: nearest)
        widthButton.isEnabled = usesWidth
    }

    /// The segment of `tool` (for anchoring a menu or popover under it).
    func frame(of tool: Tool) -> (NSView, NSRect)? {
        for (g, group) in Tool.groups.enumerated() {
            guard let i = group.firstIndex(of: tool) else { continue }
            let control = controls[g]
            var x: CGFloat = 0
            for k in 0..<i { x += control.width(forSegment: k) + 2 }
            let width: CGFloat = control.width(forSegment: i)
            return (control, NSRect(x: x, y: 0, width: width, height: control.bounds.height))
        }
        return nil
    }

    @objc private func picked(_ sender: NSSegmentedControl) {
        let group = Tool.groups[sender.tag]
        guard sender.selectedSegment >= 0 else { return }
        let tool = group[sender.selectedSegment]
        onTool?(tool)
        if let spot = frame(of: tool) {
            if tool == .stamp { onStampMenu?(spot.0, spot.1) }
            if tool == .image { onImageMenu?(spot.0, spot.1) }
            if tool == .signature { onSignatureMenu?(spot.0, spot.1) }
        }
    }

    @objc private func colorPicked(_ sender: NSMenuItem) { onColor?(Palette.colors[sender.tag].color) }

    @objc private func otherColor(_ sender: Any?) {
        let panel = NSColorPanel.shared
        panel.setTarget(self)
        panel.setAction(#selector(panelColor(_:)))
        panel.showsAlpha = false
        panel.isContinuous = false // one edit per color chosen, not one per drag
        panel.orderFront(nil)
    }

    @objc private func panelColor(_ sender: NSColorPanel) { onColor?(Palette.annot(sender.color)) }

    @objc private func widthPicked() { onWidth?(Self.widths[max(widthButton.indexOfSelectedItem, 0)]) }
}

/// The Tools menu: it shows each tool's single key, but leaves keys without Command, Control or Option to the focused
/// view (the pages pick the tool; a text field types the letter). A menu item's key equivalent would take the key even
/// from a field, enabled or not.
final class ToolsMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty { return false }
        return super.performKeyEquivalent(with: event)
    }
}
