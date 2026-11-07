import Foundation
import PrintCore

/// What differs between two looks of the same words (the Windows app's `LookParts`).
public struct LookParts: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let font = LookParts(rawValue: 1)
    public static let size = LookParts(rawValue: 2)
    public static let color = LookParts(rawValue: 4)
    public static let bold = LookParts(rawValue: 8)
    public static let italic = LookParts(rawValue: 16)
}

/// How text is set: its font family (`FontNames.family`), size in points, bold, italic and color (0xRRGGBB) (the Windows
/// app's `WordLook`).
public struct WordLook: Sendable, Equatable, Hashable {
    public var font: String
    public var size: Double
    public var bold: Bool
    public var italic: Bool
    public var color: UInt32

    /// Sizes closer than this are the same (Word's sizes come out of a PDF as 11.04 or 10.98).
    public static let sizeTolerance = 0.25

    /// A color channel closer than this is the same (black set as 0x050505, a color through another profile).
    public static let colorTolerance = 12

    public init(_ font: String, _ size: Double, _ bold: Bool, _ italic: Bool, _ color: UInt32) {
        self.font = font
        self.size = size
        self.bold = bold
        self.italic = italic
        self.color = color
    }

    public func partsDifferent(from other: WordLook) -> LookParts {
        var parts: LookParts = []
        if font.caseInsensitiveCompare(other.font) != .orderedSame { parts.insert(.font) }
        if abs(size - other.size) >= Self.sizeTolerance { parts.insert(.size) }
        if bold != other.bold { parts.insert(.bold) }
        if italic != other.italic { parts.insert(.italic) }
        if Self.channel(color, 16, other.color) || Self.channel(color, 8, other.color) || Self.channel(color, 0, other.color) { parts.insert(.color) }
        return parts
    }

    private static func channel(_ a: UInt32, _ shift: UInt32, _ b: UInt32) -> Bool {
        abs(Int(a >> shift & 0xFF) - Int(b >> shift & 0xFF)) > colorTolerance
    }
}

/// A formatting change: the same words, set as `old` and now as `new`.
public struct LookChange: Sendable, Equatable {
    public var old: WordLook
    public var new: WordLook
    public var parts: LookParts

    public init(_ old: WordLook, _ new: WordLook, _ parts: LookParts) {
        self.old = old
        self.new = new
        self.parts = parts
    }

    /// "bold added, size 11 → 14 pt": for the list and the comments.
    public func describe() -> String {
        var list: [String] = []
        if parts.contains(.bold) { list.append(new.bold ? loc("bold added") : loc("bold removed")) }
        if parts.contains(.italic) { list.append(new.italic ? loc("italic added") : loc("italic removed")) }
        if parts.contains(.size) { list.append(loc("size {0} → {1} pt", Self.points(old.size), Self.points(new.size))) }
        if parts.contains(.font) { list.append(loc("font {0} → {1}", Self.name(old.font), Self.name(new.font))) }
        if parts.contains(.color) { list.append(loc("color {0} → {1}", Self.colorName(old.color), Self.colorName(new.color))) }
        return list.joined(separator: ", ")
    }

    /// "11", "10.5": at most one decimal, a point always (as Windows' invariant "0.#").
    static func points(_ size: Double) -> String {
        guard size.isFinite else { return "0" }
        let text = String(format: "%.1f", size) // no locale: a point
        return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
    }

    private static func name(_ font: String) -> String { font.isEmpty ? loc("unnamed") : font }

    private static func colorName(_ color: UInt32) -> String {
        switch color {
        case 0: loc("black")
        case 0xFFFFFF: loc("white")
        default: "#" + String(format: "%06X", color & 0xFFFFFF) // in every language: a code, no words
        }
    }
}

/// The looks of a page's text: for each UTF-16 unit of `PageText.text`, as runs. Immutable; shared freely.
public struct PageLooks: Sendable {
    private let starts: [Int]
    private let looks: [WordLook]

    /// - Parameter runs: each run's first unit and its look, in order; the first run covers everything before it too.
    public init(_ runs: [(start: Int, look: WordLook)]) {
        starts = runs.map(\.start)
        looks = runs.map(\.look)
    }

    public var isEmpty: Bool { looks.isEmpty }

    /// The last run starting at or before `index` (the first run when none does).
    private func run(at index: Int) -> Int {
        var lo = 0, hi = starts.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= index {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return found
    }

    /// The look at a unit of the text; nil on a page without any.
    public func at(_ index: Int) -> WordLook? { looks.isEmpty ? nil : looks[run(at: index)] }

    /// The look most of [start, end) has.
    public func main(_ start: Int, _ end: Int) -> WordLook? {
        if looks.isEmpty { return nil }
        var best: WordLook?
        var bestUnits = -1
        var i = run(at: start)
        while i < looks.count && (i == 0 || starts[i] < end) {
            let from = max(start, i == 0 ? start : starts[i])
            let to = i + 1 < starts.count ? min(end, starts[i + 1]) : end
            if to - from > bestUnits {
                best = looks[i]
                bestUnits = to - from
            }
            i += 1
        }
        return best
    }
}

/// What Compare reads from a page. `isPicture`: pictures cover most of the page, a scan whatever text lies over it.
public struct ComparePage: Sendable {
    public var text: PageText
    public var looks: PageLooks
    public var isPicture: Bool

    public init(_ text: PageText, _ looks: PageLooks, isPicture: Bool) {
        self.text = text
        self.looks = looks
        self.isPicture = isPicture
    }

    public static let empty = ComparePage(.empty, PageLooks([]), isPicture: false)
}

/// One document's side of a comparison: its pages' text, and what is known about them.
public struct CompareSource: Sendable {
    public var pages: [PageText]
    /// Per page, how its text is set; nil, or nil for a page, when unknown (a scan's text has no looks): nothing is said
    /// about formatting there.
    public var looks: [PageLooks?]?
    /// Per page, whether its text was read from a picture of the page (recognized, or an OCR layer over a scan), so a
    /// difference may be a misreading.
    public var scanned: [Bool]?

    public init(_ pages: [PageText], looks: [PageLooks?]? = nil, scanned: [Bool]? = nil) {
        self.pages = pages
        self.looks = looks
        self.scanned = scanned
    }

    public func looksOf(_ page: Int) -> PageLooks? {
        guard let looks, page >= 0, page < looks.count else { return nil }
        return looks[page]
    }

    public func isScanned(_ page: Int) -> Bool {
        guard let scanned, page >= 0, page < scanned.count else { return false }
        return scanned[page]
    }

    /// A document as read for Compare, with what was recognized on its scans in place of the pages' text (where a page
    /// was). A scan says nothing about formatting: an OCR layer's font and size aren't what the page shows.
    /// - Parameter formatting: whether formatting is compared at all.
    public static func of(_ pages: [ComparePage], recognized: [Int: PageText]? = nil, formatting: Bool = true) -> CompareSource {
        let text = pages.enumerated().map { i, p in recognized?[i] ?? p.text }
        let looks: [PageLooks?]? = formatting ? pages.map { $0.isPicture ? nil : $0.looks } : nil
        return CompareSource(text, looks: looks, scanned: pages.map(\.isPicture))
    }
}
