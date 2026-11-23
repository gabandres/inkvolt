import Foundation
import PrintCore

/// Blank pages of a document (the back of a one-sided sheet, a separator sheet; the Windows app's `BlankPages`, roadmap
/// 4.4): a page is blank when its picture, as it shows with its comments, is almost all paper, by the test File › Scan
/// uses to skip blank pages (PrintCore's `BlankPage`, the shared scanning code): a page with as little as a short word on
/// it is not blank, specks and show-through are. Remove Blank Pages, Split at Blank Pages and their Batch actions go
/// through here.
public enum BlankPages {
    /// The longer side of the picture a page is judged on, in pixels (as File › Scan judges a scan).
    public static let analysisSize = 1100.0

    /// Whether `page` is blank. A page that can't be drawn (or isn't in the document) is not: no page is ever lost to the
    /// check.
    /// - Throws: `CancellationError` when `cancel` fired.
    public static func isBlank(_ engine: PdfEngine, _ page: Int, cancel: CancelToken? = nil) throws -> Bool {
        guard page >= 0, page < engine.pageCount else { return false }
        let image: RenderedImage
        do {
            let g = engine.page(page)
            let longest = max(g.width, g.height)
            if !longest.isFinite || longest <= 0 { return false }
            image = try engine.render(page, scale: analysisSize / longest, cancel: cancel)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return false
        }
        return BlankPage.isBlank(gray(image))
    }

    /// The blank pages among `pages` (all when nil), in page order; `progress` is told (done, total) before each page.
    /// - Throws: `CancellationError` when `cancel` fired.
    public static func find(_ engine: PdfEngine, pages: [Int]? = nil, progress: ((Int, Int) -> Void)? = nil, cancel: CancelToken? = nil) throws -> [Int] {
        let look = pages ?? Array(0..<engine.pageCount)
        var blank = Set<Int>()
        for (i, p) in look.enumerated() {
            try cancel.check()
            progress?(i, look.count)
            if try isBlank(engine, p, cancel: cancel) { blank.insert(p) }
        }
        return blank.sorted()
    }

    /// The documents a stack with blank separator sheets holds: the runs of pages between blank ones, the blank pages left
    /// out. Several blank pages in a row (a sheet's two sides) separate once; runs of no page are dropped.
    public static func splitAt(_ pageCount: Int, _ blanks: [Int]) -> [[Int]] {
        let separators = Set(blanks)
        var parts: [[Int]] = []
        var run: [Int] = []
        for p in 0..<max(pageCount, 0) {
            if !separators.contains(p) {
                run.append(p)
                continue
            }
            if !run.isEmpty { parts.append(run) }
            run = []
        }
        if !run.isEmpty { parts.append(run) }
        return parts
    }

    /// Removes the blank pages `blanks` (as found by `find` and reviewed), with the bookmarks and links that led to them,
    /// as Delete Pages does.
    /// - Throws: `PdfEditError` when every page is blank: a document keeps at least one page.
    public static func remove(_ data: [UInt8], _ password: String?, _ blanks: [Int]) throws -> [UInt8] {
        try PageEditor.delete(data, password, blanks)
    }

    /// An RGB picture as 8-bit grey (0 black, 255 white), as the scan's test reads it (Windows' weights, its picture BGR).
    static func gray(_ image: RenderedImage) -> PrintCore.GrayImage {
        let px = image.pixels
        let n = min(image.width * image.height, px.count / 3)
        var gray = [UInt8](repeating: 255, count: max(image.width * image.height, 0))
        for i in 0..<n {
            let s = i * 3
            gray[i] = UInt8((Int(px[s]) * 77 + Int(px[s + 1]) * 150 + Int(px[s + 2]) * 29) >> 8)
        }
        return PrintCore.GrayImage(width: image.width, height: image.height, pixels: gray)
    }
}
