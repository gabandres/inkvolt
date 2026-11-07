import AppKit
import PdfCore
import PrintCore

/// File › Print…: AppKit's print panel (printer, copies, paper, orientation, its preview) with Inkvolt's options in an
/// accessory view: which pages of the document, and how they go on the paper (the core's `PrintSetup`: one per sheet at
/// actual size or fitted, pages per sheet, booklet, poster), and, for a printer Inkvolt Print knows, its state and toner
/// (`PrinterStatusLookup`; a warning in red when it is offline or has an error) with a button that opens Inkvolt Print.
/// Windows asks "Print anyway?" after its dialog closes; AppKit's print operation runs the panel and the job in one call
/// with no step between them, so here the warning is in the panel, before Print is pressed. The sheets are laid out by
/// `PrintPlan` and drawn by `PrintSheetView`: on paper each page as vectors from the core's `PrintCopy` (text stays text,
/// jobs stay small), a page the copy can't draw as MuPDF shows it as a picture the engine renders (300 dpi); the panel's
/// preview is always the engine's pictures (at the screen's resolution). The copy is made before the panel opens, off
/// the main thread (`preparePrint`: a sheet with Cancel when it takes a while), never by the preview or the job.
extension DocumentWindowController {
    /// The print copy made for the next print operation, and the engine whose bytes it was made from.
    struct PreparedPrint {
        let engine: PdfEngine
        let copy: PrintSheetView.Prepared?
    }

    /// Makes the print copy for the next print operation off the main thread, with a sheet and Cancel when it takes
    /// over 0.3 s (`progress`); false when cancelled (nothing prints). A copy that can't be made prints pictures.
    func preparePrint(progress: Bool = true) async -> Bool {
        let printed = layerEngine ?? engine
        guard let session = pdf.session else {
            preparedPrint = PreparedPrint(engine: printed, copy: nil)
            return true
        }
        // The layers chosen in the Layers pane print as they show (E9), as on Windows: the copy is made from the bytes
        // the layer engine draws, made again here rather than kept beside the document's.
        let source = PrintSheetView.Source(data: session.data, password: session.password, layers: layerEngine == nil ? [:] : layerVisibility)
        let shown = PrintSheetView.shownSizes(printed)
        let sheet = ProgressSheet(title: loc("Print"), text: loc("Getting the pages ready for the printer…"))
        let token = sheet.token
        let work = Task.detached { PrintSheetView.prepare(source, shown: shown, cancel: token) }
        let reveal = Task { @MainActor [weak self] in
            try await Task.sleep(for: .milliseconds(300))
            guard progress, let self, self.progressSheet == nil else { return }
            self.progressSheet = sheet
            sheet.begin(on: self.window)
        }
        let copy = await work.value
        reveal.cancel()
        if progressSheet === sheet {
            sheet.end()
            progressSheet = nil
        }
        if sheet.cancelled { return false }
        preparedPrint = PreparedPrint(engine: printed, copy: copy)
        return true
    }

    /// The copy `preparePrint` made, once (nil when there is none, or it was made from other bytes than `printed`'s).
    func takePreparedPrint(_ printed: PdfEngine) -> PrintSheetView.Prepared? {
        defer { preparedPrint = nil }
        guard let preparedPrint, preparedPrint.engine === printed else { return nil }
        return preparedPrint.copy
    }

    /// The print operation for this window's document (the panel shown by NSDocument's printDocument), drawing on
    /// paper from `copy` (none: every page a picture).
    func printOperation(_ info: NSPrintInfo, copy: PrintSheetView.Prepared? = nil) -> NSPrintOperation {
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        let printed = layerEngine ?? engine
        let options = PrintOptions(pageCount: printed.pageCount, preset: printPreset())
        let view = PrintSheetView(engine: printed, options: options, info: info, copy: copy)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = pdf.name
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        let panel = operation.printPanel
        panel.options.insert([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview, .showsCopies, .showsPageSetupAccessory])
        panel.addAccessoryController(PrintAccessory(options: options))
        return operation
    }

