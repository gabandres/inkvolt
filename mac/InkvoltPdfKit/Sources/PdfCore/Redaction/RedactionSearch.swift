import Foundation
import PrintCore

/// Why a page needs a person's eyes: what the search could only read through text recognition, or not at all.
public enum RedactionLookReason: CaseIterable, Sendable {
    /// The page is a scan (a picture with or without a text layer), read by text recognition.
    case scanReadByOcr
    /// The page has its own text and pictures or drawn text besides, those read by text recognition.
    case picturesReadByOcr
    /// The page is a scan and text recognition couldn't read it (none given, or it failed): at most its text layer was searched.
    case scanNotRead
    /// The page has ink that isn't text, and text recognition couldn't read it.
    case picturesNotRead
}

/// A page to look at by hand. `unread`: places with ink where no word was read at all, page space (a dropped line, a
/// stamp, a signature, a logo).
public struct RedactionLook: Equatable, Sendable {
    public var page: Int
    public var reason: RedactionLookReason
    public var unread: [RectD]

    public init(_ page: Int, _ reason: RedactionLookReason, _ unread: [RectD]) {
        self.page = page
        self.reason = reason
        self.unread = unread
    }

    /// One line for a list that has said the rest above it.
    public var short: String {
        let why: String
        switch reason {
        case .scanReadByOcr: why = loc("A scan, read by OCR.")
        case .picturesReadByOcr: why = loc("Pictures or drawn text, read by OCR.")
        case .scanNotRead: why = loc("A scan that text recognition couldn't read.")
        case .picturesNotRead: why = loc("Pictures or drawn text that text recognition couldn't read.")
        }
        switch unread.count {
        case 0: return why
        case 1: return why + loc(" Tick to black out the {0} place nothing was read.", CoreLanguage.number(1))
        default: return why + loc(" Tick to black out the {0} places nothing was read.", CoreLanguage.number(unread.count))
        }
    }

    /// Why these pages need a person's eyes, as the end of a sentence: read badly, or not read at all. Never says a page
    /// is clean.
    public static func why(_ looks: [RedactionLook]) -> String {
        let read = looks.contains { $0.reason == .scanReadByOcr || $0.reason == .picturesReadByOcr }
        let unread = looks.contains { $0.reason == .scanNotRead || $0.reason == .picturesNotRead }
        if read && unread {
            return loc("text in scans and pictures is read by text recognition (OCR), which can misread words and miss whole lines, and some scans and pictures with text in them couldn't be read, not even by text recognition")
        }
        return unread ? loc("scans and pictures with text in them couldn't be read, not even by text recognition")
            : loc("text in scans and pictures is read by text recognition (OCR), which can misread words and miss whole lines")
    }

    /// What to tell the person. Never says a page is clean.
    public var text: String {
        let why: String
        switch reason {
        case .scanReadByOcr: why = loc("A scan, read by text recognition, which can misread words and miss whole lines.")
        case .picturesReadByOcr: why = loc("Has pictures or drawn text, read by text recognition, which can misread words and miss whole lines.")
        case .scanNotRead: why = loc("A scan that text recognition couldn't read: only a text layer, if it has one, was searched.")
        case .picturesNotRead: why = loc("Has pictures or drawn text that text recognition couldn't read.")
        }
        switch unread.count {
        case 0: return why
        case 1: return why + loc(" {0} place has ink where nothing was read.", CoreLanguage.number(1))
        default: return why + loc(" {0} places have ink where nothing was read.", CoreLanguage.number(unread.count))
        }
    }
}

/// What a search found: the matches, and the pages that can't be taken as clean whatever it found on them. `skipped`:
/// pages the engine refused (page checks), not searched at all (a Mac difference: Windows' search stops there).
public struct RedactionSearchResult: Equatable, Sendable {
    public var hits: [RedactionMatch]
    public var looks: [RedactionLook]
    public var skipped: [Int]

