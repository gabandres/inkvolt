import Foundation

/// Just enough of a PDF to find each page's pictures: objects, the page tree, resources (inherited too), streams. A scanner's
/// PDF comes off the network, so everything is read from the file's bytes, in place: one pass over the objects, each search
/// bounded (an object's stream keyword before its `endobj`), lengths checked without overflow and nesting capped, so a
/// hostile file is read in time linear in its size and gives no pages instead of a trap or a hang. A dictionary or value is
/// a range of the file's bytes; `text` gives it as Latin-1, one character per byte. A key is looked for among a dictionary's
/// own keys only, its values (nested dictionaries and arrays, strings, comments) stepped over as PDF's syntax reads them.
struct MiniPdf {
    struct Obj {
        var id: Int
        /// The object's text before its stream (all of it when it has none).
        var dict: Range<Int>
        var streamStart: Int
    }

    /// Arrays or dictionaries nested deeper than this are refused (a scanner's PDF nests a few levels; at most 64, one bit
    /// each in `valueEnd`).
    static let maxDepth = 64

    /// The bytes scanned. A buffer pointer, not the array, so a debug build reads a byte without retaining the array.
    private typealias Bytes = UnsafeBufferPointer<UInt8>

    /// Keywords and keys (with their slash), as bytes.
    private enum Word {
        static let obj = Array("obj".utf8)
        static let endobj = Array("endobj".utf8)
        static let stream = Array("stream".utf8)
        static let endstream = Array("endstream".utf8)
        static let root = Array("/Root".utf8)
        static let length = Array("/Length".utf8)
        static let resources = Array("/Resources".utf8)
        static let rotate = Array("/Rotate".utf8)
        static let type = Array("/Type".utf8)
        static let kids = Array("/Kids".utf8)
        static let pages = Array("/Pages".utf8)
        static let xObject = Array("/XObject".utf8)
        static let subtype = Array("/Subtype".utf8)
        static let image = Array("/Image".utf8)
    }

    private let bytes: [UInt8]
    private var objects: [Int: Obj] = [:]

    init?(_ bytes: [UInt8]) {
        guard bytes.starts(with: Array("%PDF-".utf8)) else { return nil }
        self.bytes = bytes
        objects = bytes.withUnsafeBufferPointer(Self.objects)
    }

    /// Object by object, stepping over each stream's data, so bytes inside a picture are never taken for an object. The next
    /// `endobj` is remembered while it is still ahead, so a file without one is searched once, not once per object. An object
    /// whose number is beyond Int is stepped over the same way, and left out.
    private static func objects(_ b: Bytes) -> [Int: Obj] {
        let length = b.count
        var objects: [Int: Obj] = [:]
        var endobjFrom = Int.max, endobjAt: Int? = nil
        var pos = 0
        while pos < length, let found = objectStart(b, from: pos) {
            let start = found.after
            if endobjFrom > start || (endobjAt.map { $0 < start } ?? false) {
                (endobjFrom, endobjAt) = (start, find(Word.endobj, in: b, from: start, to: length))
            }
            let end = endobjAt ?? length
            let stream = streamKeyword(b, from: start, to: end)
            let dict = start..<(stream?.at ?? end)
            if let id = int(b, found.id) {
                objects[id] = Obj(id: id, dict: dict, streamStart: stream?.data ?? -1) // a later revision replaces the earlier
            }
            guard let stream else {
                pos = end
                continue
            }
            let declared = valueRange(b, dict, Word.length).flatMap { int(b, $0) } ?? 0
            let data = declared <= 0 ? stream.data : declared >= length - stream.data ? length : stream.data + declared
            pos = find(Word.endstream, in: b, from: data, to: length) ?? length
        }
        return objects
    }

    func object(_ id: Int) -> Obj? { objects[id] }

