import Foundation

// The pieces `PageCleanup` builds on, from the Windows app's `ScanCleanup.cs` (`ToGray`, `Smooth`, `PaperLevel.Map`,
// `Despeckle`). Inkvolt PDF's PdfCore has its own public copies (Ocr/ScanCleanup.swift, ported before these, for its
// recognizer); these stay internal so a file that imports both modules sees one of each. Colour pixels are RGB on the Mac.

/// Runs `body` for each of `count` rows, spread over the cores (.NET's `Parallel.For`). Rows left when `stop` fires are
/// skipped, and it throws `CancellationError` once all have returned.
func cleanupRows(_ count: Int, _ stop: BatchStop?, _ body: (Int) -> Void) throws {
    try stop?.check()
    if count <= 0 { return }
    let chunks = min(count, max(1, ProcessInfo.processInfo.activeProcessorCount * 4))
    withoutActuallyEscaping(body) { body in
        let shared = CleanupRowBody(run: body, stop: stop)
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            let start = count * c / chunks, end = count * (c + 1) / chunks
            for y in start..<end {
                if shared.stop?.isStopped == true { return }
                shared.run(y)
            }
        }
    }
    try stop?.check()
}

/// Each row writes only its own part of the result, through pointers the caller keeps alive for the call.
private struct CleanupRowBody: @unchecked Sendable {
    let run: (Int) -> Void
    let stop: BatchStop?
}

/// A level as a byte: below 0 (and NaN) is 0, above 255 is 255, else cut down to a whole level, as .NET's `(byte)` cast of
/// a clamped float.
@inline(__always)
func cleanupByte(_ v: Float) -> UInt8 { v >= 255 ? 255 : v > 0 ? UInt8(v) : 0 }

enum CleanupGray {
    /// Luma of RGB pixels (the weights Rec. 601 uses, in integers).
    static func of(_ rgb: [UInt8], _ width: Int, _ height: Int, _ stop: BatchStop?) throws -> [UInt8] {
        var g = [UInt8](repeating: 0, count: width * height)
        try rgb.withUnsafeBufferPointer { src in
            try g.withUnsafeMutableBufferPointer { dst in
                let out = dst
                try cleanupRows(height, stop) { y in
                    var j = y * width * 3
                    for i in (y * width)..<(y * width + width) {
                        let r = Int(src[j]) * 77
                        let gr = Int(src[j + 1]) * 150
                        let b = Int(src[j + 2]) * 29
                        out[i] = UInt8((r + gr + b) >> 8)
                        j += 3
                    }
                }
            }
        }
        return g
    }
}

/// A 3 × 3 median: takes out the paper's grain and single-pixel noise, keeps the edges of letters.
enum CleanupSmooth {
    static func median3(_ gray: [UInt8], _ width: Int, _ height: Int, _ stop: BatchStop?) throws -> [UInt8] {
        var result = [UInt8](repeating: 0, count: gray.count)
        try gray.withUnsafeBufferPointer { src in
            try result.withUnsafeMutableBufferPointer { dst in
                let out = dst
                try cleanupRows(height, stop) { y in
                    let (y0, y2) = (max(0, y - 1), min(height - 1, y + 1))
                    var v = (UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0), UInt8(0))
                    for x in 0..<width {
                        let (xa, xb) = (max(0, x - 1), min(width - 1, x + 1))
                        v = (src[y0 * width + xa], src[y0 * width + x], src[y0 * width + xb],
                             src[y * width + xa], src[y * width + x], src[y * width + xb],
                             src[y2 * width + xa], src[y2 * width + x], src[y2 * width + xb])
                        out[y * width + x] = median9(&v)
                    }
                }
            }
        }
        return result
    }

    /// The median of nine values by a sorting network (19 compare-exchanges).
    private static func median9(_ p: inout (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)) -> UInt8 {
        withUnsafeMutableBytes(of: &p) { raw in
            let a = raw.bindMemory(to: UInt8.self)
            func s(_ i: Int, _ j: Int) {
                if a[i] > a[j] { a.swapAt(i, j) }
            }
            s(1, 2); s(4, 5); s(7, 8); s(0, 1); s(3, 4); s(6, 7); s(1, 2); s(4, 5); s(7, 8)
            s(0, 3); s(5, 8); s(4, 7); s(3, 6); s(1, 4); s(2, 5); s(4, 7); s(4, 2); s(6, 4); s(4, 2)
            return a[4]
        }
    }
}

/// The paper's own level across a page, one value per block, read bilinearly between block centres (`PaperLevel.Map`).
struct PaperMap: Sendable {
    let width: Int, height: Int, block: Int, columns: Int, rows: Int
    let levels: [Float]

    /// The paper level at a pixel, bilinear between block centres.
    func at(_ x: Int, _ y: Int) -> Float {
        let fx = min(max((Float(x) + 0.5) / Float(block) - 0.5, 0), Float(columns - 1))
        let fy = min(max((Float(y) + 0.5) / Float(block) - 0.5, 0), Float(rows - 1))
        let (x0, y0) = (Int(fx), Int(fy))
        let (x1, y1) = (min(x0 + 1, columns - 1), min(y0 + 1, rows - 1))
        let (ax, ay) = (fx - Float(x0), fy - Float(y0))
        let top = levels[y0 * columns + x0] * (1 - ax) + levels[y0 * columns + x1] * ax
        let bottom = levels[y1 * columns + x0] * (1 - ax) + levels[y1 * columns + x1] * ax
        return top * (1 - ay) + bottom * ay
    }

