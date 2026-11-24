import Foundation

/// What a print asks for. Nil paper, color, quality or type: the printer's default.
public struct DirectPrintRequest: Equatable, Sendable {
    public var copies: Int
    public var twoSided: Bool
    /// A paper by its PWG name (`DirectPaper.name`), else by `paperInches`, else the printer's default.
    public var paperName: String?
    /// A paper by size (portrait or landscape), matched within 2 mm.
    public var paperInches: (width: Double, height: Double)?
    public var borderless = false
    /// True color, false black and grey, nil the printer's default.
    public var color: Bool?
    /// 3 draft, 4 normal, 5 high; nil the printer's default.
    public var quality: Int?
    /// A `media-type` keyword.
    public var mediaType: String?
    /// Only this raster format (a check sends each one to a test printer); nil: the first the printer takes.
    public var format: RasterFormat?

    public init(copies: Int = 1, twoSided: Bool = false) {
        (self.copies, self.twoSided) = (copies, twoSided)
    }

    public static func == (a: DirectPrintRequest, b: DirectPrintRequest) -> Bool {
        a.copies == b.copies && a.twoSided == b.twoSided && a.paperName == b.paperName && a.paperInches?.width == b.paperInches?.width
            && a.paperInches?.height == b.paperInches?.height && a.borderless == b.borderless && a.color == b.color && a.quality == b.quality
            && a.mediaType == b.mediaType && a.format == b.format
    }
}

/// How one job goes to a printer with no driver: the raster format (PWG raster first, then Apple raster, then PCLm, the first
/// the printer both lists and says how to make), its resolution (300 dpi when offered; else the nearest above, drawn at 300
/// and enlarged when it is a multiple), color, the paper with its margins, two-sided and how the back is turned, and copies
/// (the printer's when it makes enough and collates them, else the pages are sent again). `choose` never changes what was
/// asked quietly: a setting the printer can't keep is a problem, and nothing is sent.
public struct DirectPrintPlan: Equatable, Sendable {
    public static let preferredDpi = 300

    public var format: RasterFormat
    public var dpi: Int
    public var color: RasterColor
    public var paper: DirectPaper
    public var twoSided = false
    public var back: BackSide = .normal
    /// The `copies` attribute sent (1: not sent).
    public var copies = 1
    /// How many times the pages go in the document: copies the printer doesn't make itself.
    public var repeatCount = 1
    /// The `print-color-mode` keyword sent, or nil.
    public var colorMode: String?
    /// Sent as RGB but drawn grey: the person asked for grey and the format takes only color.
    public var grey = false
    public var quality: Int?
    public var mediaType: String?
    public var stripHeight = 16
    public var runLength = false

    public init(_ format: RasterFormat, dpi: Int, color: RasterColor, paper: DirectPaper) {
        (self.format, self.dpi, self.color, self.paper) = (format, dpi, color, paper)
    }

    /// The resolution the pages are drawn at; `enlarge` makes it `dpi`.
    public var renderDpi: Int { dpi % Self.preferredDpi == 0 && (1...8).contains(dpi / Self.preferredDpi) ? Self.preferredDpi : dpi }

    public var enlarge: Int { dpi / renderDpi }

    public var documentFormat: String {
        switch format {
        case .pwgRaster: IppPrintCaps.pwgRasterType
        case .urf: IppPrintCaps.urfType
        case .pclm: IppPrintCaps.pclmType
        }
    }

    /// The raster job for `pages` pages (one copy's worth, times `repeatCount`).
    public func job(_ pages: Int) -> RasterJob {
        var j = RasterJob(format, dpi: dpi, color: color, mediaName: paper.name, widthHmm: paper.widthHmm, heightHmm: paper.heightHmm,
                          pages: pages * repeatCount)
        (j.duplex, j.back, j.quality, j.mediaType, j.stripHeight, j.runLength) = (twoSided, back, quality ?? 0, mediaType, stripHeight, runLength)
        return j
    }

    /// Pages in the document for `pages` pages of one copy: a two-sided copy with an odd count gets a blank back, so the next
    /// copy starts on a new sheet.
    public func pagesPerCopy(_ pages: Int) -> Int { twoSided && repeatCount > 1 && pages % 2 == 1 ? pages + 1 : pages }

    /// The sides the printer prints for `pages` pages, as "page N of M" counts them (Windows' `PagesPerCopy(pages) * Repeat *
    /// Copies`): a blank back between copies sent again included, the copies the printer makes too.
    public func impressions(_ pages: Int) -> Int { pagesPerCopy(pages) * repeatCount * copies }

