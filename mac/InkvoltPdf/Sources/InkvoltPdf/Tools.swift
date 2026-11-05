import AppKit
import PdfCore

/// What a press on the pages does: the reading tools (hand, select text) and the comment tools, each with the single
/// key that picks it while the pages have the focus (the Windows app's keys where it has one).
enum Tool: Int, CaseIterable {
    case hand, text, highlight, underline, strikeOut, note, textBox, pen, highlighter, rectangle, ellipse, line, arrow, stamp, image, link
    case fillText, fillCheck, fillCross, fillDate, signature, editContent
    case callout, polygon, polyline
    case redact
    case measureDistance, measurePerimeter, measureArea, measureCalibrate
    case prepareForm
    /// Copies a dragged rectangle of a page as a picture (Windows' Snapshot); last, so the other tools' tags stay.
    case snapshot

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
        case .callout: "Callout"
        case .polygon: "Polygon"
        case .polyline: "Polyline"
        case .redact: "Redact"
        case .measureDistance: "Measure Distance"
        case .measurePerimeter: "Measure Perimeter"
        case .measureArea: "Measure Area"
        case .measureCalibrate: "Calibrate Scale from a Known Length"
        case .prepareForm: "Prepare Form"
        case .snapshot: "Snapshot"
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
        case .callout: "q"
        case .polygon: "v"
        case .polyline: "z"
        case .redact: "f"
        case .measureDistance, .measurePerimeter, .measureArea, .measureCalibrate, .prepareForm: "" // none, as on Windows
        // Windows' G is the Signature tool's here, and every other letter is taken: Tools › Snapshot's ⌥⌘C instead.
        case .snapshot: ""
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
        case .callout: "text.bubble"
        case .polygon: "pentagon"
        case .polyline: "point.topleft.down.to.point.bottomright.curvepath"
        case .redact: "rectangle.fill"
        case .measureDistance, .measureCalibrate: "ruler"
        case .measurePerimeter: "point.topleft.down.to.point.bottomright.curvepath"
        case .measureArea: "square.dashed"
        case .prepareForm: "rectangle.and.pencil.and.ellipsis"
        case .snapshot: "camera.viewfinder"
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
        case .callout: "Callout: press where it points, drag to where the text goes"
        case .polygon: "Polygon: click each corner; double-click, Return or a click on the first corner closes it"
        case .polyline: "Polyline: click each point; double-click or Return ends it"
        case .redact: "Redact: drag over the areas to black out, click a mark to unmark it; nothing is removed until you apply the redactions"
        case .measureDistance: "Click the start and the end; Shift keeps it straight. The value is saved as a measurement at the page's scale (Tools › Measure › Set Measuring Scale)"
        case .measurePerimeter, .measureArea: "Click each corner; double-click or Return finishes, Delete takes a corner back, Esc cancels"
        case .measureCalibrate: "Click both ends of something whose real length you know (a dimension, a scale bar)"
        case .prepareForm: "Add and edit form fields"
        case .snapshot: "Snapshot: drag over part of a page to copy it as a picture; Esc cancels"
        }
    }

    /// The measuring tools (Tools › Measure), which aren't in the tool strip, as on Windows they are in Review › Measure.
    static let measuring: [Tool] = [.measureDistance, .measurePerimeter, .measureArea, .measureCalibrate]

    var measureTool: MeasureTool? {
        switch self {
        case .measureDistance: .distance
        case .measurePerimeter: .perimeter
        case .measureArea: .area
        case .measureCalibrate: .calibrate
        default: nil
        }
    }

    /// What the tooltip names as its key: the single key, or Snapshot's menu shortcut.
    var shortcut: String { self == .snapshot ? "⌥⌘C" : key.uppercased() }

    /// Tools that only read the pages (split view's second pane takes them).
    var readsOnly: Bool { self == .hand || self == .text || self == .snapshot }

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
        [.hand, .text, .snapshot],
        [.highlight, .underline, .strikeOut, .note, .textBox, .callout],
        [.pen, .highlighter, .rectangle, .ellipse, .line, .arrow, .polygon, .polyline],
        [.stamp, .image, .link],
        [.fillText, .fillCheck, .fillCross, .fillDate, .signature],
        [.editContent],
        [.redact],
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
        case .callout: return .textBox(fontSize: 12, border: .red, fill: AnnotColor(1, 1, 1))
        case .link, .editContent: return AnnotStyle(color: AnnotColor(0.1, 0.4, 0.9), width: 1)
        case .fillText, .fillCheck, .fillCross, .fillDate, .signature: return AnnotStyle(color: AnnotColor(0, 0, 0), width: 1)
        default: return .pen(.red)
        }
    }

    func set(_ tool: Tool, _ style: AnnotStyle) { styles[tool] = style }
}