    /// A range of the file as Latin-1 text.
    func text(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(bytes[range].map { Unicode.Scalar($0) })) }

    /// The pages in order, each with the resources it uses (its own or inherited; empty for none) and its turn. The walk
    /// stops one page past `limit`, so more pages than that come back as `limit + 1` of them.
    func pages(limit: Int = .max) -> [(page: Obj, resources: Range<Int>, rotate: Int)]? {
        bytes.withUnsafeBufferPointer { b in
            var root: Int?
            var at = 0
            while let r = Self.find(Word.root, in: b, from: at, to: b.count) { // the last /Root wins (an update)
                at = r + Word.root.count
                var i = at
                while i < b.count && Self.isSpace(b[i]) { i += 1 }
                if i > at, let ref = Self.ref(b, at: i, end: b.count) {
                    root = ref.id
                    at = ref.end
                }
            }
            guard let root, let catalog = object(root) else { return nil }
            guard let pagesId = Self.valueRange(b, catalog.dict, Word.pages).flatMap({ Self.refs(b, $0, first: true).first }),
                  let tree = object(pagesId) else { return nil }
            var pages: [(Obj, Range<Int>, Int)] = []
            var seen = Set<Int>()
            let whole = walk(b, tree, 0..<0, 0, &pages, 0, &seen, limit)
            if pages.count > limit { return pages }
            return whole ? pages : nil
        }
    }

    private func walk(_ b: Bytes, _ node: Obj, _ resources: Range<Int>, _ rotate: Int, _ pages: inout [(Obj, Range<Int>, Int)],
                      _ depth: Int, _ seen: inout Set<Int>, _ limit: Int) -> Bool {
        guard depth <= 32, seen.insert(node.id).inserted else { return false } // the page tree loops
        let resources = Self.valueRange(b, node.dict, Word.resources) ?? resources
        let rotate = Self.valueRange(b, node.dict, Word.rotate).flatMap { Self.int(b, $0) } ?? rotate
        if Self.is(b, node.dict, Word.type, Word.pages) {
            guard let kids = Self.valueRange(b, node.dict, Word.kids) else { return false }
            for k in Self.refs(b, kids) {
                guard let kid = object(k), walk(b, kid, resources, rotate, &pages, depth + 1, &seen, limit) else { return false }
            }
        } else {
            pages.append((node, resources, rotate))
        }
        return pages.count <= limit
    }

    /// The object numbers of the pictures and forms a page's resources name.
    func xObjects(_ resources: Range<Int>) -> [Int] {
        bytes.withUnsafeBufferPointer { b in
            guard let xobjects = Self.valueRange(b, resolve(b, resources), Word.xObject) else { return [] }
            return Self.refs(b, resolve(b, xobjects))
        }
    }

    /// Whether the object is a picture ("/Subtype /Image").
    func isImage(_ obj: Obj) -> Bool {
        bytes.withUnsafeBufferPointer { Self.is($0, obj.dict, Word.subtype, Word.image) }
    }

    /// The object's own value for `key` (with its slash: "/Filter") as Latin-1 text; nil when its dictionary has no such key.
    func value(_ obj: Obj, _ key: String) -> String? {
        let key = Array(key.utf8)
        return bytes.withUnsafeBufferPointer { Self.valueRange($0, obj.dict, key) }.map(text)
    }

    /// The object's own value for `key` as names: one name, or an array of names; nil when it has none or is anything else.
    func names(_ obj: Obj, _ key: String) -> [String]? {
        let key = Array(key.utf8)
        let ranges: [Range<Int>]? = bytes.withUnsafeBufferPointer { b in
            guard let v = Self.valueRange(b, obj.dict, key) else { return nil }
            if b[v.lowerBound] == 0x2F { return [v] }
            guard b[v.lowerBound] == 0x5B else { return nil }
            var out: [Range<Int>] = []
            var i = v.lowerBound + 1
            while true {
                i = Self.skipSpace(b, i, v.upperBound)
                guard i < v.upperBound else { return nil }
                if b[i] == 0x5D { return out }
                guard b[i] == 0x2F, let end = Self.tokenEnd(b, i, v.upperBound) else { return nil }
                out.append(i..<end)
                i = end
            }
        }
        return ranges?.map(text)
    }

    func streamData(_ obj: Obj) -> [UInt8]? {
        if obj.streamStart < 0 { return nil }
        let start = obj.streamStart
        let length: Int? = bytes.withUnsafeBufferPointer { b in
            let lengthValue = Self.valueRange(b, obj.dict, Word.length)
            if let lengthValue, let id = Self.refs(b, lengthValue, first: true).first, let lengthObj = object(id) {
                return Self.int(b, Self.trimmed(b, lengthObj.dict))
            }
            if let lengthValue, let n = Self.int(b, lengthValue) { return n }
            guard let end = Self.find(Word.endstream, in: b, from: start, to: b.count) else { return nil }
            var length = end - start
            while length > 0 && (b[start + length - 1] == 0x0A || b[start + length - 1] == 0x0D) { length -= 1 }
            return length
        }
        guard let length, length >= 0, length <= bytes.count - start else { return nil } // runs past the file (no overflow)
        return Array(bytes[start..<start + length])
    }

    /// An indirect reference's object's dictionary, or the value itself.
    private func resolve(_ b: Bytes, _ value: Range<Int>) -> Range<Int> {
        let trimmed = Self.trimmed(b, value)
        if let r = Self.ref(b, at: trimmed.lowerBound, end: trimmed.upperBound), r.end == trimmed.upperBound, let o = object(r.id) {
            return o.dict
        }
        return value
    }

    /// A key's value in a dictionary's text, `<<…>>` or its keys and values alone (the tests' way in; the file's own are
    /// ranges).
    static func value(_ dict: String, _ key: String) -> String? {
        // The text as bytes, a character beyond Latin-1 as 0xFF (never a delimiter).
        let bytes = dict.unicodeScalars.map { $0.value > 0xFF ? 0xFF : UInt8($0.value) }
        let key = Array("/\(key)".utf8)
        guard let range = bytes.withUnsafeBufferPointer({ valueRange($0, 0..<$0.count, key) }) else { return nil }
        return String(String.UnicodeScalarView(bytes[range].map { Unicode.Scalar($0) }))
    }

    // MARK: Bytes

    /// PDF's white space: NUL, TAB, LF, FF, CR and space.
    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }

    /// PDF's delimiters: ( ) < > [ ] { } / %.
    private static func isDelimiter(_ c: UInt8) -> Bool {
        switch c {
        case 0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25: true
        default: false
        }
    }

    /// A byte of a name, number or keyword: neither white space nor a delimiter.
    private static func isRegular(_ c: UInt8) -> Bool { !isSpace(c) && !isDelimiter(c) }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    /// Whether the dictionary's own `key` is the name `name` (both with their slash).
    private static func `is`(_ b: Bytes, _ dict: Range<Int>, _ key: [UInt8], _ name: [UInt8]) -> Bool {
        guard let v = valueRange(b, dict, key), v.count == name.count else { return false }
        return zip(v, name).allSatisfy { b[$0] == $1 }
    }

    /// The value of a dictionary's own key (with its slash) in `b[dict]`, which is `<<…>>` (white space and comments around
    /// it) or its keys and values alone: a reference, a balanced dictionary or array (at most `maxDepth` deep), or one token.
    /// Keys and values are read in turn, each value stepped over whole, so a key inside a nested dictionary, an array, a
    /// string or a comment, or a value that names the key, is never taken for it. Nil when there is no such key, or the
    /// dictionary breaks off before it.
    private static func valueRange(_ b: Bytes, _ dict: Range<Int>, _ key: [UInt8]) -> Range<Int>? {
        let limit = dict.upperBound
        var i = skipSpace(b, dict.lowerBound, limit)
        let inside = i + 1 < limit && b[i] == 0x3C && b[i + 1] == 0x3C
        if inside { i += 2 }
        func closes(_ i: Int) -> Bool { inside && i + 1 < limit && b[i] == 0x3E && b[i + 1] == 0x3E }
        while true {
            i = skipSpace(b, i, limit)
            guard i < limit, !closes(i), let keyEnd = valueEnd(b, i, limit) else { return nil }
            let isName = b[i] == 0x2F
            let isKey = isName && keyEnd - i == key.count && zip(i..<keyEnd, key).allSatisfy { b[$0] == $1 }
            i = keyEnd
            if !isName { continue } // not a key: stepped over, and the next item read as one
            i = skipSpace(b, i, limit)
            guard i < limit, !closes(i) else { return nil }
            guard let end = ref(b, at: i, end: limit)?.end ?? valueEnd(b, i, limit) else { return nil }
            if isKey { return i..<end }
            i = end
        }
    }

    /// Past white space and comments (`%` to the line's end) from `i`.
    private static func skipSpace(_ b: Bytes, _ i: Int, _ limit: Int) -> Int {
        var i = i
        while i < limit {
            if isSpace(b[i]) {
                i += 1
            } else if b[i] == 0x25 {
                while i < limit && b[i] != 0x0A && b[i] != 0x0D { i += 1 }
            } else {
                break
            }
        }
        return i
    }

    /// Where the value at `start` (not white space) ends: one token, or a dictionary or array balanced with the strings and
    /// comments inside stepped over, at most `maxDepth` deep. Nil when it never closes, closes the wrong way or is a closer.
    private static func valueEnd(_ b: Bytes, _ start: Int, _ limit: Int) -> Int? {
        var dictionaries: UInt64 = 0 // per level, whether it is a dictionary
        var depth = 0
        var i = start
        repeat {
            i = skipSpace(b, i, limit)
            guard i < limit else { return nil }
            let c = b[i]
            let pair = i + 1 < limit && b[i + 1] == c
            if c == 0x5B || (c == 0x3C && pair) {
                guard depth < maxDepth else { return nil }
                let bit = UInt64(1) << UInt64(depth)
                dictionaries = c == 0x3C ? dictionaries | bit : dictionaries & ~bit
                depth += 1
                i += c == 0x5B ? 1 : 2
            } else if c == 0x5D || (c == 0x3E && pair) {
                guard depth > 0 else { return nil }
                depth -= 1
                guard (dictionaries >> UInt64(depth) & 1 == 1) == (c == 0x3E) else { return nil }
                i += c == 0x5D ? 1 : 2
            } else {
                guard let end = tokenEnd(b, i, limit) else { return nil }
                i = end
            }
        } while depth > 0
        return i
    }

    /// Where the token at `i` ends: a literal string (nested parentheses, a backslash taking the next byte as it is), a hex
    /// string, a name, a number or keyword, or one stray delimiter; nil for a string that never ends. `<<`, `>>`, `[` and
    /// `]` are `valueEnd`'s.
    private static func tokenEnd(_ b: Bytes, _ i: Int, _ limit: Int) -> Int? {
        var j = i + 1
        switch b[i] {
        case 0x28: // (
            var depth = 1
            while j < limit {
                switch b[j] {
                case 0x5C: j += 1 // \: the next byte is the string's
                case 0x28: depth += 1
                case 0x29:
                    depth -= 1
                    if depth == 0 { return j + 1 }
                default: break
                }
                j += 1
            }
            return nil
        case 0x3C: // <, a hex string
            while j < limit && b[j] != 0x3E { j += 1 }
            return j < limit ? j + 1 : nil
        case 0x2F: // a name
            while j < limit && isRegular(b[j]) { j += 1 }
            return j
        case let c where isDelimiter(c):
            return j
        default:
            while j < limit && isRegular(b[j]) { j += 1 }
            return j
        }
    }

    private static func trimmed(_ b: Bytes, _ range: Range<Int>) -> Range<Int> {
        var (lo, hi) = (range.lowerBound, range.upperBound)
        while lo < hi && isSpace(b[lo]) { lo += 1 }
        while hi > lo && isSpace(b[hi - 1]) { hi -= 1 }
        return lo..<hi
    }

    /// A whole number written in `b[range]` (an optional sign, then digits); nil for anything else or one beyond Int.
    private static func int(_ b: Bytes, _ range: Range<Int>) -> Int? {
        var i = range.lowerBound
        let negative = i < range.upperBound && b[i] == 0x2D
        if i < range.upperBound && (b[i] == 0x2D || b[i] == 0x2B) { i += 1 }
        guard i < range.upperBound else { return nil }
        var n = 0
        while i < range.upperBound {
            guard isDigit(b[i]) else { return nil }
            let digit = Int(b[i] - 0x30)
            let (times, o1) = n.multipliedReportingOverflow(by: 10)
            let (next, o2) = negative ? times.subtractingReportingOverflow(digit) : times.addingReportingOverflow(digit)
            if o1 || o2 { return nil }
            n = next
            i += 1
        }
        return n
    }

    /// Where `needle` first starts in `b[from..<to]`.
    private static func find(_ needle: [UInt8], in b: Bytes, from: Int, to: Int) -> Int? {
        guard let first = needle.first, from >= 0 else { return nil }
        let count = needle.count
        var i = from
        let last = to - count
        while i <= last {
            if b[i] == first {
                var k = 1
                while k < count && b[i + k] == needle[k] { k += 1 }
                if k == count { return i }
            }
            i += 1
        }
        return nil
    }

    /// The next "<id> <generation> obj" at or after `from`: the id's digits and where the object's text starts.
    private static func objectStart(_ b: Bytes, from: Int) -> (id: Range<Int>, after: Int)? {
        var at = from
        while let o = find(Word.obj, in: b, from: at, to: b.count) {
            at = o + 1
            let after = o + Word.obj.count
            if after < b.count && isRegular(b[after]) { continue }
            // Back over " <generation> " and the id: digits and white space only, so the walks back never overlap.
            var i = o
            func back(_ test: (UInt8) -> Bool) -> Bool {
                let was = i
                while i > from && test(b[i - 1]) { i -= 1 }
                return i < was
            }
            guard back(isSpace), back(isDigit), back(isSpace) else { continue }
            let idEnd = i
            guard back(isDigit) else { continue }
            return (i..<idEnd, after)
        }
        return nil
    }

    /// "stream" followed by a line end, starting in `b[from..<to]` (not the end of "endstream"): where it is and where its
    /// data starts.
    private static func streamKeyword(_ b: Bytes, from: Int, to: Int) -> (at: Int, data: Int)? {
        var at = from
        while let s = find(Word.stream, in: b, from: at, to: to) {
            at = s + 1
            if s > 0 && b[s - 1] >= 0x61 && b[s - 1] <= 0x7A { continue }
            var e = s + Word.stream.count
            if e < b.count && b[e] == 0x0D { e += 1 }
            if e < b.count && b[e] == 0x0A { return (s, e + 1) }
        }
        return nil
    }

    /// The reference "<id> <generation> R" starting exactly at `s`, before `end`: its object number (-1 when too big) and
    /// where it ends.
    private static func ref(_ b: Bytes, at s: Int, end: Int) -> (id: Int, end: Int)? {
        var i = s
        func run(_ test: (UInt8) -> Bool) -> Bool {
            let was = i
            while i < end && test(b[i]) { i += 1 }
            return i > was
        }
        guard run(isDigit) else { return nil }
        let idEnd = i
        guard run(isSpace), run(isDigit), run(isSpace), i < end, b[i] == 0x52 else { return nil }
        i += 1
        if i < end && isRegular(b[i]) { return nil }
        return (int(b, s..<idEnd) ?? -1, i)
    }

    /// The object numbers of the references in `b[range]`, in order (only the first with `first`).
    private static func refs(_ b: Bytes, _ range: Range<Int>, first: Bool = false) -> [Int] {
        var out: [Int] = []
        var i = range.lowerBound
        while i < range.upperBound {
            if !isDigit(b[i]) {
                i += 1
                continue
            }
            if let r = ref(b, at: i, end: range.upperBound) {
                out.append(r.id)
                if first { break }
                i = r.end
                continue
            }
            while i < range.upperBound && isDigit(b[i]) { i += 1 } // the generation's digits may start one
        }
        return out
    }
}
