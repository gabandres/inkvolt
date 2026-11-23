import AppKit
import ApplicationServices
import PDFKit
import PrintCore

/// Print a PDF's layouts (roadmap 4.18): several pages per sheet (2, 4, 6, 9, 16), a booklet (saddle-stitch order, both
/// sides) or a poster (150 to 400 % over overlapping sheets with cut marks), laid out by PrintCore's `SheetPrint` and drawn
/// here, each page as vectors (PDFKit draws it, annotations included) into its place on the sheet. The Windows app's
/// SheetPrinting. Mac differences: copies and two-sided are the print panel's (macOS makes the copies; Windows makes each
/// copy itself so it starts on a sheet of its own), a booklet asks the panel for two-sided on the long edge, and backs are
/// drawn half-turned only when the job prints on the long edge (on the short edge they need no turn); no two-sided by
/// hand, so a booklet on a printer that can't print both sides is refused.
@MainActor
final class SheetPrintView: NSView {
    let document: PDFDocument
    let choice: SheetChoice
    private let setup: Sheets.PrintSetup
    /// Each page's size as shown (rotation applied), in DIPs (`SheetPrint`'s unit), brought within `SheetPrint.maxPageSide`.
    private let sizes: [(Double, Double)]
    private let fallbackInfo: NSPrintInfo
    private(set) var plan: Sheets.PrintPlan
    /// The paper in points (AppKit's) and in DIPs (the plan's).
    private var paper = NSSize(width: 612, height: 792)
    private var paperUnits = (816.0, 1056.0)

    init(document: PDFDocument, choice: SheetChoice, setup: Sheets.PrintSetup, info: NSPrintInfo) {
        self.document = document
        self.choice = choice
        self.setup = setup
        fallbackInfo = info
        sizes = Self.sizes(document).map(SheetPrint.bounded)
        plan = SheetPrint.plan(sizes, 816, 1056, setup)
        super.init(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        layOut()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    /// Each page's size as shown (its crop box, turned by its rotation), in DIPs.
    static func sizes(_ document: PDFDocument) -> [(Double, Double)] {
        (0..<document.pageCount).map { i in
            guard let page = document.page(at: i) else { return (816, 1056) }
            let box = page.bounds(for: .cropBox)
            let turned = (page.rotation / 90) % 2 != 0
            let (w, h) = turned ? (box.height, box.width) : (box.width, box.height)
            return (Double(w) / SheetPrint.pointsPerUnit, Double(h) / SheetPrint.pointsPerUnit)
        }
    }

    /// The plan for the paper chosen now (the panel's paper and orientation can change at any time).
    func layOut() {
        let info = NSPrintOperation.current?.printInfo ?? fallbackInfo
        paper = info.paperSize
        paperUnits = (Double(paper.width) / SheetPrint.pointsPerUnit, Double(paper.height) / SheetPrint.pointsPerUnit)
        plan = SheetPrint.plan(sizes, paperUnits.0, paperUnits.1, setup)
        setFrameSize(NSSize(width: paper.width, height: paper.height * CGFloat(max(plan.sheetCount, 1))))
    }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        layOut()
        range.pointee = NSRange(location: 1, length: max(plan.sheetCount, 1))
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * paper.height, width: paper.width, height: paper.height)
    }

    /// Whether the job prints on both sides flipping on the long edge, as the panel says now: backs of a turned sheet are
    /// then drawn half-turned (`SheetPrint.halfTurned`).
    private var longEdge: Bool {
        let info = NSPrintOperation.current?.printInfo ?? fallbackInfo
        var mode = PMDuplexMode(kPMDuplexNone)
        guard PMGetDuplex(OpaquePointer(info.pmPrintSettings()), &mode) == noErr else { return false }
        return mode == PMDuplexMode(kPMDuplexNoTumble)
    }

