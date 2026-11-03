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
        alert.informativeText = "Makes the file smaller, mostly by storing its pictures at a lower resolution. Nothing changes if it wouldn't help."
        let quality = NSPopUpButton(frame: .zero, pullsDown: false)
        quality.addItems(withTitles: ["High (200 dpi, for printing)", "Medium (150 dpi, for e-mail)", "Low (96 dpi, for the screen)", "Keep pictures as they are"])
        quality.selectItem(at: 1)
        quality.setAccessibleName("Pictures")
        let thumbnails = NSButton(checkboxWithTitle: "Remove page thumbnails saved in the file", target: nil, action: nil)
        thumbnails.state = .on
        let privateData = NSButton(checkboxWithTitle: "Remove other apps' private data", target: nil, action: nil)
        privateData.state = .on
        let metadata = NSButton(checkboxWithTitle: "Remove extra document details (the title and author stay)", target: nil, action: nil)
        // Plain words first, advanced choices behind More Options with good defaults (UX review, round 2).
        let form = SheetForm("ReduceFileSize")
        form.row("Pictures", quality)
        form.row("Remove", thumbnails, advanced: true)
        form.row(nil, privateData, advanced: true)
        form.row(nil, metadata, advanced: true)
        form.install(in: alert)
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
        alert.informativeText = "Draws comments and form fields into the pages, so nobody can move or change them. Signature fields stay."
        let annotations = NSButton(checkboxWithTitle: "Comments and drawings", target: nil, action: nil)
        annotations.state = .on
        let fields = NSButton(checkboxWithTitle: "Form fields (the form can't be filled in afterwards)", target: nil, action: nil)
        fields.state = .on
        let links = NSButton(checkboxWithTitle: "Links (they stop working)", target: nil, action: nil)
        let printable = NSButton(checkboxWithTitle: "Only what prints", target: nil, action: nil)
        printable.toolTip = "Hidden comments and comments that don't print are left out."
        let form = SheetForm("Flatten")
        form.row("Flatten", annotations)
        form.row(nil, fields)
        form.row(nil, links, advanced: true)
        form.row(nil, printable, advanced: true)
        form.note("Hidden comments and comments that don't print are left out.", advanced: true)
        form.install(in: alert)
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
        alert.informativeText = "Text at the top and bottom of the pages, written into them so it prints everywhere."
        let last = Self.lastHeaderFooter
        func field(_ text: String, _ label: String) -> NSTextField {
            let f = NSTextField(string: text)
            f.setAccessibleName(label)
            f.widthAnchor.constraint(equalToConstant: 130).isActive = true
            return f
        }
        let names = ["Header, left", "Header, center", "Header, right", "Footer, left", "Footer, center", "Footer, right"]
        let slots = HeaderFooterSlot.allCases.enumerated().map { field(last.text($0.element), names[min($0.offset, names.count - 1)]) }
        slots[4].placeholderString = "Page <<page>> of <<pages>>"
        let size = SheetForm.number(PdfNum.f2(last.fontSize), label: "Font size")
        let margins = zip([last.marginTop, last.marginBottom, last.marginLeft, last.marginRight], ["Top margin", "Bottom margin", "Left margin", "Right margin"])
            .map { SheetForm.number(PdfNum.f2($0.0), label: $0.1) }
        let batesOn = NSButton(checkboxWithTitle: "Number the pages for legal use (Bates)", target: nil, action: nil)
        batesOn.state = last.bates != nil ? .on : .off
        let prefix = field(last.bates?.prefix ?? "", "Bates prefix")
        prefix.placeholderString = "Prefix"
        let start = SheetForm.number(String(last.bates?.start ?? 1), label: "Bates start")
        let digits = SheetForm.number(String(last.bates?.digits ?? 6), width: 40, label: "Bates digits")
        let suffix = field(last.bates?.suffix ?? "", "Bates suffix")
        suffix.placeholderString = "Suffix"
        let choice = pageChoice(allTitle: "All pages")
        func caption(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.textColor = .secondaryLabelColor
            l.alignment = .center
            l.widthAnchor.constraint(equalToConstant: 130).isActive = true
            return l
        }
        let form = SheetForm("HeaderFooter", width: 520)
        form.row(nil, caption("Left"), caption("Center"), caption("Right"))
        form.row("Header", slots[0], slots[1], slots[2])
        form.row("Footer", slots[3], slots[4], slots[5])
        form.note("<<page>> is the page number, <<pages>> the page count; <<date>>, <<time>> and <<file>> work too.")
        form.row("Pages", choice.view)
        form.row("Font size", size, NSTextField(labelWithString: "pt"), advanced: true)
        form.row("Margins", NSTextField(labelWithString: "Top"), margins[0], NSTextField(labelWithString: "Bottom"), margins[1], NSTextField(labelWithString: "pt"), advanced: true)
        form.row(nil, NSTextField(labelWithString: "Left"), margins[2], NSTextField(labelWithString: "Right"), margins[3], NSTextField(labelWithString: "pt"), advanced: true)
        form.row(nil, batesOn, advanced: true)
        form.row(nil, prefix, start, NSTextField(labelWithString: "digits"), digits, suffix, advanced: true)
        form.note("<<bates>> puts the number where you want it; the number starts at the value given.", advanced: true)
        form.install(in: alert)
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
        alert.informativeText = "Words or a picture across the pages, see-through, written into them so it prints everywhere."
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
        let size = SheetForm.number(PdfNum.f2(last.fontSize), label: "Font size")
        let opacity = NSSlider(value: last.opacity, minValue: 0.05, maxValue: 1, target: nil, action: nil)
        opacity.widthAnchor.constraint(equalToConstant: 120).isActive = true
        opacity.setAccessibleName("Opacity")
        let rotation = SheetForm.number(PdfNum.f2(last.rotation), label: "Angle")
        let layout = NSPopUpButton(frame: .zero, pullsDown: false)
        layout.addItems(withTitles: ["Once, in the middle", "Tiled across the page"])
        layout.selectItem(at: last.layout == .tiled ? 1 : 0)
        layout.setAccessibleName("Placement")
        let color = NSPopUpButton(frame: .zero, pullsDown: false)
        let colors: [(String, AnnotColor)] = [("Gray", AnnotColor(0.5, 0.5, 0.5)), ("Red", AnnotColor(0.85, 0.1, 0.1)), ("Blue", AnnotColor(0.1, 0.3, 0.85)),
                                              ("Green", AnnotColor(0.1, 0.6, 0.2)), ("Black", AnnotColor(0, 0, 0))]
        color.addItems(withTitles: colors.map(\.0))
        color.selectItem(at: colors.firstIndex { $0.1 == last.color } ?? 0)
        color.setAccessibleName("Color")
        let behind = NSButton(checkboxWithTitle: "Behind the page's content", target: nil, action: nil)
        behind.state = last.behind ? .on : .off
        let scale = SheetForm.number(String(Int(last.imageScale * 100)), label: "Picture width, percent of the page")
        let choice = pageChoice(allTitle: "All pages")
        func light(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.textColor = .secondaryLabelColor
            return l
        }
        let form = SheetForm("Watermark")
        form.row("Text", text)
        form.row("Or a picture", picture, pictureName)
        form.row("Color", color)
        form.row("Opacity", light("Faint"), opacity, light("Solid"))
        form.row("Placement", layout)
        form.row("Pages", choice.view)
        form.row("Font size", size, NSTextField(labelWithString: "pt"), advanced: true)
        form.row("Angle", rotation, NSTextField(labelWithString: "°"), advanced: true)
        form.row("Picture width", scale, NSTextField(labelWithString: "% of the page"), advanced: true)
        form.row(nil, behind, advanced: true)
        form.install(in: alert)
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
