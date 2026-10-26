import Foundation

/// A standard print size, short side first, in inches.
public struct PhotoSize: Equatable, Sendable {
    public var name: String
    public var width: Double
    public var height: Double

    public init(_ name: String, _ width: Double, _ height: Double) {
        self.name = name
        self.width = width
        self.height = height
    }
}

/// The print sizes the photo layout offers.
public enum PhotoSizes {
    public static let in4x6 = PhotoSize("4 × 6 in", 4, 6)
    public static let in5x7 = PhotoSize("5 × 7 in", 5, 7)
    public static let in8x10 = PhotoSize("8 × 10 in", 8, 10)
    public static let cm10x15 = PhotoSize("10 × 15 cm", 100 / 25.4, 150 / 25.4)
    public static let cm13x18 = PhotoSize("13 × 18 cm", 130 / 25.4, 180 / 25.4)
    public static let wallet = PhotoSize("Wallet (2.5 × 3.5 in)", 2.5, 3.5)

    public static let all = [in4x6, in5x7, in8x10, cm10x15, cm13x18, wallet]
}

public enum PhotoLayoutKind: Sendable {
    /// One photo per sheet, as large as the printable area.
    case fullPage

    /// Prints at a standard photo size (`PhotoLayoutOptions.size`), as many per sheet as fit.
    case printSize

    /// An index: `PhotoLayoutOptions.perSheet` small whole photos per sheet, each with its file name.
    case contactSheet
}

public enum PhotoFit: Sendable {
    /// Covers the whole cell; what doesn't fit is cropped (the crop can be moved and zoomed).
    case fill

    /// Shows the whole photo; white bands where its shape differs from the cell's.
    case fit
}

public struct PhotoLayoutOptions: Equatable, Sendable {
    public var kind: PhotoLayoutKind
    public var size: PhotoSize

    /// Contact sheet: photos per sheet.
    public var perSheet: Int

    public var fit: PhotoFit

    /// Print sizes: every cell of a sheet holds the same photo (wallets of one portrait); copies count sheets.
    public var onePhotoPerSheet: Bool

    public init(kind: PhotoLayoutKind = .fullPage, size: PhotoSize = PhotoSizes.in4x6, perSheet: Int = 12, fit: PhotoFit = .fill,
                onePhotoPerSheet: Bool = false) {
        self.kind = kind
        self.size = size
        self.perSheet = perSheet
        self.fit = fit
        self.onePhotoPerSheet = onePhotoPerSheet
    }
}

/// A sheet of paper in inches, with the margins the printer can't print in (all zero: borderless).
public struct SheetPaper: Equatable, Sendable {
    public var width: Double, height: Double, left: Double, top: Double, right: Double, bottom: Double

    public init(_ width: Double, _ height: Double, _ left: Double, _ top: Double, _ right: Double, _ bottom: Double) {
        self.width = width
        self.height = height
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public var printable: Placement { Placement(left, top, max(0, width - left - right), max(0, height - top - bottom)) }
}

/// How a photo sits in its cell. `zoom` ≥ 1 enlarges it beyond fill or fit; `panX` and `panY` (−1 … 1) move the visible
/// part to an edge of the photo, in the photo's own frame, so a turned photo keeps its crop.
public struct PhotoCrop: Equatable, Sendable {
    public var zoom: Double, panX: Double, panY: Double

    public init(_ zoom: Double, _ panX: Double, _ panY: Double) {
        self.zoom = zoom
        self.panX = panX
        self.panY = panY
    }

    public static let maxZoom = 4.0
    public static let none = PhotoCrop(1, 0, 0)

    public var isNone: Bool { zoom <= 1 && panX == 0 && panY == 0 }
}

/// A photo to lay out: its size as it should look (EXIF and the user's turns applied), in pixels.
public struct PhotoInput: Equatable, Sendable {
    public var width: Double, height: Double
    public var copies: Int
    public var crop: PhotoCrop