    /// Pages chosen in the organizer (or several thumbnails) are offered as the range to print.
    private func printPreset() -> String {
        let chosen = selectedPages
        return chosen.count > 1 || organizerShown ? PageRange.format(chosen) : ""
    }

    /// What `printToFile` printed: sheets laid out (-1 when the job failed), and pages drawn as vectors or as pictures.
    struct PrintedToFile {
        var sheets = -1
        var vectors = 0
        var pictures = 0
        /// Why pages printed as pictures (page index → reason).
        var reasons: [Int: String] = [:]
    }

    /// Prints to a PDF file instead of a printer (the self-test: never a real printer job), with these options;
    /// `pictures`: every page as a picture, as before vector printing (to compare).
    func printToFile(_ url: URL, setup: PrintSetup, range: String, pictures: Bool = false) async -> PrintedToFile {
        let info = (pdf.printInfo.copy() as! NSPrintInfo)
        info.jobDisposition = .save
        info.dictionary().setObject(url, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)
        var copy: PrintSheetView.Prepared?
        if !pictures {
            guard await preparePrint(progress: false) else { return PrintedToFile() }
            copy = takePreparedPrint(layerEngine ?? engine)
        }
        let operation = printOperation(info, copy: copy)
        guard let view = operation.view as? PrintSheetView else { return PrintedToFile() }
        view.options.setup = setup
        view.options.range = range
        view.picturesOnly = pictures
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { return PrintedToFile() }
        return PrintedToFile(sheets: view.plan.sheetCount, vectors: view.drawnAsVectors, pictures: view.drawnAsPictures,
                             reasons: view.pictureReasons)
    }
}

/// The print options the accessory view edits and the sheet view lays out: the document's pages to print (a range
/// typed in, empty for all) and the core's `PrintSetup`.
@MainActor
final class PrintOptions {
    let pageCount: Int
    var setup = PrintSetup()
    var range: String
    /// Called after a change (the accessory view bumps the preview).
    var changed: (() -> Void)?

    init(pageCount: Int, preset: String) {
        self.pageCount = pageCount
        range = preset
    }

    /// The pages printed (0-based, in order): the range, or all when it is empty or not valid.
    var pages: [Int] {
        let typed = range.trimmingCharacters(in: .whitespaces)
        if !typed.isEmpty {
            let parsed = PageRange.tryParse(typed, pageCount)
            if parsed.ok && !parsed.pages.isEmpty { return parsed.pages }
        }
        return Array(0..<pageCount)
    }

    /// Why the range typed can't be used (nil when it can).
    var rangeError: String? {
        let typed = range.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return nil }
        let parsed = PageRange.tryParse(typed, pageCount)
        return parsed.ok ? nil : parsed.error ?? loc("That page range isn't valid.")
    }
}

/// The print copy's bytes, held for Core Graphics' data provider while its document lives (read-only).
private final class PrintCopyBytes: @unchecked Sendable {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
}

/// The sheets of a print job, one under the other (flipped: y down, as the core's paper coordinates): AppKit asks how
/// many there are and draws each one in its rectangle.
final class PrintSheetView: NSView {
    /// What the print copy is made from: the document's bytes and password, and the layers the Layers pane shows
    /// differently (by object number; empty: the document's own), so the copy has the bytes `engine` draws.
    struct Source: Sendable {
        var data: [UInt8]
        var password: String?
        var layers: [Int: Bool]
    }

    /// The print copy as Core Graphics opened it (nil when no page prints as vectors), and how each page prints.
    struct Prepared: @unchecked Sendable {
        let document: CGPDFDocument?
        let pages: [PrintedPage]
    }

    /// Where a placed page is in the job (its sheet and its place on it), so a page AppKit draws in parts counts once.
    private struct Slot: Hashable {
        let sheet: Int
        let index: Int
    }