    public init(hits: [RedactionMatch], looks: [RedactionLook], skipped: [Int] = []) {
        self.hits = hits
        self.looks = looks
        self.skipped = skipped
    }

    /// Scans that nothing could read: searching this file didn't really happen.
    public var unreadScans: [Int] { looks.filter { $0.reason == .scanNotRead }.map(\.page) }
}

/// Redaction by pattern over a whole document, its scans too (the Windows Core's `RedactionSearch`): `RedactionPatterns`
/// runs on each page's own text and, on a page that has ink the text doesn't explain (a scan, a picture of text, text drawn
/// as shapes), on what text recognition reads there. Places with ink where nothing at all was read are read again on their
/// own (a recognizer can skip a whole line), and what stays unread is reported. A page read by recognition is never
/// reported clean: it comes back in `RedactionSearchResult.looks` for a person to look at, hits or not.
public enum RedactionSearch {
    /// A picture share above this makes a page a scan, even under a text layer (an old layer can be poor or planted).
    static let scanShare = 0.5
    /// A place is read again at this resolution, and no more than this many on a page.
    static let rereadDpi = 300.0, maxRereads = 24
    /// Text boxes taller or wider than this don't vouch for the ink under them (hostile text can claim to cover a page).
    static let tallestWord = 150.0

    /// The options of the recognition a search reads pages with (Windows' `RecognizeOptions(CheckWords: false)`).
    static let readOptions = RecognizeOptions(clean: true, checkWords: false)

    /// - Parameters:
    ///   - ocr: the recognizer; nil: pages that need one come back as not read.
    ///   - ocrOnly: look past the text only on these pages (the read-back, after the others were looked at once); nil: every page.
    ///   - progress: (pages done, pages to search).
    /// - Throws: `PdfEditError` when the options aren't valid (`RedactionPatterns.validate`); `RedactionSearchTimeout` when
    ///   a pattern took too long (the search stopped, it isn't reported clean); `TooManyHits`; `CancellationError`.
    public static func find(_ engine: PdfEngine, _ options: RedactionPatternOptions, ocr: (any TextRecognizer)? = nil,
                            progress: ((Int, Int) -> Void)? = nil, cancel: CancelToken? = nil, ocrOnly: Set<Int>? = nil) throws -> RedactionSearchResult {
        let custom = try RedactionPatterns.compile(options)
        let pages = Array(Set((options.pages ?? Array(0..<engine.pageCount)).filter { $0 >= 0 && $0 < engine.pageCount })).sorted()
        var hits: [RedactionMatch] = []
        var looks: [RedactionLook] = []
        let skipped = SkippedPages()
        for (i, p) in pages.enumerated() {
            try cancel.check()
            // Cached only for a few pages: a long document would push the pages the viewer shows out of the engine's text cache.
            guard let text = try skipped.unlessRefused({ try engine.text(p, cache: pages.count <= 8, cancel: cancel) }) else {
                progress?(i + 1, pages.count)
                continue
            }
            let own = try RedactionPatterns.findOnPage(text, p, options, custom)
            hits += own
            if ocrOnly?.contains(p) ?? true {
                guard let inked = try skipped.unlessRefused({ try readInk(engine, p, text, ocr, cancel) }) else {
                    progress?(i + 1, pages.count)
                    continue
                }
                let (read, look) = inked
                if let look { looks.append(look) }
                if !read.isEmpty {
                    var taken: [RedactionPattern: RectIndex] = [:]
                    for (pattern, list) in Dictionary(grouping: own, by: \.pattern) { taken[pattern] = RectIndex(list.flatMap(\.rects)) }
                    for var hit in try RedactionPatterns.findOnPage(ocrPageText(read), p, options, custom, lenient: true) {
                        // The same value read twice lies on itself; one on the next line only touches the first.
                        if let same = taken[hit.pattern], same.liesOn(hit.rects) { continue }
                        // Boxes from a recognizer are rough: a little more room, so no edge of a figure stays.
                        hit.rects = hit.rects.map { $0.inflate(1.5) }
                        hit.fromOcr = true
                        hits.append(hit)
                    }
                }
            }
            if hits.count > RedactionPatterns.maxHits { throw TooManyHits(limit: RedactionPatterns.maxHits) }
            progress?(i + 1, pages.count)
        }
        return RedactionSearchResult(hits: hits, looks: looks, skipped: skipped.list)
    }

