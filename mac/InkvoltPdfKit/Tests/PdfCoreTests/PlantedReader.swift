import Foundation
@testable import PdfCore

/// Ported from PlantedReader.cs. Stands in for the recognizer, without a language of its own beyond en-US: told where each
/// page's words are on the upright page, it tells which page it was handed from its shape (each corpus page has a height
/// of its own), and returns the words it can see there (ink in the box, not blacked out), so what comes back after
/// redacting really is what is left to see. A word can be dropped, as a recognizer sometimes drops a whole line, and come
/// back or not when its place is read alone. Adapted: it takes the Mac's RGB `RenderedImage` and gives boxes in its pixels.
final class PlantedReader: TextRecognizer, @unchecked Sendable {
    /// A word, its box as shares of the page's size.
    private struct Word {
        var text: String
        var x: Double, y: Double, w: Double, h: Double
    }

    private struct Sheet {
        var shape: Double
        var words: [Word]
    }

    private let lock = NSLock()
    private var sheets: [Sheet] = []
    private var dropped: Set<String> = []
    private var placesRead = 0

    var language: String? { "en-US" }

    /// A dropped word is read when its place is read on its own.
    var readsPlacesAlone = false

    /// These words aren't read when a whole page is.
    func drop(_ word: String) { lock.withLock { _ = dropped.insert(word) } }

    /// How many places were read on their own.
    var placesReadCount: Int { lock.withLock { placesRead } }

    func plant(_ pageWidth: Double, _ pageHeight: Double, _ text: PageText) {
        var words: [(String, RectD)] = []
        let units = Array(text.text.utf16)
        var i = 0
        while i < units.count {
            if PageText.isWhiteSpace(units[i]) {
                i += 1
                continue
            }
            var end = i
            while end < units.count && !PageText.isWhiteSpace(units[end]) { end += 1 }
            words.append((text.string(i, end), text.rects(i, end)[0]))
            i = end
        }
        plantWords(pageWidth, pageHeight, words)
    }

    /// `words`: boxes in points on the page.
    func plantWords(_ pageWidth: Double, _ pageHeight: Double, _ words: [(String, RectD)]) {
        let sheet = Sheet(shape: pageWidth / pageHeight, words: words.map {
            Word(text: $0.0, x: $0.1.x / pageWidth, y: $0.1.y / pageHeight, w: $0.1.width / pageWidth, h: $0.1.height / pageHeight)
        })
        lock.withLock { sheets.append(sheet) }
    }

    func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] {
        let (width, height) = (image.width, image.height)
        let gray = ScanCleanup.toGray(image.pixels, width, height)
        return lock.withLock {
            if height < 500 {
                placesRead += 1
                guard readsPlacesAlone, let text = dropped.first else { return [] }
                let inked = (0..<gray.count).filter { gray[$0] < 128 }
                if inked.isEmpty { return [] }
                dropped.remove(text)
                let xs = inked.map { $0 % width }, ys = inked.map { $0 / width }
                let (x0, y0, x1, y1) = (xs.min()!, ys.min()!, xs.max()!, ys.max()!)
                return [OcrWord(text, RectD(Double(x0), Double(y0), Double(x1 - x0 + 1), Double(y1 - y0 + 1)))]
            }
            let shape = Double(width) / Double(height)
            guard let sheet = sheets.min(by: { abs($0.shape - shape) < abs($1.shape - shape) }), abs(sheet.shape - shape) <= 0.002 else {
                return [] // on its side still: nothing reads
            }
            var found: [OcrWord] = []
            for w in sheet.words where !dropped.contains(w.text) {
                let (x, y, bw, bh) = (w.x * Double(width), w.y * Double(height), w.w * Double(width), w.h * Double(height))
                if Self.sees(gray, width, height, x, y, bw, bh) { found.append(OcrWord(w.text, RectD(x, y, bw, bh))) }
            }
            return found
        }
    }

    /// Ink in the word's box, and not a black bar.
    private static func sees(_ gray: [UInt8], _ width: Int, _ height: Int, _ wx: Double, _ wy: Double, _ ww: Double, _ wh: Double) -> Bool {
        func clamp(_ v: Double, _ hi: Int) -> Int { Int(min(max(v, 0), Double(hi))) }
        let (x0, y0, x1, y1) = (clamp(wx, width), clamp(wy, height), clamp(wx + ww, width), clamp(wy + wh, height))
        if x1 <= x0 || y1 <= y0 { return false }
        var dark = 0
        for y in y0..<y1 { for x in x0..<x1 where gray[y * width + x] < 128 { dark += 1 } }
        let share = Double(dark) / Double((x1 - x0) * (y1 - y0))
        return share > 0.03 && share < 0.8
    }
}