/// The markup toolbar (as Preview's): the tools in groups, the color and line width for the current tool, and the stamp in
/// use, under the window's toolbar as a titlebar accessory, so it shares the toolbar's material (Liquid Glass) and the
/// system draws its background and edge (UX review, round 2: it was a strip of its own over the pages, painted with the
/// window's background). The color is the system's color well (its swatches and Show Colors…), the width a standard
/// pop-up. Every control has a VoiceOver label and a tooltip with its key.
@MainActor
final class ToolStrip: NSView {
    private var controls: [NSSegmentedControl] = []
    let colorWell = NSColorWell(style: .minimal)
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
    /// The titlebar accessory that holds the strip under the toolbar.
    let accessory = NSTitlebarAccessoryViewController()
    private var showing: NSColor?

    init() {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Markup")
        var views: [NSView] = []
        for (g, group) in Tool.groups.enumerated() {
            let control = NSSegmentedControl()
            control.segmentCount = group.count
            control.trackingMode = .selectOne
            control.segmentStyle = .automatic
            control.tag = g
            for (i, tool) in group.enumerated() {
                let image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.title)
                control.setImage(image, forSegment: i)
                control.setImageScaling(.scaleProportionallyDown, forSegment: i)
                control.setWidth(28, forSegment: i)
                control.setToolTip("\(tool.help) (\(tool.shortcut))", forSegment: i)
                if tool == .stamp || tool == .image || tool == .signature { control.setShowsMenuIndicator(true, forSegment: i) }
            }
            control.target = self
            control.action = #selector(picked(_:))
            control.setAccessibilityLabel(["Reading tools", "Text comments", "Drawing tools", "Stamps, images and links", "Fill & Sign",
                                           "Edit page content", "Redaction"][g])
            controls.append(control)
            views.append(control)
        }

        colorWell.widthAnchor.constraint(equalToConstant: 40).isActive = true
        colorWell.setAccessibleName("Color")
        colorWell.toolTip = "Color for the current tool or the selected comment"
        colorWell.supportsAlpha = false
        colorWell.isContinuous = false // one edit per color chosen, not one per drag
        colorWell.target = self
        colorWell.action = #selector(colorChanged(_:))

        widthButton.setAccessibleName("Line width")
        widthButton.toolTip = "Line width for the current tool or the selected comment"
        for w in Self.widths { widthButton.addItem(withTitle: w < 1 ? "\(w) pt" : "\(Int(w)) pt") }
        widthButton.target = self
        widthButton.action = #selector(widthPicked)

        stampLabel.textColor = .secondaryLabelColor
        stampLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stampLabel.setAccessibilityLabel("Stamp in use")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: views + [colorWell, widthButton, stampLabel, spacer])
        stack.spacing = 8
        stack.setCustomSpacing(16, after: controls[controls.count - 1])
        // A narrow window drops the stamp's name, then the width and color, then the tool groups from the right (each
        // tool stays in the Tools menu with its key). Before, the strip's full width was the window's minimum: about
        // 1,300 points with the sidebar, so a document window could never be narrower (UX review, 2026-11-03).
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: stampLabel)
        stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 600), for: widthButton)
        stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: 700), for: colorWell)
        for (g, control) in controls.enumerated() where g > 0 {
            stack.setVisibilityPriority(NSStackView.VisibilityPriority(rawValue: Float(800 - g * 10)), for: control)
        }
        stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        frame.size = NSSize(width: 600, height: stack.fittingSize.height)
        accessory.view = self
        accessory.layoutAttribute = .bottom
        accessory.automaticallyAdjustsSize = true
    }

    /// Shown and hidden with its accessory (the window's toolbar area grows and shrinks with it).
    override var isHidden: Bool {
        didSet { if accessory.isHidden != isHidden { accessory.isHidden = isHidden } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Shows `tool` as the chosen one, with its color and width.
    func show(_ tool: Tool, style: AnnotStyle, stamp: String?) {
        for (g, group) in Tool.groups.enumerated() {
            controls[g].selectedSegment = group.firstIndex(of: tool) ?? -1
        }
        // Measurements are drawn in their own look (Measurements.defaultStyle), as on Windows.
        let plain = Set<Tool>([.hand, .text, .snapshot, .stamp, .image, .fillText, .fillCheck, .fillCross, .fillDate, .signature, .editContent] + Tool.measuring)
        showStyle(style, usesWidth: !plain.contains(tool) && ![.highlight, .underline, .strikeOut, .note].contains(tool),
                  usesColor: !plain.contains(tool))
        stampLabel.stringValue = tool == .stamp ? (stamp ?? "") : ""
    }

    func showStyle(_ style: AnnotStyle, usesWidth: Bool, usesColor: Bool) {
        let color = style.color ?? style.textColor
        let ns = Palette.ns(color)
        if showing != ns {
            showing = ns
            colorWell.color = ns
        }
        colorWell.setAccessibilityValue(Palette.name(color))
        colorWell.isEnabled = usesColor
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

    @objc private func colorChanged(_ sender: NSColorWell) {
        guard sender.color != showing else { return }
        showing = sender.color
        onColor?(Palette.annot(sender.color))
    }

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

extension NSControl {
    /// Names the control for VoiceOver on the control and its cell: AppKit reports a pop-up's or a field's cell as the
    /// element, and the UX review's audit found those cells nameless with only the control named.
    func setAccessibleName(_ name: String) {
        setAccessibilityLabel(name)
        cell?.setAccessibilityLabel(name)
    }
}
