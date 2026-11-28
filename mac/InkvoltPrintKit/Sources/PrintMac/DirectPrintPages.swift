import CoreGraphics
import Foundation
import PDFKit
import PrintCore

/// The pages of a PDF made ready to go straight to a printer (roadmap 2.1, Windows' DirectPrinter drawing with WPF): each page
/// drawn by PDFKit (annotations and filled form fields included, its own /Rotate applied) at the plan's drawing resolution on
/// the plan's paper, fitted inside the paper's margins and centred, a landscape page on portrait paper turned a quarter
/// clockwise (`PageFit`, as Print a PDF's macOS route fits pages), white around it; then made grey or RGB as the plan says,
/// enlarged to the printer's resolution and cut to the job's exact size. One page's pixels are held at a time, and the
/// encoded pages go to the job's file as they're made (`write`). A sheet already laid out for the paper (Print photos, an
/// ID card copy, Print a PDF's layouts: `Layout.sheet`) goes on the whole paper at its own size, as Windows' paginators lay
/// out on the whole paper.
public enum DirectPrintPages {
    /// How a page goes on the paper: inside the printer's margins, sized as asked (Print a PDF, Copy, a batch's files); or a
    /// sheet laid out for this paper, on all of it at its own size (only a larger one shrinks), centred.
    public enum Layout: Sendable, Equatable {
        case fitted(PageSizing)
        case sheet
    }

    /// Why a page couldn't be drawn (Windows' `CoreStrings.Direct_NotDrawn`): nothing was sent.
    public struct NotDrawn: Error {
        public init() {}
    }

    /// The raster document for `pages` of `document` (indices; every page when nil), as `plan` says: its pages, a blank back
    /// between copies the printer doesn't make where a two-sided copy has an odd count, `plan.repeatCount` times. Each page's
    /// bytes go to `out` as soon as they're encoded (a `DirectJobFile`'s append, which refuses a job past its limit), so the
    /// document is never held whole. Checks `Task.isCancelled` and `stop` between pages.
    public static func write(_ document: PDFDocument, pages: [Int]? = nil, plan: DirectPrintPlan, layout: Layout = .fitted(.fitToPaper),
                             stop: BatchStop? = nil, to out: ([UInt8]) throws -> Void) throws {
        let indices = pages ?? Array(0..<document.pageCount)
        guard !indices.isEmpty else { throw NotDrawn() }
        let perCopy = plan.pagesPerCopy(indices.count)
        let writer = try RasterWriter.forJob(plan.job(perCopy))
        var drawn: [Int: RasterPage] = [:] // kept only while a copy repeats, at most a few pages' worth
        let keep = plan.repeatCount > 1 && indices.count <= 4
        for _ in 0..<plan.repeatCount {
            for i in indices {
                if Task.isCancelled || stop?.isStopped == true { throw CancellationError() }
                guard let page = document.page(at: i) else { throw NotDrawn() }
                let raster = try drawn[i] ?? Self.page(page, plan: plan, job: writer.job, layout: layout)
                if keep { drawn[i] = raster }
                try writer.write(raster)
                try out(writer.drain())
            }
            if perCopy > indices.count {
                try writer.write(try RasterPage.blank(width: writer.job.widthPixels, height: writer.job.heightPixels, color: writer.job.color))
                try out(writer.drain())
            }
        }
        try writer.finish()
        try out(writer.drain())
    }

    /// The whole raster document in memory (the checks' small ones).
    public static func document(_ document: PDFDocument, pages: [Int]? = nil, plan: DirectPrintPlan, layout: Layout = .fitted(.fitToPaper)) throws -> [UInt8] {
        var all: [UInt8] = []
        try write(document, pages: pages, plan: plan, layout: layout) { all += $0 }
        return all
    }

    /// One page, the job's paper in pixels at its resolution and color.
    public static func page(_ page: PDFPage, plan: DirectPrintPlan, job: RasterJob, layout: Layout = .fitted(.fitToPaper)) throws -> RasterPage {
        let dpi = plan.renderDpi
        let paper = plan.paper
        let (w, h) = (RasterJob.pixels(paper.widthHmm, dpi), RasterJob.pixels(paper.heightHmm, dpi))
        guard w > 0, h > 0, DirectPrintPlan.fits(paper, dpi) else { throw NotDrawn() } // a page that fits in memory (the plan chose so)
        let px = { (hmm: Int) in Double(hmm) * Double(dpi) / 2540 }
        let sheet = layout == .sheet
        let (left, top, right, bottom) = sheet ? (0.0, 0.0, 0.0, 0.0) : (px(paper.left), px(paper.top), px(paper.right), px(paper.bottom))
        let (areaW, areaH) = (Double(w) - left - right, Double(h) - top - bottom)
        guard areaW > 1, areaH > 1 else { throw NotDrawn() }
        let box = page.bounds(for: .cropBox)
        let turned = page.rotation % 180 != 0
        let (pageW, pageH) = turned ? (Double(box.height), Double(box.width)) : (Double(box.width), Double(box.height))
        guard pageW > 0, pageH > 0 else { throw NotDrawn() }
        // Placed in pixels (the page's points at the drawing resolution), so PageFit's same-size rule sees like for like.
        let toPixels = Double(dpi) / 72
        let sizing: PageSizing = if case .fitted(let s) = layout { s } else { .actualSize }
        let place = PageFit.place(pageW * toPixels, pageH * toPixels, areaW, areaH, sizing)
        let scale = place.rotated ? place.at.width / pageH : place.at.width / pageW // pixels per point

        let stride = w * 4
        var bgra = [UInt8](repeating: 255, count: stride * h)
        let ok: Bool = bgra.withUnsafeMutableBytes { buffer in
            let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                                          space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(), bitmapInfo: info) else { return false }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            // The placed box's bottom left corner in Core Graphics' coordinates (y up from the paper's bottom).
            let x = left + place.at.x
            let y = bottom + (areaH - place.at.y - place.at.height)
            context.translateBy(x: CGFloat(x), y: CGFloat(y))
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            if place.rotated {
                // A quarter clockwise: the page's top edge goes to the right.
                context.translateBy(x: 0, y: CGFloat(pageW))
                context.rotate(by: -.pi / 2)
            }
            context.interpolationQuality = .high
            page.draw(with: .cropBox, to: context)
            return true
        }
        guard ok else { throw NotDrawn() }
        let raster = try RasterPage.fromBgra(width: w, height: h, stride: stride, bgra, color: plan.color, grey: plan.grey)
        return try raster.enlarged(plan.enlarge).fitted(width: job.widthPixels, height: job.heightPixels)
    }
}
