import Foundation

/// An 8-bit greyscale image, row by row with no padding (0 black, 255 white). The app decodes a downscaled copy of a scan
/// into one.
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    /// The level most of the page has (the median): the paper on a document.
    static func median(_ img: GrayImage, _ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Int {
        var histogram = [Int](repeating: 0, count: 256)
        for y in y0..<y1 {
            for x in x0..<x1 { histogram[Int(img.pixels[y * img.width + x])] += 1 }
        }
        let half = (x1 - x0) * (y1 - y0) / 2
        var seen = 0
        for level in 0..<256 {
            seen += histogram[level]
            if seen > half { return level }
        }
        return 255
    }
}

/// Blank page detection for scans (the back of a one-sided sheet in the feeder, a separator sheet): a page is blank when
/// almost none of it is ink. Measured inside a margin (scanner edges, lid shadows and punched holes live there), against the
/// page's own paper level, and only ink pixels with an ink neighbour count, so specks of dust and JPEG noise don't.
/// Conservative on purpose: a page with as little as a short word on it is not blank.
public enum BlankPage {
    /// Fraction of the width and height left out on each side.
    public static let margin = 0.06

    /// How much darker than the paper a pixel must be to be ink (show-through from the back is lighter than this).
    public static let inkContrast = 48

    /// Most ink a blank page may have: 0.02% of the area, a few specks; one short word is more.
    public static let maxCoverage = 0.0002

    /// The share of the page (inside the margin) that is ink, 0 to 1. A dark page (paper below mid-grey) counts as all ink.
    public static func inkCoverage(_ img: GrayImage) -> Double {
        let (x0, y0) = (Int(Double(img.width) * margin), Int(Double(img.height) * margin))
        let (x1, y1) = (img.width - x0, img.height - y0)
        if x1 - x0 < 3 || y1 - y0 < 3 { return 1 }
        let paper = GrayImage.median(img, x0, y0, x1, y1)
        if paper < 128 { return 1 } // a photo or a dark page: never "blank"
        let ink = paper - inkContrast
        var count = 0
        for y in y0..<y1 {
            for x in x0..<x1 where Int(img[x, y]) < ink && hasInkNeighbour(img, x, y, ink) { count += 1 }
        }
        return Double(count) / Double((x1 - x0) * (y1 - y0))
    }

    public static func isBlank(_ img: GrayImage) -> Bool { inkCoverage(img) <= maxCoverage }

    private static func hasInkNeighbour(_ img: GrayImage, _ x: Int, _ y: Int, _ ink: Int) -> Bool {
        for dy in -1...1 {
            for dx in -1...1 where dx != 0 || dy != 0 {
                let (nx, ny) = (x + dx, y + dy)
                if nx >= 0 && ny >= 0 && nx < img.width && ny < img.height && Int(img[nx, ny]) < ink { return true }
            }
        }
        return false
    }
}

/// Skew detection for scanned documents (a page fed or laid a little crooked), by projection profile: the ink is projected
/// onto lines at each candidate angle, and text lines line up into sharp peaks only at the page's true angle. Small angles
/// only (±`maxAngle`°); pages with no clear answer (photos, a few words, already straight) get 0, so they keep their
/// original JPEG.
public enum Deskew {
    public static let maxAngle = 10.0

    /// Smaller skews aren't worth re-encoding the page for.
    public static let minAngle = 0.4

    private static let inkContrast = 60
    private static let minInkPixels = 200
    private static let maxInkPixels = 40_000

    /// How far the page's content is turned, in degrees, clockwise positive as seen on screen; rotating it by the negative
    /// straightens it. 0 when the page is straight enough or the answer isn't clear.
    public static func angle(_ img: GrayImage) -> Double {
        let (x0, y0) = (Int(Double(img.width) * 0.03), Int(Double(img.height) * 0.03))
        let (x1, y1) = (img.width - x0, img.height - y0)
        if x1 - x0 < 16 || y1 - y0 < 16 { return 0 }
        let paper = GrayImage.median(img, x0, y0, x1, y1)
        if paper < 128 { return 0 }
        let ink = paper - inkContrast

        // Ink pixels, relative to the centre; evenly thinned out on busy pages.
        var total = 0
        for y in y0..<y1 {
            for x in x0..<x1 where Int(img[x, y]) < ink { total += 1 }
        }
        if total < minInkPixels { return 0 }
        let step = max(1, total / maxInkPixels)
        let (cx, cy) = (Double(img.width) / 2, Double(img.height) / 2)
        var xs: [Double] = [], ys: [Double] = []
        xs.reserveCapacity(total / step + 1)
        ys.reserveCapacity(total / step + 1)
        var i = 0
        for y in y0..<y1 {
            for x in x0..<x1 where Int(img[x, y]) < ink {
                if i % step == 0 {
                    xs.append(Double(x) - cx)
                    ys.append(Double(y) - cy)
                }
                i += 1
            }
        }
        let diagonal = (Double(img.width) * Double(img.width) + Double(img.height) * Double(img.height)).squareRoot()
        var bins = [Int](repeating: 0, count: Int(diagonal.rounded(.up)) + 2)

        func score(_ degrees: Double) -> Double {
            for b in bins.indices { bins[b] = 0 }
            let (s, c) = (sin(degrees * .pi / 180), cos(degrees * .pi / 180))
            let offset = bins.count / 2
            for k in xs.indices {
                let projected: Double = ys[k] * c - xs[k] * s
                let bin = Int(projected.rounded(.toNearestOrEven)) + offset
                if bin >= 0 && bin < bins.count { bins[bin] += 1 }
            }
            var sum = 0.0
            for b in bins { sum += Double(b) * Double(b) }
            return sum
        }

        // Coarse, then fine around the best.
        let coarse = 0.5, fine = 0.05
        let steps = Int(maxAngle / coarse)
        var scores = [Double](repeating: 0, count: 2 * steps + 1)
        var best = 0
        for k in scores.indices {
            scores[k] = score(Double(k - steps) * coarse)
            if scores[k] > scores[best] { best = k }
        }
        if best == 0 || best == scores.count - 1 { return 0 } // at the edge of the range: not a small skew
        let mean = scores.reduce(0, +) / Double(scores.count)
        if scores[best] < 1.25 * mean { return 0 } // a flat profile: no lines to go by

        var angle = Double(best - steps) * coarse
        var bestScore = scores[best]
        var a = angle - coarse + fine
        let end = angle + coarse - fine / 2
        while a < end {
            let s = score(a)
            if s > bestScore { (bestScore, angle) = (s, a) }
            a += fine
        }
        angle = (angle / fine).rounded(.toNearestOrEven) * fine
        return abs(angle) < minAngle ? 0 : angle
    }
}

