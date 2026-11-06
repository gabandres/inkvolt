import AppKit
import PdfCore
import PrintCore
import UniformTypeIdentifiers

/// Reduce File Size, Flatten, Add Header & Footer, Add Watermark (the Windows app's `PageMarkActions` and `FileTools`):
/// each a sheet with the command's settings, then one edit (one undo step) through `DocumentEditor.run`, which asks for
/// the permissions password or the signatures' rewrite when needed. Remove Header & Footer and Remove Watermark take off
/// what Inkvolt PDF added.
extension DocumentWindowController {
    /// The last header and footer and watermark choices, for the next sheet (the self-test reads what was applied).
    private static var lastHeaderFooter = HeaderFooterOptions()
    /// The watermark's default text is a word the person edits first, in the interface's language (Windows' CONFIDENTIAL).
    private static var lastWatermark = WatermarkOptions(text: loc("DRAFT"))

    // MARK: Reduce File Size

    @objc func reduceFileSize(_ sender: Any?) {
        guard let window, pdf.session != nil else { return }
        let alert = NSAlert()
        alert.messageText = loc("Reduce File Size")
        alert.informativeText = loc("Makes the file smaller, mostly by storing its pictures at a lower resolution. Nothing changes if it wouldn't help.")
        let quality = NSPopUpButton(frame: .zero, pullsDown: false)
        quality.addItems(withTitles: [loc("High (200 dpi, for printing)"), loc("Medium (150 dpi, for e-mail)"), loc("Low (96 dpi, for the screen)"),
                                      loc("Keep pictures as they are")])
        quality.selectItem(at: 1)
        quality.setAccessibleName(loc("Pictures"))
        let thumbnails = NSButton(checkboxWithTitle: loc("Remove page thumbnails saved in the file"), target: nil, action: nil)
        thumbnails.state = .on
        let privateData = NSButton(checkboxWithTitle: loc("Remove other apps' private data"), target: nil, action: nil)
        privateData.state = .on
        let metadata = NSButton(checkboxWithTitle: loc("Remove extra document details (the title and author stay)"), target: nil, action: nil)
        // Plain words first, advanced choices behind More Options with good defaults (UX review, round 2).
        let form = SheetForm("ReduceFileSize")
        form.row(loc("Pictures"), quality)
        form.row(loc("Remove"), thumbnails, advanced: true)
        form.row(nil, privateData, advanced: true)
        form.row(nil, metadata, advanced: true)
        form.install(in: alert)
        alert.addButton(withTitle: loc("Reduce"))
        alert.addButton(withTitle: loc("Cancel"))
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
        let ok = await editor.run(loc("Reduce file size")) { d, pw in
            let r = try Optimizer.optimize(d, pw, options)
            if !r.isWorthIt { throw PdfEditError(loc("The document is already compact: nothing worth changing.")) }
            return r.data
        }
        if ok, let after = pdf.session?.data.count {
            notify(loc("Reduced from {0} to {1}. Save to keep it.", Self.size(before), Self.size(after)), canUndo: true)
        }
        return ok
    }

    /// A file size as the interface writes numbers (1.5 MB, 1,5 MB in Spanish).
    static func size(_ bytes: Int) -> String {
        if bytes >= 1 << 20 {
            let mb = (Double(bytes) / Double(1 << 20)).formatted(.number.precision(.fractionLength(1)).locale(CoreLanguage.locale))
            return "\(mb) MB"
        }
        return "\(CoreLanguage.number(max(1, bytes / 1024))) KB"
    }

    // MARK: Flatten

    @objc func flattenDocument(_ sender: Any?) {
        guard let window, pdf.session != nil else { return }
        let alert = NSAlert()
        alert.messageText = loc("Flatten")
        alert.informativeText = loc("Draws comments and form fields into the pages, so nobody can move or change them. Signature fields stay.")
        let annotations = NSButton(checkboxWithTitle: loc("Comments and drawings"), target: nil, action: nil)
        annotations.state = .on
        let fields = NSButton(checkboxWithTitle: loc("Form fields (the form can't be filled in afterwards)"), target: nil, action: nil)
        fields.state = .on
        let links = NSButton(checkboxWithTitle: loc("Links (they stop working)"), target: nil, action: nil)
        let printable = NSButton(checkboxWithTitle: loc("Only what prints"), target: nil, action: nil)
        printable.toolTip = loc("Hidden comments and comments that don't print are left out.")
        let form = SheetForm("Flatten")
        form.row(loc("Flatten"), annotations)
        form.row(nil, fields)
        form.row(nil, links, advanced: true)
        form.row(nil, printable, advanced: true)
        form.note(loc("Hidden comments and comments that don't print are left out."), advanced: true)
        form.install(in: alert)
        alert.addButton(withTitle: loc("Flatten"))
        alert.addButton(withTitle: loc("Cancel"))
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
        let ok = await editor.run(loc("Flatten")) { d, pw in
            let flat = try Flattener.flatten(d, pw, options)
            if flat == d { throw PdfEditError(loc("There is nothing to flatten.")) }
            return flat
        }
        if ok { notify(loc("Flattened. Save to keep it."), canUndo: true) }
        return ok
    }

