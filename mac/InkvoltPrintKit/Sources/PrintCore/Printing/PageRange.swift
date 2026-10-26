import Foundation

/// Parses print-dialog page ranges such as "1-3, 5" or "4-" into sorted, distinct 1-based page numbers.
public enum PageRange {
    /// Why a range was refused, in words for the user ("Pages start at 1").
    public struct Invalid: Error, Equatable, Sendable {
        public let message: String

        public init(_ message: String) { self.message = message }
    }

    private static let hint = "Use page numbers like 1-3, 5"

    /// The pages `text` names in a document of `pageCount` pages; empty text means all pages. (The Windows app's
    /// `TryParse` with its out parameters.)
    public static func parse(_ text: String?, _ pageCount: Int) -> Result<[Int], Invalid> {
        let text = text ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .success(pageCount > 0 ? Array(1...pageCount) : [])
        }

        var set = Set<Int>()
        let dashed = text.replacingOccurrences(of: "\u{2013}", with: "-").replacingOccurrences(of: "\u{2014}", with: "-")
        for raw in dashed.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if part.isEmpty { continue }
            var from: Int, to: Int
            if let dash = part.firstIndex(of: "-") {
                let left = part[..<dash].trimmingCharacters(in: .whitespacesAndNewlines)
                let right = part[part.index(after: dash)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if right.contains("-") { return .failure(Invalid(hint)) }
                if left.isEmpty { from = 1 } else if let n = Int(left) { from = n } else { return .failure(Invalid(hint)) }
                if right.isEmpty { to = pageCount } else if let n = Int(right) { to = n } else { return .failure(Invalid(hint)) }
            } else {
                guard let n = Int(part) else { return .failure(Invalid(hint)) }
                (from, to) = (n, n)
            }
            if from > to { (from, to) = (to, from) }
            if from < 1 { return .failure(Invalid("Pages start at 1")) }
            if to > pageCount { return .failure(Invalid("This document has \(pageCount) page\(pageCount == 1 ? "" : "s")")) }
            for p in from...to { set.insert(p) }
        }
        if set.isEmpty { return .failure(Invalid(hint)) }
        return .success(set.sorted())
    }
}