/// A crop as fractions of the image (0 to 1): left, top, width, height.
public struct CropBox: Equatable, Sendable, Codable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(_ x: Double, _ y: Double, _ width: Double, _ height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public static let full = CropBox(0, 0, 1, 1)

    /// The same area after the image turns `quarterTurns` quarters clockwise (negative: anticlockwise).
    public func turn(_ quarterTurns: Int) -> CropBox {
        var box = self
        for _ in 0..<((quarterTurns % 4) + 4) % 4 { box = CropBox(1 - box.y - box.height, box.x, box.height, box.width) } // (x, y) → (1 − y, x)
        return box
    }

    /// Kept inside the image, at least `min` wide and tall.
    public func clamp(_ min: Double = 0.02) -> CropBox {
        let w = Swift.min(Swift.max(width, min), 1)
        let h = Swift.min(Swift.max(height, min), 1)
        return CropBox(Swift.min(Swift.max(x, 0), 1 - w), Swift.min(Swift.max(y, 0), 1 - h), w, h)
    }

    public var isFull: Bool { x <= 0.001 && y <= 0.001 && width >= 0.999 && height >= 0.999 }
}

/// What's been done to a scanned page, applied in this order when the page is saved: straightened by `deskew` degrees
/// (anticlockwise by that much), cropped to `crop` (in the straightened page), then turned `quarterTurns` quarters
/// clockwise. No edits: the scanner's own JPEG is saved untouched.
public struct PageEdits: Equatable, Sendable {
    public var quarterTurns = 0
    public var deskew = 0.0
    public var crop: CropBox?

    public init(quarterTurns: Int = 0, deskew: Double = 0, crop: CropBox? = nil) {
        self.quarterTurns = quarterTurns
        self.deskew = deskew
        self.crop = crop
    }

    public static let none = PageEdits()

    public var isEmpty: Bool { quarterTurns % 4 == 0 && deskew == 0 && (crop?.isFull ?? true) }

    public func turned(_ quarters: Int) -> PageEdits {
        var e = self
        e.quarterTurns = (((quarterTurns + quarters) % 4) + 4) % 4
        return e
    }

    /// The crop as seen on the turned page (what the crop view shows).
    public var shownCrop: CropBox { (crop ?? .full).turn(quarterTurns) }

    /// Sets the crop from a box drawn on the turned page.
    public func withShownCrop(_ shown: CropBox?) -> PageEdits {
        var e = self
        e.crop = shown.flatMap { $0.isFull ? nil : $0.clamp().turn(-quarterTurns) }
        return e
    }
}

/// Arbitrary-angle rotation of raw pixels (straightening a page), bilinear, same size, uncovered corners white.
public enum PageRotate {
    /// `pixels` turned `degrees` clockwise (as seen on screen) about the centre. `channels`: 1 for grey, 3 for BGR or RGB;
    /// rows are `stride` bytes apart.
    public static func rotate(_ pixels: [UInt8], width: Int, height: Int, stride: Int, channels: Int, degrees: Double) -> [UInt8] {
        var result = [UInt8](repeating: 255, count: pixels.count)
        let (s, c) = (sin(degrees * .pi / 180), cos(degrees * .pi / 180))
        let (cx, cy) = (Double(width - 1) / 2, Double(height - 1) / 2)
        for y in 0..<height {
            let dy = Double(y) - cy
            for x in 0..<width {
                // Where this output pixel comes from in the original.
                let dx = Double(x) - cx
                let sx = c * dx + s * dy + cx
                let sy = -s * dx + c * dy + cy
                if sx <= -1 || sy <= -1 || sx >= Double(width) || sy >= Double(height) { continue }
                let (x0, y0) = (Int(sx.rounded(.down)), Int(sy.rounded(.down)))
                let (fx, fy) = (sx - Double(x0), sy - Double(y0))
                for ch in 0..<channels {
                    func at(_ px: Int, _ py: Int) -> Double {
                        px < 0 || py < 0 || px >= width || py >= height ? 255 : Double(pixels[py * stride + px * channels + ch])
                    }
                    let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
                    let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
                    let value = (top * (1 - fy) + bottom * fy).rounded(.toNearestOrEven)
                    result[y * stride + x * channels + ch] = UInt8(min(max(value, 0), 255))
                }
            }
        }
        return result
    }
}
