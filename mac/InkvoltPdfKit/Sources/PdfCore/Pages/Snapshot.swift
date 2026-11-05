import Foundation

/// The Snapshot tool (the Windows viewer's `CopySnapshot`): a rectangle dragged on a page is copied as a picture, the way
/// the page shows (the view's rotation applied), at least 144 dpi (2 pixels a point) or the view's own resolution when
/// that is sharper, and at most 40 megapixels. The app puts the picture on the clipboard; this decides what is rendered.
public enum Snapshot {
    /// A side shorter than this (page points) isn't a drag: nothing is copied, as on Windows.
    public static let minimumSide = 2.0
    /// Pixels a page point at least (144 dpi).
    public static let minimumScale = 2.0
    /// Pixels a picture at most.
    public static let maximumPixels = 40_000_000.0
    /// The view's scale is taken up to this (pixels a point); anything above, or not a number, is no view scale at all.
    static let largestViewScale = 64.0

    /// The page region a drag from `start` to `end` marks (page points, top-left origin), cut to the page; nil when it is
    /// too small to copy or a point isn't a number.
    public static func region(_ start: PointD, _ end: PointD, pageWidth: Double, pageHeight: Double) -> RectD? {
        let values: [Double] = [start.x, start.y, end.x, end.y, pageWidth, pageHeight]
        guard values.allSatisfy(\.isFinite), pageWidth > 0, pageHeight > 0 else { return nil }
        func clamp(_ v: Double, _ limit: Double) -> Double { min(max(v, 0), limit) }
        let r = RectD.fromEdges(clamp(start.x, pageWidth), clamp(start.y, pageHeight), clamp(end.x, pageWidth), clamp(end.y, pageHeight))
        return r.width < minimumSide || r.height < minimumSide ? nil : r
    }

    /// Pixels a page point for `region`: the view's (zoom times the screen's backing scale) when over 2, then cut by a
    /// fifth at a time until the picture is under 40 megapixels (Windows' loop).
    public static func scale(for region: RectD, viewScale: Double) -> Double {
        var scale = viewScale.isFinite && viewScale <= largestViewScale ? max(minimumScale, viewScale) : minimumScale
        let area = region.width * region.height
        guard area.isFinite, area > 0 else { return scale }
        while area * scale * scale > maximumPixels { scale *= 0.8 }
        return scale
    }

    /// The picture's size in points as it shows (turned by the view's rotation): what an app pastes it at.
    public static func shownSize(_ region: RectD, rotation: Int) -> (width: Double, height: Double) {
        RotatedView.size(region.width, region.height, RotatedView.normalize(rotation))
    }

    /// The picture of `region` on `page`, turned as the view shows the page.
    /// - Throws: what the engine's render throws (`PdfEngineClosed` when the document was closed meanwhile,
    ///   `CancellationError`, `PdfEngineError`).
    public static func render(_ engine: PdfEngine, page: Int, region: RectD, viewScale: Double, rotation: Int,
                              cancel: CancelToken? = nil) throws -> RenderedImage {
        let scale = scale(for: region, viewScale: viewScale)
        return try engine.render(page, scale: scale, region: region, cancel: cancel).rotated(rotation, cancel: cancel)
    }
}