    let engine: PdfEngine
    let options: PrintOptions
    private let fallbackInfo: NSPrintInfo
    private(set) var plan: PrintPlan
    private var paper = NSSize(width: 612, height: 792)
    private let sizes: [(Double, Double)]
    /// Made before the job (`DocumentWindowController.preparePrint`); nil: every page prints as a picture.
    private let copy: Prepared?
    var hasCopy: Bool { copy != nil }
    /// Every page as a picture (the self-test's comparison with how pages printed before).
    var picturesOnly = false
    /// Pages (or poster tiles) drawn on paper as vectors and as pictures in this job, each once.
    private(set) var drawnAsVectors = 0
    private(set) var drawnAsPictures = 0
    private var counted = Set<Slot>()
    /// Why pages this job drew on paper are pictures (page index → reason), for the self-test.
    private(set) var pictureReasons: [Int: String] = [:]
    /// The reason when the job had no print copy at all.
    static let noCopy = "no print copy"

    /// Each page's size as `engine` shows it (rotation applied): what the copy's pages must match.
    static func shownSizes(_ engine: PdfEngine) -> [(Double, Double)] {
        (0..<engine.pageCount).map { (engine.page($0).width, engine.page($0).height) }
    }

    @MainActor
    init(engine: PdfEngine, options: PrintOptions, info: NSPrintInfo, copy: Prepared? = nil) {
        self.engine = engine
        self.options = options
        self.copy = copy
        fallbackInfo = info
        let sizes = Self.shownSizes(engine)
        self.sizes = sizes
        plan = PrintPlan([], { i in sizes[i] }, RectD(0, 0, 612, 792), PrintSetup())
        super.init(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        layOut()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// The plan for the paper chosen now (the panel's paper and orientation can change at any time).
    @MainActor
    func layOut() {
        let info = NSPrintOperation.current?.printInfo ?? fallbackInfo
        paper = info.paperSize
        let printable = info.imageablePageBounds
        let paperW = Double(paper.width), paperH = Double(paper.height)
        var area = RectD(Double(printable.minX), paperH - Double(printable.maxY), Double(printable.width), Double(printable.height))
        if area.width <= 0 || area.height <= 0 { area = RectD(0, 0, paperW, paperH) }
        let sizes = sizes
        plan = PrintPlan(options.pages, { i in sizes[i] }, area, options.setup)
        let height: CGFloat = paper.height * CGFloat(max(plan.sheetCount, 1))
        setFrameSize(NSSize(width: paper.width, height: height))
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        MainActor.assumeIsolated { layOut() }
        range.pointee = NSRange(location: 1, length: max(plan.sheetCount, 1))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * paper.height, width: paper.width, height: paper.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let index = Int((dirtyRect.midY / max(paper.height, 1)).rounded(.down)) // bounded: AppKit's rectangle in the print view, over at least 1
        guard index >= 0, index < plan.sheetCount, let ctx = NSGraphicsContext.current else { return }
        let top: CGFloat = CGFloat(index) * paper.height
        let sheet = plan.sheet(index)
        let screen = ctx.isDrawingToScreen
        for (i, placed) in sheet.pages.enumerated() where placed.page >= 0 {
            draw(placed, Slot(sheet: index, index: i), top: top, screen: screen, cg: ctx.cgContext)
        }
        if sheet.borders {
            NSColor.black.setStroke()
            for placed in sheet.pages where placed.page >= 0 {
                let path = NSBezierPath(rect: rect(placed.box, top))
                path.lineWidth = 0.5
                path.stroke()
            }
        }
        if !sheet.marks.isEmpty {
            let path = NSBezierPath()
            for m in sheet.marks {
                path.move(to: NSPoint(x: m.x1, y: Double(top) + m.y1))
                path.line(to: NSPoint(x: m.x2, y: Double(top) + m.y2))
            }
            path.lineWidth = 0.5
            NSColor.black.setStroke()
            path.stroke()
        }
    }

    private func rect(_ box: RectD, _ top: CGFloat) -> NSRect {
        NSRect(x: box.x, y: Double(top) + box.y, width: box.width, height: box.height)
    }

    /// The print copy for a job (off the main thread, before it starts): the core's `PrintCopy` of `source` (always MuPDF's
    /// rewrite, each vector page read through the bounded engine first), opened by Core Graphics, each page checked against
    /// how Core Graphics reads its box and turn. Nil when cancelled, or when it couldn't be made or read (every page
    /// prints as a picture).
    nonisolated static func prepare(_ source: Source, shown: [(Double, Double)], cancel: CancelToken?) -> Prepared? {
        do {
            var bytes = source.data, password = source.password
            if !source.layers.isEmpty {
                let layered = try Layers.withVisibility(bytes, password, source.layers)
                if layered != bytes { (bytes, password) = (layered, nil) } // written decrypted
            }
            let made = try PrintCopy.make(bytes, password, shown: shown, cancel: cancel)
            guard made.hasVectors else { return Prepared(document: nil, pages: made.pages) }
            let document = open(made.data)
            if cancel?.isCancelled == true { return nil }
            guard let document, document.numberOfPages == shown.count else {
                NSLog("Inkvolt PDF printing: Core Graphics couldn't read the print copy; pages print as pictures")
                return nil
            }
            return Prepared(document: document, pages: made.checked { i in box(document.page(at: i + 1)) })
        } catch is CancellationError {
            return nil
        } catch {
            NSLog("Inkvolt PDF printing: no print copy (%@); pages print as pictures", String(describing: error))
            return nil
        }
    }

    /// A page's visible box (its crop box clipped to its media box) and turn as Core Graphics reads them.
    nonisolated private static func box(_ page: CGPDFPage?) -> PageBox? {
        guard let page else { return nil }
        let visible = page.getBoxRect(.cropBox).intersection(page.getBoxRect(.mediaBox))
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        let x1 = Double(visible.minX), y1 = Double(visible.minY)
        return PageBox(x1, y1, Double(visible.maxX), Double(visible.maxY), rotation: Int(page.rotationAngle))
    }

    /// Core Graphics opens the copy reading its bytes where they are (`Data(bytes)` would hold a second copy of them).
    nonisolated private static func open(_ bytes: [UInt8]) -> CGPDFDocument? {
        guard !bytes.isEmpty else { return nil }
        let info = Unmanaged.passRetained(PrintCopyBytes(bytes))
        var callbacks = CGDataProviderDirectCallbacks(
            version: 0, getBytePointer: nil, releaseBytePointer: nil,
            getBytesAtPosition: { info, buffer, position, count in
                guard let info else { return 0 }
                let bytes = Unmanaged<PrintCopyBytes>.fromOpaque(info).takeUnretainedValue().bytes
                guard position >= 0, position < off_t(bytes.count) else { return 0 }
                let start = Int(position)
                let n = min(count, bytes.count - start)
                bytes.withUnsafeBytes { all in buffer.copyMemory(from: all.baseAddress! + start, byteCount: n) }
                return n
            },
            releaseInfo: { info in
                if let info { Unmanaged<PrintCopyBytes>.fromOpaque(info).release() }
            })
        guard let provider = CGDataProvider(directInfo: info.toOpaque(), size: off_t(bytes.count), callbacks: &callbacks) else {
            info.release()
            return nil
        }
        guard let document = CGPDFDocument(provider) else { return nil }
        return document.isUnlocked ? document : nil
    }

    /// Why a page drawn on paper is a picture: the copy's reason, or that Core Graphics had no page or no copy.
    private func pictureReason(_ page: Int) -> String {
        guard let copy, page < copy.pages.count else { return Self.noCopy }
        if case .picture(let why) = copy.pages[page] { return why }
        return "Core Graphics couldn't read the page"
    }

    /// One page (or part of one) in its box: on paper as vectors when the copy has it so, else as a picture.
    private func draw(_ placed: PlacedPage, _ slot: Slot, top: CGFloat, screen: Bool, cg: CGContext) {
        let first = !screen && counted.insert(slot).inserted
        if !screen, !picturesOnly, let copy, let document = copy.document, placed.page < copy.pages.count,
           case .vector(let toPage) = copy.pages[placed.page], let page = document.page(at: placed.page + 1) {
            drawVector(page, toPage, placed, top: top, cg: cg)
            if first { drawnAsVectors += 1 }
            return
        }
        if first {
            drawnAsPictures += 1
            if !picturesOnly { pictureReasons[placed.page] = pictureReason(placed.page) }
        }
        drawPicture(placed, top: top, screen: screen, cg: cg)
    }

    /// The copy's page drawn by Core Graphics through the core's matrices (its PDF space → page space → the paper),
    /// clipped to its box (a poster tile shows only its part).
    private func drawVector(_ page: CGPDFPage, _ toPage: Affine, _ placed: PlacedPage, top: CGFloat, cg: CGContext) {
        let size = sizes[placed.page]
        let onSheet = Affine(1, 0, 0, 1, 0, Double(top))
        let m = toPage.then(PrintLayout.toPaper(placed, size.0, size.1)).then(onSheet)
        cg.saveGState()
        cg.clip(to: rect(placed.box, top))
        cg.concatenate(CGAffineTransform(a: m.a, b: m.b, c: m.c, d: m.d, tx: m.tx, ty: m.ty))
        cg.drawPDFPage(page)
        cg.restoreGState()
    }

    /// One page (or part of one) rendered by the engine in its box, turned a quarter clockwise when the layout says so.
    private func drawPicture(_ placed: PlacedPage, top: CGFloat, screen: Bool, cg: CGContext) {
        let size = sizes[placed.page]
        let source = placed.source ?? RectD(0, 0, size.0, size.1)
        let turned = placed.turns % 2 == 1
        let drawnW: Double = turned ? placed.box.height : placed.box.width
        let drawnH: Double = turned ? placed.box.width : placed.box.height
        guard source.width > 0, source.height > 0, drawnW > 0, drawnH > 0 else { return }
        // Pixels per page point: 300 dpi on paper (the preview: twice the screen's points), under 40 megapixels.
        let dpi: Double = screen ? 144 : 300
        var scale: Double = drawnW / source.width * dpi / 72
        let pixels: Double = source.width * source.height * scale * scale
        if pixels > 40_000_000 { scale *= (40_000_000 / pixels).squareRoot() }
        let rendered: RenderedImage
        do {
            rendered = try engine.render(placed.page, scale: scale, region: placed.source)
        } catch let refused as PageRefused {
            // The engine won't draw it (a bomb, a picture too large): the sheet says why, as the screen does, not blank.
            if !screen { pictureReasons[placed.page] = refused.message }
            drawRefusal(refused.message, rect(placed.box, top))
            return
        } catch {
            return
        }
        guard let image = PageRenderer.cgImage(rendered) else { return }
        let box = rect(placed.box, top)
        cg.saveGState()
        cg.translateBy(x: box.midX, y: box.midY)
        if turned { cg.rotate(by: .pi / 2) }
        cg.scaleBy(x: 1, y: -1) // the view is flipped; images draw upright in unflipped space
        cg.interpolationQuality = .high
        cg.draw(image, in: CGRect(x: -drawnW / 2, y: -drawnH / 2, width: drawnW, height: drawnH))
        cg.restoreGState()
    }
}

extension PrintSheetView {
    /// A page the engine refused, in its box: the reason, centered, in gray, and a thin frame (a poster tile shows it too).
    func drawRefusal(_ message: String, _ box: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: box).addClip()
        NSColor.gray.setStroke()
        let frame = NSBezierPath(rect: box.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 0.5
        frame.stroke()
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let size: CGFloat = max(6, min(12, box.width / 30))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.darkGray,
                                                          .paragraphStyle: style]
        let text = NSAttributedString(string: message, attributes: attributes)
        let inset = box.insetBy(dx: min(36, box.width / 10), dy: 0)
        let height = text.boundingRect(with: NSSize(width: inset.width, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin]).height
        let place = NSRect(x: inset.minX, y: inset.midY - height / 2, width: inset.width, height: height)
        text.draw(with: place, options: [.usesLineFragmentOrigin])
    }
}

/// Inkvolt's options in the print panel: Pages (a range of the document's pages) and Layout (one page per sheet at
/// actual size or fitted, pages per sheet with order and borders, booklet with its binding, poster with its size,
/// overlap and cut marks). Every change redraws the panel's preview.
final class PrintAccessory: NSViewController, NSPrintPanelAccessorizing {
    private let options: PrintOptions
    @objc dynamic var revision = 0
    private let range = NSTextField(string: "")
    private let rangeNote = NSTextField(labelWithString: "")
    private let handling = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sizing = NSPopUpButton(frame: .zero, pullsDown: false)
    private let perSheet = NSPopUpButton(frame: .zero, pullsDown: false)
    private let order = NSPopUpButton(frame: .zero, pullsDown: false)
    private let borders = NSButton(checkboxWithTitle: loc("Page borders"), target: nil, action: nil)
    private let binding = NSPopUpButton(frame: .zero, pullsDown: false)
    private let posterScale = NSPopUpButton(frame: .zero, pullsDown: false)
    private let overlap = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cutMarks = NSButton(checkboxWithTitle: loc("Cut marks"), target: nil, action: nil)
    /// The panel's printer's state, when it is one Inkvolt Print knows (`PrinterStatusLookup`).
    let printerStatus = NSTextField(wrappingLabelWithString: "")
    private let printerSettings = NSButton(title: loc("Printer Settings (Inkvolt Print)"), target: nil, action: nil)
    private var watchedPrinter: String?
    private var watch: Timer?
    private var lookupTask: Task<Void, Never>?
    var lookup = PrinterStatusLookup.shared
    /// The printer to look at instead of the panel's (the self-test's).
    var testPrinterName: String?
    private static let scales: [Double] = [1.5, 2, 3, 4]
    private static let overlaps: [Double] = [0, 9, 18, 36] // points: none, ⅛, ¼, ½ inch

