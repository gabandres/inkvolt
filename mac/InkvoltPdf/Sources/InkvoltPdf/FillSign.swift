import AppKit
import PdfCore
import ImageIO

/// Fill & Sign's handwritten signatures and initials (pictures placed as stamps, not digital signatures; the Windows
/// app's SignatureLibrary and Add signature tool): drawn on a pad or typed in a handwriting font, then put down with a
/// click. Kept between launches as PNG files, up to three signatures and one set of initials (`SavedSignatures`), in
/// Application Support's "Inkvolt PDF/signatures"; the self-test keeps its own in a temporary folder.
@MainActor
final class SignatureLibrary {
    static let shared = SignatureLibrary()
    var store = SavedSignatures(folder: SignatureLibrary.defaultFolder)

    static var defaultFolder: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Inkvolt PDF/signatures").path
    }

    var saved: [SavedSignature] { store.list() }
    var isFull: Bool { store.signatureCount >= SavedSignatures.maxSignatures }

    /// Saves a new signature (first free slot) or replaces the initials; nil when the three signature slots are taken.
    func save(_ image: StampImage, initials: Bool) throws -> SavedSignature? {
        guard let png = SignatureImages.png(image) else { throw CocoaError(.fileWriteUnknown) }
        return try store.save(png, initials: initials)
    }

    func delete(_ signature: SavedSignature) throws { try store.delete(signature) }

    /// The picture of a saved signature (nil when its file can't be read).
    func image(_ signature: SavedSignature) -> StampImage? {
        guard let data = try? signature.load() else { return nil }
        return SignatureImages.stampImage(png: data)
    }

    /// The first saved signature (or the initials).
    func first(initials: Bool) -> SavedSignature? { saved.first { $0.initials == initials } }

    /// The size a click puts it down at: 42 pt high (28 for initials), at most 260 pt wide.
    static func size(_ image: StampImage, initials: Bool) -> (width: Double, height: Double) {
        let h = initials ? 28.0 : 42.0
        let aspect = Double(image.width) / Double(max(image.height, 1))
        let w = min(260, h * aspect)
        return (w, w / max(aspect, 0.01))
    }
}

/// The menu bar's Place Saved Signature submenu, filled with the saved signatures each time it opens; the items go
/// along the responder chain to the front document window.
@MainActor
final class SavedSignaturesMenu: NSObject, NSMenuDelegate {
    static let shared = SavedSignaturesMenu()