    public init(_ width: Double, _ height: Double, _ copies: Int, _ crop: PhotoCrop) {
        self.width = width
        self.height = height
        self.copies = copies
        self.crop = crop
    }
}

/// One print on a sheet: `cell` is its place on the paper; `image` the box the whole photo is drawn in (larger than the
/// cell when cropped: draw it clipped to the cell); `turned`: a quarter turn clockwise to suit the cell; `caption` where
/// the file name goes (contact sheets). Inches, from the paper's top-left corner.
public struct PhotoCell: Equatable, Sendable {
    public var photo: Int
    public var cell: Placement
    public var image: Placement
    public var turned: Bool
    public var caption: Placement?

    public init(_ photo: Int, _ cell: Placement, _ image: Placement, _ turned: Bool, _ caption: Placement? = nil) {
        self.photo = photo
        self.cell = cell
        self.image = image
        self.turned = turned
        self.caption = caption
    }
}

public struct PhotoSheet: Equatable, Sendable {
    public var cells: [PhotoCell]

    public init(_ cells: [PhotoCell]) { self.cells = cells }
}

/// The cells of one sheet; `shrunk`: the print size didn't fit in the printable area, so one smaller print.
public struct SheetGrid: Equatable, Sendable {
    public var cells: [Placement]
    public var shrunk: Bool

    public init(_ cells: [Placement], _ shrunk: Bool) {
        self.cells = cells
        self.shrunk = shrunk
    }
}

/// Photo printing layouts: cells per sheet, fit and fill, turning each photo to its cell's orientation, crop and pan, and
/// the resolution a photo prints at. Pure arithmetic in inches; the app draws the result (preview and print alike).
public enum PhotoLayout {
    /// Space left between prints for cutting them apart, when the sheet has room for it.
    public static let cutGap = 0.125

    /// Below this a print may look soft.
    public static let lowDpi = 150.0

    private static let epsilon = 1e-9

    /// Every sheet to print, in order. Photos without copies are left out; a contact sheet shows each photo once.
    public static func sheets(_ photos: [PhotoInput], _ options: PhotoLayoutOptions, _ paper: SheetPaper) -> [PhotoSheet] {
        if photos.isEmpty { return [] }
        if options.kind == .contactSheet { return contactSheets(photos, options, paper) }

        let landscape = photos.filter { $0.width > $0.height }.count
        let cells = grid(options, paper, preferLandscape: landscape > photos.count - landscape).cells
        if cells.isEmpty { return [] }

        // Which photo goes in each print, in order.
        var sheets: [PhotoSheet] = []
        if options.kind == .printSize && options.onePhotoPerSheet {
            for (i, photo) in photos.enumerated() {
                for _ in 0..<max(0, photo.copies) { sheets.append(PhotoSheet(cells.map { cell(i, photo, $0, options.fit) })) }
            }
            return sheets
        }
        var prints: [Int] = []
        for (i, photo) in photos.enumerated() { prints += repeatElement(i, count: max(0, photo.copies)) }
        for start in stride(from: 0, to: prints.count, by: cells.count) {
            let chunk = prints[start..<min(start + cells.count, prints.count)]
            sheets.append(PhotoSheet(chunk.enumerated().map { k, p in cell(p, photos[p], cells[k], options.fit) }))
        }
        return sheets
    }

    private static func cell(_ index: Int, _ photo: PhotoInput, _ cell: Placement, _ fit: PhotoFit) -> PhotoCell {
        let turned = shouldTurn(photo.width, photo.height, cell.width, cell.height)
        return PhotoCell(index, cell, place(cell, photo.width, photo.height, fit, photo.crop, turned: turned), turned)
    }

    /// A landscape photo in a portrait cell (or the reverse) is turned rather than cropped or shrunk; squares never are.
    public static func shouldTurn(_ photoW: Double, _ photoH: Double, _ cellW: Double, _ cellH: Double) -> Bool {
        photoW != photoH && cellW != cellH && (photoW > photoH) != (cellW > cellH)
    }

