import Foundation

/// How Recognize Text reads a page (the Windows app's `RecognizeOptions`). `clean`: straighten, turn upright, despeckle
/// and whiten the page image first (`ScanCleanup`). `checkWords`: mark suspect words (`SuspectWords`), which reads the page
/// a second time as scanned to compare. `keepCleanedImage`: return the cleaned page to put in the document in place of the
/// scan (the user's choice, off by default); the words then fit the cleaned page.
public struct RecognizeOptions: Equatable, Sendable {
    public var clean: Bool
    public var checkWords: Bool
    public var keepCleanedImage: Bool

    public init(clean: Bool = true, checkWords: Bool = true, keepCleanedImage: Bool = false) {
        self.clean = clean
        self.checkWords = checkWords
        self.keepCleanedImage = keepCleanedImage
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
        func asScanned() throws -> [OcrWord] { try recognizer.recognize(image, cancel: cancel).map(inPoints) }

        if !options.clean {
            let plain = try asScanned()
            return RecognizedPage(words: options.checkWords ? mark(plain, nil, spelling) : plain, skew: 0, quarterTurns: 0, cleaned: nil)
        }

        let color = options.keepCleanedImage && isColor(image.pixels)
        let cleaned = try ScanCleanup.clean(image.pixels, image.width, image.height, 3, dpi, keepColor: color, cancel: cancel)
        var (turns, gray, rgb) = (cleaned.quarterTurns, cleaned.gray, cleaned.rgb)
        var found = try recognizer.recognize(asImage(gray), cancel: cancel)
        if !cleaned.uprightSure {
            // The lines didn't say which way up: read it the other way too. The page is turned over only when the turned
            // reading has clearly more real words; otherwise it stays as rendered, whatever the ink hinted. Digits read
            // plausibly both ways (6 and 9, 0 and 8: the redaction corpus's page of numbers read "OO 6830 9999" turned),
            // and count as words neither way, so a page of numbers isn't turned on a guess.
            let other = GrayImage(gray.width, gray.height, ScanCleanup.turn(gray.pixels, gray.width, gray.height, 1, 2))
            let otherFound = try recognizer.recognize(asImage(other), cancel: cancel)
            let hinted = (cleaned.quarterTurns & 2) != 0
            let (asRendered, turnedOver) = hinted ? (otherFound, found) : (found, otherFound)
            if clearlyMore(plausible(turnedOver, spelling), plausible(asRendered, spelling)) != hinted {
                (found, turns) = (otherFound, (turns + 2) % 4)
                gray = other
                if let c = rgb { rgb = ScanCleanup.turn(c, gray.width, gray.height, 3, 2) }
            }
        }

        let frame = ScanFrame(width: image.width, height: image.height, skew: cleaned.skew, quarterTurns: turns)
        let onScan = found.map { frame.toRendered($0, sx, sy) }
        var words = options.keepCleanedImage ? found.map(inPoints) : onScan
        // A page that wasn't upright as scanned can't be read as scanned: nothing to compare with.
        if options.checkWords {
            words = mark(words, turns == 0 ? SuspectWords.readDifferently(onScan, try asScanned(), spelling) : nil, spelling)
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

    private static func mark(_ words: [OcrWord], _ readDifferently: [Bool]?, _ spelling: (any Spelling)?) -> [OcrWord] {
        var words = words
        for i in words.indices {
            var reasons = SuspectWords.check(words[i].text, spelling)
            if let readDifferently, readDifferently[i] { reasons.insert(.readDifferently) }
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
/// is the rendered one (`width` × `height` px) straightened by `skew` degrees (rotated anticlockwise by that much about
/// its centre, same size) and then turned `quarterTurns` quarters clockwise. Turning and straightening are both about the
/// centre, so going back is turning back, then rotating by the skew.
public struct ScanFrame: Sendable, Equatable {
    public var width: Int, height: Int
    public var skew: Double
    public var quarterTurns: Int

    public init(width: Int, height: Int, skew: Double, quarterTurns: Int) {
        self.width = width
        self.height = height
        self.skew = skew
        self.quarterTurns = quarterTurns
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
        let (x, y): (Double, Double) = switch ((quarterTurns % 4) + 4) % 4 {
        case 1: (py, h - px)
        case 2: (w - px, h - py)
        case 3: (w - py, px)
        default: (px, py)
        }
        if skew == 0 { return (x, y) }
        // Undo the straightening: the content goes back clockwise by the skew, about the centre.
        let (s, c) = (sin(skew * .pi / 180), cos(skew * .pi / 180))
        let (dx, dy) = (x - w / 2, y - h / 2)
        return (w / 2 + dx * c - dy * s, h / 2 + dx * s + dy * c)
    }

    /// A recognized word of the cleaned image (pixels) as a word on the page (points; its box turned by `textAngle`).
    /// `sx`, `sy`: points per pixel.
    public func toRendered(_ word: OcrWord, _ sx: Double, _ sy: Double) -> OcrWord {
        let (cx, cy) = toRendered(word.rect.x + word.rect.width / 2, word.rect.y + word.rect.height / 2)
        return OcrWord(word.text, RectD(cx * sx - word.rect.width * sx / 2, cy * sy - word.rect.height * sy / 2, word.rect.width * sx, word.rect.height * sy),
                       angle: textAngle)
    }
}
