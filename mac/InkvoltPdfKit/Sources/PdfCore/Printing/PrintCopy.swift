import Foundation

/// An affine map of the plane: x' = a·x + c·y + tx, y' = b·x + d·y + ty (Core Graphics' order of the six numbers).
public struct Affine: Equatable, Sendable {
    public var a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double

    public init(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ tx: Double, _ ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = Affine(1, 0, 0, 1, 0, 0)

    public func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        let px: Double = a * x + c * y + tx
        let py: Double = b * x + d * y + ty
        return (px, py)
    }

    /// This map followed by `next`.
    public func then(_ next: Affine) -> Affine {
        let na: Double = next.a * a + next.c * b
        let nb: Double = next.b * a + next.d * b
        let nc: Double = next.a * c + next.c * d
        let nd: Double = next.b * c + next.d * d
        let ntx: Double = next.a * tx + next.c * ty + next.tx
        let nty: Double = next.b * tx + next.d * ty + next.ty
        return Affine(na, nb, nc, nd, ntx, nty)
    }
}

extension PageFrame {
    /// `toPage` as a matrix: PDF user space → page space (the page as shown: cropped, turned, origin at its top-left,
    /// y down). Nil for a /Rotate that isn't a quarter turn (MuPDF and Core Graphics may disagree on it).
    var toPageMatrix: Affine? {
        switch rot {
        case 0: Affine(1, 0, 0, -1, -bx1, by2)
        case 90: Affine(0, 1, 1, 0, h - by2, -bx1)
        case 180: Affine(-1, 0, 0, 1, w + bx1, h - by2)
        case 270: Affine(0, -1, -1, 0, by2, w + bx1)
        default: nil
        }
    }
}

extension PrintLayout {
    /// Where a placed page's points go on the paper: page space (the page as shown, `pageW` × `pageH`) → paper
    /// coordinates (origin at the paper's top-left, y down). The placed `source` (all of the page when nil) fills the
    /// box, turned a quarter clockwise when the layout says so: its top-left corner goes to the box's top-right.
    public static func toPaper(_ placed: PlacedPage, _ pageW: Double, _ pageH: Double) -> Affine {
        let source = placed.source ?? RectD(0, 0, pageW, pageH)
        let box = placed.box
        let turned = placed.turns % 2 == 1
        let drawnW: Double = turned ? box.height : box.width
        let drawnH: Double = turned ? box.width : box.height
        let sx: Double = source.width > 0 ? drawnW / source.width : 0
        let sy: Double = source.height > 0 ? drawnH / source.height : 0
        if !turned { return Affine(sx, 0, 0, sy, box.x - source.x * sx, box.y - source.y * sy) }
        let tx: Double = box.x + drawnH + source.y * sy
        let ty: Double = box.y - source.x * sx
        return Affine(0, sx, -sy, 0, tx, ty)
    }
}

/// How one page of a print job is drawn.
public enum PrintedPage: Equatable, Sendable {
    /// From the print copy as vectors (text stays text): `toPage` maps the copy's PDF user space to page space.
    case vector(toPage: Affine)
    /// As a picture MuPDF renders (the way every page printed before), for the reason given.
    case picture(String)
}

/// A page's visible box in PDF user space (its crop box clipped to its media box) and its /Rotate: as MuPDF reads them
/// (`PrintCopy.boxes`), and as Core Graphics does (`PrintCopy.checked`).
public struct PageBox: Equatable, Sendable {
    public var x1: Double, y1: Double, x2: Double, y2: Double
    public var rotation: Int

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, rotation: Int) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.rotation = rotation
    }
}