    @MainActor
    init(options: PrintOptions) {
        self.options = options
        super.init(nibName: nil, bundle: nil)
        title = "Inkvolt PDF" // English: the app's name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        range.stringValue = options.range
        range.placeholderString = loc("All {0} pages (or e.g. 1-3, 5)", CoreLanguage.number(options.pageCount))
        range.setAccessibilityLabel(loc("Pages to print"))
        range.target = self
        range.action = #selector(changed)
        range.widthAnchor.constraint(equalToConstant: 220).isActive = true
        rangeNote.textColor = .systemRed
        rangeNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        handling.addItems(withTitles: [loc("One page per sheet"), loc("Several pages per sheet"), loc("Booklet"), loc("Poster")])
        sizing.addItems(withTitles: [loc("Actual size (only larger pages shrink)"), loc("Fit to paper (small pages grow too)")])
        perSheet.addItems(withTitles: PrintSetup.pagesPerSheetChoices.map { loc("{0} pages", CoreLanguage.number($0)) })
        order.addItems(withTitles: [loc("Across, then down"), loc("Down, then across")])
        binding.addItems(withTitles: [loc("Bound on the left"), loc("Bound on the right")])
        posterScale.addItems(withTitles: Self.scales.map { "\(Int($0 * 100)) %" })
        posterScale.selectItem(at: 1)
        overlap.addItems(withTitles: [loc("No overlap"), loc("⅛ inch overlap"), loc("¼ inch overlap"), loc("½ inch overlap")])
        cutMarks.state = .on
        for control in [handling, sizing, perSheet, order, binding, posterScale, overlap] as [NSPopUpButton] {
            control.target = self
            control.action = #selector(changed)
        }
        for b in [borders, cutMarks] {
            b.target = self
            b.action = #selector(changed)
        }
        handling.setAccessibilityLabel(loc("Layout"))
        sizing.setAccessibilityLabel(loc("Size"))
        perSheet.setAccessibilityLabel(loc("Pages per sheet"))
        order.setAccessibilityLabel(loc("Page order"))
        binding.setAccessibilityLabel(loc("Binding"))
        posterScale.setAccessibilityLabel(loc("Poster size"))
        overlap.setAccessibilityLabel(loc("Overlap"))

        func label(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            return l
        }
        let grid = NSGridView(views: [
            [label(loc("Pages:")), range],
            [NSGridCell.emptyContentView, rangeNote],
            [label(loc("Layout:", context: "print panel")), handling],
            [label(loc("Size:")), sizing],
            [label(loc("Pages per sheet:")), perSheet],
            [label(loc("Order:")), order],
            [NSGridCell.emptyContentView, borders],
            [label(loc("Binding:")), binding],
            [label(loc("Poster size:")), posterScale],
            [label(loc("Overlap:")), overlap],
            [NSGridCell.emptyContentView, cutMarks],
            [label(loc("Printer:")), printerStatus],
            [NSGridCell.emptyContentView, printerSettings],
        ])
        printerStatus.preferredMaxLayoutWidth = 320
        printerStatus.setAccessibilityLabel(loc("Printer status"))
        printerSettings.bezelStyle = .push
        printerSettings.target = self
        printerSettings.action = #selector(openPrinterSettings)
        printerSettings.toolTip = loc("Opens Inkvolt Print: the printers' status, ink and toner, and their settings")
        grid.rowSpacing = 6
        grid.column(at: 0).xPlacement = .trailing
        let container = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        view = container
        gridView = grid
        syncFromOptions()
    }

