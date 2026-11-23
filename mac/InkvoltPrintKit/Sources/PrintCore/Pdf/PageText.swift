import Foundation

/// A line of recognized text on a page: its words in order, its top and left edge and its height (the image's pixels).
public struct TextLine: Equatable, Sendable {
    public var text: String
    public var left: Double, top: Double, height: Double
    /// Its words, left to right.
    public var words: [PdfWriter.Word]

    public init(_ text: String, left: Double, top: Double, height: Double, words: [PdfWriter.Word] = []) {
        self.text = text
        self.left = left
        self.top = top
        self.height = height
        self.words = words
    }
}

/// A scanned page's recognized words (in the image's pixels from its top left, as `PdfWriter` takes them; Windows'
/// `OcrWord`) put back into lines, top to bottom: words whose boxes share most of their height are one line, read left to
/// right. What a scan's name is read from (`TextFinds`).
public enum PageText {
    /// At most this many words are read from a page (a recognizer's answer is outside input).
    public static let maxWords = 20_000

    public static func lines(_ words: [PdfWriter.Word]?) -> [TextLine] {
        guard let words else { return [] }
        let usable = words.prefix(maxWords).filter { w in
            !w.text.allSatisfy(\.isWhitespace) && w.x.isFinite && w.y.isFinite && w.height.isFinite && w.height > 0
        }
        // .NET's OrderBy is stable: equal keys keep their order.
        let sorted = usable.enumerated().sorted { a, b in
            let (ka, kb) = (a.element.y + a.element.height / 2, b.element.y + b.element.height / 2)
            return ka != kb ? ka < kb : a.offset < b.offset
        }.map(\.element)
        var lines: [(top: Double, bottom: Double, words: [PdfWriter.Word])] = []
        for w in sorted {
            let (top, bottom) = (w.y, w.y + w.height)
            let line = lines.lastIndex { l in min(l.bottom, bottom) - max(l.top, top) >= 0.5 * min(l.bottom - l.top, bottom - top) }
            if let line {
                lines[line].words.append(w)
                lines[line].top = min(lines[line].top, top)
                lines[line].bottom = max(lines[line].bottom, bottom)
            } else {
                lines.append((top, bottom, [w]))
            }
        }
        let byTop = lines.enumerated().sorted { a, b in a.element.top != b.element.top ? a.element.top < b.element.top : a.offset < b.offset }
        return byTop.map { entry in
            let l = entry.element
            let ordered = l.words.enumerated().sorted { a, b in a.element.x != b.element.x ? a.element.x < b.element.x : a.offset < b.offset }.map(\.element)
            let heights = ordered.map(\.height).sorted()
            let text = ordered.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
            return TextLine(text, left: ordered[0].x, top: l.top, height: heights[heights.count / 2], words: ordered)
        }
    }

    /// The line's text without a lone character at either end standing apart from the rest (a punch hole or a speck read as
    /// "O" or "."): further from its neighbour than the line is tall.
    public static func withoutStrays(_ line: TextLine) -> String {
        var words = line.words
        if words.count < 2 { return line.text }
        func lone(_ w: PdfWriter.Word) -> Bool { w.text.trimmingCharacters(in: .whitespacesAndNewlines).count <= 1 }
        if lone(words[0]) && words[1].x - (words[0].x + words[0].width) > line.height { words.removeFirst() }
        if words.count >= 2, let last = words.last, lone(last), last.x - (words[words.count - 2].x + words[words.count - 2].width) > line.height {
            words.removeLast()
        }
        return words.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ")
    }
}