    /// The plan, or the reason in plain words why this printer can't print the request without a driver.
    public static func choose(_ caps: IppPrintCaps, _ request: DirectPrintRequest) -> Result<DirectPrintPlan, DirectPrintProblem> {
        guard caps.canPrint else { return .failure(.noFormat) }
        if request.twoSided && !caps.twoSided { return .failure(.notTwoSided) }
        guard (1...999).contains(request.copies) else { return .failure(.copies) }
        guard let paper = choosePaper(caps, request) else { return .failure(.noPaper) }
        if let quality = request.quality, !caps.qualities.contains(quality) { return .failure(.noQuality) }
        if let type = request.mediaType, !caps.mediaTypes.contains(type) { return .failure(.noMediaType) }
        let wantColor = request.color ?? caps.colorByDefault
        for format in caps.formats where request.format == nil || format == request.format {
            let colors: [RasterColor], dpis: [Int], back: BackSide
            switch format {
            case .pwgRaster: (colors, dpis, back) = (caps.pwgColors, caps.pwgDpis, caps.pwgBack)
            case .urf: (colors, dpis, back) = (caps.urfColors, caps.urfDpis, caps.urfBack)
            case .pclm: (colors, dpis, back) = ([.gray8, .rgb8], caps.pclmDpis, caps.pclmBack)
            }
            let color: RasterColor?
            if wantColor && caps.color && colors.contains(.rgb8) { color = .rgb8 }
            else if colors.contains(.gray8) { color = .gray8 }
            else if colors.contains(.rgb8) { color = .rgb8 }
            else { color = nil }
            guard let color, let dpi = chooseDpi(dpis) else { continue }
            // Grey asked for (or a printer that prints only black) on a format that takes only RGB: the pages are made grey here.
            let grey = color == .rgb8 && !(wantColor && caps.color)
            // The printer makes the copies only when it collates them; else the pages go again, a copy at a time.
            let printerCopies = request.copies <= caps.maxCopies && (request.copies == 1 || caps.collatedCopies)
            var plan = DirectPrintPlan(format, dpi: dpi, color: color, paper: paper)
            (plan.twoSided, plan.back) = (request.twoSided, back)
            (plan.copies, plan.repeatCount) = printerCopies ? (request.copies, 1) : (1, request.copies)
            plan.grey = grey
            plan.colorMode = caps.color ? (color == .rgb8 && !grey ? "color" : "monochrome") : nil
            (plan.quality, plan.mediaType) = (request.quality, request.mediaType)
            (plan.stripHeight, plan.runLength) = (caps.pclmStripHeight, caps.pclmRunLength)
            return .success(plan)
        }
        return .failure(.noFormat)
    }

    /// 300 when offered, else the lowest above it, else the highest below it.
    static func chooseDpi(_ offered: [Int]) -> Int? {
        guard let highest = offered.max() else { return nil }
        if offered.contains(preferredDpi) { return preferredDpi }
        return offered.filter { $0 > preferredDpi }.min() ?? highest
    }

    private static func choosePaper(_ caps: IppPrintCaps, _ request: DirectPrintRequest) -> DirectPaper? {
        let candidates: [DirectPaper]
        if let name = request.paperName {
            candidates = caps.papers.filter { $0.name == name }
        } else if let inches = request.paperInches {
            let w = (min(inches.width, inches.height) * 2540).rounded(.toNearestOrEven).clampedInt
            let h = (max(inches.width, inches.height) * 2540).rounded(.toNearestOrEven).clampedInt
            candidates = caps.papers.filter { abs($0.widthHmm - w) <= 200 && abs($0.heightHmm - h) <= 200 }
        } else if let d = caps.defaultPaper {
            candidates = [d] + caps.papers.filter { IppPrintCaps.same($0, d) }
        } else {
            candidates = caps.papers.filter { $0.name == "na_letter_8.5x11in" || $0.name == "iso_a4_210x297mm" } + caps.papers
        }
        if request.borderless { return candidates.first { $0.borderless } }
        let defaultSource = caps.defaultPaper?.source
        let bordered = candidates.filter { !$0.borderless }
        return bordered.first { $0.source == defaultSource } ?? bordered.first ?? candidates.first
    }
}

/// Why a print can't go straight to the printer, said before anything is drawn or sent (Windows' `CoreStrings.Direct_*`).
public enum DirectPrintProblem: Error, Equatable, Sendable {
    case noFormat, notTwoSided, copies, noPaper, noQuality, noMediaType

    public var message: String {
        switch self {
        case .noFormat: loc("This printer takes none of the formats Inkvolt Print sends without a driver (PWG raster, Apple raster, PCLm).")
        case .notTwoSided: loc("This printer doesn't print on both sides. Turn two-sided off and print again.")
        case .copies: loc("Copies must be between 1 and 999.")
        case .noPaper: loc("The printer doesn't offer that paper. Choose another paper size.")
        case .noQuality: loc("The printer doesn't offer that print quality. Choose another one.")
        case .noMediaType: loc("The printer doesn't take that paper type. Choose another one.")
        }
    }
}
