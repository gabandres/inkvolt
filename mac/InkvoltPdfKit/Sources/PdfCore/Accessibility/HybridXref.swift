import Foundation

/// Hybrid-reference files (Word writes them: a classic xref table whose trailer points at an xref stream with /XRefStm, for
/// the objects kept in object streams). The table marks those objects free, and MuPDF, like PDFsharp on Windows, takes a
/// free row at its word, so they (in Word's files, the structure tree among them) resolve to null. `normalize` appends one
/// xref stream that lists every object of the whole chain, as a reader that follows /XRefStm sees them; MuPDF then finds
/// them all. Nothing before it changes. The Windows app's `HybridXref`.
enum HybridXref {
    private static let maxSections = 64, maxObjects = 8_000_000

    private struct Damaged: Error {}

    private struct Entry {
        var type: Int
        var field2: Int
        var field3: Int
    }

    /// The file with every object reachable, or the same bytes when it isn't a hybrid file (or can't be read as one).
    static func normalize(_ data: [UInt8]) -> [UInt8] { (try? merge(data)) ?? data }

    private static func merge(_ data: [UInt8]) throws -> [UInt8]? {
        guard let start = startXref(data) else { return nil }
        var entries: [Int: Entry] = [:]
        var seen = Set<Int>()
        var hybrid = false
        var lastTrailer: String?
        var queue = [start]
        var i = 0
        while i < queue.count && i < maxSections {
            let at = queue[i]
            i += 1
            guard at > 0, at < data.count, seen.insert(at).inserted else { continue }
            let trailer: String
            if data[at...].starts(with: Array("xref".utf8)) {
                trailer = try classic(data, at, &entries)
                if let x = number(trailer, "/XRefStm") {
                    hybrid = true
                    if seen.insert(x).inserted { _ = try stream(data, x, &entries) }
                }
            } else {
                trailer = try stream(data, at, &entries)
            }
            if lastTrailer == nil { lastTrailer = trailer }
            if let p = number(trailer, "/Prev") { queue.append(p) }
        }
        guard hybrid, let lastTrailer, let top = entries.keys.max(), top + 2 <= maxObjects else { return nil }

        // One xref stream after the file: every object, no /Prev.
        let own = top + 1
        let size = own + 1
        let offset = data.count + 1
        entries[own] = Entry(type: 1, field2: offset, field3: 0)
        var rows: [UInt8] = []
        rows.reserveCapacity(size * 11)
        for n in 0..<size {
            let e = entries[n] ?? Entry(type: 0, field2: 0, field3: n == 0 ? 65535 : 0)
            rows.append(UInt8(truncatingIfNeeded: e.type))
            for b in stride(from: 7, through: 0, by: -1) { rows.append(UInt8(truncatingIfNeeded: e.field2 >> (8 * b))) }
            rows.append(UInt8(truncatingIfNeeded: e.field3 >> 8))
            rows.append(UInt8(truncatingIfNeeded: e.field3))
        }
        var keys = ""
        for key in ["Root", "Info", "Encrypt"] {
            if let m = groups(#"/\#(key)\s+(\d+\s+\d+\s+R)"#, lastTrailer) { keys += " /\(key) \(m[0])" }
        }
        if let id = groups(#"/ID\s*(\[[^\]]*\])"#, lastTrailer) { keys += " /ID \(id[0])" }
        let head = latin1Bytes("\n\(own) 0 obj\n<< /Type /XRef /Size \(size) /W [1 8 2]\(keys) /Length \(rows.count) >>\nstream\n")
        let tail = latin1Bytes("\nendstream\nendobj\nstartxref\n\(offset)\n%%EOF\n")
        return data + head + rows + tail
    }

    /// The offset after the file's last "startxref".
    private static func startXref(_ data: [UInt8]) -> Int? {
        guard let r = data.lastRange(of: Array("startxref".utf8)) else { return nil }
        var i = r.upperBound
        while i < data.count && ContentLexer.isSpace(data[i]) { i += 1 }
        let digits = i
        while i < data.count && (48...57).contains(data[i]) { i += 1 }
        return Int(latin1String(data[digits..<i]))
    }

    /// The capture groups of `pattern`'s first match in `text`.
    private static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1 else { return nil }
        return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }

    /// The number after `/Key` in `text`.
    private static func number(_ text: String, _ key: String) -> Int? {
        groups(key + #"\s+(\d+)"#, text).flatMap { Int($0[0]) }
    }

    /// Reads a classic table into `entries` (entries already known win) and returns its trailer's text.
    private static func classic(_ data: [UInt8], _ at: Int, _ entries: inout [Int: Entry]) throws -> String {
        var p = at + 4
        func skipSpace() { while p < data.count && ContentLexer.isSpace(data[p]) { p += 1 } }
        func digits(_ most: Int) -> Int? {
            let from = p
            while p < data.count && (48...57).contains(data[p]) && p - from < most { p += 1 }
            return p > from ? Int(latin1String(data[from..<p])) : nil
        }
        while true {
            let sectionAt = p
            skipSpace()
            guard let first = digits(10) else {
                p = sectionAt
                break
            }
            skipSpace()
            guard let count = digits(10) else {
                p = sectionAt
                break
            }
            var k = -1
            while k + 1 < count && entries.count < maxObjects {
                k += 1
                skipSpace()
                guard let offset = digits(10) else { throw Damaged() }
                skipSpace()
                guard let generation = digits(5) else { throw Damaged() }
                skipSpace()
                guard p < data.count, data[p] == 110 || data[p] == 102 else { throw Damaged() }
                let inUse = data[p] == 110
                p += 1
                // A hybrid file's table marks the objects kept in object streams as free (so older readers skip them): a
                // free row doesn't hide what the xref stream says.
                if inUse && entries[first + k] == nil { entries[first + k] = Entry(type: 1, field2: offset, field3: generation) }
            }
        }
        guard let t = data[p...].firstRange(of: Array("trailer".utf8)) else { throw Damaged() }
        let end = data[t.lowerBound...].firstRange(of: Array("startxref".utf8))?.lowerBound ?? min(data.count, t.lowerBound + 4096)
        return latin1String(data[t.lowerBound..<end])
    }

    /// Reads an xref stream into `entries` (entries already known win) and returns its dictionary's text.
    private static func stream(_ data: [UInt8], _ at: Int, _ entries: inout [Int: Entry]) throws -> String {
        guard at >= 0, at < data.count else { throw Damaged() }
        let window = data[at..<min(data.count, at + 64 * 1024)]
        guard let s = window.firstRange(of: Array("stream".utf8)) else { throw Damaged() }
        let dict = latin1String(data[at..<s.lowerBound])
        guard groups(#"(/Type\s*/XRef)\b"#, dict) != nil else { throw Damaged() }
        guard let lengthText = groups(#"/Length\s+(\d+)(?!\s+\d+\s+R)\b"#, dict), let length = Int(lengthText[0]) else { throw Damaged() }
        var bodyAt = s.upperBound
        if bodyAt < data.count && data[bodyAt] == 13 { bodyAt += 1 }
        if bodyAt < data.count && data[bodyAt] == 10 { bodyAt += 1 }
        guard bodyAt <= data.count else { throw Damaged() }
        let raw = data[bodyAt..<min(data.count, bodyAt + min(length, data.count))]
        var bytes = Array(raw)
        if groups(#"(/Filter\s*\[?\s*/FlateDecode)"#, dict) != nil {
            guard let inflated = Inflate.zlib(raw, limit: 256 << 20) else { throw Damaged() }
            bytes = inflated
        }
        guard let w = groups(#"/W\s*\[\s*(\d+)\s+(\d+)\s+(\d+)\s*\]"#, dict), let w1 = Int(w[0]), let w2 = Int(w[1]), let w3 = Int(w[2]),
              w1 <= 8, w2 <= 8, w3 <= 8, w1 + w2 + w3 > 0 else { throw Damaged() }
        let rowLength = w1 + w2 + w3
        if let predictor = number(dict, "/Predictor"), predictor >= 10 {
            let columns = number(dict, "/Columns") ?? 1
            guard columns > 0, columns <= 1 << 20 else { throw Damaged() } // a row of xref entries is a few bytes
            bytes = unpredict(bytes, columns)
        }
        var index: [(first: Int, count: Int)] = []
        if let ix = groups(#"/Index\s*\[([\d\s]*)\]"#, dict) {
            let nums = ix[0].split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
            for i in stride(from: 0, to: nums.count - 1, by: 2) where nums[i] <= maxObjects { index.append((nums[i], nums[i + 1])) }
        } else {
            index.append((0, number(dict, "/Size") ?? 0))
        }
        var row = 0
        for (first, count) in index {
            var k = 0
            while k < count && (row + 1) * rowLength <= bytes.count && entries.count < maxObjects {
                let o = row * rowLength
                func field(_ from: Int, _ width: Int) -> Int {
                    var v = 0
                    for b in 0..<width { v = v << 8 | Int(bytes[o + from + b]) }
                    return v
                }
                let type = w1 == 0 ? 1 : field(0, w1)
                if (0...2).contains(type) && entries[first + k] == nil {
                    entries[first + k] = Entry(type: type, field2: field(w1, w2), field3: field(w1 + w2, w3))
                }
                k += 1
                row += 1
            }
        }
        return dict
    }

    /// Undoes PNG predictors (one filter byte per row of `columns` bytes).
    private static func unpredict(_ data: [UInt8], _ columns: Int) -> [UInt8] {
        let rows = data.count / (columns + 1)
        var result = [UInt8](repeating: 0, count: rows * columns)
        for r in 0..<rows {
            let filter = data[r * (columns + 1)]
            for c in 0..<columns {
                let x = Int(data[r * (columns + 1) + 1 + c])
                let left = c > 0 ? Int(result[r * columns + c - 1]) : 0
                let up = r > 0 ? Int(result[(r - 1) * columns + c]) : 0
                let upLeft = r > 0 && c > 0 ? Int(result[(r - 1) * columns + c - 1]) : 0
                let add: Int
                switch filter {
                case 1: add = left
                case 2: add = up
                case 3: add = (left + up) / 2
                case 4: add = paeth(left, up, upLeft)
                default: add = 0
                }
                result[r * columns + c] = UInt8(truncatingIfNeeded: x + add)
            }
        }
        return result
    }

    private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c
    }
}