/// The document as it prints in vectors: the bytes the print system draws its pages from (Core Graphics), and how
/// each page goes. Every comment and form field (signatures too) is drawn into its page as MuPDF shows it, by its own
/// appearance (`Flattener`); the copy is MuPDF's rewrite of the document (decrypted, one version, a fresh
/// cross-reference table), so Core Graphics reads the objects MuPDF shows, never its own repair of a broken file or its
/// own pick of an object defined twice; it stays in memory, never saved. A page prints as a picture when Core Graphics
/// couldn't draw it as MuPDF shows it: a comment or field MuPDF draws with an appearance flattening can't
/// (`Flattener.Look.madeUp`), a /Rotate that isn't a quarter turn, a size read differently from MuPDF's (a /UserUnit,
/// broken boxes), or a box or turn Core Graphics reads differently (`checked`); and when the bounded engine refuses it
/// (`PageRefused`: a decompression bomb, a picture too large), since Core Graphics draws with no bound at all (`bound`).
/// Layers, redactions and Dark Pages need nothing here: the copy is made from the bytes the view engine shows (layers
/// as chosen, redactions applied as edits), and Dark Pages only colors the screen.
public struct PrintCopy: Sendable {
    /// The copy's bytes: MuPDF's rewrite (the document's own when no page prints as vectors, or MuPDF couldn't write a
    /// document that needed nothing changed: `written`).
    public let data: [UInt8]
    public let pages: [PrintedPage]
    /// Each page's box and turn as MuPDF reads them (nil when the page counts disagree): Core Graphics must read the
    /// same for its page to print as vectors (`checked`).
    public let boxes: [PageBox?]

    /// Sizes of a page as shown may differ by this much (points, or that fraction of the size) and still print as
    /// vectors: MuPDF's bounds are floats.
    static let sizeTolerance = 0.5, sizeFraction = 0.001
    private static let flagNoRotate = 16
    static let unreadByCoreGraphics = "Core Graphics couldn't read the page"
    static let readDifferently = "Core Graphics reads its box or turn differently than MuPDF"

    /// - Parameters:
    ///   - shown: each page's size as the engine shows it (rotation applied).
    ///   - rated: the view engine's verdict on each page so far (`PdfEngine.verdictOf`): a page it read within its bounds
    ///     isn't read again, one it refused for a picture or a stream prints its sentence; the others are read (`bound`).
    ///   - cancel: checked between pages; a cancelled copy throws `CancellationError`.
    public static func make(_ data: consuming [UInt8], _ password: String?, shown: [(Double, Double)], rated: [PageVerdict] = [],
                            cancel: CancelToken? = nil) throws -> PrintCopy {
        try cancel.check()
        // MuPDF's document is let go of once the copy is written, and the document's bytes here once they aren't the
        // copy's, before the pages are read: the most memory printing holds at once.
        let made = try written(data, password, shown, cancel)
        data = []
        var pages = made.pages
        try bound(made.data, &pages, rated, cancel)
        return PrintCopy(data: made.data, pages: pages, boxes: made.boxes)
    }

    /// The copy as MuPDF writes it, each page's way as read before flattening. The document's own bytes when no page
    /// prints as vectors (nothing for Core Graphics to read: nothing written), or when MuPDF can't write it and the
    /// document's bytes are what it would have written (nothing flattened, not encrypted: how every such document
    /// printed before the copy was always MuPDF's).
    private static func written(_ data: [UInt8], _ password: String?, _ shown: [(Double, Double)], _ cancel: CancelToken?) throws -> PrintCopy {
        let doc = try PdfEdit.openToRead(data, password)
        let pageObjects = try doc.pages()
        guard pageObjects.count == shown.count else {
            let why = "the document's page count reads \(pageObjects.count), not \(shown.count)"
            return PrintCopy(data: data, pages: shown.map { _ in .picture(why) }, boxes: shown.map { _ in nil })
        }
        // The fields' appearances stay the file's own, as MuPDF shows them (it ignores /NeedAppearances): one made
        // here would differ from the screen's, and a field without one MuPDF makes up prints its page as a picture.
        var pages: [PrintedPage] = []
        var boxes: [PageBox?] = []
        pages.reserveCapacity(pageObjects.count)
        boxes.reserveCapacity(pageObjects.count)
        for (i, page) in pageObjects.enumerated() {
            try cancel.check()
            pages.append(way(page, shown[i]))
            let b = PageBoxes.visibleBox(page)
            boxes.append(PageBox(b.x1, b.y1, b.x2, b.y2, rotation: PageBoxes.rotate(page)))
        }
        guard pages.contains(where: isVector) else { return PrintCopy(data: data, pages: pages, boxes: boxes) }
        var options = FlattenOptions(annotations: true, formFields: true, links: false)
        options.signatureFields = true
        let touched = try Flattener.flattenPages(doc, options, appearancesReady: true, cancel: cancel)
        try doc.checkFailure()
        try cancel.check()
        do {
            if writeFailsForTests { throw PdfEngineError(message: "MuPDF couldn't write the copy (a test).") } // English: for a developer
            return PrintCopy(data: try doc.write("decrypt=yes,encrypt=no"), pages: pages, boxes: boxes)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard !touched && !doc.hasEncrypt else { throw error }
            return PrintCopy(data: data, pages: pages, boxes: boxes)
        }
    }