    static func make() -> NSMenu {
        let menu = NSMenu(title: "Place Saved Signature")
        menu.delegate = shared
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let saved = SignatureLibrary.shared.saved
        for s in saved {
            let item = NSMenuItem(title: s.name, action: #selector(DocumentWindowController.placeSavedSignature(_:)), keyEquivalent: "")
            item.representedObject = s.path
            item.image = SignatureImages.thumbnail(s)
            menu.addItem(item)
        }
        if saved.isEmpty {
            let none = NSMenuItem(title: "No Saved Signatures", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }
}

/// Signature pictures: strokes or typed text drawn in dark blue ink on a transparent background, cropped to the ink.
@MainActor
enum SignatureImages {
    static let ink = NSColor(srgbRed: 0.05, green: 0.1, blue: 0.35, alpha: 1)

    /// Strokes (points of a pad of `canvas` size, top-left origin) at 3 pixels per point.
    static func drawn(_ strokes: [[CGPoint]], canvas: CGSize, lineWidth: CGFloat = 2.4) -> StampImage? {
        let points = strokes.flatMap { $0 }
        guard !points.isEmpty else { return nil }
        let xs = points.map(\.x), ys = points.map(\.y)
        let pad: CGFloat = lineWidth * 2
        let minX: CGFloat = (xs.min() ?? 0) - pad, minY: CGFloat = (ys.min() ?? 0) - pad
        let width: CGFloat = max((xs.max() ?? 0) + pad - minX, 4), height: CGFloat = max((ys.max() ?? 0) + pad - minY, 4)
        return render(CGSize(width: width, height: height)) { ctx in
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineWidth(lineWidth)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for stroke in strokes {
                guard let first = stroke.first else { continue }
                // Top-left points into the context's bottom-left space.
                func map(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - minX, y: height - (p.y - minY)) }
                ctx.beginPath()
                ctx.move(to: map(first))
                if stroke.count == 1 { ctx.addLine(to: map(CGPoint(x: first.x + 0.5, y: first.y))) }
                for p in stroke.dropFirst() { ctx.addLine(to: map(p)) }
                ctx.strokePath()
            }
        }
    }

    /// The handwriting font typed signatures use (Snell Roundhand, else Apple Chancery, else an italic system font).
    static func font(size: CGFloat) -> NSFont {
        for name in ["SnellRoundhand", "Apple Chancery"] {
            if let f = NSFont(name: name, size: size) { return f }
        }
        return NSFontManager.shared.convert(.systemFont(ofSize: size), toHaveTrait: .italicFontMask)
    }

    /// Typed text in the handwriting font.
    static func typed(_ text: String) -> StampImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let attributes: [NSAttributedString.Key: Any] = [.font: font(size: 48), .foregroundColor: ink]
        let string = NSAttributedString(string: trimmed, attributes: attributes)
        let bounds = string.boundingRect(with: NSSize(width: 4000, height: 400), options: [.usesLineFragmentOrigin, .usesFontLeading])
        let size = CGSize(width: ceil(bounds.width) + 16, height: ceil(bounds.height) + 12)
        return render(size) { ctx in
            let graphics = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            string.draw(with: NSRect(x: 8, y: 6, width: bounds.width + 4, height: bounds.height), options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A picture as PNG bytes (straight alpha), for the library.
    static func png(_ image: StampImage) -> Data? {
        let n = image.width * image.height
        guard n > 0, image.rgb.count >= n * 3 else { return nil }
        var rgba = [UInt8](repeating: 255, count: n * 4)
        for i in 0..<n {
            rgba[i * 4] = image.rgb[i * 3]
            rgba[i * 4 + 1] = image.rgb[i * 3 + 1]
            rgba[i * 4 + 2] = image.rgb[i * 3 + 2]
            if let alpha = image.alpha { rgba[i * 4 + 3] = alpha[i] }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB), let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                               space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// A saved PNG back into a picture.
    static func stampImage(png: Data) -> StampImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return Pictures.stampImage(cg)
    }

    /// A small picture of a saved signature for menus (on white: the ink is dark).
    static func thumbnail(_ signature: SavedSignature, height: CGFloat = 24) -> NSImage? {
        guard let data = try? signature.load(), let image = NSImage(data: data), image.size.height > 0 else { return nil }
        let width = min(140, height * image.size.width / image.size.height)
        let size = NSSize(width: width + 8, height: height + 4)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            image.draw(in: NSRect(x: 4, y: 2, width: width, height: height))
            return true
        }
    }

    /// Draws into a transparent bitmap of `size` points at 3x and converts it for the stamp.
    private static func render(_ size: CGSize, _ draw: (CGContext) -> Void) -> StampImage? {
        let scale: CGFloat = 3
        let w = Int((size.width * scale).rounded(.up)), h = Int((size.height * scale).rounded(.up))
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        draw(ctx)
        guard let image = ctx.makeImage() else { return nil }
        return Pictures.stampImage(image)
    }
}

/// The pad a signature is drawn on with the mouse or trackpad.
@MainActor
final class SignaturePad: NSView {
    private(set) var strokes: [[CGPoint]] = []
    var onChange: (() -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Signature pad: draw with the mouse or trackpad")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func clear() {
        strokes = []
        needsDisplay = true
        onChange?()
    }

    /// Adds a stroke (the self-test draws one this way, as the mouse would).
    func add(_ stroke: [CGPoint]) {
        strokes.append(stroke)
        needsDisplay = true
        onChange?()
    }

    override func mouseDown(with event: NSEvent) {
        strokes.append([convert(event.locationInWindow, from: nil)])
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !strokes.isEmpty else { return }
        strokes[strokes.count - 1].append(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { onChange?() }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill() // paper, in dark mode too: the ink is dark
        bounds.fill()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 16, y: bounds.height - 30))
        line.line(to: NSPoint(x: bounds.width - 16, y: bounds.height - 30))
        NSColor.separatorColor.setStroke()
        line.lineWidth = 1
        line.stroke()
        SignatureImages.ink.setStroke()
        for stroke in strokes where !stroke.isEmpty {
            let path = NSBezierPath()
            path.move(to: stroke[0])
            for p in stroke.dropFirst() { path.line(to: p) }
            path.lineWidth = 2.4
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.stroke()
        }
        NSColor.separatorColor.setStroke()
        NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)).stroke()
    }
}

