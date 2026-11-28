import Foundation
import PrintCore

/// How Recognize Text reads a page (the Windows app's `RecognizeOptions`). `clean`: straighten, turn upright, despeckle
/// and whiten the page image first (`ScanCleanup`). `checkWords`: mark suspect words (`SuspectWords`), which reads the page
/// a second time as scanned to compare. `keepCleanedImage`: return the cleaned page to put in the document in place of the
/// scan (the user's choice, off by default); the words then fit the cleaned page. `trapezoid` and `curvedLines` (with
/// `clean`; roadmap 2.2): a page photographed at an angle is warped back to a rectangle, and lines bent by a book's spine
/// are flattened, each only when the page shows it clearly (`ScanCleanup.clean`'s `CleanupSteps`).
public struct RecognizeOptions: Equatable, Sendable {
    public var clean: Bool
    public var checkWords: Bool
    public var keepCleanedImage: Bool
    public var trapezoid: Bool
    public var curvedLines: Bool

    public init(clean: Bool = true, checkWords: Bool = true, keepCleanedImage: Bool = false, trapezoid: Bool = false, curvedLines: Bool = false) {
        self.clean = clean
        self.checkWords = checkWords
        self.keepCleanedImage = keepCleanedImage
        self.trapezoid = trapezoid
        self.curvedLines = curvedLines
    }

    /// The cleanup's further steps these options ask for.
    public var steps: CleanupSteps {
        var steps: CleanupSteps = []
        if trapezoid { steps.insert(.trapezoid) }
        if curvedLines { steps.insert(.curvedLines) }
        return steps
    }

    /// As Recognize Text read pages before 2.2: the page as rendered, no cleaning, no suspect words.
    public static let asScanned = RecognizeOptions(clean: false, checkWords: false)
}

/// A cleaned page to write into the document (`ScanPage.writeBack`): straightened, despeckled and whitened, in the page's
/// displayed orientation, and the quarter turns clockwise that then set the page upright. `deflated`: the pixels as the
/// PDF's image stream will hold them (rows of `width` × `channels` bytes, 1 = grey, 3 = RGB, zlib-compressed), so many
/// pages waiting to be written take what they will take in the file, not 25 MB each.
public struct CleanedPageImage: Equatable, Sendable {
    public let width: Int, height: Int, channels: Int
    public let deflated: [UInt8]
    public let quarterTurns: Int

    /// A cleaned page from its raw pixels (grey, or RGB as rendered).
    public static func from(_ width: Int, _ height: Int, _ channels: Int, _ pixels: [UInt8], _ quarterTurns: Int) -> CleanedPageImage {
        CleanedPageImage(width: width, height: height, channels: channels, deflated: Deflate.zlib(pixels), quarterTurns: quarterTurns)
    }
}

/// A recognized page: its words in page space (points from the top-left of the displayed page, each box turned by its
/// word's angle about its centre), how far the page was skewed (degrees clockwise) and how many quarter turns set it
/// upright, and the cleaned image when it was asked for. With a cleaned image, the words are placed for the page as it
/// will be after `ScanPage.writeBack` (straight and upright).
public struct RecognizedPage: Sendable {
    public var words: [OcrWord]
    public var skew: Double
    public var quarterTurns: Int
    public var cleaned: CleanedPageImage?
}

/// Text recognition of one page, engine-neutral (the Windows app's `ScanText`): render the page at 300 dpi, clean it,
/// hand it to a `TextRecognizer`, and map its words back onto the page (through the straightening and the quarter
/// turns), then mark suspect words. The engine is Vision on the Mac (`VisionRecognizer`), Windows' own there.
public enum ScanText {
    public static let dpi = 300.0