    /// The result of redacting searched again: the matches that are still there, other than those the person chose to keep
    /// (`kept`, by place), and the pages the engine refused (not searched: the caller says so). No hits means nothing the
    /// patterns can read is left on the pages; it doesn't say a scanned page is clean.
    /// - Parameter redactedPages: the pages that were redacted: they are pictures now, so the recognizer reads them again.
    public static func readBack(_ data: [UInt8], _ password: String?, _ options: RedactionPatternOptions, ocr: (any TextRecognizer)?,
                                redactedPages: Set<Int>, kept: [RedactionMatch], progress: ((Int, Int) -> Void)? = nil,
                                cancel: CancelToken? = nil) throws -> (hits: [RedactionMatch], skipped: [Int]) {
        let engine = try PdfEngine.open(data, password: password)
        defer { engine.close() }
        let found = try find(engine, options, ocr: ocr, progress: progress, cancel: cancel, ocrOnly: redactedPages)
        var keptByPage: [Int: RectIndex] = [:]
        for (page, list) in Dictionary(grouping: kept, by: \.page) { keptByPage[page] = RectIndex(list.flatMap(\.rects)) }
        // Kept means where a kept hit is (most of a box on it): a box that only touches one (a recognized word's box is grown,
        // so two values side by side touch) is still there (Windows: touches).
        let left = found.hits.filter { h in !(keptByPage[h.page]?.liesOn(h.rects) ?? false) }
        return (left, found.skipped)
    }

    /// The areas to black out per page: each match's boxes, grown by half a point so no edge of a glyph survives.
    public static func areas(_ matches: [RedactionMatch]) -> [Int: [RectD]] { RedactionPatterns.areas(matches) }

    static let maxValueLength = 200

    /// What to look for afterwards in everything else the file holds: each match as it reads, and as it was written.
    public static func values(_ matches: [RedactionMatch]) -> [String] {
        var values: [String] = []
        for m in matches {
            // Long matches (a pattern that takes a whole page) are looked for by their start: the checker's matcher has limits.
            values.append(String(m.normalized.prefix(maxValueLength)))
            if !m.fromOcr { values.append(String(m.text.prefix(maxValueLength))) }
        }
        return values
    }

    /// What was removed, to look for in the rest of the file: not dates and ZIP codes, whose digits a file's own time stamps
    /// and ids can hold. What the patterns read outside the pages (`RedactionCheckOptions.patterns`) covers those.
    public static func soughtValues(_ matches: [RedactionMatch]) -> [String] {
        values(matches.filter { $0.pattern != .date && $0.pattern != .zipCode })
    }

    /// Boxes filed by height on the page: a page of hostile text can hold a hundred thousand of them.
    struct RectIndex {
        private static let band = 16.0
        private var bands: [Int: [RectD]] = [:]

        init(_ rects: [RectD]) {
            for r in rects { for b in Self.bands(r) { bands[b, default: []].append(r) } }
        }

        // A box taller than the page is odd enough to file by its first bands only; it stays findable from them. Edges that
        // aren't numbers (or are out of range) file nowhere.
        private static func bands(_ r: RectD) -> ClosedRange<Int> {
            let lo = (r.y / band).rounded(.down), hi = (r.bottom / band).rounded(.down)
            guard lo.isFinite, hi.isFinite, abs(lo) < 1e12, abs(hi) < 1e12 else { return 1...0 }
            let first = Int(lo)
            return first...max(first, min(Int(hi), first + 512))
        }

