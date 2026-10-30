import Foundation

/// The overlay of two renders: ink both share in grey, ink only the old one has in red, ink only the new one has in
/// blue. `regions` are the areas that differ (pixel coordinates of `image`), grouped so a changed word or detail is one
/// box.
public struct VisualDiff: Sendable {
    public var image: RenderedImage
    public var changedPixels: Int
    public var changedShare: Double
    public var regions: [RectD]
}

/// Pixel comparison of two pages rendered at the same scale, for drawings and scans without text (the Windows app's
/// `VisualCompare`; the Mac's renders are RGB where Windows' are BGR).
public enum VisualCompare {
    /// Ink only the old page has (removed): red.
    public static let removedColor: (r: Int, g: Int, b: Int) = (220, 40, 40)

    /// Ink only the new page has (added): blue.
    public static let addedColor: (r: Int, g: Int, b: Int) = (40, 90, 230)

    /// Overlays two renders aligned at their top-left corners (the result is as large as the larger one; the smaller is
    /// white beyond its edge). A pixel differs when its brightness differs by more than `tolerance` (0-255), so faint
    /// scanner noise and tints don't count; a `block`-pixel square counts toward a region only with at least `minPixels`
    /// differing pixels, so a lone speck doesn't either.
    public static func overlay(_ oldImage: RenderedImage, _ newImage: RenderedImage, tolerance: Int = 48, block: Int = 8, minPixels: Int = 2,
                               cancel: CancelToken? = nil) throws -> VisualDiff {
        let w = max(oldImage.width, newImage.width)
        let h = max(oldImage.height, newImage.height)
        let stride = w * 3
        var output = [UInt8](repeating: 255, count: stride * h)
        let bw = (w + block - 1) / block
        let bh = (h + block - 1) / block
        var counts = [Int](repeating: 0, count: bw * bh)
        var bounds = [(x0: Int, y0: Int, x1: Int, y1: Int)](repeating: (0, 0, 0, 0), count: bw * bh)
        var changed = 0
        let removed = removedColor, added = addedColor

        for y in 0..<h {
            if y & 63 == 0 { try cancel?.check() }
            let row = y * stride
            for x in 0..<w {
                let lo = luma(oldImage, x, y)
                let ln = luma(newImage, x, y)
                let i = row + x * 3
                let d = lo - ln
                if abs(d) <= tolerance {
                    // Shared: grey, lightened so the colors stand out.
                    let g = UInt8(255 - (255 - ln) * 55 / 100)
                    output[i] = g
                    output[i + 1] = g
                    output[i + 2] = g
                    continue
                }
                changed += 1
                let s = min(255, abs(d) * 7 / 5) // strength 0..255
                let c = d < 0 ? removed : added // old darker: removed
                output[i] = UInt8(255 - (255 - c.r) * s / 255)
                output[i + 1] = UInt8(255 - (255 - c.g) * s / 255)
                output[i + 2] = UInt8(255 - (255 - c.b) * s / 255)

                let b = y / block * bw + x / block
                if counts[b] == 0 {
                    bounds[b] = (x, y, x, y)
                } else {
                    bounds[b] = (min(bounds[b].x0, x), min(bounds[b].y0, y), max(bounds[b].x1, x), max(bounds[b].y1, y))
                }
                counts[b] += 1
            }
        }

        let regions = regionsOf(counts, bounds, bw, bh, minPixels)
        return VisualDiff(image: RenderedImage(w, h, output), changedPixels: changed, changedShare: w * h == 0 ? 0 : Double(changed) / Double(w * h),
                          regions: regions)
    }

    /// Brightness 0-255 of an RGB pixel; white outside the image.
    private static func luma(_ img: RenderedImage, _ x: Int, _ y: Int) -> Int {
        if x >= img.width || y >= img.height { return 255 }
        let i = y * img.stride + x * 3
        return (Int(img.pixels[i]) * 299 + Int(img.pixels[i + 1]) * 587 + Int(img.pixels[i + 2]) * 114) / 1000
    }

    /// Groups changed blocks lying within two blocks of each other and returns each group's tight pixel box.
    private static func regionsOf(_ counts: [Int], _ bounds: [(x0: Int, y0: Int, x1: Int, y1: Int)], _ bw: Int, _ bh: Int, _ minPixels: Int) -> [RectD] {
        var regions: [RectD] = []
        var seen = [Bool](repeating: false, count: counts.count)
        var stack: [Int] = []
        for start in counts.indices where !seen[start] && counts[start] >= minPixels {
            seen[start] = true
            stack.append(start)
            var box = bounds[start]
            while let b = stack.popLast() {
                let bx = b % bw, by = b / bw
                for dy in -2...2 {
                    for dx in -2...2 {
                        let nx = bx + dx, ny = by + dy
                        if nx < 0 || ny < 0 || nx >= bw || ny >= bh { continue }
                        let n = ny * bw + nx
                        if seen[n] || counts[n] < minPixels { continue }
                        seen[n] = true
                        let nb = bounds[n]
                        box = (min(box.x0, nb.x0), min(box.y0, nb.y0), max(box.x1, nb.x1), max(box.y1, nb.y1))
                        stack.append(n)
                    }
                }
            }
            regions.append(RectD(Double(box.x0), Double(box.y0), Double(box.x1 - box.x0 + 1), Double(box.y1 - box.y0 + 1)))
        }
        return regions
    }
}
