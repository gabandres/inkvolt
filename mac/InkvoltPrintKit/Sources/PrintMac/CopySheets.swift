import CoreGraphics
import Foundation
import PrintCore

/// A page copy laid out on paper (the Windows app's `QueuePrinter.PagesPaginator` for Copy): each side of the job in the order
/// `CopyLayout.order` gives (−1: a blank side), its pages placed by `CopyLayout.nUp` (1, 2 or 4 a side, actual size or fitted,
/// turned a quarter clockwise where a cell's orientation differs), written as a PDF of sides at the paper's size. Each
/// scanned page is decoded when its side is drawn and let go after it, so a long feeder copy never holds every page.
public enum CopySheets {
    /// Why the sheets couldn't be written: a page that can't be decoded, or the PDF file.
    public struct NotWritten: Error {
        public init() {}
    }

    /// Writes the sides to `url`. `paper`: in points (Letter 612 × 792, A4 595 × 842); `pages`: the scanned pages, their size
    /// in inches. Placement is worked out in 96ths of an inch, as Windows lays a copy out (`CopyLayout.nUpMargin` is ¼ in).
    /// `stop` is checked between sides.
    public static func write(_ pages: [BatchPrintPage], perSheet: Int, order: [Int], paper: CGSize, sizing: PageSizing, to url: URL,
                             stop: BatchStop? = nil) throws {
        let sides = try CopyLayout.sides(pages.count, perSheet)
        let toDip = 96.0 / 72, toPoint = 72.0 / 96
        let paperW = Double(paper.width) * toDip, paperH = Double(paper.height) * toDip
        var box = CGRect(origin: .zero, size: paper)
        guard paper.width > 0, paper.height > 0,
              let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: "Copy"] as CFDictionary) else { throw NotWritten() }
        defer { context.closePDF() }
        for side in order {
            try stop?.check()
            context.beginPDFPage(nil)
            defer { context.endPDFPage() }
            guard side >= 0, side < sides.count else { continue } // a blank back
            let on = sides[side]
            let placed = try CopyLayout.nUp(on.map { (w: pages[$0].widthInches * 96, h: pages[$0].heightInches * 96) }, perSheet, paperW, paperH, sizing)
            for (i, p) in placed.enumerated() {
                guard let image = try? ScanImaging.decode(pages[on[i]].jpeg, maxPixels: nil) else { throw NotWritten() }
                // Placements are top-left based, y down, in 96ths; PDF pages are y up, in points.
                let rect = CGRect(x: p.at.x * toPoint, y: Double(paper.height) - (p.at.y + p.at.height) * toPoint,
                                  width: p.at.width * toPoint, height: p.at.height * toPoint)
                draw(image, in: rect, turned: p.rotated, context)
            }
        }
    }

    /// A scanned page made small for the preview (`maxPixels` on its longest side), decoded as every scan is
    /// (`ScanImaging.decode`: a page whose header claims a size past `PageCleanup.maxPixels` is never decoded whole); nil when
    /// it can't be.
    public static func thumbnail(_ jpeg: [UInt8], maxPixels: Int) -> CGImage? { try? ScanImaging.decode(jpeg, maxPixels: maxPixels) }

    /// `image` filling `rect`; `turned`: a quarter clockwise first (its top on the rect's right), as `PageFit` turns a page.
    static func draw(_ image: CGImage, in rect: CGRect, turned: Bool, _ context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.interpolationQuality = .high
        guard turned else {
            context.draw(image, in: rect)
            return
        }
        // (u, v) in the image's box (rect's height × width) goes to (x + v, y + h − u): its top edge ends on the right.
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.rotate(by: -.pi / 2)
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.height, height: rect.width))
    }
}