    // MARK: Header & footer

    @objc func addHeaderFooter(_ sender: Any?) {
        guard let window, pdf.session != nil else { return }
        let alert = NSAlert()
        alert.messageText = loc("Add Header & Footer")
        alert.informativeText = loc("Text at the top and bottom of the pages, written into them so it prints everywhere.")
        let last = Self.lastHeaderFooter
        func field(_ text: String, _ label: String) -> NSTextField {
            let f = NSTextField(string: text)
            f.setAccessibleName(label)
            f.widthAnchor.constraint(equalToConstant: 130).isActive = true
            return f
        }
        let names = [loc("Header, left"), loc("Header, center"), loc("Header, right"), loc("Footer, left"), loc("Footer, center"), loc("Footer, right")]
        let slots = HeaderFooterSlot.allCases.enumerated().map { field(last.text($0.element), names[min($0.offset, names.count - 1)]) }
        slots[4].placeholderString = loc("Page <<page>> of <<pages>>")
        let size = SheetForm.number(PdfNum.f2(last.fontSize), label: loc("Font size"))
        let marginNames = [loc("Top margin"), loc("Bottom margin"), loc("Left margin"), loc("Right margin")]
        let margins = zip([last.marginTop, last.marginBottom, last.marginLeft, last.marginRight], marginNames)
            .map { SheetForm.number(PdfNum.f2($0.0), label: $0.1) }
        let batesOn = NSButton(checkboxWithTitle: loc("Number the pages for legal use (Bates)"), target: nil, action: nil)
        batesOn.state = last.bates != nil ? .on : .off
        let prefix = field(last.bates?.prefix ?? "", loc("Bates prefix"))
        prefix.placeholderString = loc("Prefix")
        let start = SheetForm.number(String(last.bates?.start ?? 1), label: loc("Bates start"))
        let digits = SheetForm.number(String(last.bates?.digits ?? 6), width: 40, label: loc("Bates digits"))
        let suffix = field(last.bates?.suffix ?? "", loc("Bates suffix"))
        suffix.placeholderString = loc("Suffix")
        let choice = pageChoice(allTitle: loc("All pages"))
        func caption(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.textColor = .secondaryLabelColor
            l.alignment = .center
            l.widthAnchor.constraint(equalToConstant: 130).isActive = true
            return l
        }
        let form = SheetForm("HeaderFooter", width: 520)
        // Points: "pt" in every language (Windows' "Font size (pt)").
        func points() -> NSTextField { NSTextField(labelWithString: "pt") } // English: a unit's symbol
        form.row(nil, caption(loc("Left")), caption(loc("Center")), caption(loc("Right")))
        form.row(loc("Header"), slots[0], slots[1], slots[2])
        form.row(loc("Footer"), slots[3], slots[4], slots[5])
        form.note(loc("<<page>> is the page number, <<pages>> the page count; <<date>>, <<time>> and <<file>> work too."))
        form.row(loc("Pages"), choice.view)
        form.row(loc("Font size"), size, points(), advanced: true)
        form.row(loc("Margins"), NSTextField(labelWithString: loc("Top")), margins[0], NSTextField(labelWithString: loc("Bottom")), margins[1], points(),
                 advanced: true)
        form.row(nil, NSTextField(labelWithString: loc("Left")), margins[2], NSTextField(labelWithString: loc("Right")), margins[3], points(), advanced: true)
        form.row(nil, batesOn, advanced: true)
        form.row(nil, prefix, start, NSTextField(labelWithString: loc("digits")), digits, suffix, advanced: true)
        form.note(loc("<<bates>> puts the number where you want it; the number starts at the value given."), advanced: true)
        form.install(in: alert)
        alert.addButton(withTitle: loc("Add"))
        alert.addButton(withTitle: loc("Cancel"))
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
                guard let chosen = pages.pages else { return self.pdf.showError(pages.error ?? loc("That page range isn't valid."), nil) }
                if o.isEmpty { return self.pdf.showError(loc("Type the text of a header or a footer."), nil) }
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
        TypedNumber.parse(field.stringValue)
    }

    @discardableResult
    func addHeaderFooter(_ options: HeaderFooterOptions, pages: [Int]) async -> Bool {
        var made = options
        made.fileName = pdf.session?.displayName ?? pdf.name
        made.date = Date()
        let o = made
        let label = o.bates != nil ? loc("Add header, footer & Bates numbers") : loc("Add header & footer")
        let ok = await editor.run(label) { d, pw in try HeaderFooter.apply(d, pw, pages, o) }
        if ok { notify(loc("Header and footer added. Save to keep them."), canUndo: true) }
        return ok
    }

    @objc func removeHeaderFooter(_ sender: Any?) {
        Task {
            let ok = await editor.run(loc("Remove header & footer")) { d, pw in
                let r = try HeaderFooter.remove(d, pw)
                if r == d { throw PdfEditError(loc("The document has no header or footer Inkvolt PDF added.")) }
                return r
            }
            if ok { notify(loc("Header and footer removed. Save to keep it."), canUndo: true) }
        }
    }