    /// `at(x, y)` for every pixel of row `y`, into `out` (width values).
    func row(_ y: Int, into out: UnsafeMutableBufferPointer<Float>) {
        let fy = min(max((Float(y) + 0.5) / Float(block) - 0.5, 0), Float(rows - 1))
        let y0 = Int(fy)
        let y1 = min(y0 + 1, rows - 1)
        let ay = fy - Float(y0)
        levels.withUnsafeBufferPointer { l in
            for x in 0..<width {
                let fx = min(max((Float(x) + 0.5) / Float(block) - 0.5, 0), Float(columns - 1))
                let x0 = Int(fx)
                let x1 = min(x0 + 1, columns - 1)
                let ax = fx - Float(x0)
                let top = l[y0 * columns + x0] * (1 - ax) + l[y0 * columns + x1] * ax
                let bottom = l[y1 * columns + x0] * (1 - ax) + l[y1 * columns + x1] * ax
                out[x] = top * (1 - ay) + bottom * ay
            }
        }
    }
}

/// Removes specks: small dark spots (dust, toner, a hole's shadow) with no other ink near them. Small means at most
/// `maxArea` pixels at 300 dpi (a 9 × 9 dot, scaled with the resolution); near means within `isolation` of an inch. A full
/// stop, a comma, the dot of an i or an accent is always near its letters, so it stays.
enum CleanupDespeckle {
    static let maxArea = 80
    static let isolation = 1 / 20.0
    private static let ink: UInt8 = 160

    /// Turns lone specks white (in place); returns how many went. `dpi` is a scan's (1 to 9600, as `PageCleanup` gives it).
    static func remove(_ gray: inout [UInt8], _ width: Int, _ height: Int, _ dpi: Int, _ stop: BatchStop?) throws -> Int {
        let scale = Double(dpi) / 300
        let maxArea = max(2, Int(Double(self.maxArea) * scale * scale))
        let reach = max(2, Int((Double(dpi) * isolation).rounded(.toNearestOrEven)))
        let stride = width + 1

        // Ink counts summed over the rectangle above and left of each pixel, to count the ink around a speck at once.
        var sums = [Int32](repeating: 0, count: (width + 1) * (height + 1))
        try gray.withUnsafeBufferPointer { g in
            try sums.withUnsafeMutableBufferPointer { s in
                for y in 0..<height {
                    try stop?.check()
                    var row: Int32 = 0
                    for x in 0..<width {
                        row += g[y * width + x] < ink ? 1 : 0
                        s[(y + 1) * stride + x + 1] = s[y * stride + x + 1] + row
                    }
                }
            }
        }

        var seen = [Bool](repeating: false, count: gray.count)
        var stack: [Int] = []
        var pixels: [Int] = []
        var removed = 0
        try seen.withUnsafeMutableBufferPointer { seen in
            try sums.withUnsafeBufferPointer { sums in
                func inkIn(_ ax: Int, _ ay: Int, _ bx: Int, _ by: Int) -> Int {
                    let (x0, y0, x1, y1) = (max(0, ax), max(0, ay), min(width, bx), min(height, by))
                    return Int(sums[y1 * stride + x1] - sums[y0 * stride + x1] - sums[y1 * stride + x0] + sums[y0 * stride + x0])
                }
                try gray.withUnsafeMutableBufferPointer { g in
                    for start in 0..<g.count {
                        if start % width == 0 { try stop?.check() }
                        if seen[start] || g[start] >= ink { continue }
                        // One spot of ink (8-connected), given up on as soon as it is too big to be a speck.
                        pixels.removeAll(keepingCapacity: true)
                        stack.append(start)
                        seen[start] = true
                        var (minX, minY, maxX, maxY) = (Int.max, Int.max, -1, -1)
                        var big = false
                        while let p = stack.popLast() {
                            let (px, py) = (p % width, p / width)
                            if !big {
                                pixels.append(p)
                                (minX, minY, maxX, maxY) = (min(minX, px), min(minY, py), max(maxX, px), max(maxY, py))
                                big = pixels.count > maxArea
                            }
                            for ny in max(0, py - 1)...min(height - 1, py + 1) {
                                for nx in max(0, px - 1)...min(width - 1, px + 1) {
                                    let n = ny * width + nx
                                    if seen[n] || g[n] >= ink { continue }
                                    seen[n] = true
                                    stack.append(n)
                                }
                            }
                        }
                        if big { continue }
                        let own = inkIn(minX, minY, maxX + 1, maxY + 1)
                        if inkIn(minX - reach, minY - reach, maxX + 1 + reach, maxY + 1 + reach) > own { continue }
                        for p in pixels { g[p] = 255 }
                        // Its soft edge (lighter than ink) goes too.
                        for y in max(0, minY - 1)...min(height - 1, maxY + 1) {
                            for x in max(0, minX - 1)...min(width - 1, maxX + 1) { g[y * width + x] = 255 }
                        }
                        removed += 1
                    }
                }
            }
        }
        return removed
    }
}
