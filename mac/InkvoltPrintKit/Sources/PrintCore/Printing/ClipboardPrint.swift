import Foundation

/// A picture's size in pixels.
public struct PixelSize: Equatable, Sendable {
    public var width: Int, height: Int
    public init(_ width: Int, _ height: Int) {
        self.width = width
        self.height = height
    }
}

/// What the clipboard holds, as the app read it: text, a picture's size, files copied in Finder (Windows' `ClipboardContent`).
public struct ClipboardContent: Sendable {
    /// Its text, or nil.
    public var text: String?
    /// Its picture's size in pixels, or nil.
    public var picture: PixelSize?
    /// Files copied in Finder (full paths), or empty.
    public var files: [String]

    public init(text: String?, picture: PixelSize?, files: [String]) {
        self.text = text
        self.picture = picture
        self.files = files
    }
}

/// What Print the Clipboard does with it.
public enum ClipboardWhat: Sendable {
    /// Nothing it can print: no text, picture or file.
    case nothing
    /// The text, laid out on pages and printed as a PDF.
    case text
    /// The picture, opened in Print Photos.
    case picture
    /// One PDF copied in Finder, printed as Print a PDF prints it.
    case pdf
    /// Pictures copied in Finder, opened in Print Photos.
    case pictures
    /// Several files, PDFs and pictures (Windows opens them in Batch).
    case batch
    /// Files, but none is a PDF or a picture.
    case notPrintable
    /// A picture or text too big to print from the clipboard.
    case tooBig
}

/// The decision: what to print, and the files when they came from Finder.
public struct ClipboardPlan: Equatable, Sendable {
    public var what: ClipboardWhat
    public var files: [String]
    public init(_ what: ClipboardWhat, _ files: [String] = []) {
        self.what = what
        self.files = files
    }
}

/// Where the text's lines go on the paper: how many characters a line holds and how many lines a page.
public struct ClipboardTextLayout: Equatable, Sendable {
    public let paperWidthInches: Double, paperHeightInches: Double, marginInches: Double, fontPoints: Double
    public let columns: Int, lines: Int

    /// The distance between two lines' baselines, in inches.
    public var lineInches: Double { fontPoints * ClipboardPrint.lineSpacing / 72 }
    /// One character's width, in inches (a monospaced font's advance taken as 0.55 of its size, Consolas's; the Mac draws
    /// its monospaced font at the size that gives that advance).
    public var columnInches: Double { fontPoints * ClipboardPrint.charWidth / 72 }
}

/// Print the Clipboard (roadmap 4.13; Windows' `ClipboardPrint`): what's on it decides where it goes, so the usual print
/// options come with it. Files copied in Finder go as they are (one PDF as Print a PDF prints it, pictures to Print Photos,
/// several together); a picture goes to Print Photos; text is laid out on pages here (`pages`) and printed as a PDF. When there
/// are both text and a picture (Word and Excel put both; a browser's copied picture often brings its address), the text wins
/// unless it's one line with no space in it (`prefersPicture`). Everything on the clipboard came from another app: it is
/// bounded (`maxChars`, `maxPages`, `maxPicturePixels`, `maxFiles`). Lengths count Unicode scalars where .NET counts UTF-16
/// units.
public enum ClipboardPrint {
    public static let maxChars = 2_000_000, maxPages = 300, maxFiles = 100, tabStop = 8
    public static let maxPicturePixels = 100_000_000
    public static let charWidth = 0.55, lineSpacing = 1.2

    static let pictureTypes = [".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff", ".heic", ".heif", ".webp"]