    override func draw(_ dirtyRect: NSRect) {
        let index = Int((dirtyRect.midY / max(paper.height, 1)).rounded(.down)) // bounded: AppKit's rectangle in the view, over at least 1
        guard index >= 0, index < plan.sheetCount, let cg = NSGraphicsContext.current?.cgContext else { return }
        let sheet = plan.sheet(index)
        let half = SheetPrint.halfTurned(sheet, index, twoSided: longEdge)
        // The sheet's DIPs (origin at the paper's top left, y down) to the view's points, turned a half on a back that needs it.
        var toView = CGAffineTransform.identity
        if half { toView = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: paperUnits.0, ty: paperUnits.1) }
        toView = toView.concatenating(CGAffineTransform(a: SheetPrint.pointsPerUnit, b: 0, c: 0, d: SheetPrint.pointsPerUnit,
                                                        tx: 0, ty: CGFloat(index) * paper.height))
        for placed in sheet.pages where placed.page >= 0 && placed.page < sizes.count {
            draw(placed, toView, cg)
        }
        if !sheet.marks.isEmpty {
            cg.saveGState()
            cg.setStrokeColor(NSColor.black.cgColor)
            cg.setLineWidth(0.5)
            for m in sheet.marks {
                cg.move(to: CGPoint(x: m.x1, y: m.y1).applying(toView))
                cg.addLine(to: CGPoint(x: m.x2, y: m.y2).applying(toView))
            }
            cg.strokePath()
            cg.restoreGState()
        }
    }

    /// One page (or a poster's part of one) in its box: the page's own space (its crop box, rotation applied by PDFKit's
    /// transform) to its shown size from the top left, then to the box (`toSheet`), then to the view; clipped to the box.
    private func draw(_ placed: Sheets.PlacedPage, _ toView: CGAffineTransform, _ cg: CGContext) {
        guard let page = document.page(at: placed.page) else { return }
        let (w, h) = sizes[placed.page]
        let box = page.bounds(for: .cropBox)
        let turned = (page.rotation / 90) % 2 != 0
        let (ptW, ptH) = turned ? (Double(box.height), Double(box.width)) : (Double(box.width), Double(box.height))
        guard ptW > 0, ptH > 0 else { return }
        // PDFKit draws the page turned by its /Rotate itself (`draw(with:to:)`; `transform(_:for:)` as well turned a
        // rotated page twice, off the sheet: checked on the build Mac), into its shown size from the bottom left, y up.
        let fromPage = CGAffineTransform(a: w / ptW, b: 0, c: 0, d: -h / ptH, tx: 0, ty: h)
        let onSheet = fromPage.concatenating(Self.toSheet(placed, w, h)).concatenating(toView)
        let clip = CGRect(x: placed.box.x, y: placed.box.y, width: placed.box.width, height: placed.box.height).applying(toView)
        cg.saveGState()
        cg.clip(to: clip)
        cg.concatenate(onSheet)
        page.draw(with: .cropBox, to: cg)
        cg.restoreGState()
    }

    /// A page's shown space (DIPs from its top left, `w` × `h`) to its box on the sheet: the part `source` shows, scaled to
    /// the box, a quarter turn clockwise when the layout turns it (the box's width is then the source's height).
    static func toSheet(_ placed: Sheets.PlacedPage, _ w: Double, _ h: Double) -> CGAffineTransform {
        let source = placed.source ?? Placement(0, 0, w, h)
        let box = placed.box
        let turned = placed.turns % 2 == 1
        let drawnW = turned ? box.height : box.width, drawnH = turned ? box.width : box.height
        let sx = source.width > 0 ? drawnW / source.width : 0
        let sy = source.height > 0 ? drawnH / source.height : 0
        if !turned { return CGAffineTransform(a: sx, b: 0, c: 0, d: sy, tx: box.x - source.x * sx, ty: box.y - source.y * sy) }
        return CGAffineTransform(a: 0, b: sx, c: -sy, d: 0, tx: box.x + drawnH + source.y * sy, ty: box.y - source.x * sx)
    }
}

/// Print a PDF's Layout choice, in the open panel where the PDF is picked (an accessory under the file list).
@MainActor
final class SheetChoiceView: NSView {
    private let layout = NSPopUpButton()
    private let perSheet = NSPopUpButton()
    private let poster = NSPopUpButton()
    private let cutMarks = NSButton(checkboxWithTitle: String(localized: "Cut marks"), target: nil, action: nil)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 34))
        layout.addItems(withTitles: [String(localized: "One page per sheet"), String(localized: "Several pages per sheet"),
                                     String(localized: "Booklet"), String(localized: "Poster")])
        perSheet.addItems(withTitles: Sheets.PrintSetup.pagesPerSheetChoices.map { String(localized: "\($0) pages per sheet") })
        poster.addItems(withTitles: SheetPrint.posterPercents.map { "\($0) %" })
        poster.selectItem(at: SheetPrint.posterPercents.firstIndex(of: 200) ?? 0)
        cutMarks.state = .on
        for control in [layout, perSheet, poster] {
            control.target = self
            control.action = #selector(changed)
        }
        let label = NSTextField(labelWithString: String(localized: "Layout:"))
        let row = NSStackView(views: [label, layout, perSheet, poster, cutMarks])
        row.orientation = .horizontal
        row.spacing = 8
        row.frame = bounds.insetBy(dx: 12, dy: 4)
        row.autoresizingMask = [.width, .height]
        addSubview(row)
        changed()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func changed() {
        let kind = PdfLayout.allCases[max(0, layout.indexOfSelectedItem)]
        perSheet.isHidden = kind != .pagesPerSheet
        poster.isHidden = kind != .poster
        cutMarks.isHidden = kind != .poster
    }

    var choice: SheetChoice {
        SheetChoice(PdfLayout.allCases[max(0, layout.indexOfSelectedItem)],
                    pagesPerSheet: Sheets.PrintSetup.pagesPerSheetChoices[max(0, perSheet.indexOfSelectedItem)],
                    posterPercent: SheetPrint.posterPercents[max(0, poster.indexOfSelectedItem)], cutMarks: cutMarks.state == .on)
    }
}

