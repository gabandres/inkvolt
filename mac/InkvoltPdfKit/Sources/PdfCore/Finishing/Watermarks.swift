import Foundation

/// Where a watermark goes: once in the middle of the page, or repeated across it.
public enum WatermarkLayout: Sendable, CaseIterable { case center, tiled }

/// What `Watermarks.apply` writes: a text or an image (one of the two).
public struct WatermarkOptions: Equatable, Sendable {
    public var text: String?
    public var image: StampImage?
    public var fontSize: Double = 72
    public var color = AnnotColor(0.5, 0.5, 0.5)
    /// 0 (invisible) to 1 (opaque).
    public var opacity: Double = 0.3
    /// Degrees counterclockwise on the page as shown (45: rising from bottom-left to top-right).
    public var rotation: Double = 45
    public var layout: WatermarkLayout = .center
    /// An image's width as a fraction of the page's width (as shown).
    public var imageScale: Double = 0.5
    /// Under the page's content (opaque areas, such as a scanned page, hide it) instead of over it.
    public var behind = false

    public init(text: String? = nil, image: StampImage? = nil, fontSize: Double = 72, color: AnnotColor = AnnotColor(0.5, 0.5, 0.5),
                opacity: Double = 0.3, rotation: Double = 45, layout: WatermarkLayout = .center, imageScale: Double = 0.5, behind: Bool = false) {
        self.text = text
        self.image = image
        self.fontSize = fontSize
        self.color = color
        self.opacity = opacity
        self.rotation = rotation
        self.layout = layout
        self.imageScale = imageScale
        self.behind = behind
    }
}

/// Watermarks (the Windows app's `Watermarks`): a text (Helvetica, or embedded fonts for other scripts) or an image,
/// turned and see-through, once in the middle of each page or tiled across it, over or behind the page's content. Written
/// into the pages (it prints everywhere), laid out on the page as shown, and tagged so `remove` can take it off again
/// (see `PageMarks`). Applying again replaces the earlier watermark of those pages.
public enum Watermarks {
    static let kind = "Watermark"

    /// Tiles never exceed this many per page (a tiny text would otherwise make a huge content stream).
    public static let maxTiles = 400

    /// Centers (displayed-page coordinates, origin bottom-left, y up) for tileWidth x tileHeight tiles turned by
    /// `rotation` degrees: rows a little apart, every other row shifted by half a step, reaching past the page's edges
    /// so its corners are covered too. At most `maxTiles`.
    public static func tileCenters(_ pageWidth: Double, _ pageHeight: Double, _ tileWidth: Double, _ tileHeight: Double, _ rotation: Double) -> [(x: Double, y: Double)] {
        let (ew, eh) = turnedExtent(tileWidth, tileHeight, rotation)
        let gap = max(12, min(ew, eh) * 0.6)
        var stepX = ew + gap
        var stepY = eh + gap
        // Grow the steps until the grid fits the limit.
        while (pageWidth / stepX + 3) * (pageHeight / stepY + 3) > Double(maxTiles) {
            stepX *= 1.25
            stepY *= 1.25
        }
        var list: [(x: Double, y: Double)] = []
        var row = 0
        var y = pageHeight / 2 - ceil(pageHeight / 2 / stepY + 1) * stepY
        while y <= pageHeight + stepY {
            let shift = row % 2 == 0 ? 0 : stepX / 2
            var x = pageWidth / 2 - ceil(pageWidth / 2 / stepX + 1) * stepX + shift
            while x <= pageWidth + stepX {
                if x + ew / 2 >= 0 && x - ew / 2 <= pageWidth && y + eh / 2 >= 0 && y - eh / 2 <= pageHeight && list.count < maxTiles {
                    list.append((x, y))
                }
                x += stepX
            }
            y += stepY
            row += 1
        }
        return list
    }

    /// The axis-aligned size of a w x h box turned by `degrees`.
    static func turnedExtent(_ w: Double, _ h: Double, _ degrees: Double) -> (w: Double, h: Double) {
        let a = degrees * .pi / 180
        let c = abs(cos(a)), s = abs(sin(a))
        return (w * c + h * s, w * s + h * c)
    }