    public static func choose(_ content: ClipboardContent) -> ClipboardPlan {
        let files = Array(content.files.lazy.filter { !isBlank($0) }.prefix(maxFiles + 1))
        if !files.isEmpty {
            if files.count > maxFiles { return ClipboardPlan(.tooBig) }
            let printable = files.filter { isPdf($0) || isPicture($0) }
            if printable.isEmpty { return ClipboardPlan(.notPrintable) }
            if printable.allSatisfy(isPicture) { return ClipboardPlan(.pictures, printable) }
            return ClipboardPlan(printable.count == 1 ? .pdf : .batch, printable)
        }
        let text = content.text.flatMap { isBlank($0) ? nil : $0 }
        let picture = content.picture.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil }
        if let size = picture, text.map(prefersPicture) ?? true {
            return ClipboardPlan(size.width.multipliedReportingOverflow(by: size.height).overflow
                                 || size.width * size.height > maxPicturePixels ? .tooBig : .picture)
        }
        guard let text else { return ClipboardPlan(.nothing) }
        return ClipboardPlan(text.unicodeScalars.count > maxChars ? .tooBig : .text)
    }

    /// Text beside a picture that's only its address or file name: one line with no space in it.
    public static func prefersPicture(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.unicodeScalars.count <= 2048 && !trimmed.unicodeScalars.contains { $0.properties.isWhitespace }
    }

    public static func isPdf(_ path: String) -> Bool { path.lowercased().hasSuffix(".pdf") }

    public static func isPicture(_ path: String) -> Bool {
        let lower = path.lowercased()
        return pictureTypes.contains { lower.hasSuffix($0) }
    }

    /// The layout on `widthInches` × `heightInches` paper: 3/4-inch margins, 10-point type (a little smaller on narrow paper so
    /// a line still holds 40 characters), as many whole columns and lines as fit.
    public static func layout(_ widthInches: Double, _ heightInches: Double) -> ClipboardTextLayout {
        var (width, height) = (widthInches, heightInches)
        if !width.isFinite || !height.isFinite || width < 2 || height < 2 || width > 50 || height > 50 { (width, height) = (8.5, 11) }
        let margin = 0.75
        var points = 10.0
        let usable = width - 2 * margin
        while points > 6 && usable / (points * charWidth / 72) < 40 { points -= 0.5 }
        let columns = max(1, Int((usable / (points * charWidth / 72) + 1e-9).rounded(.down)))
        let lines = max(1, Int(((height - 2 * margin) / (points * lineSpacing / 72) + 1e-9).rounded(.down)))
        return ClipboardTextLayout(paperWidthInches: width, paperHeightInches: height, marginInches: margin, fontPoints: points,
                                   columns: columns, lines: lines)
    }

    /// The text in pages of lines: line ends of any kind, tabs to the next stop of `tabStop`, control characters out, lines
    /// wrapped at a space where one is near the end else cut, a wide character (CJK, Hangul, fullwidth forms, and any past
    /// the Basic Multilingual Plane, as .NET counts its surrogate pairs) counted as two columns. A form feed starts a new
    /// page. Past `maxPages` the rest is left out and `cut` says so. Trailing empty lines and pages are dropped.
    public static func pages(_ text: String, _ columns: Int, _ linesPerPage: Int, cut: inout Bool) -> [[String]] {
        let columns = max(1, columns), linesPerPage = max(1, linesPerPage)
        // Two reasons for a cut: text past maxChars (the rest is laid out), and lines with something on them past maxPages.
        var scalars = Array(text.unicodeScalars)
        let tooLong = scalars.count > maxChars
        if tooLong { scalars.removeSubrange(maxChars...) }
        var dropped = false
        var pages: [[String]] = []
        var page: [String] = []
        // Line ends: CRLF, CR or LF; then form feeds within a line.
        var rawLines: [ArraySlice<Unicode.Scalar>] = []
        var start = 0, i = 0
        while i < scalars.count {
            let c = scalars[i]
            if c == "\r" || c == "\n" {
                rawLines.append(scalars[start..<i])
                if c == "\r" && i + 1 < scalars.count && scalars[i + 1] == "\n" { i += 1 }
                start = i + 1
            }
            i += 1
        }
        rawLines.append(scalars[start..<scalars.count])
        outer: for raw in rawLines {
            let parts = raw.split(separator: "\u{0C}", omittingEmptySubsequences: false)
            for (p, part) in parts.enumerated() {
                if p > 0 && !page.isEmpty {
                    pages.append(page)
                    page = []
                }
                // Line by line as cut, so one huge line stops at the last page (.NET's Wrap is lazy too).
                wrapScalars(expandScalars(part), columns) { line in
                    if page.count == linesPerPage {
                        pages.append(page)
                        page = []
                    }
                    if pages.count >= maxPages {
                        if line.isEmpty { return true } // blank lines past the last page lose nothing
                        dropped = true
                        return false
                    }
                    page.append(line)
                    return true
                }
                if dropped { break outer }
            }
        }
        if !page.isEmpty { pages.append(page) }
        cut = tooLong || dropped
        // No blank lines or pages at the end.
        while var last = pages.last {
            while last.last?.isEmpty == true { last.removeLast() }
            if !last.isEmpty {
                pages[pages.count - 1] = last
                break
            }
            pages.removeLast()
        }
        return pages
    }

    /// Tabs to spaces at the next stop; control characters (other than tab) out.
    static func expand(_ line: String) -> String { String(String.UnicodeScalarView(expandScalars(Array(line.unicodeScalars)[...]))) }

    /// A line cut to `columns`: at the last space in its second half when there is one, else where it's full.
    static func wrap(_ line: String, _ columns: Int) -> [String] {
        var lines: [String] = []
        wrapScalars(Array(line.unicodeScalars), columns) { lines.append($0); return true }
        return lines
    }

    private static func expandScalars(_ line: ArraySlice<Unicode.Scalar>) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        out.reserveCapacity(line.count)
        var column = 0
        for c in line {
            if c == "\t" {
                let spaces = tabStop - column % tabStop
                out.append(contentsOf: repeatElement(" ", count: spaces))
                column += spaces
            } else if c.properties.generalCategory != .control {
                out.append(c)
                column += width(c)
            }
        }
        return out
    }

    /// Each piece of the line to `each`, until it answers false.
    private static func wrapScalars(_ line: [Unicode.Scalar], _ columns: Int, _ each: (String) -> Bool) {
        if line.isEmpty {
            _ = each("")
            return
        }
        var start = 0
        while start < line.count {
            var used = 0, end = start
            while end < line.count {
                let w = width(line[end])
                if used + w > columns && end > start { break }
                used += w
                end += 1
            }
            if end < line.count, let space = line[start..<end].lastIndex(of: " "), space > start + (end - start) / 2 { end = space + 1 }
            var piece = line[start..<end]
            while let last = piece.last, last.properties.isWhitespace { piece = piece.dropLast() }
            if !each(String(String.UnicodeScalarView(piece))) { return }
            start = end
        }
    }

    /// Two columns for East Asian wide and fullwidth characters (and any past the BMP), one for the rest.
    static func width(_ c: Unicode.Scalar) -> Int {
        switch c.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0x10000...: 2
        default: 1
        }
    }

    /// "Clipboard 2026-11-22 0130": the name the PDF or picture is saved under (a job's name in the queue), in `timeZone`.
    public static func name(_ now: Date, _ word: String, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        func two(_ n: Int?) -> String { n.map { $0 < 10 ? "0\($0)" : "\($0)" } ?? "00" }
        return "\(word) \(c.year ?? 0)-\(two(c.month))-\(two(c.day)) \(two(c.hour))\(two(c.minute))"
    }

    private static func isBlank(_ s: String) -> Bool { s.unicodeScalars.allSatisfy { $0.properties.isWhitespace } }
}