    // MARK: Watermark

    @objc func addWatermark(_ sender: Any?) {
        guard let window, pdf.session != nil else { return }
        let alert = NSAlert()
        alert.messageText = loc("Add Watermark")
        alert.informativeText = loc("Words or a picture across the pages, see-through, written into them so it prints everywhere.")
        let last = Self.lastWatermark
        let text = NSTextField(string: last.text ?? "")
        text.placeholderString = loc("DRAFT, CONFIDENTIAL, …")
        text.setAccessibilityLabel(loc("Watermark text"))
        text.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let picture = NSButton(title: loc("Choose Picture…"), target: nil, action: nil)
        let pictureName = NSTextField(labelWithString: last.image != nil ? loc("the last picture") : loc("none", context: "picture"))
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
        let size = SheetForm.number(PdfNum.f2(last.fontSize), label: loc("Font size"))
        let opacity = NSSlider(value: last.opacity, minValue: 0.05, maxValue: 1, target: nil, action: nil)
        opacity.widthAnchor.constraint(equalToConstant: 120).isActive = true
        opacity.setAccessibleName(loc("Opacity"))
        let rotation = SheetForm.number(PdfNum.f2(last.rotation), label: loc("Angle"))
        let layout = NSPopUpButton(frame: .zero, pullsDown: false)
        layout.addItems(withTitles: [loc("Once, in the middle"), loc("Tiled across the page")])
        layout.selectItem(at: last.layout == .tiled ? 1 : 0)
        layout.setAccessibleName(loc("Placement"))
        let color = NSPopUpButton(frame: .zero, pullsDown: false)
        let colors: [(String, AnnotColor)] = [(loc("Gray"), AnnotColor(0.5, 0.5, 0.5)), (loc("Red"), AnnotColor(0.85, 0.1, 0.1)),
                                              (loc("Blue"), AnnotColor(0.1, 0.3, 0.85)), (loc("Green"), AnnotColor(0.1, 0.6, 0.2)),
                                              (loc("Black"), AnnotColor(0, 0, 0))]
        color.addItems(withTitles: colors.map(\.0))
        color.selectItem(at: colors.firstIndex { $0.1 == last.color } ?? 0)
        color.setAccessibleName(loc("Color"))
        let behind = NSButton(checkboxWithTitle: loc("Behind the page's content"), target: nil, action: nil)
        behind.state = last.behind ? .on : .off
        let scale = SheetForm.number(String(Int(last.imageScale * 100)), label: loc("Picture width, percent of the page"))
        let choice = pageChoice(allTitle: loc("All pages"))
        func light(_ t: String) -> NSTextField {
            let l = NSTextField(labelWithString: t)
            l.textColor = .secondaryLabelColor
            return l
        }
        let form = SheetForm("Watermark")
        form.row(loc("Text"), text)
        form.row(loc("Or a picture"), picture, pictureName)
        form.row(loc("Color"), color)
        form.row(loc("Opacity"), light(loc("Faint")), opacity, light(loc("Solid")))
        form.row(loc("Placement"), layout)
        form.row(loc("Pages"), choice.view)
        form.row(loc("Font size"), size, NSTextField(labelWithString: "pt"), advanced: true) // English: a unit's symbol
        form.row(loc("Angle"), rotation, NSTextField(labelWithString: "°"), advanced: true)
        form.row(loc("Picture width"), scale, NSTextField(labelWithString: loc("% of the page")), advanced: true)
        form.row(nil, behind, advanced: true)
        form.install(in: alert)
        alert.addButton(withTitle: loc("Add"))
        alert.addButton(withTitle: loc("Cancel"))
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
                guard let chosen = pages.pages else { return self.pdf.showError(pages.error ?? loc("That page range isn't valid."), nil) }
                if o.text == nil && o.image == nil { return self.pdf.showError(loc("Type the watermark's text or choose a picture."), nil) }
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
        panel.message = loc("Choose the watermark's picture.")
        guard let url = StartWindowController.pick(panel)?.first else { return }
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let stamp = Pictures.stampImage(cg) else {
            return pdf.showError(loc("That picture couldn't be read."), nil)
        }
        handler(stamp, url.lastPathComponent)
    }

    @discardableResult
    func addWatermark(_ options: WatermarkOptions, pages: [Int]) async -> Bool {
        let ok = await editor.run(loc("Add watermark")) { d, pw in try Watermarks.apply(d, pw, pages, options) }
        if ok { notify(loc("Watermark added. Save to keep it."), canUndo: true) }
        return ok
    }

    @objc func removeWatermark(_ sender: Any?) {
        Task {
            let ok = await editor.run(loc("Remove watermark")) { d, pw in
                let r = try Watermarks.remove(d, pw)
                if r == d { throw PdfEditError(loc("The document has no watermark Inkvolt PDF added.")) }
                return r
            }
            if ok { notify(loc("Watermark removed. Save to keep it."), canUndo: true) }
        }
    }
}