    private static func isVector(_ page: PrintedPage) -> Bool {
        if case .vector = page { return true }
        return false
    }

    /// Pages read at once at most, each by an engine of its own (they share the copy's bytes; a MuPDF context reads on
    /// one thread at a time), and no more than the Mac has cores.
    static let readers = 8

    /// Test hook: reads a page instead of the engine (what it throws is what the engine's reading would).
    @TaskLocal static var readForTests: (@Sendable (Int) throws -> Void)?
    /// Test hook: MuPDF fails to write the copy.
    @TaskLocal static var writeFailsForTests = false

    /// Core Graphics draws with no bound at all, so each vector page is first read through the bounded engine without
    /// drawing (`PdfEngine.readThrough`: its streams checked, its reading under the page budget, its pictures by their
    /// size, none decoded), unless the view engine read it within its bounds already (`rated`). A page refused prints
    /// as a picture, which the view engine refuses too: its sentence on paper, as on screen. A page MuPDF fails on
    /// without refusing it (its own error, not a bound) prints as vectors: a picture of it would fail as well.
    private static func bound(_ bytes: [UInt8], _ pages: inout [PrintedPage], _ rated: [PageVerdict], _ cancel: CancelToken?) throws {
        var todo: [Int] = []
        for i in pages.indices where isVector(pages[i]) {
            switch i < rated.count ? rated[i] : .unknown {
            case .fine:
                continue
            case .failed:
                pages[i] = .picture(PageRefused(page: i, tooSlow: false).message)
            case .tooSlow, .unknown:
                // Too slow on screen may be its drawing's time, which reading it here doesn't spend.
                todo.append(i)
            }
        }
        if todo.isEmpty { return }
        let refusals = try read(bytes, todo, cancel)
        for (k, page) in todo.enumerated() {
            if let why = refusals[k] { pages[page] = .picture(why) }
        }
    }

    /// Why each of `todo`'s pages is refused (nil: read, or failed on without a refusal), the pages read on up to
    /// `readers` threads.
    private static func read(_ bytes: [UInt8], _ todo: [Int], _ cancel: CancelToken?) throws -> [String?] {
        let outcomes = ReadOutcomes(todo.count)
        var engines: [PdfEngine] = []
        defer { for engine in engines { engine.close() } }
        let readPage: @Sendable (Int, Int) throws -> Void
        if let hook = readForTests {
            readPage = { _, page in try hook(page) }
        } else {
            let first = try PdfEngine.open(bytes)
            engines.append(first)
            let wanted = min(todo.count, readers, max(1, ProcessInfo.processInfo.activeProcessorCount))
            while engines.count < wanted { engines.append(try first.sibling()) }
            let all = engines
            readPage = { reader, page in try all[reader].readThrough(page, cancel: cancel) }
        }
        DispatchQueue.concurrentPerform(iterations: max(engines.count, 1)) { reader in
            while let k = outcomes.next() {
                do {
                    try readPage(reader, todo[k])
                } catch let refused as PageRefused {
                    outcomes.refuse(k, refused.message)
                } catch is CancellationError {
                    outcomes.cancel()
                } catch {
                    continue // MuPDF's own failure, not a bound: Core Graphics draws the page, as before the bound
                }
            }
        }
        return try outcomes.finish()
    }