        /// Most of one of the boxes is inside one of these.
        func liesOn(_ rects: [RectD]) -> Bool {
            rects.contains { r in
                Self.bands(r).contains { b in
                    (bands[b] ?? []).contains { k in
                        let i = k.intersect(r)
                        return !i.isEmpty && i.width * i.height >= 0.5 * min(k.width * k.height, r.width * r.height)
                    }
                }
            }
        }

    }

    // ---- The page's ink ----

    /// What recognition reads on a page whose ink its text doesn't explain, and what to tell the person about the page.
    private static func readInk(_ engine: PdfEngine, _ page: Int, _ text: PageText, _ ocr: (any TextRecognizer)?,
                                _ cancel: CancelToken?) throws -> ([OcrWord], RedactionLook?) {
        let boxes = try engine.pictureBoxes(page, cancel: cancel)
        let ink = try InkMap.of(engine, page, boxes, cancel)
        let g = engine.page(page)
        let pictures = boxes.reduce(0.0) { $0 + $1.width * $1.height }
        // No ink and no picture: a blank page. A picture with no ink to see may be a very faint scan, so it isn't let through.
        if ink.isBlank && pictures <= 0 { return ([], nil) }
        let known = knownBoxes(text)
        var unread = ink.unread(known)
        let hasText = text.text.unicodeScalars.contains { !$0.properties.isWhitespace }
        let scan = !hasText || pictures >= scanShare * (g.width * g.height)
        if !scan && unread.isEmpty { return ([], nil) }
        let notRead = RedactionLook(page, scan ? .scanNotRead : .picturesNotRead, unread)
        guard let ocr else { return ([], notRead) }
        do {
            let read = try ScanText.recognize(engine, page, ocr, readOptions, cancel: cancel)
            var words = read.words
            unread = ink.unread(known + words.map(box))
            if !unread.isEmpty && read.quarterTurns == 0 && abs(read.skew) <= 3 {
                words += try reread(engine, page, ocr, unread, words, cancel)
                unread = ink.unread(known + words.map(box))
            }
            return (words, RedactionLook(page, scan ? .scanReadByOcr : .picturesReadByOcr, unread))
        } catch is CancellationError {
            throw CancellationError()
        } catch let refused as PageRefused {
            throw refused
        } catch {
            // The recognizer gave up on this page (a page too large for it, an engine error): as good as not having one here.
            return ([], notRead)
        }
    }

    private static func knownBoxes(_ text: PageText) -> [RectD] {
        var boxes: [RectD] = []
        if text.isEmpty { return boxes }
        // Unit by unit: a line's box would also vouch for a picture sitting between two of its words.
        for (i, u) in text.text.utf16.enumerated() where !PageText.isWhiteSpace(u) {
            let b = text.boxAt(i)
            if !b.isEmpty && b.height <= tallestWord && b.width <= tallestWord { boxes.append(b) }
        }
        return boxes
    }