    /// - Throws: `CancellationError` when `cancel` fires; the recognizer's and the engine's errors.
    public static func recognize(_ pdf: PdfEngine, _ page: Int, _ recognizer: some TextRecognizer, _ options: RecognizeOptions,
                                 spelling: (any Spelling)? = nil, cancel: CancelToken? = nil) throws -> RecognizedPage {
        let g = pdf.page(page)
        let scale = PageOcr.scale(g)
        // A page kept as its cleaned image keeps its comments as comments, so they're left out of the picture.
        let image = try pdf.render(page, scale: scale, cancel: cancel, annotations: !options.keepCleanedImage)
        guard image.width > 0, image.height > 0 else { return RecognizedPage(words: [], skew: 0, quarterTurns: 0, cleaned: nil) }
        let dpi = Int((scale * 72).rounded(.toNearestOrEven)) // bounded: PageOcr.scale is 0 to 300 dpi's
        // Points per pixel, each way (the rendered size is rounded).
        let (sx, sy) = (g.width / Double(image.width), g.height / Double(image.height))
        func inPoints(_ w: OcrWord) -> OcrWord { OcrWord(w.text, RectD(w.rect.x * sx, w.rect.y * sy, w.rect.width * sx, w.rect.height * sy)) }
        func asScanned() throws -> [RecognizedWord] { try recognizer.read(image, cancel: cancel) }
        // Which words the engine itself wasn't sure of (roadmap 2.2's unsure words).
        func unsure(_ read: [RecognizedWord]) -> [Bool] { read.map { ($0.confidence ?? .infinity) < recognizer.unsureBelow } }

        if !options.clean {
            let read = try asScanned()
            let plain = read.map { inPoints($0.word) }
            return RecognizedPage(words: options.checkWords ? mark(plain, nil, unsure(read), spelling) : plain, skew: 0, quarterTurns: 0, cleaned: nil)
        }

        let color = options.keepCleanedImage && isColor(image.pixels)
        let cleaned = try ScanCleanup.clean(image.pixels, image.width, image.height, 3, dpi, keepColor: color, cancel: cancel, steps: options.steps)
        var (turns, gray, rgb) = (cleaned.quarterTurns, cleaned.gray, cleaned.rgb)
        var found = try recognizer.read(asImage(gray), cancel: cancel)
        if !cleaned.uprightSure {
            // The lines didn't say which way up: read it the other way too. The page is turned over only when the turned
            // reading has clearly more real words; otherwise it stays as rendered, whatever the ink hinted. Digits read
            // plausibly both ways (6 and 9, 0 and 8: the redaction corpus's page of numbers read "OO 6830 9999" turned),
            // and count as words neither way, so a page of numbers isn't turned on a guess.
            let other = GrayImage(gray.width, gray.height, ScanCleanup.turn(gray.pixels, gray.width, gray.height, 1, 2))
            let otherFound = try recognizer.read(asImage(other), cancel: cancel)
            let hinted = (cleaned.quarterTurns & 2) != 0
            let (asRendered, turnedOver) = hinted ? (otherFound, found) : (found, otherFound)
            if clearlyMore(plausible(turnedOver.map(\.word), spelling), plausible(asRendered.map(\.word), spelling)) != hinted {
                (found, turns) = (otherFound, (turns + 2) % 4)
                gray = other
                if let c = rgb { rgb = ScanCleanup.turn(c, gray.width, gray.height, 3, 2) }
            }
        }

        let frame = ScanFrame(width: image.width, height: image.height, skew: cleaned.skew, quarterTurns: turns,
                              perspective: cleaned.perspective, curve: cleaned.curve)
        let onScan = found.map { frame.toRendered($0.word, sx, sy) }
        var words = options.keepCleanedImage ? found.map { inPoints($0.word) } : onScan
        // A page that wasn't upright as scanned can't be read as scanned: nothing to compare with. Windows doesn't ask an
        // engine that gives each word a confidence twice (Tesseract); Vision's confidence is a line's, and on the OCR corpus
        // every line's was 1.0, wrong words too (VisionProbeTests), so the Mac compares as before and marks unsure words too.
        if options.checkWords {
            let scanned = turns == 0 ? try asScanned().map { inPoints($0.word) } : nil
            words = mark(words, scanned.map { SuspectWords.readDifferently(onScan, $0, spelling) }, unsure(found), spelling)
        }

        var keep: CleanedPageImage?
        if options.keepCleanedImage {
            // Stored in the page's own orientation; the page's /Rotate then turns it upright.
            let (w, h) = turns % 2 == 0 ? (gray.width, gray.height) : (gray.height, gray.width)
            keep = rgb.map { CleanedPageImage.from(w, h, 3, ScanCleanup.turn($0, gray.width, gray.height, 3, -turns), turns) }
                ?? CleanedPageImage.from(w, h, 1, ScanCleanup.turn(gray.pixels, gray.width, gray.height, 1, -turns), turns)
        }
        return RecognizedPage(words: words, skew: cleaned.skew, quarterTurns: turns, cleaned: keep)
    }

    /// The grey page as the RGB image a recognizer takes.
    private static func asImage(_ gray: GrayImage) -> RenderedImage {
        var rgb = [UInt8](repeating: 0, count: gray.pixels.count * 3)
        gray.pixels.withUnsafeBufferPointer { src in
            rgb.withUnsafeMutableBufferPointer { dst in
                for i in 0..<src.count {
                    let v = src[i]
                    dst[i * 3] = v
                    dst[i * 3 + 1] = v
                    dst[i * 3 + 2] = v
                }
            }
        }
        return RenderedImage(gray.width, gray.height, rgb)
    }

    private static func mark(_ words: [OcrWord], _ readDifferently: [Bool]?, _ unsure: [Bool], _ spelling: (any Spelling)?) -> [OcrWord] {
        var words = words
        for i in words.indices {
            var reasons = SuspectWords.check(words[i].text, spelling)
            if let readDifferently, readDifferently[i] { reasons.insert(.readDifferently) }
            if i < unsure.count && unsure[i] { reasons.insert(.unsure) }
            if !reasons.isEmpty { words[i].suspect = reasons }
        }
        return words
    }

    /// Whether a reading with `more` real words beats one with `fewer` by a margin: two words, or a quarter more.
    static func clearlyMore(_ more: Int, _ fewer: Int) -> Bool { more >= fewer + max(2, (fewer + 3) / 4) }

