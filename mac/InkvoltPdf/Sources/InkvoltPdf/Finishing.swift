import AppKit
import PdfCore
import UniformTypeIdentifiers

/// Reduce File Size, Flatten, Add Header & Footer, Add Watermark (the Windows app's `PageMarkActions` and `FileTools`):
/// each a sheet with the command's settings, then one edit (one undo step) through `DocumentEditor.run`, which asks for
/// the permissions password or the signatures' rewrite when needed. Remove Header & Footer and Remove Watermark take off
/// what Inkvolt PDF added.
extension DocumentWindowController {
    /// The last header and footer and watermark choices, for the next sheet (the self-test reads what was applied).
    private static var lastHeaderFooter = HeaderFooterOptions()
    private static var lastWatermark = WatermarkOptions(text: "DRAFT")

    // MARK: Reduce File Size

    @objc func reduceFileSize(_ sender: Any?) {
        guard let window, pdf.session != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Reduce File Size"
        alert.informativeText = "Rewrites the document smaller: pictures shown larger than the chosen resolution are downsampled and stored as JPEG, identical streams merged, uncompressed ones compressed, unused objects dropped. Nothing changes when it wouldn't help."
        let quality = NSPopUpButton(frame: .zero, pullsDown: false)
        quality.addItems(withTitles: ["High quality (200 dpi)", "Medium (150 dpi)", "Low (96 dpi)", "Keep pictures as they are"])
        quality.selectItem(at: 1)
        quality.setAccessibilityLabel("Picture quality")
        let thumbnails = NSButton(checkboxWithTitle: "Remove embedded page thumbnails", target: nil, action: nil)
        thumbnails.state = .on
        let privateData = NSButton(checkboxWithTitle: "Remove other apps' private data", target: nil, action: nil)
        privateData.state = .on
        let metadata = NSButton(checkboxWithTitle: "Remove XMP metadata (the title and author stay)", target: nil, action: nil)
        let stack = NSStackView(views: [quality, thumbnails, privateData, metadata])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: 110)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Reduce")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                var options = OptimizeOptions()
                options.maxImageDpi = [200.0, 150, 96, nil][max(quality.indexOfSelectedItem, 0)]
                options.removeThumbnails = thumbnails.state == .on
                options.removePieceInfo = privateData.state == .on
                options.removeMetadata = metadata.state == .on
                Task { await self.reduceFileSize(options) }
            }
        }
    }

    @discardableResult
    func reduceFileSize(_ options: OptimizeOptions) async -> Bool {
        guard let session = pdf.session else { return false }
        let before = session.data.count
        let ok = await editor.run("Reduce file size") { d, pw in
            let r = try Optimizer.optimize(d, pw, options)
            if !r.isWorthIt { throw PdfEditError("The document is already compact: nothing worth changing.") }
            return r.data
        }
        if ok, let after = pdf.session?.data.count {
            notify("Reduced from \(Self.size(before)) to \(Self.size(after)). Save to keep it.", canUndo: true)
        }
        return ok
    }

    static func size(_ bytes: Int) -> String {
        bytes >= 1 << 20 ? String(format: "%.1f MB", Double(bytes) / Double(1 << 20)) : "\(max(1, bytes / 1024)) KB"
    }

    // MARK: Flatten

    @objc func flattenDocument(_ sender: Any?) {
        guard let window, pdf.session != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Flatten"
        alert.informativeText = "Draws comments and form fields into the pages, where nobody can move or change them. Signature fields stay."
        let annotations = NSButton(checkboxWithTitle: "Comments and drawings", target: nil, action: nil)
        annotations.state = .on
        let fields = NSButton(checkboxWithTitle: "Form fields (the form is removed)", target: nil, action: nil)
        fields.state = .on
        let links = NSButton(checkboxWithTitle: "Links (removed)", target: nil, action: nil)
        let printable = NSButton(checkboxWithTitle: "Only what prints (hidden and non-printing comments are dropped)", target: nil, action: nil)
        let stack = NSStackView(views: [annotations, fields, links, printable])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 380, height: 100)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Flatten")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                let options = FlattenOptions(annotations: annotations.state == .on, formFields: fields.state == .on, links: links.state == .on,
                                             printableOnly: printable.state == .on)
                Task { await self.flattenDocument(options) }
            }
        }
    }

    @discardableResult
    func flattenDocument(_ options: FlattenOptions) async -> Bool {
        let ok = await editor.run("Flatten") { d, pw in
            let flat = try Flattener.flatten(d, pw, options)
            if flat == d { throw PdfEditError("There is nothing to flatten.") }
            return flat
        }
        if ok { notify("Flattened. Save to keep it.", canUndo: true) }
        return ok
    }

    // MARK: Header & footer

    @objc func addHeaderFooter(_ sender: Any?) {
        guard let window, pdf.session != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Add Header & Footer"
        alert.informativeText = "Text at the top and bottom of the pages, written into them (it prints everywhere). Tokens: <<page>>, <<pages>>, <<date>>, <<time>>, <<file>>, <<bates>>."
        let last = Self.lastHeaderFooter
        func field(_ text: String, _ label: String) -> NSTextField {
            let f = NSTextField(string: text)
            f.setAccessibilityLabel(label)
            f.widthAnchor.constraint(equalToConstant: 150).isActive = true
            return f
        }
        let slots = HeaderFooterSlot.allCases.map { field(last.text($0), "\($0)") }
        let size = field(PdfNum.f2(last.fontSize), "Font size")
        let margins = [last.marginTop, last.marginBottom, last.marginLeft, last.marginRight].map { field(PdfNum.f2($0), "Margin") }
        let batesOn = NSButton(checkboxWithTitle: "Bates numbers (<<bates>>):", target: nil, action: nil)
        batesOn.state = last.bates != nil ? .on : .off
        let prefix = field(last.bates?.prefix ?? "", "Bates prefix")
        let start = field(String(last.bates?.start ?? 1), "Bates start")
        let digits = field(String(last.bates?.digits ?? 6), "Bates digits")
        let suffix = field(last.bates?.suffix ?? "", "Bates suffix")
        let choice = pageChoice(allTitle: "All pages")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: ""), NSTextField(labelWithString: "Left"), NSTextField(labelWithString: "Center"), NSTextField(labelWithString: "Right")],
            [NSTextField(labelWithString: "Header:"), slots[0], slots[1], slots[2]],
            [NSTextField(labelWithString: "Footer:"), slots[3], slots[4], slots[5]],
            [NSTextField(labelWithString: "Font size:"), size, NSTextField(labelWithString: "Margins (top, bottom):"), stackOf(margins[0], margins[1])],
            [NSTextField(labelWithString: ""), NSGridCell.emptyContentView, NSTextField(labelWithString: "Margins (left, right):"), stackOf(margins[2], margins[3])],
            [batesOn, stackOf(prefix, start), NSTextField(labelWithString: "digits, suffix:"), stackOf(digits, suffix)],
            [NSTextField(labelWithString: "Pages:"), choice.view, NSGridCell.emptyContentView, NSGridCell.emptyContentView],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 620, height: 230)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                var o = HeaderFooterOptions()
                (o.headerLeft, o.headerCenter, o.headerRight) = (slots[0].stringValue, slots[1].stringValue, slots[2].stringValue)
                (o.footerLeft, o.footerCenter, o.footerRight) = (slots[3].stringValue, slots[4].stringValue, slots[5].stringValue)
                o.fontSize = Self.number(size) ?? 10
                o.marginTop = Self.number(margins[0]) ?? 36
                o.marginBottom = Self.number(margins[1]) ?? 36
                o.marginLeft = Self.number(margins[2]) ?? 72
                o.marginRight = Self.number(margins[3]) ?? 72
                if batesOn.state == .on {
                    o.bates = BatesFormat(prefix.stringValue, Int64(start.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1,
                                          Int(digits.stringValue.trimmingCharacters(in: .whitespaces)) ?? 6, suffix.stringValue)
                }
                let pages = choice.read()
                guard let chosen = pages.pages else { return self.pdf.showError(pages.error ?? "That page range isn't valid.", nil) }
                if o.isEmpty { return self.pdf.showError("Type the text of a header or a footer.", nil) }
                Self.lastHeaderFooter = o
                Task { await self.addHeaderFooter(o, pages: chosen) }
            }
        }
    }

    private func stackOf(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 4
        return s
    }

    private static func number(_ field: NSTextField) -> Double? {
        Double(field.stringValue.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
    }

    @discardableResult
    func addHeaderFooter(_ options: HeaderFooterOptions, pages: [Int]) async -> Bool {
        var made = options
        made.fileName = pdf.session?.displayName ?? pdf.name
        made.date = Date()
        let o = made
        let ok = await editor.run(o.bates != nil ? "Add header, footer & Bates numbers" : "Add header & footer") { d, pw in try HeaderFooter.apply(d, pw, pages, o) }
        if ok { notify("Header and footer added. Save to keep them.", canUndo: true) }
        return ok
    }

    @objc func removeHeaderFooter(_ sender: Any?) {
        Task {
            let ok = await editor.run("Remove header & footer") { d, pw in
                let r = try HeaderFooter.remove(d, pw)
                if r == d { throw PdfEditError("The document has no header or footer Inkvolt PDF added.") }
                return r
            }
            if ok { notify("Header and footer removed. Save to keep it.", canUndo: true) }
        }
    }

    // MARK: Watermark

    @objc func addWatermark(_ sender: Any?) {
        guard let window, pdf.session != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Add Watermark"
        alert.informativeText = "A text or a picture, turned and see-through, once in the middle of each page or tiled across it, written into the pages (it prints everywhere)."
        let last = Self.lastWatermark
        let text = NSTextField(string: last.text ?? "")
        text.placeholderString = "DRAFT, CONFIDENTIAL, …"
        text.setAccessibilityLabel("Watermark text")
        text.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let picture = NSButton(title: "Choose Picture…", target: nil, action: nil)
        let pictureName = NSTextField(labelWithString: last.image != nil ? "the last picture" : "none")
        pictureName.textColor = .secondaryLabelColor
        final class Picked: @unchecked Sendable { var image: StampImage? }
        let picked = Picked()
        picked.image = last.image
        picture.target = self
        picture.action = #selector(choosePictureClicked(_:))
        picture.tag = 0
        objc_setAssociatedObject(picture, &Self.pickedKey, { [weak pictureName] (image: StampImage?, name: String) in
            picked.image = image
            pictureName?.stringValue = name
        } as PictureHandler, .OBJC_ASSOCIATION_RETAIN)
        let size = NSTextField(string: PdfNum.f2(last.fontSize))
        size.widthAnchor.constraint(equalToConstant: 60).isActive = true
        size.setAccessibilityLabel("Font size")
        let opacity = NSSlider(value: last.opacity, minValue: 0.05, maxValue: 1, target: nil, action: nil)
        opacity.widthAnchor.constraint(equalToConstant: 140).isActive = true
        opacity.setAccessibilityLabel("Opacity")
        let rotation = NSTextField(string: PdfNum.f2(last.rotation))
        rotation.widthAnchor.constraint(equalToConstant: 60).isActive = true
        rotation.setAccessibilityLabel("Angle")
        let layout = NSPopUpButton(frame: .zero, pullsDown: false)
        layout.addItems(withTitles: ["Once, in the middle", "Tiled across the page"])
        layout.selectItem(at: last.layout == .tiled ? 1 : 0)
        let color = NSPopUpButton(frame: .zero, pullsDown: false)
        let colors: [(String, AnnotColor)] = [("Gray", AnnotColor(0.5, 0.5, 0.5)), ("Red", AnnotColor(0.85, 0.1, 0.1)), ("Blue", AnnotColor(0.1, 0.3, 0.85)),
                                              ("Green", AnnotColor(0.1, 0.6, 0.2)), ("Black", AnnotColor(0, 0, 0))]
        color.addItems(withTitles: colors.map(\.0))
        color.selectItem(at: colors.firstIndex { $0.1 == last.color } ?? 0)
        let behind = NSButton(checkboxWithTitle: "Behind the page's content", target: nil, action: nil)
        behind.state = last.behind ? .on : .off
        let scale = NSTextField(string: String(Int(last.imageScale * 100)))
        scale.widthAnchor.constraint(equalToConstant: 60).isActive = true
        scale.setAccessibilityLabel("Picture width, percent of the page")
        let choice = pageChoice(allTitle: "All pages")
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Text:"), text],
            [NSTextField(labelWithString: "Or a picture:"), stackOf(picture, pictureName)],
            [NSTextField(labelWithString: "Font size:"), stackOf(size, NSTextField(labelWithString: "Picture width (%):"), scale)],
            [NSTextField(labelWithString: "Color:"), stackOf(color, NSTextField(labelWithString: "Opacity:"), opacity)],
            [NSTextField(labelWithString: "Angle:"), stackOf(rotation, layout)],
            [NSTextField(labelWithString: ""), behind],
            [NSTextField(labelWithString: "Pages:"), choice.view],
        ])
        grid.rowSpacing = 6
        grid.columnSpacing = 8
        grid.frame = NSRect(x: 0, y: 0, width: 520, height: 230)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                var o = WatermarkOptions()
                let typed = text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                o.text = typed.isEmpty ? nil : typed
                o.image = typed.isEmpty ? picked.image : nil
                o.fontSize = Self.number(size) ?? 72
                o.opacity = opacity.doubleValue
                o.rotation = Self.number(rotation) ?? 45
                o.layout = layout.indexOfSelectedItem == 1 ? .tiled : .center
                o.color = colors[max(color.indexOfSelectedItem, 0)].1
                o.behind = behind.state == .on
                o.imageScale = (Self.number(scale) ?? 50) / 100
                let pages = choice.read()
                guard let chosen = pages.pages else { return self.pdf.showError(pages.error ?? "That page range isn't valid.", nil) }
                if o.text == nil && o.image == nil { return self.pdf.showError("Type the watermark's text or choose a picture.", nil) }
                Self.lastWatermark = o
                Task { await self.addWatermark(o, pages: chosen) }
            }
        }
    }

    private typealias PictureHandler = (StampImage?, String) -> Void
    private static var pickedKey = 0

    @objc private func choosePictureClicked(_ sender: NSButton) {
        guard let handler = objc_getAssociatedObject(sender, &Self.pickedKey) as? PictureHandler else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.message = "Choose the watermark's picture."
        guard let url = StartWindowController.pick(panel)?.first else { return }
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let stamp = Pictures.stampImage(cg) else {
            return pdf.showError("That picture couldn't be read.", nil)
        }
        handler(stamp, url.lastPathComponent)
    }

    @discardableResult
    func addWatermark(_ options: WatermarkOptions, pages: [Int]) async -> Bool {
        let ok = await editor.run("Add watermark") { d, pw in try Watermarks.apply(d, pw, pages, options) }
        if ok { notify("Watermark added. Save to keep it.", canUndo: true) }
        return ok
    }

    @objc func removeWatermark(_ sender: Any?) {
        Task {
            let ok = await editor.run("Remove watermark") { d, pw in
                let r = try Watermarks.remove(d, pw)
                if r == d { throw PdfEditError("The document has no watermark Inkvolt PDF added.") }
                return r
            }
            if ok { notify("Watermark removed. Save to keep it.", canUndo: true) }
        }
    }
}
