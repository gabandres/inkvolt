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

/// The document as it prints in vectors: the bytes the print system draws its pages from (Core Graphics), and how
/// each page goes. Every comment and form field (signatures too) is drawn into its page as MuPDF shows it, by its own
/// appearance (`Flattener`); the copy is decrypted and stays in memory, never saved. A page prints as a picture when
/// Core Graphics couldn't draw it as MuPDF shows it: a comment or field with no appearance of its own (MuPDF makes one
/// up), a /Rotate that isn't a quarter turn, or a size read differently from MuPDF's (a /UserUnit, broken boxes).
/// Layers, redactions and Dark Pages need nothing here: the copy is made from the bytes the view engine shows (layers
/// as chosen, redactions applied as edits), and Dark Pages only colors the screen.
public struct PrintCopy: Sendable {
    /// The copy's bytes (the document's own when nothing needed changing).
    public let data: [UInt8]
    /// Whether `data` was written by MuPDF (the document's own bytes otherwise).
    public let rewritten: Bool
    public let pages: [PrintedPage]

    /// Sizes of a page as shown may differ by this much (points, or that fraction of the size) and still print as
    /// vectors: MuPDF's bounds are floats.
    static let sizeTolerance = 0.5, sizeFraction = 0.001
    private static let flagNoRotate = 16

    /// - Parameters:
    ///   - shown: each page's size as the engine shows it (rotation applied).
    ///   - rewrite: write the copy even when nothing changed (Core Graphics couldn't open the document's own bytes;
    ///     MuPDF's are a repaired, plain file).
    public static func make(_ data: [UInt8], _ password: String?, shown: [(Double, Double)], rewrite: Bool = false) throws -> PrintCopy {
        let doc = try PdfEdit.openToRead(data, password)
        let pageObjects = try doc.pages()
        guard pageObjects.count == shown.count else {
            let why = "the document's page count reads \(pageObjects.count), not \(shown.count)"
            return PrintCopy(data: data, rewritten: false, pages: shown.map { _ in .picture(why) })
        }
        if let acro = doc.catalog.dict("AcroForm") { try FormEditor.ensureAppearances(doc, acro) }
        var pages: [PrintedPage] = []
        pages.reserveCapacity(pageObjects.count)
        for (i, page) in pageObjects.enumerated() {
            pages.append(way(page, shown[i]))
        }
        var options = FlattenOptions(annotations: true, formFields: true, links: false)
        options.signatureFields = true
        let touched = try Flattener.flattenPages(doc, options, appearancesReady: true)
        try doc.checkFailure()
        guard touched || rewrite || doc.hasEncrypt else { return PrintCopy(data: data, rewritten: false, pages: pages) }
        return PrintCopy(data: try doc.write("decrypt=yes,encrypt=no"), rewritten: true, pages: pages)
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