    private var gridView: NSGridView?

    /// Shows the rows the chosen layout uses.
    private func showRows() {
        guard let grid = gridView else { return }
        let h = handling.indexOfSelectedItem
        let visible: [Int: Bool] = [3: h == 0, 4: h == 1, 5: h == 1, 6: h == 1, 7: h == 2, 8: h == 3, 9: h == 3, 10: h == 3]
        for (row, shown) in visible { grid.row(at: row).isHidden = !shown }
        grid.row(at: 1).isHidden = rangeNote.stringValue.isEmpty
        grid.row(at: 11).isHidden = printerStatus.stringValue.isEmpty
        grid.row(at: 12).isHidden = !printAppInstalled
    }

    /// Whether Inkvolt Print is on this Mac, asked of Launch Services once a panel.
    private lazy var printAppInstalled = InkvoltPrintApp.isInstalled

    // MARK: Printer status (the Inkvolt suite)

    // The panel's printer is looked at twice a second while the panel shows (AppKit tells an accessory nothing when it
    // changes); a new one is checked once, in the background, and its line shown when it answers.
    override func viewDidAppear() {
        super.viewDidAppear()
        watch?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.printerMayHaveChanged() }
        }
        RunLoop.main.add(timer, forMode: .common) // the panel runs the modal mode
        watch = timer
        printerMayHaveChanged()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        watch?.invalidate()
        watch = nil
        lookupTask?.cancel()
        watchedPrinter = nil // its check was cut short: shown again, the panel's printer is checked again
    }

    private var panelPrinter: String? {
        testPrinterName ?? (representedObject as? NSPrintInfo)?.printer.name ?? NSPrintOperation.current?.printInfo.printer.name
    }

    private func printerMayHaveChanged() {
        let name = panelPrinter
        guard name != watchedPrinter else { return }
        watchedPrinter = name
        lookupTask?.cancel()
        show(nil)
        guard let name else { return }
        lookupTask = Task { [weak self] in await self?.checkPrinter(name) }
    }

    /// Checks `name` (the panel's printer) and shows its line, unless another printer was chosen meanwhile.
    func checkPrinter(_ name: String) async {
        let found = await lookup.check(printerName: name)
        guard !Task.isCancelled, panelPrinter == name else { return }
        show(found)
    }

    private func show(_ found: PrinterStatusLookup.Found?) {
        guard let found, let health = found.health else {
            printerStatus.stringValue = ""
            showRows()
            return
        }
        if health.shouldWarn {
            printerStatus.stringValue = "⚠︎ \(PrinterCheck.problem(health, found.printer.name)). \(PrinterCheck.advice(health))"
            printerStatus.textColor = .systemRed
        } else {
            printerStatus.stringValue = PrinterCheck.line(health, found.printer.name)
            printerStatus.textColor = .secondaryLabelColor
        }
        showRows()
        if health.shouldWarn {
            NSAccessibility.post(element: printerStatus, notification: .announcementRequested,
                                 userInfo: [.announcement: printerStatus.stringValue])
        }
    }

    @objc private func openPrinterSettings() { InkvoltPrintApp.open(from: view.window) }

    private func syncFromOptions() {
        let s = options.setup
        switch s.handling {
        case .fit: handling.selectItem(at: 0)
        case .pagesPerSheet: handling.selectItem(at: 1)
        case .booklet: handling.selectItem(at: 2)
        case .poster: handling.selectItem(at: 3)
        }
        sizing.selectItem(at: s.sizing == .fitToPaper ? 1 : 0)
        perSheet.selectItem(at: PrintSetup.pagesPerSheetChoices.firstIndex(of: s.pagesPerSheet) ?? 0)
        order.selectItem(at: s.order == .down ? 1 : 0)
        borders.state = s.borders ? .on : .off
        binding.selectItem(at: s.rightBinding ? 1 : 0)
        posterScale.selectItem(at: Self.scales.firstIndex(of: s.posterScale) ?? 1)
        overlap.selectItem(at: Self.overlaps.firstIndex(of: s.overlap) ?? 0)
        cutMarks.state = s.cutMarks ? .on : .off
        showRows()
    }

    @objc private func changed() {
        var s = PrintSetup()
        s.handling = [PrintHandling.fit, .pagesPerSheet, .booklet, .poster][max(handling.indexOfSelectedItem, 0)]
        s.sizing = sizing.indexOfSelectedItem == 1 ? .fitToPaper : .actualSize
        s.pagesPerSheet = PrintSetup.pagesPerSheetChoices[max(perSheet.indexOfSelectedItem, 0)]
        s.order = order.indexOfSelectedItem == 1 ? .down : .across
        s.borders = borders.state == .on
        s.rightBinding = binding.indexOfSelectedItem == 1
        s.posterScale = Self.scales[max(posterScale.indexOfSelectedItem, 0)]
        s.overlap = Self.overlaps[max(overlap.indexOfSelectedItem, 0)]
        s.cutMarks = cutMarks.state == .on
        options.setup = s
        options.range = range.stringValue
        rangeNote.stringValue = options.rangeError.map { loc("{0} All pages will print.", $0) } ?? ""
        showRows()
        revision += 1 // the panel redraws its preview
    }

    nonisolated func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        MainActor.assumeIsolated {
            let pages = options.range.trimmingCharacters(in: .whitespaces).isEmpty ? loc("All", context: "pages") : options.range
            return [
                [.itemName: loc("Pages"), .itemDescription: pages],
                [.itemName: loc("Layout"), .itemDescription: handling.titleOfSelectedItem ?? ""],

            ]
        }
    }

    nonisolated func keyPathsForValuesAffectingPreview() -> Set<String> { ["revision"] }
}