    /// The places with ink and no words, each read on its own, larger and with a margin of white.
    private static func reread(_ engine: PdfEngine, _ page: Int, _ ocr: any TextRecognizer, _ places: [RectD], _ have: [OcrWord],
                               _ cancel: CancelToken?) throws -> [OcrWord] {
        let margin = 48
        let scale = rereadDpi / 72
        let g = engine.page(page)
        var found: [OcrWord] = []
        let chosen = places.filter { $0.height <= 96 && $0.width <= 2000 }.sorted { $0.width > $1.width }.prefix(maxRereads)
        for place in chosen {
            try cancel.check()
            let region = place.inflate(3).intersect(RectD(0, 0, g.width, g.height))
            if region.isEmpty { continue }
            let image = try engine.render(page, scale: scale, region: region, cancel: cancel)
            guard image.width > 0, image.height > 0 else { continue }
            let gray = ScanCleanup.toGray(image.pixels, image.width, image.height)
            let (w, h) = (image.width + 2 * margin, image.height + 2 * margin)
            var canvas = [UInt8](repeating: 255, count: w * h * 3)
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let v = gray[y * image.width + x], at = ((y + margin) * w + x + margin) * 3
                    canvas[at] = v
                    canvas[at + 1] = v
                    canvas[at + 2] = v
                }
            }
            for word in try ocr.recognize(RenderedImage(w, h, canvas), cancel: cancel) {
                let b = RectD(region.x + (word.rect.x - Double(margin)) / scale, region.y + (word.rect.y - Double(margin)) / scale,
                              word.rect.width / scale, word.rect.height / scale)
                if word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                let overlaps = (have + found).contains { o in
                    let i = box(o).intersect(b)
                    return !i.isEmpty && i.width * i.height > 0.5 * b.width * b.height
                }
                if !overlaps { found.append(OcrWord(word.text, b)) }
            }
        }
        return found
    }

    /// A word's level box on the page: its own box turned by its angle.
    static func box(_ word: OcrWord) -> RectD {
        if word.angle == 0 { return word.rect }
        let a = word.angle * .pi / 180
        let (s, c) = (sin(a), cos(a))
        let w = abs(word.rect.width * c) + abs(word.rect.height * s), h = abs(word.rect.width * s) + abs(word.rect.height * c)
        return RectD(word.rect.centerX - w / 2, word.rect.centerY - h / 2, w, h)
    }

    /// Recognized words as a page's text, in the order they were read (the recognizer knows the columns). Every character has
    /// the box of its whole word: a recognizer gives no finer place, and guessing from the width could leave a digit of a
    /// value showing, so a hit always blacks out the whole word it is in.
    static func ocrPageText(_ words: [OcrWord]) -> PageText {
        var lines: [[(String, RectD)]] = []
        var directions: [(Double, Double)] = []
        var (lastAcross, lastAlong, lastHeight) = (0.0, -Double.greatestFiniteMagnitude, 0.0)
        for word in words where !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !word.rect.isEmpty {
            // Along and across the line, whatever way the word runs on the page.
            let a = word.angle * .pi / 180
            let (s, c) = (sin(a), cos(a))
            let along = word.rect.centerX * c + word.rect.centerY * s
            let across = -word.rect.centerX * s + word.rect.centerY * c
            let b = box(word)
            if lines.isEmpty || abs(across - lastAcross) > 0.6 * max(word.rect.height, lastHeight) || along < lastAlong {
                lines.append([])
                directions.append((c, s))
            } else if let prev = lines[lines.count - 1].last {
                lines[lines.count - 1].append((" ", RectD(prev.1.right, prev.1.y, 0, prev.1.height)))
            }
            for scalar in word.text.unicodeScalars { lines[lines.count - 1].append((String(scalar), b)) }
            (lastAcross, lastAlong, lastHeight) = (across, along, word.rect.height)
        }
        return PageText(lines, directions: directions)
    }
}

/// Where a page has ink, drawn small: enough to tell the ink the page's words explain from the ink they don't (a line the
/// recognizer dropped, a picture, text drawn as shapes). Paper shade, rules, frames and specks don't count.
struct InkMap {
    private static let scale = 1.5, maxPixels = 8_000_000.0
    /// A straight run of ink this long (points) is a rule, a frame or a filled box, not a character.
    private static let longestStroke = 36.0
    /// The smallest place that could be a few characters (points); ink this close together is one place.
    private static let minWidth = 14.0, minHeight = 4.0, joinAcross = 6.0

    private let w: Int, h: Int
    private let scale: Double
    private let dark: [Bool]
    let isBlank: Bool

    private init(_ w: Int, _ h: Int, _ scale: Double, _ dark: [Bool]) {
        (self.w, self.h, self.scale, self.dark) = (w, h, scale, dark)
        isBlank = !dark.contains(true)
    }