    /// How much of a reading looks like real words: dictionary words, or without a dictionary, words of three letters or more.
    private static func plausible(_ words: [OcrWord], _ spelling: (any Spelling)?) -> Int {
        words.map { SuspectWords.core($0.text) }.filter { c in c.count >= 3 && c.allSatisfy(\.isLetter) && (spelling?.isKnown(c) ?? true) }.count
    }

    /// Whether an RGB page has colour worth keeping (more than a trace of pixels whose channels differ).
    public static func isColor(_ rgb: [UInt8]) -> Bool {
        var colored = 0, sampled = 0
        var i = 0
        while i + 2 < rgb.count {
            let (r, g, b) = (Int(rgb[i]), Int(rgb[i + 1]), Int(rgb[i + 2]))
            if max(r, g, b) - min(r, g, b) > 32 { colored += 1 }
            sampled += 1
            i += 3 * 7
        }
        return colored > sampled / 500
    }
}

/// Where a point of the cleaned page image was on the page as rendered (the Windows app's `ScanFrame`): the cleaned image
/// is the rendered one (`width` × `height` px), its photographed page warped to a rectangle (`perspective`, when there was
/// one), straightened by `skew` degrees (rotated anticlockwise by that much about its centre, same size), its bent lines
/// flattened (`curve`) and then turned `quarterTurns` quarters clockwise. Turning and straightening are both about the
/// centre, so going back is turning back, unbending, rotating by the skew, then mapping into the photo.
public struct ScanFrame: Sendable, Equatable {
    public var width: Int, height: Int
    public var skew: Double
    public var quarterTurns: Int
    public var perspective: Perspective?
    public var curve: LineCurve?

    public init(width: Int, height: Int, skew: Double, quarterTurns: Int, perspective: Perspective? = nil, curve: LineCurve? = nil) {
        self.width = width
        self.height = height
        self.skew = skew
        self.quarterTurns = quarterTurns
        self.perspective = perspective
        self.curve = curve
    }

    /// The angle (degrees clockwise) at which text that is level in the cleaned image runs on the rendered page.
    public var textAngle: Double {
        var a = skew - 90.0 * Double(((quarterTurns % 4) + 4) % 4)
        while a <= -180 { a += 360 }
        while a > 180 { a -= 360 }
        return a
    }

    /// A point of the cleaned image (pixels) on the rendered page (pixels).
    public func toRendered(_ px: Double, _ py: Double) -> (x: Double, y: Double) {
        let (w, h) = (Double(width), Double(height))
        // Undo the quarter turns: one clockwise turn took (x, y) of a W × H image to (H − y, x).
        var (x, y): (Double, Double) = switch ((quarterTurns % 4) + 4) % 4 {
        case 1: (py, h - px)
        case 2: (w - px, h - py)
        case 3: (w - py, px)
        default: (px, py)
        }
        if let curve {
            let s = curve.source(x, y)
            (x, y) = (s.x, s.y)
        }
        if skew != 0 {
            // Undo the straightening: the content goes back clockwise by the skew, about the centre.
            let (s, c) = (sin(skew * .pi / 180), cos(skew * .pi / 180))
            let (dx, dy) = (x - w / 2, y - h / 2)
            (x, y) = (w / 2 + dx * c - dy * s, h / 2 + dx * s + dy * c)
        }
        if let perspective {
            let s = perspective.source(x, y)
            return (s.x, s.y)
        }
        return (x, y)
    }

    /// A recognized word of the cleaned image (pixels) as a word on the page (points; its box turned by `textAngle`).
    /// `sx`, `sy`: points per pixel. Through a warp (`perspective`, `curve`) a word takes the length, height and slant its
    /// box's middle lines have on the page.
    public func toRendered(_ word: OcrWord, _ sx: Double, _ sy: Double) -> OcrWord {
        let r = word.rect
        let (cx, cy) = toRendered(r.x + r.width / 2, r.y + r.height / 2)
        let level = OcrWord(word.text, RectD(cx * sx - r.width * sx / 2, cy * sy - r.height * sy / 2, r.width * sx, r.height * sy), angle: textAngle)
        if perspective == nil && curve == nil { return level }
        let (mid, centre) = (r.y + r.height / 2, r.x + r.width / 2)
        let (l, rr) = (toRendered(r.x, mid), toRendered(r.x + r.width, mid))
        let (t, b) = (toRendered(centre, r.y), toRendered(centre, r.y + r.height))
        // In points (a rendered page's pixels are square but for rounding: each way's own scale).
        let length = (((rr.x - l.x) * sx) * ((rr.x - l.x) * sx) + ((rr.y - l.y) * sy) * ((rr.y - l.y) * sy)).squareRoot()
        let height = (((b.x - t.x) * sx) * ((b.x - t.x) * sx) + ((b.y - t.y) * sy) * ((b.y - t.y) * sy)).squareRoot()
        let angle = atan2((rr.y - l.y) * sy, (rr.x - l.x) * sx) * 180 / .pi
        guard length > 0 && height > 0 && length.isFinite && height.isFinite && angle.isFinite && cx.isFinite && cy.isFinite else { return level }
        return OcrWord(word.text, RectD(cx * sx - length / 2, cy * sy - height / 2, length, height), angle: (angle * 100).rounded(.toNearestOrEven) / 100)
    }
}