    /// Writes the watermark on `pages` (0-based).
    /// - Throws: `PdfEditError` for options that can't be drawn; `OwnerPasswordRequired`; `SignaturesWouldBreak`.
    public static func apply(_ data: [UInt8], _ password: String?, _ pages: [Int], _ options: WatermarkOptions) throws -> [UInt8] {
        let text = options.text?.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\n "))
        let blank = (text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        if blank == (options.image == nil) {
            throw PdfEditError(options.image == nil ? "Type the watermark's text or choose an image." : "A watermark is a text or an image, not both.")
        }
        if options.image == nil && (!options.fontSize.isFinite || options.fontSize < 4 || options.fontSize > 500) {
            throw PdfEditError("The font size must be from 4 to 500 points.")
        }
        if options.image != nil && (!options.imageScale.isFinite || options.imageScale <= 0 || options.imageScale > 4) {
            throw PdfEditError("The image size must be from 1% to 400% of the page width.")
        }
        if !options.rotation.isFinite || !options.opacity.isFinite { throw PdfEditError("The angle and opacity must be numbers.") }
        try options.image?.validate()

        let doc = try PdfEdit.open(data, password)
        let opacity = min(max(options.opacity, 0.01), 1)
        let gs = doc.add(doc.dict([("Type", doc.name("ExtGState")), ("ca", doc.real(opacity)), ("CA", doc.real(opacity))]))

        // One tile (the text or the image, centered on its origin), shared by every page.
        let tile: PObj
        var tileW = 0.0, tileH = 0.0
        if let img = options.image {
            tile = SignatureStamps.imageXObject(doc, img) // sized per page
        } else {
            let lines = (text ?? "").components(separatedBy: "\n")
            let size = options.fontSize
            let painter = TextPainter(.helvetica, lines)
            let leading = size * 1.15
            tileW = (lines.map { painter.measure($0) }.max() ?? 0) * size
            tileH = (painter.ascent - painter.descent) * size + leading * Double(lines.count - 1)
            let top = tileH / 2 - painter.ascent * size
            for (i, line) in lines.enumerated() {
                painter.draw(line, -painter.measure(line) * size / 2, top - Double(i) * leading, size)
            }
            let (ops, res) = painter.build(doc, tileW, tileH, "/Helv", PdfColorValue(c: [options.color.r, options.color.g, options.color.b]))
            tile = doc.formXObject(ops, -tileW / 2 - 2, -tileH / 2 - 2, tileW / 2 + 2, tileH / 2 + 2, res)
        }

        let a = options.rotation * .pi / 180
        let (cosA, sinA) = (cos(a), sin(a))
        let count = try doc.pageCount()
        for p in Set(pages).filter({ $0 >= 0 && $0 < count }).sorted() {
            let page = doc.page(p)
            PageMarks.remove(doc, page, kind)
            let (w, h, matrix) = PageMarks.frame(doc, page)
            var (tw, th) = (tileW, tileH)
            if let im = options.image {
                tw = w * options.imageScale
                th = tw * Double(im.height) / Double(im.width)
            }
            let centers = options.layout == .tiled ? tileCenters(w, h, tw, th, options.rotation) : [(x: w / 2, y: h / 2)]
            var ops = "/WmGS gs\n"
            for (cx, cy) in centers {
                ops += "q 1 0 0 1 \(PdfNum.f(cx)) \(PdfNum.f(cy)) cm \(PdfNum.f(cosA)) \(PdfNum.f(sinA)) \(PdfNum.f(-sinA)) \(PdfNum.f(cosA)) 0 0 cm "
                // An image is a unit square: scale it to its size, centered on the origin.
                if options.image != nil { ops += "\(PdfNum.f(tw)) 0 0 \(PdfNum.f(th)) \(PdfNum.f(-tw / 2)) \(PdfNum.f(-th / 2)) cm " }
                ops += "/WmTile Do Q\n"
            }
            let resources = doc.dict([("ExtGState", doc.dict([("WmGS", gs)])), ("XObject", doc.dict([("WmTile", tile)]))])
            let form = doc.formXObject(Array(ops.utf8), 0, 0, w, h, resources, matrix: matrix)
            PageMarks.add(doc, page, form, kind, behind: options.behind, "<</Type /Pagination /Subtype /Watermark>>")
        }
        InfoDict.setDate(doc, "ModDate", Date())
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    /// Removes every watermark Inkvolt PDF added. Returns `data` itself when there are none.
    public static func remove(_ data: [UInt8], _ password: String?) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password)
        var any = false
        for page in try doc.pages() where PageMarks.remove(doc, page, kind) { any = true }
        if !any { return data }
        InfoDict.setDate(doc, "ModDate", Date())
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    /// True when the document has a watermark Inkvolt PDF added.
    public static func has(_ data: [UInt8], _ password: String?) throws -> Bool {
        PageMarks.has(try PdfEdit.openToRead(data, password), kind)
    }
}