    /// `pictures`: the page's pictures: in them, what is lighter than around it is ink too (words on a colored band).
    static func of(_ engine: PdfEngine, _ page: Int, _ pictures: [RectD], _ cancel: CancelToken?) throws -> InkMap {
        let g = engine.page(page)
        let s = min(scale, (maxPixels / max(1, g.width * g.height)).squareRoot())
        let image = try engine.render(page, scale: s, cancel: cancel)
        let gray = ScanCleanup.toGray(image.pixels, image.width, image.height)
        let mask = inPictures(pictures, image.width, image.height, s)
        return InkMap(image.width, image.height, s, threshold(gray, image.width, image.height, mask))
    }

    /// Dark against the paper around it, tile by tile, so a shaded scan isn't all ink; black is ink wherever it is.
    private static func threshold(_ gray: [UInt8], _ w: Int, _ h: Int, _ inPicture: [Bool]?) -> [Bool] {
        let tile = 64
        var dark = [Bool](repeating: false, count: w * h)
        var histogram = [Int](repeating: 0, count: 256)
        for ty in stride(from: 0, to: h, by: tile) {
            for tx in stride(from: 0, to: w, by: tile) {
                for k in 0..<256 { histogram[k] = 0 }
                let (x1, y1) = (min(w, tx + tile), min(h, ty + tile))
                for y in ty..<y1 { for x in tx..<x1 { histogram[Int(gray[y * w + x])] += 1 } }
                let half = (x1 - tx) * (y1 - ty) / 2
                var (paper, seen) = (0, 0)
                while paper < 255 {
                    seen += histogram[paper]
                    if seen >= half { break }
                    paper += 1
                }
                let limit = max(90, paper - 40)
                for y in ty..<y1 {
                    for x in tx..<x1 {
                        // In a picture, what is lighter than around it is ink; on a dark ground it is the only ink there is.
                        let v = Int(gray[y * w + x])
                        let light = inPicture?[y * w + x] == true
                        dark[y * w + x] = (light && v > paper + 40) || (v < limit && !(light && paper < limit))
                    }
                }
            }
        }
        return dark
    }

    private static func inPictures(_ pictures: [RectD], _ w: Int, _ h: Int, _ scale: Double) -> [Bool]? {
        if pictures.isEmpty { return nil }
        var mask = [Bool](repeating: false, count: w * h)
        for b in pictures {
            let (x0, x1) = (clampPixel((b.x * scale).rounded(.up), w), clampPixel((b.right * scale).rounded(.down), w))
            let (y0, y1) = (clampPixel((b.y * scale).rounded(.up), h), clampPixel((b.bottom * scale).rounded(.down), h))
            if x1 <= x0 { continue }
            for y in y0..<max(y0, y1) { for x in x0..<x1 { mask[y * w + x] = true } }
        }
        return mask
    }

    /// `v` as a pixel within 0...`hi`, checked as a Double first (a box from a file can be anything).
    private static func clampPixel(_ v: Double, _ hi: Int) -> Int {
        guard v.isFinite else { return v > 0 ? hi : 0 }
        return Int(min(max(v, 0), Double(hi)))
    }

    /// The places with ink outside `known` (boxes in page points), largest first, at most 64.
    func unread(_ known: [RectD]) -> [RectD] {
        var left = dark
        for k in known {
            let b = k.inflate(1.5)
            let (x0, x1) = (Self.clampPixel((b.x * scale).rounded(.down), w), Self.clampPixel((b.right * scale).rounded(.up), w))
            let (y0, y1) = (Self.clampPixel((b.y * scale).rounded(.down), h), Self.clampPixel((b.bottom * scale).rounded(.up), h))
            if x1 <= x0 { continue }
            for y in y0..<max(y0, y1) { for x in x0..<x1 { left[y * w + x] = false } }
        }
        var alone: [Int] = []
        for y in 0..<h {
            for x in 0..<w where left[y * w + x] {
                let neighbour = (x > 0 && left[y * w + x - 1]) || (x + 1 < w && left[y * w + x + 1])
                    || (y > 0 && left[(y - 1) * w + x]) || (y + 1 < h && left[(y + 1) * w + x])
                if !neighbour { alone.append(y * w + x) }
            }
        }
        for i in alone { left[i] = false }
        removeLongRuns(&left)
        return places(left)
    }