/// The sheet that makes a signature or initials: Draw or Type, then Use.
@MainActor
final class SignatureSheet: NSWindowController, NSTextFieldDelegate {
    let initials: Bool
    let pad = SignaturePad(frame: NSRect(x: 0, y: 0, width: 420, height: 150))
    let typed = NSTextField(string: "")
    let mode = NSSegmentedControl(labels: ["Draw", "Type"], trackingMode: .selectOne, target: nil, action: nil)
    private let preview = NSTextField(labelWithString: "")
    private let use = NSButton(title: "Use", target: nil, action: nil)
    var done: ((StampImage?) -> Void)?

    init(initials: Bool, typing: Bool) {
        self.initials = initials
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        super.init(window: panel)
        let title = NSTextField(labelWithString: initials ? "Your initials" : "Your signature")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        mode.selectedSegment = typing ? 1 : 0
        mode.target = self
        mode.action = #selector(modeChanged)
        mode.setAccessibilityLabel("Draw or type")
        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.widthAnchor.constraint(equalToConstant: 420).isActive = true
        pad.heightAnchor.constraint(equalToConstant: 150).isActive = true
        pad.onChange = { [weak self] in self?.validate() }
        typed.placeholderString = initials ? "Type your initials" : "Type your name"
        typed.delegate = self
        typed.setAccessibilityLabel(initials ? "Initials" : "Name")
        preview.font = SignatureImages.font(size: 36)
        preview.textColor = SignatureImages.ink
        preview.setAccessibilityElement(false)
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearClicked))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        use.target = self
        use.action = #selector(useClicked)
        use.keyEquivalent = "\r"
        let note = NSTextField(wrappingLabelWithString: "This puts a picture of your signature on the page. It isn't a digital signature.")
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.preferredMaxLayoutWidth = 420
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [clear, spacer, cancel, use])
        buttons.widthAnchor.constraint(equalToConstant: 420).isActive = true
        let stack = NSStackView(views: [title, mode, pad, typed, preview, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        typed.widthAnchor.constraint(equalToConstant: 420).isActive = true
        panel.contentView = stack
        modeChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    var isTyping: Bool { mode.selectedSegment == 1 }

    @objc private func modeChanged() {
        pad.isHidden = isTyping
        typed.isHidden = !isTyping
        preview.isHidden = !isTyping
        window?.makeFirstResponder(isTyping ? typed : pad)
        validate()
    }

    func controlTextDidChange(_ obj: Notification) { validate() }

    private func validate() {
        preview.stringValue = typed.stringValue
        use.isEnabled = isTyping ? !typed.stringValue.trimmingCharacters(in: .whitespaces).isEmpty : !pad.strokes.isEmpty
    }

    /// The picture made from what was drawn or typed.
    func image() -> StampImage? {
        isTyping ? SignatureImages.typed(typed.stringValue) : SignatureImages.drawn(pad.strokes, canvas: pad.bounds.size)
    }

    @objc private func clearClicked() {
        if isTyping { typed.stringValue = "" } else { pad.clear() }
        validate()
    }

    @objc private func cancelClicked() { finish(nil) }

    @objc func useClicked() {
        guard let image = image() else { return NSSound.beep() }
        finish(image)
    }

    private func finish(_ image: StampImage?) {
        if let window, let parent = window.sheetParent { parent.endSheet(window) }
        done?(image)
        done = nil
    }
}
