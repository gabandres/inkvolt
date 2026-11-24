import Foundation

/// One bar across a patch: its offset from the patch's edge and its width, in inches.
public struct PatchBar: Equatable, Sendable {
    public var offset: Double
    public var width: Double

    public init(offset: Double, width: Double) {
        self.offset = offset
        self.width = width
    }
}

/// A filled rectangle on a sheet. `SeparatorSheet.layout`: inches from the top-left corner; `SeparatorSheetPage.bars`:
/// points from the bottom-left corner (PDF and Core Graphics space).
public struct SheetRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// A line of text on the separator sheet: Helvetica at `size` points, centred across the page (but at least
/// `SeparatorSheet.minTextMargin` from the left edge), its baseline `baseline` points from the bottom.
public struct SheetText: Equatable, Sendable {
    public var text: String
    public var size: Double
    public var baseline: Double

    public init(_ text: String, size: Double, baseline: Double) {
        self.text = text
        self.size = size
        self.baseline = baseline
    }
}

/// The separator sheet as the Mac draws it (into a one-page PDF context): page size, the bars and the text, in points from
/// the bottom-left corner. Black on white.
public struct SeparatorSheetPage: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var bars: [SheetRect]
    /// The QR code saying PATCHT (`SeparatorSheet.qrLayout`), a rectangle per run of dark modules; none for an image-control
    /// patch.
    public var qr: [SheetRect] = []
    public var lines: [SheetText]
    /// The PDF's title: "Separator sheet (Patch T)".
    public var title: String
}

/// A printable separator sheet: one page with a patch code at its exact size (vector bars, `PatchCodes` geometry) in the
/// middle, running down the page, with a clear zone around it, and a few lines of text above and below saying what it is and
/// how to use it. Left of the bars of a separating patch (2, 3 or T), well clear of their clear zone, a QR code saying PATCHT
/// (`SeparatorCodes`), read when the bars aren't (and by Paperless-ngx). Printed at actual size it is read by Inkvolt Print's
/// batch scanning (and by scanners that read patch codes themselves). PrintCore has the geometry; the Mac draws it with Core
/// Graphics (the Windows app writes the PDF itself).
public enum SeparatorSheet {
    /// How long the bars are, in inches: twice the spec's 2 in minimum, so a sheet fed off-centre still shows enough.
    public static let barLength = 4.0

    /// The QR code's side without its quiet zone, in inches: about 0.06 in a module, 6 pixels in the app's analysis copy of a page.
    public static let qrSize = 1.25

    /// The QR code's dark modules on the sheet, in inches from the top-left, joined into a rectangle per run along each row:
    /// left of the bars, level with their middle. None on the sheet of an image-control patch (1, 4 or 6), which separates
    /// nothing.
    public static func qrLayout(_ code: PatchCode, widthIn: Double, heightIn: Double) -> [SheetRect] {
        guard PatchCodes.separates(code) else { return [] }
        let modules = SeparatorCodes.qrModules()
        let module: Double = qrSize / Double(modules[0].count)
        let left: Double = (widthIn - PatchCodes.size) / 2 - 1.35 - qrSize // 1.35 in from the bars: past their 0.8 in clear zone
        let top: Double = (heightIn - barLength) / 2 - 0.25 + (barLength - qrSize) / 2
        var rects: [SheetRect] = []
        for (y, row) in modules.enumerated() {
            var x = 0
            while x < row.count {
                guard row[x] else {
                    x += 1
                    continue
                }
                let start = x
                while x + 1 < row.count && row[x + 1] { x += 1 }
                let rx: Double = left + Double(start) * module
                rects.append(SheetRect(x: rx, y: top + Double(y) * module, width: Double(x - start + 1) * module, height: module))
                x += 1
            }
        }
        return rects
    }

    /// Text never starts closer than this to the page's left edge, in points.
    public static let minTextMargin = 36.0

    /// The four bars across the patch, in reading order.
    public static func bars(_ code: PatchCode) -> [PatchBar] {
        var bars: [PatchBar] = []
        var x = 0.0
        for c in PatchCodes.pattern(code) {
            let width: Double = c == "W" ? PatchCodes.wide : PatchCodes.narrow
            bars.append(PatchBar(offset: x, width: width))
            x += width + PatchCodes.narrow
        }
        return bars
    }