    /// Takes out straight runs of ink longer than any stroke of a character.
    private func removeLongRuns(_ map: inout [Bool]) {
        let limit = Int(Self.longestStroke * scale)
        var marks = [Bool](repeating: false, count: map.count)
        for y in 0..<h {
            var run = 0
            for x in 0...w {
                if x < w && map[y * w + x] {
                    run += 1
                } else {
                    if run >= limit { for k in (x - run)..<x { marks[y * w + k] = true } }
                    run = 0
                }
            }
        }
        for x in 0..<w {
            var run = 0
            for y in 0...h {
                if y < h && map[y * w + x] {
                    run += 1
                } else {
                    if run >= limit { for k in (y - run)..<y { marks[k * w + x] = true } }
                    run = 0
                }
            }
        }
        for i in 0..<map.count where marks[i] { map[i] = false }
    }

    /// Ink close together as boxes (runs of each row joined across small gaps, touching the row above).
    private func places(_ map: [Bool]) -> [RectD] {
        let join = max(1, Int(Self.joinAcross * scale))
        var parents: [Int] = []
        var boxes: [(x0: Int, y0: Int, x1: Int, y1: Int, ink: Int)] = []
        var above: [(x0: Int, x1: Int, id: Int)] = []
        func root(_ start: Int) -> Int {
            var i = start
            while parents[i] != i {
                parents[i] = parents[parents[i]]
                i = parents[i]
            }
            return i
        }
        for y in 0..<h {
            var row: [(x0: Int, x1: Int, id: Int)] = []
            var x = 0
            while x < w {
                if !map[y * w + x] {
                    x += 1
                    continue
                }
                var (start, end, ink, gap) = (x, x, 0, 0)
                while x < w && gap <= join {
                    if map[y * w + x] {
                        end = x
                        gap = 0
                        ink += 1
                    } else {
                        gap += 1
                    }
                    x += 1
                }
                let id = parents.count
                parents.append(id)
                boxes.append((start, y, end, y, ink))
                for a in above where !(a.x0 > end || a.x1 < start) {
                    let (r, s) = (root(a.id), root(id))
                    if r == s { continue }
                    parents[s] = r
                    let (p, q) = (boxes[r], boxes[s])
                    boxes[r] = (min(p.x0, q.x0), min(p.y0, q.y0), max(p.x1, q.x1), max(p.y1, q.y1), p.ink + q.ink)
                }
                row.append((start, end, id))
            }
            above = row
        }
        var out: [RectD] = []
        for i in 0..<parents.count where root(i) == i {
            let b = boxes[i]
            let (bw, bh) = (Double(b.x1 - b.x0 + 1) / scale, Double(b.y1 - b.y0 + 1) / scale)
            if bw < Self.minWidth || bh < Self.minHeight || b.ink < 16 { continue }
            out.append(RectD(Double(b.x0) / scale, Double(b.y0) / scale, bw, bh).inflate(1))
        }
        return Array(out.sorted { $0.width * $0.height > $1.width * $1.height }.prefix(64))
    }
}

extension PdfEngine {
    /// Where a page's pictures are, in page points (cut to the page), its comments' too (the Windows engine's `PictureBoxes`).
    func pictureBoxes(_ page: Int, cancel: CancelToken? = nil) throws -> [RectD] {
        let read = try exportRead(page, images: true, boxesOnly: true, jpegAbovePixels: Int.max, cancel: cancel)
        let g = self.page(page)
        let whole = RectD(0, 0, g.width, g.height)
        return read.images.map { $0.box.intersect(whole) }.filter { !$0.isEmpty && $0.width.isFinite && $0.height.isFinite }
    }
}
