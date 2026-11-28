import CryptoKit
import Foundation
import PrintCore
@testable import PdfCore

// The OCR corpus's photographed pages (the Windows app's pdf/tools/ocr-corpus PhotoCorpus.cs), ported for the tests of
// roadmap 2.2's trapezoid correction and straightened lines: a corpus page as typeset (no damage but light noise), then
// put on a desk at an angle with a known map, or bent as an open book bends it with a known shift. The same seeded
// generator gives the same noise as on Windows; nothing is committed.

/// How a photographed page was photographed.
enum PhotoDamage {
    /// At an angle, on a darker desk: the page a trapezoid.
    case trapezoid
    /// Open in a book: lines bent towards the spine on the left, sagging and fanning out.
    case bent
}

/// `page`: the typeset page it starts from (its font, size and words; `ScanCorpus`'s first page of it).
struct PhotoFile {
    var name: String
    var page: CorpusFile
    var damage: PhotoDamage
}

enum PhotoCorpus {
    static let dpi = ScanCorpus.dpi

    static let files: [PhotoFile] = [
        PhotoFile(name: "en-trapezoid", page: ScanCorpus.files[0], damage: .trapezoid),
        PhotoFile(name: "es-trapezoid", page: ScanCorpus.files[3], damage: .trapezoid),
        PhotoFile(name: "en-book", page: ScanCorpus.files[2], damage: .bent),
        PhotoFile(name: "es-book", page: ScanCorpus.files[4], damage: .bent),
    ]

    static func file(_ name: String) -> PhotoFile { files.first { $0.name == name }! }

    /// The page's corners in the photo (clockwise from the top left) for a page of `w` × `h`: the camera tipped back, the
    /// top further away.
    static func corners(_ w: Int, _ h: Int) -> [WarpPoint] {
        let (w, h) = (Double(w), Double(h))
        return [WarpPoint(0.16 * w, 0.09 * h), WarpPoint(0.86 * w, 0.075 * h), WarpPoint(0.95 * w, 0.93 * h), WarpPoint(0.06 * w, 0.95 * h)]
    }

    /// How far down an open book moves a line (pixels) at (`x`, `y`) of a page of `w` × `h`: nothing at the outer edge
    /// (right), sagging towards the spine (left), and lines further apart there.
    static func sag(_ x: Double, _ y: Double, _ w: Int, _ h: Int) -> Double {
        let s = min(max(1 - x / Double(w), 0), 1)
        return 0.25 * Double(dpi) * s * s * s + 0.04 * s * s * (y - Double(h) / 2)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [String: (pixels: [UInt8], width: Int, height: Int, words: [String])] = [:]

    /// The photographed page (grey) and its words (made once a test run).
    static func photo(_ file: PhotoFile) throws -> (pixels: [UInt8], width: Int, height: Int, words: [String]) {
        lock.lock()
        defer { lock.unlock() }
        if let hit = made[file.name] { return hit }
        let (clean, w, h, words) = try ScanCorpus.cleanPage(file.page, 0)
        var rng = Rng(seed(file.name))
        let px = file.damage == .trapezoid ? onDesk(clean, w, h, corners(w, h), &rng) : bend(clean, w, h, &rng)
        made[file.name] = (px, w, h, words)
        return (px, w, h, words)
    }

    /// The photo as a one-page PDF (a grey JPEG at 300 dpi).
    static func pdf(_ file: PhotoFile) throws -> [UInt8] {
        let (px, w, h, _) = try photo(file)
        var page = file.page
        page.name = file.name
        return ScanCorpus.scanPdf(page, [(try ScanCorpus.jpeg(px, w, h, quality: 0.8), w, h)])
    }

    /// `page` laid on a grey desk with its corners at `corners` (the photo the page's size), lit a little unevenly, noisy.
    static func onDesk(_ page: [UInt8], _ w: Int, _ h: Int, _ corners: [WarpPoint], _ rng: inout Rng) -> [UInt8] {
        let square = [WarpPoint(0, 0), WarpPoint(Double(w), 0), WarpPoint(Double(w), Double(h)), WarpPoint(0, Double(h))]
        let toPage = Homography.between(corners, square)!
        let noise = (0..<(w * h)).map { _ in (rng.nextDouble() - 0.5) * 16 }
        return rows(w, h) { x, y in
            let s = toPage.apply(Double(x) + 0.5, Double(y) + 0.5)
            let v: Double
            if s.x < 0 || s.y < 0 || s.x >= Double(w) || s.y >= Double(h) {
                v = 70 + 25.0 * Double(x) / Double(w) // the desk
            } else {
                let ink = bilinear(page, w, h, s.x - 0.5, s.y - 0.5)
                let paper = 228 - 20.0 * Double(y) / Double(h) // further from the lamp at the bottom
                v = 30 + (paper - 30) * ink / 255
            }
            return v + noise[y * w + x]
        }
    }

    /// `page` as an open book shows it: each column moved down by `sag`, noisy.
    static func bend(_ page: [UInt8], _ w: Int, _ h: Int, _ rng: inout Rng) -> [UInt8] {
        let noise = (0..<(w * h)).map { _ in (rng.nextDouble() - 0.5) * 16 }
        return rows(w, h) { x, y in
            // The content shown at y came from the y' that the sag moved here: y = y' + Sag(x, y'), solved by a few steps.
            var from = Double(y)
            for _ in 0..<4 { from = Double(y) - sag(Double(x) + 0.5, from, w, h) }
            let ink = bilinear(page, w, h, Double(x), from - 0.5)
            return 30 + (232 - 30) * ink / 255 + noise[y * w + x]
        }
    }

    /// A picture made pixel by pixel, rows spread over the cores (.NET's `Parallel.For`), each value rounded and clamped.
    private static func rows(_ w: Int, _ h: Int, _ value: @Sendable (Int, Int) -> Double) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: w * h)
        result.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: h) { y in
                for x in 0..<w { out[y * w + x] = UInt8(min(max(value(x, y).rounded(.toNearestOrEven), 0), 255)) }
            }
        }
        return result
    }

    private static func bilinear(_ px: [UInt8], _ w: Int, _ h: Int, _ x: Double, _ y: Double) -> Double {
        let (x0, y0) = (Int(x.rounded(.down)), Int(y.rounded(.down)))
        let (fx, fy) = (x - Double(x0), y - Double(y0))
        func at(_ a: Int, _ b: Int) -> Double { a < 0 || b < 0 || a >= w || b >= h ? 255 : Double(px[b * w + a]) }
        return (at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx) * (1 - fy) + (at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx) * fy
    }

    private static func seed(_ name: String) -> UInt64 {
        let h = Array(SHA256.hash(data: Array("inkvolt-photo-\(name)".utf8)))
        return (0..<8).reduce(UInt64(0)) { $0 | UInt64(h[$1]) << (8 * UInt64($1)) } // BitConverter.ToUInt64: little-endian
    }
}