extension Printing {
    /// Why a laid-out job can't print as chosen (nil: it can): too many sheets (`SheetPrint.tooMany`, counted on Letter or
    /// A4 by region), or a booklet on a queue that prints one side only (no two-sided by hand on the Mac).
    static func sheetProblem(_ setup: Sheets.PrintSetup, _ document: PDFDocument, bothSides: Bool?) -> String? {
        let paper = SheetPrint.guessPaper(metric: Locale.current.measurementSystem == .metric)
        if SheetPrint.tooMany(setup, SheetPrintView.sizes(document), (paper.width, paper.height), copies: 1) {
            return String(localized: "Not printed: this layout would take more than \(SheetPrint.maxSides) sheets. Choose fewer pages or a smaller poster.")
        }
        if SheetPrint.route(setup, asked: false, printerTwoSided: bothSides ?? true, byHand: false) == .noBothSides {
            return String(localized: "Not printed: a booklet prints on both sides, and this printer's queue says it prints one side only. Choose another layout, or another printer.")
        }
        return nil
    }

    /// The laid-out job: the print panel over `SheetPrintView`, on the printer's queue when it has one; a booklet asks for
    /// two-sided on the long edge (the panel can change it). `save`: written to that PDF instead (the report's checks).
    @discardableResult
    static func printSheets(_ document: PDFDocument, choice: SheetChoice, name: String, on printer: PrinterModel?, app: AppModel?,
                            save: URL? = nil) -> SheetPrintView? {
        guard let setup = SheetPrint.setup(choice) else { return nil }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        if let printer, let app, let target = macPrinter(for: printer, app: app) { info.printer = target }
        (info.topMargin, info.bottomMargin, info.leftMargin, info.rightMargin) = (0, 0, 0, 0) // the layout keeps its own ¼ in
        info.horizontalPagination = .clip
        info.verticalPagination = .clip
        info.orientation = .portrait
        if SheetPrint.twoSided(setup, asked: false) {
            PMSetDuplex(OpaquePointer(info.pmPrintSettings()), PMDuplexMode(kPMDuplexNoTumble))
            info.updateFromPMPrintSettings()
        }
        if let save {
            info.jobDisposition = .save
            info.dictionary().setObject(save, forKey: NSPrintInfo.AttributeKey.jobSavingURL.rawValue as NSString)
        } else {
            info.jobDisposition = .spool
        }
        let view = SheetPrintView(document: document, choice: choice, setup: setup, info: info)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = name
        operation.showsPrintPanel = save == nil
        operation.showsProgressPanel = save == nil
        operation.printPanel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize, .showsPreview])
        operation.run()
        return view
    }
}

extension Report {
    /// `--pdf-layout` (roadmap 4.18): an 8-page sample PDF laid out four to a sheet, as a booklet and as a 200 % poster, each
    /// written through `SheetPrintView`'s own print path to a PDF in the container (never a printer): its sheets, and where
    /// PDFKit finds the pages' own words on each of the first sheets (left or right half, top or bottom, upright or not),
    /// so the order and the turns are seen from the paper as it would print.
    static func pdfLayoutCheck() -> [String] {
        guard let document = PDFDocument(data: Data(BatchPrintSamples.pdf(8, "Sample"))) else { return ["pdf layout: no sample"] }
        let folder = AppModel.dataFolder.appendingPathComponent("pdf-layout", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var lines = ["pdf layout:"]
        for (name, choice) in [("sheet-4", SheetChoice(.pagesPerSheet, pagesPerSheet: 4)), ("booklet", SheetChoice(.booklet)),
                               ("poster-200", SheetChoice(.poster, posterPercent: 200))] {
            let url = folder.appendingPathComponent("\(name).pdf")
            try? FileManager.default.removeItem(at: url)
            let view = Printing.printSheets(document, choice: choice, name: name, on: nil, app: nil, save: url)
            guard let printed = PDFDocument(url: url) else {
                lines.append("  \(name): nothing written (plan \(view?.plan.sheetCount ?? -1) sheets)")
                continue
            }
            lines.append("  \(name): \(printed.pageCount) sheets (plan \(view?.plan.sheetCount ?? -1)), problem: \(Printing.sheetProblem(SheetPrint.setup(choice)!, document, bothSides: nil) ?? "none")")
            for s in 0..<min(printed.pageCount, 2) {
                guard let sheet = printed.page(at: s) else { continue }
                let bounds = sheet.bounds(for: .mediaBox)
                var found: [String] = []
                for n in 1...8 {
                    for hit in printed.findString("page \(n)", withOptions: []) where hit.pages.first == sheet {
                        let b = hit.bounds(for: sheet)
                        let side = b.midX < bounds.midX ? "left" : "right", height = b.midY > bounds.midY ? "top" : "bottom"
                        found.append("\(n) \(side)-\(height)\(b.height > b.width ? " turned" : "")")
                    }
                }
                lines.append("    sheet \(s + 1): \(found.isEmpty ? "no page words" : found.joined(separator: ", "))")
            }
        }
        return lines
    }
}
