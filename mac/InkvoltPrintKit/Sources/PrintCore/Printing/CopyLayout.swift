import Foundation

/// Where an image goes on the paper, in the paper's units (left, top, width, height).
public struct Placement: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

/// Copying (scan, then print what was scanned): page placement at actual size, and the ID card copy layout, front on the
/// top half and back on the bottom half of one sheet. Units are whatever the caller uses for both page and paper.
public enum CopyLayout {
    /// One side of an ID card is scanned from the glass's top-left corner (the scanner's reference corner): 4.5 × 3 in, in
    /// eSCL's 1/300 in. An ID-1 card is 3.37 × 2.13 in, so there's room for a card placed a little off the corner.
    public static let idCardScanWidth = 1350, idCardScanHeight = 900

    /// Space kept clear around each half, so a side never runs into the printer's unprintable edge (¼ in at 96 per inch).
    public static let idCardMargin = 24.0

    /// A scanned page's size in inches, from its pixel size and the resolution it was scanned at.
    public static func inches(_ widthPx: Int, _ heightPx: Int, _ dpi: Int) -> (width: Double, height: Double) {
        dpi <= 0 ? (0, 0) : (Double(widthPx) / Double(dpi), Double(heightPx) / Double(dpi))
    }

    /// The ID card scan region on this scanner's glass: the corner area, clamped to what the glass allows.
    public static func idCardRequest(_ color: ScanColor, _ dpi: Int) -> ScanRequest {
        ScanRequest(source: .platen, color: color, resolution: dpi, width: idCardScanWidth, height: idCardScanHeight)
    }

    /// A copied page centred on the paper, turned to the paper's orientation as it prints: at its own size (only pages
    /// larger than the paper shrink to fit), or enlarged or shrunk to fill the paper.
    public static func page(_ pageW: Double, _ pageH: Double, _ paperW: Double, _ paperH: Double, _ sizing: PageSizing = .actualSize) -> PagePlacement {
        PageFit.place(pageW, pageH, paperW, paperH, sizing)
    }

    /// ID card copy: `front` centred in the top half, `back` in the bottom half, both at actual size. A side larger than its
    /// half (minus `margin` all round) shrinks to fit; both sides then use the same scale, so the copy's two halves always
    /// match.
    public static func idCard(_ paperW: Double, _ paperH: Double, _ front: (w: Double, h: Double), _ back: (w: Double, h: Double),
                              margin: Double = idCardMargin) -> (front: Placement, back: Placement) {
        let halfH = paperH / 2
        let boxW = max(1, paperW - 2 * margin)
        let boxH = max(1, halfH - 2 * margin)
        let scale = min(PageFit.scale(front.w, front.h, boxW, boxH, .actualSize), PageFit.scale(back.w, back.h, boxW, boxH, .actualSize))
        func place(_ top: Double, _ side: (w: Double, h: Double)) -> Placement {
            let (w, h) = (side.w * scale, side.h * scale)
            return Placement((paperW - w) / 2, top + (halfH - h) / 2, w, h)
        }
        return (place(0, front), place(halfH, back))
    }
}