    /// The cells of one sheet. Full page: the printable area. Print size: as many prints as fit at their real size, in the
    /// orientation that fits more (a tie goes to `preferLandscape`), centred, with a `cutGap` between them where there's
    /// room; a size larger than the printable area shrinks to it (one per sheet).
    public static func grid(_ options: PhotoLayoutOptions, _ paper: SheetPaper, preferLandscape: Bool) -> SheetGrid {
        let area = paper.printable
        if area.width <= 0 || area.height <= 0 { return SheetGrid([], false) }
        switch options.kind {
        case .fullPage:
            return SheetGrid([area], false)
        case .contactSheet:
            let (cols, rows) = contactGrid(options.perSheet, area.width, area.height)
            let (w, h) = (area.width / Double(cols), area.height / Double(rows))
            var cells: [Placement] = []
            cells.reserveCapacity(cols * rows)
            for r in 0..<rows {
                for c in 0..<cols { cells.append(Placement(area.x + Double(c) * w, area.y + Double(r) * h, w, h)) }
            }
            return SheetGrid(cells, false)
        case .printSize:
            break
        }

        let (sw, sh) = (options.size.width, options.size.height)
        let portrait = count(sw, sh, area)
        let landscape = count(sh, sw, area)
        let (portraitN, landscapeN) = (portrait.cols * portrait.rows, landscape.cols * landscape.rows)
        let useLandscape = landscapeN > portraitN || (landscapeN == portraitN && preferLandscape)
        var (cw, ch) = useLandscape ? (sh, sw) : (sw, sh)
        let (nc, nr) = useLandscape ? landscape : portrait
        if nc * nr == 0 {
            // Doesn't fit at its size: one print, shrunk into the printable area, turned to suit it.
            if (cw > ch) != (area.width > area.height) { (cw, ch) = (ch, cw) }
            let scale = min(area.width / cw, area.height / ch)
            (cw, ch) = (cw * scale, ch * scale)
            return SheetGrid([Placement(area.x + (area.width - cw) / 2, area.y + (area.height - ch) / 2, cw, ch)], true)
        }
        let gapX = nc > 1 ? min(cutGap, (area.width - Double(nc) * cw) / Double(nc - 1)) : 0
        let gapY = nr > 1 ? min(cutGap, (area.height - Double(nr) * ch) / Double(nr - 1)) : 0
        let x0 = area.x + (area.width - (Double(nc) * cw + Double(nc - 1) * gapX)) / 2
        let y0 = area.y + (area.height - (Double(nr) * ch + Double(nr - 1) * gapY)) / 2
        var list: [Placement] = []
        list.reserveCapacity(nc * nr)
        for r in 0..<nr {
            for c in 0..<nc { list.append(Placement(x0 + Double(c) * (cw + gapX), y0 + Double(r) * (ch + gapY), cw, ch)) }
        }
        return SheetGrid(list, false)
    }

    /// Prints of `w` × `h` that fit across and down `area`. A size of zero (or one so small the count is absurd) fits none,
    /// rather than trapping on the conversion to `Int`.
    private static func count(_ w: Double, _ h: Double, _ area: Placement) -> (cols: Int, rows: Int) {
        func fits(_ length: Double, _ size: Double) -> Int {
            let n = (length / size + epsilon).rounded(.down)
            return n.isFinite && n >= 0 && n <= 10_000 ? Int(n) : 0
        }
        return (fits(area.width, w), fits(area.height, h))
    }

    /// Columns × rows for `perSheet` photos on a printable area: the split whose cells come closest to a photo-and-caption
    /// shape (a little wider than tall), so 12 is 3 × 4 on portrait paper and 4 × 3 on landscape.
    public static func contactGrid(_ perSheet: Int, _ width: Double, _ height: Double) -> (columns: Int, rows: Int) {
        let perSheet = min(max(perSheet, 1), 100)
        let target = 1.2
        var best = (columns: 1, rows: perSheet)
        var bestScore = Double.greatestFiniteMagnitude
        for cols in 1...perSheet where perSheet % cols == 0 {
            let rows = perSheet / cols
            let score = abs(log(width / Double(cols) / (height / Double(rows)) / target))
            if score < bestScore - epsilon { (best, bestScore) = ((cols, rows), score) }
        }
        return best
    }

