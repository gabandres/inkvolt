import Foundation

public enum PageSubset: Sendable { case all, even, odd }

/// Parses page ranges as the user types them, such as "1-3, 5, 8-" or "2-end" (1-based), into sorted 0-based page
/// indices.
public enum PageRange {
    /// `ok` false with `error` saying why; else the pages.
    public static func tryParse(_ text: String?, _ pageCount: Int) -> (ok: Bool, pages: [Int], error: String?) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, [], "Enter one or more pages, e.g. 1-3, 5, 8-")
        }
        var set = Set<Int>()
        let parts = text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for raw in parts {
            // En and em dashes come in from copied text and autocorrect.
            let from: Int, to: Int
            if let dash = raw.firstIndex(where: { $0 == "-" || $0 == "–" || $0 == "—" }) {
                let a = raw[..<dash].trimmingCharacters(in: .whitespaces)
                let b = raw[raw.index(after: dash)...].trimmingCharacters(in: .whitespaces)
                var f = 1, t = pageCount
                if !a.isEmpty {
                    guard let p = page(a, pageCount) else { return fail(raw) }
                    f = p
                }
                if !b.isEmpty {
                    guard let p = page(b, pageCount) else { return fail(raw) }
                    t = p
                }
                (from, to) = (f, t)
            } else {
                guard let p = page(raw, pageCount) else { return fail(raw) }
                (from, to) = (p, p)
            }
            if from < 1 || to > pageCount || from > to { return (false, [], "\"\(raw)\" is outside 1–\(pageCount).") }
            for p in from...to { set.insert(p - 1) }
        }
        let pages = set.sorted()
        return pages.isEmpty ? fail(text) : (true, pages, nil)
    }

    /// "Even" and "odd" refer to 1-based page numbers, as the user sees them.
    public static func apply(_ pages: [Int], _ subset: PageSubset) -> [Int] {
        switch subset {
        case .even: pages.filter { ($0 + 1) % 2 == 0 }
        case .odd: pages.filter { ($0 + 1) % 2 == 1 }
        case .all: pages
        }
    }

    /// 0-based indices back as a compact 1-based range string ("1-3, 5").
    public static func format(_ pages: [Int]) -> String {
        let sorted = Set(pages).sorted()
        var parts: [String] = []
        var i = 0
        while i < sorted.count {
            var j = i
            while j + 1 < sorted.count && sorted[j + 1] == sorted[j] + 1 { j += 1 }
            parts.append(i == j ? "\(sorted[i] + 1)" : "\(sorted[i] + 1)-\(sorted[j] + 1)")
            i = j + 1
        }
        return parts.joined(separator: ", ")
    }

    /// A page number, "end" or "last" (digits only, as .NET's NumberStyles.None).
    private static func page(_ s: String, _ pageCount: Int) -> Int? {
        if s.caseInsensitiveCompare("end") == .orderedSame || s.caseInsensitiveCompare("last") == .orderedSame { return pageCount }
        guard !s.isEmpty, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }

    private static func fail(_ raw: String) -> (ok: Bool, pages: [Int], error: String?) {
        (false, [], "\"\(raw)\" is not a valid page range.")
    }
}
