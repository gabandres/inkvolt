import Foundation
import PrintCore

/// How a run of page labels is numbered: 1, 2, 3; I, II; i, ii; A, B; a, b; or no number (the prefix alone).
public enum PageNumbering: Sendable, CaseIterable {
    case none, decimal, upperRoman, lowerRoman, upperLetters, lowerLetters
}

/// A run of page labels: its numbering, the text before the number ("A-" makes A-1, A-2) and the first number.
public struct PageLabelStyle: Equatable, Sendable {
    public var numbering: PageNumbering
    public var prefix: String
    public var start: Int

    public init(_ numbering: PageNumbering, _ prefix: String, _ start: Int) {
        self.numbering = numbering
        self.prefix = prefix
        self.start = start
    }

    /// The label of the page `offset` pages into the run.
    public func format(_ offset: Int) -> String {
        prefix + DocumentFeatures.formatNumber(PageLabels.add(start, offset), PageLabels.styleName(numbering))
    }
}

/// Page labels (/PageLabels): what the page box, thumbnails and Go to Page show for a page ("iv", "A-3") instead of its
/// number (the Windows app's `PageLabels`). Edit Page Labels sets them for a range of pages, the pages after it keeping
/// theirs; a document whose labels all come back to plain 1, 2, 3 has none written. Pages moved, inserted or removed keep
/// their labels (`PageEditor`).
public enum PageLabels {
    /// The longest prefix kept, in characters.
    public static let maxPrefix = 64

    /// The largest first number (Roman numerals and letters past their range show as plain numbers).
    public static let maxStart = 1_000_000

    static func styleName(_ n: PageNumbering) -> String? {
        switch n {
        case .decimal: "D"
        case .upperRoman: "R"
        case .lowerRoman: "r"
        case .upperLetters: "A"
        case .lowerLetters: "a"
        case .none: nil
        }
    }

    private static func numbering(_ style: String?) -> PageNumbering {
        switch style {
        case "D": .decimal
        case "R": .upperRoman
        case "r": .lowerRoman
        case "A": .upperLetters
        case "a": .lowerLetters
        default: .none
        }
    }

    /// `a + b`, held at Int32's largest (a label number never goes past it).
    static func add(_ a: Int, _ b: Int) -> Int { min(Int(Int32.max), a + b) }

    /// The style page `page` is labeled in, its own number as the start (plain numbers when the document has no labels).
    public static func at(_ data: [UInt8], _ password: String?, _ page: Int) throws -> PageLabelStyle {
        let doc = try PdfEdit.openToRead(data, password)
        guard let labels = try PdfStructure.readLabels(doc), page >= 0, page < labels.count else {
            return PageLabelStyle(.decimal, "", max(1, page + 1))
        }
        let l = labels[page].label
        return PageLabelStyle(numbering(l.style), l.prefix, min(max(l.number, 1), maxStart))
    }

    /// Labels `pages` (0-based; a range, as "1-4") in `style`, numbered in page order from its start; the other pages keep
    /// theirs (a page after the range goes on as it was, not from the range's last number). `restartAfter`: the pages
    /// after the last of `pages` are numbered 1, 2, 3… (front matter in i, ii, then the body from 1).
    /// - Throws: `PdfEditError` when the pages or the style aren't usable (no page, a page out of range, a prefix too
    ///   long, a start number below 1 or above `maxStart`).
    public static func write(_ data: [UInt8], _ password: String?, _ pages: [Int], _ style: PageLabelStyle, restartAfter: Bool = false) throws -> [UInt8] {
        try check(style)
        let ordered = Array(Set(pages)).sorted()
        return try PageEditor.editLabels(data, password) { labels, count in
            guard let first = ordered.first, let last = ordered.last, first >= 0, last < count else {
                throw PdfEditError(loc("No pages selected."))
            }
            var labels = labels
            for (k, p) in ordered.enumerated() {
                labels[p] = PdfStructure.PageLabel(style: styleName(style.numbering), prefix: style.prefix, number: add(style.start, k))
            }
            if restartAfter {
                for i in stride(from: last + 1, to: count, by: 1) { labels[i] = PdfStructure.PageLabel(style: "D", prefix: "", number: i - last) }
            }
            return labels
        }
    }

    /// Removes every label: the pages show their plain numbers.
    public static func remove(_ data: [UInt8], _ password: String?) throws -> [UInt8] {
        try PageEditor.editLabels(data, password) { _, _ in nil }
    }

    /// - Throws: `PdfEditError` for a prefix too long or with control characters, or a start number out of range.
    public static func check(_ style: PageLabelStyle) throws {
        // .NET counts UTF-16 code units and its char.IsControl is Unicode's Cc.
        if style.prefix.utf16.count > maxPrefix || style.prefix.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            throw PdfEditError(loc("A prefix can be up to {0} characters, without line breaks or tabs.", CoreLanguage.number(maxPrefix)))
        }
        if style.start < 1 || style.start > maxStart {
            throw PdfEditError(loc("The first number must be from 1 to {0}.", CoreLanguage.number(maxStart)))
        }
        if style.numbering == .none && style.prefix.isEmpty { throw PdfEditError(loc("Choose a numbering or type a prefix.")) }
    }
}

extension PageEditor {
    /// One edit of the page labels (`PageLabels`): `change` gets each page's label (plain numbers when there are none) and
    /// the page count, and returns the labels to write, or nil for none. Labels that are plain numbers from 1 on every page
    /// are written as none.
    static func editLabels(_ data: [UInt8], _ password: String?,
                           _ change: ([PdfStructure.PageLabel], Int) throws -> [PdfStructure.PageLabel]?) throws -> [UInt8] {
        try edit(data, password) { doc in
            let count = try doc.pageCount()
            let labels = try PdfStructure.readLabels(doc)?.map(\.label)
                ?? (0..<count).map { PdfStructure.PageLabel(style: "D", prefix: "", number: $0 + 1) }
            let changed = try change(labels, count)
            if let changed, !isPlain(changed) {
                PdfStructure.writeRanges(doc, changed)
            } else {
                doc.catalog.remove("PageLabels")
            }
        }
    }

    /// Labels that are the plain page numbers 1, 2, 3… (written as none).
    static func isPlain(_ labels: [PdfStructure.PageLabel]) -> Bool {
        labels.enumerated().allSatisfy { $0.element == PdfStructure.PageLabel(style: "D", prefix: "", number: $0.offset + 1) }
    }
}