    /// The pages' outcomes while readers take them one at a time.
    private final class ReadOutcomes: @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [String?]
        private var taken = 0
        private var cancelled = false

        init(_ count: Int) { reasons = Array(repeating: nil, count: count) }

        /// The next page to read (its index in the list), nil when none is left or the job was cancelled.
        func next() -> Int? {
            lock.withLock {
                guard !cancelled, taken < reasons.count else { return nil }
                taken += 1
                return taken - 1
            }
        }

        func refuse(_ k: Int, _ why: String) { lock.withLock { reasons[k] = why } }

        func cancel() { lock.withLock { cancelled = true } }

        func finish() throws -> [String?] {
            try lock.withLock {
                if cancelled { throw CancellationError() }
                return reasons
            }
        }
    }

    /// The pages as they print once Core Graphics has opened the copy: a vector page whose box or turn Core Graphics
    /// (`read`, by page index; nil: it has no such page) reads differently than MuPDF prints as a picture.
    public func checked(_ read: (Int) -> PageBox?) -> [PrintedPage] {
        pages.enumerated().map { i, page in
            guard case .vector = page, i < boxes.count, let mine = boxes[i] else { return page }
            guard let theirs = read(i) else { return .picture(Self.unreadByCoreGraphics) }
            return Self.same(mine, theirs) ? page : .picture(Self.readDifferently)
        }
    }

    /// Whether any page prints as vectors (else Core Graphics has nothing to open).
    public var hasVectors: Bool {
        pages.contains { page in
            if case .vector = page { return true }
            return false
        }
    }

    private static func near(_ a: Double, _ b: Double, _ size: Double) -> Bool {
        abs(a - b) <= max(sizeTolerance, sizeFraction * size)
    }

    private static func same(_ a: PageBox, _ b: PageBox) -> Bool {
        let turn = { (r: Int) in ((r % 360) + 360) % 360 }
        guard turn(a.rotation) == turn(b.rotation) else { return false }
        let size: Double = max(a.x2 - a.x1, a.y2 - a.y1)
        let xs = near(a.x1, b.x1, size) && near(a.x2, b.x2, size)
        return xs && near(a.y1, b.y1, size) && near(a.y2, b.y2, size)
    }

    /// How a page of the copy prints (read before flattening: its comments as the engine shows them).
    static func way(_ page: PObj, _ shown: (Double, Double)) -> PrintedPage {
        let frame = PageBoxes.frame(page)
        guard let matrix = frame.toPageMatrix else { return .picture("its /Rotate isn't a quarter turn") }
        let (w, h) = PageBoxes.displaySize(page)
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) <= max(sizeTolerance, sizeFraction * max(abs(a), abs(b))) }
        guard w.isFinite, h.isFinite, w > 0, h > 0, near(w, shown.0), near(h, shown.1) else {
            return .picture("its size reads differently than MuPDF shows it")
        }
        let annots = PdfStructure.annots(page).filter(\.isDict)
        if annots.contains(where: Flattener.showsWithoutAppearance) {
            return .picture("a comment or form field on it has no appearance of its own")
        }
        // A note that stays upright on a turned page (NoRotate): MuPDF turns it back about its corner, a flattened copy
        // would turn it with the page.
        if frame.rot != 0 && annots.contains(where: { a in Flattener.shows(a) && (a.int("F") ?? 0) & flagNoRotate != 0 }) {
            return .picture("a comment on it stays upright on the turned page")
        }
        return .vector(toPage: matrix)
    }
}