    /// Contact sheets: each photo once, whole, as large as its cell allows above a line for its file name.
    private static func contactSheets(_ photos: [PhotoInput], _ options: PhotoLayoutOptions, _ paper: SheetPaper) -> [PhotoSheet] {
        let cells = grid(options, paper, preferLandscape: false).cells
        if cells.isEmpty { return [] }
        var sheets: [PhotoSheet] = []
        for start in stride(from: 0, to: photos.count, by: cells.count) {
            var list: [PhotoCell] = []
            for (k, cell) in cells.enumerated() where start + k < photos.count {
                let pad = min(0.06, cell.width * 0.05)
                let caption = min(0.22, cell.height * 0.2)
                let picture = Placement(cell.x + pad, cell.y + pad, max(0, cell.width - 2 * pad), max(0, cell.height - 2 * pad - caption))
                let photo = photos[start + k]
                list.append(PhotoCell(start + k, cell, place(picture, photo.width, photo.height, .fit, .none, turned: false), false,
                                      Placement(picture.x, picture.y + picture.height, picture.width, caption)))
            }
            sheets.append(PhotoSheet(list))
        }
        return sheets
    }

    /// The box a `photoW` × `photoH` photo (any units; only its shape counts) is drawn in for `cell`: filled or fitted,
    /// zoomed, and moved by the crop's pan within what overflows the cell. `turned`: the photo is drawn a quarter turn
    /// clockwise, so the box is its turned shape.
    public static func place(_ cell: Placement, _ photoW: Double, _ photoH: Double, _ fit: PhotoFit, _ crop: PhotoCrop, turned: Bool) -> Placement {
        if photoW <= 0 || photoH <= 0 || cell.width <= 0 || cell.height <= 0 { return cell }
        var (w, h) = turned ? (photoH, photoW) : (photoW, photoH)
        var scale = fit == .fill ? max(cell.width / w, cell.height / h) : min(cell.width / w, cell.height / h)
        scale *= min(max(crop.zoom, 1), PhotoCrop.maxZoom)
        (w, h) = (w * scale, h * scale)
        let (panX, panY) = cellPan(crop, turned)
        let overX = max(0, w - cell.width)
        let overY = max(0, h - cell.height)
        return Placement(cell.x + (cell.width - w) / 2 - panX * overX / 2, cell.y + (cell.height - h) / 2 - panY * overY / 2, w, h)
    }

    /// The crop after dragging the photo by (`dx`, `dy`) on the paper (same units as the cell): the photo follows the
    /// pointer until its edge meets the cell's edge.
    public static func drag(_ cell: Placement, _ photoW: Double, _ photoH: Double, _ fit: PhotoFit, _ crop: PhotoCrop, turned: Bool,
                            dx: Double, dy: Double) -> PhotoCrop {
        let image = place(cell, photoW, photoH, fit, crop, turned: turned)
        let overX = image.width - cell.width
        let overY = image.height - cell.height
        var (panX, panY) = cellPan(crop, turned)
        if overX > epsilon { panX = min(max(panX - 2 * dx / overX, -1), 1) }
        if overY > epsilon { panY = min(max(panY - 2 * dy / overY, -1), 1) }
        // Back to the photo's own frame (see cellPan).
        var moved = crop
        (moved.panX, moved.panY) = turned ? (panY, -panX) : (panX, panY)
        return moved
    }

    /// The pan along the cell's axes. A quarter turn clockwise puts the photo's top on the cell's right and its right on
    /// the cell's bottom: the cell's x pan is the photo's −y pan, its y pan the photo's x pan.
    private static func cellPan(_ crop: PhotoCrop, _ turned: Bool) -> (x: Double, y: Double) {
        let (x, y) = (min(max(crop.panX, -1), 1), min(max(crop.panY, -1), 1))
        return turned ? (-y, x) : (x, y)
    }

    /// The resolution a photo of `pixelW` × `pixelH` prints at in `image` (inches).
    public static func dpi(_ pixelW: Double, _ pixelH: Double, _ image: Placement, turned: Bool) -> Double {
        let (w, h) = turned ? (image.height, image.width) : (image.width, image.height)
        return w <= 0 || h <= 0 ? 0 : min(pixelW / w, pixelH / h)
    }

    /// The width to decode a `pixels`-wide photo at for a print `inches` wide: no more than `maxDpi`, since more detail
    /// only makes the print job bigger.
    public static func decodeWidth(_ pixels: Int, _ inches: Double, _ maxDpi: Int) -> Int {
        if inches <= 0 { return pixels }
        let needed = (inches * Double(maxDpi)).rounded(.up)
        guard needed.isFinite, needed < Double(pixels) else { return pixels }
        return Int(needed)
    }
}