    /// The bars on a `widthIn` × `heightIn` inch sheet, in inches from the top-left: centred, a little above the middle.
    public static func layout(_ code: PatchCode, widthIn: Double, heightIn: Double) -> [SheetRect] {
        let left: Double = (widthIn - PatchCodes.size) / 2
        let top: Double = (heightIn - barLength) / 2 - 0.25
        return bars(code).map { SheetRect(x: left + $0.offset, y: top, width: $0.width, height: barLength) }
    }

    /// The sheet on a `widthIn` × `heightIn` inch page (Letter or A4); nil when the page is too short for the patch and its
    /// text.
    public static func page(_ code: PatchCode, widthIn: Double, heightIn: Double) -> SeparatorSheetPage? {
        let w: Double = widthIn * 72
        let h: Double = heightIn * 72
        let inches = layout(code, widthIn: widthIn, heightIn: heightIn)
        let points: (SheetRect) -> SheetRect = { r in
            let y: Double = h - (r.y + r.height) * 72
            return SheetRect(x: r.x * 72, y: y, width: r.width * 72, height: r.height * 72)
        }
        let bars: [SheetRect] = inches.map(points)
        let qr: [SheetRect] = qrLayout(code, widthIn: widthIn, heightIn: heightIn).map(points)
        let top: Double = inches[0].y * 72 // points from the top: text stays an inch clear of the bars
        let bottom: Double = (inches[0].y + barLength) * 72
        let foot: Double = 72 * 2.1
        if h - bottom < foot + 72 { return nil }

        let name = PatchCodes.name(code)
        let lines: [SheetText] = [
            SheetText(loc("Separator sheet"), size: 26, baseline: h - 72),
            SheetText(name, size: 18, baseline: h - 104),
            SheetText(loc("Inkvolt Print starts a new file at this sheet."), size: 11, baseline: h - min(top - 72, 150)),
            SheetText(loc("Put a copy in front of each document in the feeder, face up like the pages."), size: 11, baseline: foot),
            SheetText(loc("On the Scan tab, choose \"Split into files at: Patch or QR codes\"."), size: 11, baseline: foot - 16),
            SheetText(loc("Print at actual size (100%, not \"fit to page\"), in black. Keep the area around the bars clean."),
                      size: 9, baseline: foot - 40),
            SheetText(loc("Reuse the sheet rather than copying it: copiers widen bars. Scanned sheets are left out unless you keep them."),
                      size: 9, baseline: foot - 54),
        ]
        return SeparatorSheetPage(width: w, height: h, bars: bars, qr: qr, lines: lines, title: loc("Separator sheet ({0})", name))
    }

    /// The sheet's bars and QR code (no text) as a scan of it would show them at `pixelsPerInch`: black on white. For tests
    /// and demo mode. `bars` false: the QR code alone (a sheet whose bars were cut away).
    public static func image(_ code: PatchCode, widthIn: Double, heightIn: Double, pixelsPerInch: Double, bars: Bool = true, qr: Bool = true)
        -> GrayImage {
        let width = Int(widthIn * pixelsPerInch)
        let height = Int(heightIn * pixelsPerInch)
        var pixels = [UInt8](repeating: 255, count: width * height)
        let marks: [SheetRect] = (bars ? layout(code, widthIn: widthIn, heightIn: heightIn) : [])
            + (qr ? qrLayout(code, widthIn: widthIn, heightIn: heightIn) : [])
        for r in marks {
            let x0 = max(0, Int((r.x * pixelsPerInch).rounded())) // bounded: the sheet's own layout, at a test's or demo's resolution
            let y0 = max(0, Int((r.y * pixelsPerInch).rounded())) // bounded: the sheet's own layout, at a test's or demo's resolution
            let x1 = min(width, Int(((r.x + r.width) * pixelsPerInch).rounded())) // bounded: the sheet's own layout, at a test's or demo's resolution
            let y1 = min(height, Int(((r.y + r.height) * pixelsPerInch).rounded())) // bounded: the sheet's own layout, at a test's or demo's resolution
            if x0 >= x1 || y0 >= y1 { continue }
            for y in y0..<y1 {
                for x in x0..<x1 { pixels[y * width + x] = 0 }
            }
        }
        return GrayImage(width: width, height: height, pixels: pixels)
    }
}
