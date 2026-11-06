import Foundation

/// Just enough of a PDF to find each page's pictures: objects, the page tree, resources (inherited too), streams. A scanner's
/// PDF comes off the network, so everything is read from the file's bytes, in place: one pass over the objects, each search
/// bounded (an object's stream keyword before its `endobj`), lengths checked without overflow and nesting capped, so a
/// hostile file is read in time linear in its size and gives no pages instead of a trap or a hang. A dictionary or value is
/// a range of the file's bytes; `text` gives it as Latin-1, one character per byte.
struct MiniPdf {
    struct Obj {
        var id: Int
        /// The object's text before its stream (all of it when it has none).
        var dict: Range<Int>
        var streamStart: Int
    }

    /// Arrays or dictionaries nested deeper than this are refused (a scanner's PDF nests a few levels).
    static let maxDepth = 64

    /// The bytes scanned. A buffer pointer, not the array, so a debug build reads a byte without retaining the array.
    private typealias Bytes = UnsafeBufferPointer<UInt8>

    /// A keyword or key looked for, the same way: a literal's bytes live as long as the program.
    private typealias Word = UnsafeBufferPointer<UInt8>

    private static func word(_ literal: StaticString) -> Word { Word(start: literal.utf8Start, count: literal.utf8CodeUnitCount) }

    private let bytes: [UInt8]
    private var objects: [Int: Obj] = [:]

    // Computed: a buffer pointer isn't Sendable, so it can't be a stored static; making one from a literal costs nothing.
    private static var objWord: Word { word("obj") }
    private static var endobjWord: Word { word("endobj") }
    private static var streamWord: Word { word("stream") }
    private static var endstreamWord: Word { word("endstream") }
    private static var rootWord: Word { word("/Root") }
    private static var lengthKey: Word { word("/Length") }
    private static var resourcesKey: Word { word("/Resources") }
    private static var rotateKey: Word { word("/Rotate") }
    private static var typeKey: Word { word("/Type") }
    private static var kidsKey: Word { word("/Kids") }
    private static var pagesKey: Word { word("/Pages") }
    private static var xObjectKey: Word { word("/XObject") }
    private static var subtypeKey: Word { word("/Subtype") }
    private static var imageName: Word { word("/Image") }

    init?(_ bytes: [UInt8]) {
        guard bytes.starts(with: Array("%PDF-".utf8)) else { return nil }
        self.bytes = bytes
        guard let objects = bytes.withUnsafeBufferPointer(Self.objects) else { return nil }
        self.objects = objects
    }

    /// Object by object, stepping over each stream's data, so bytes inside a picture are never taken for an object. The next
    /// `endobj` is remembered while it is still ahead, so a file without one is searched once, not once per object.
    private static func objects(_ b: Bytes) -> [Int: Obj]? {
        let length = b.count
        var objects: [Int: Obj] = [:]
        var endobjFrom = Int.max, endobjAt: Int? = nil
        var pos = 0
        while pos < length, let found = objectStart(b, from: pos) {
            let start = found.after
            if endobjFrom > start || (endobjAt.map { $0 < start } ?? false) {
                (endobjFrom, endobjAt) = (start, find(endobjWord, in: b, from: start, to: length))
            }
            let end = endobjAt ?? length
            let stream = streamKeyword(b, from: start, to: end)
            guard let id = int(b, found.id) else { return nil }
            let obj = Obj(id: id, dict: start..<(stream?.at ?? end), streamStart: stream?.data ?? -1)
            objects[id] = obj // a later revision of an object replaces the earlier one
            guard let stream else {
                pos = end
                continue
            }
            let declared = valueRange(b, obj.dict, lengthKey).flatMap { int(b, $0) } ?? 0
            let data = declared <= 0 ? stream.data : declared >= length - stream.data ? length : stream.data + declared
            pos = find(endstreamWord, in: b, from: data, to: length) ?? length
        }
        return objects
    }

    func object(_ id: Int) -> Obj? { objects[id] }

    /// A range of the file as Latin-1 text.
    func text(_ range: Range<Int>) -> String { String(String.UnicodeScalarView(bytes[range].map { Unicode.Scalar($0) })) }

    /// The pages in order, each with the resources it uses (its own or inherited; empty for none) and its turn.
    func pages() -> [(page: Obj, resources: Range<Int>, rotate: Int)]? {
        bytes.withUnsafeBufferPointer { b in
            var root: Int?
            var at = 0
            while let r = Self.find(Self.rootWord, in: b, from: at, to: b.count) { // the last /Root wins (an update)
                at = r + Self.rootWord.count
                var i = at
                while i < b.count && Self.isSpace(b[i]) { i += 1 }
                if i > at, let ref = Self.ref(b, at: i, end: b.count) {
                    root = ref.id
                    at = ref.end
                }
            }
            guard let root, let catalog = object(root) else { return nil }
            guard let pagesId = Self.valueRange(b, catalog.dict, Self.pagesKey).flatMap({ Self.refs(b, $0, first: true).first }),
                  let tree = object(pagesId) else { return nil }
            var pages: [(Obj, Range<Int>, Int)] = []
            var seen = Set<Int>()
            guard walk(b, tree, 0..<0, 0, &pages, 0, &seen) else { return nil }
            return pages
        }
    }

    private func walk(_ b: Bytes, _ node: Obj, _ resources: Range<Int>, _ rotate: Int, _ pages: inout [(Obj, Range<Int>, Int)],
                      _ depth: Int, _ seen: inout Set<Int>) -> Bool {
        guard depth <= 32, seen.insert(node.id).inserted else { return false } // the page tree loops
        let resources = Self.valueRange(b, node.dict, Self.resourcesKey) ?? resources
        let rotate = Self.valueRange(b, node.dict, Self.rotateKey).flatMap { Self.int(b, $0) } ?? rotate
        if Self.is(b, node.dict, Self.typeKey, Self.pagesKey) {
            guard let kids = Self.valueRange(b, node.dict, Self.kidsKey) else { return false }
            for k in Self.refs(b, kids) {
                guard let kid = object(k), walk(b, kid, resources, rotate, &pages, depth + 1, &seen) else { return false }
            }
        } else {
            pages.append((node, resources, rotate))
        }
        return true
    }

    /// The object numbers of the pictures and forms a page's resources name.
    func xObjects(_ resources: Range<Int>) -> [Int] {
        bytes.withUnsafeBufferPointer { b in
            guard let xobjects = Self.valueRange(b, resolve(b, resources), Self.xObjectKey) else { return [] }
            return Self.refs(b, resolve(b, xobjects))
        }
    }

    /// Whether the object is a picture ("/Subtype /Image").
    func isImage(_ obj: Obj) -> Bool {
        bytes.withUnsafeBufferPointer { Self.is($0, obj.dict, Self.subtypeKey, Self.imageName) }
    }

    func streamData(_ obj: Obj) -> [UInt8]? {
        if obj.streamStart < 0 { return nil }
        let start = obj.streamStart
        let length: Int? = bytes.withUnsafeBufferPointer { b in
            let lengthValue = Self.valueRange(b, obj.dict, Self.lengthKey)
            if let lengthValue, let id = Self.refs(b, lengthValue, first: true).first, let lengthObj = object(id) {
                return Self.int(b, Self.trimmed(b, lengthObj.dict))
            }
            if let lengthValue, let n = Self.int(b, lengthValue) { return n }
            guard let end = Self.find(Self.endstreamWord, in: b, from: start, to: b.count) else { return nil }
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

    /// A key's value in a dictionary's text (the tests' way in; the file's own are ranges).
    static func value(_ dict: String, _ key: String) -> String? {
        // The text as bytes, a character beyond Latin-1 as 0xFF (never a delimiter).
        let bytes = dict.unicodeScalars.map { $0.value > 0xFF ? 0xFF : UInt8($0.value) }
        let keyBytes = Array("/\(key)".utf8)
        let range = bytes.withUnsafeBufferPointer { b in keyBytes.withUnsafeBufferPointer { valueRange(b, 0..<b.count, $0) } }
        guard let range else { return nil }
        return String(String.UnicodeScalarView(bytes[range].map { Unicode.Scalar($0) }))
    }

    // MARK: Bytes

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || (c >= 0x09 && c <= 0x0D) }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isAlnum(_ c: UInt8) -> Bool { isDigit(c) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
    private static func isWord(_ c: UInt8) -> Bool { isAlnum(c) || c == 0x5F }

    /// Whether the dictionary's `key` is the name `name` (both with their slash).
    private static func `is`(_ b: Bytes, _ dict: Range<Int>, _ key: Word, _ name: Word) -> Bool {
        guard let v = valueRange(b, dict, key), v.count >= name.count else { return false }
        for k in 0..<name.count where b[v.lowerBound + k] != name[k] { return false }
        return v.count == name.count || !isWord(b[v.lowerBound + name.count])
    }

    /// A key's (with its slash) value in `b[dict]`: a nested dictionary or array (balanced, at most `maxDepth` deep), a
    /// reference, or one token.
    private static func valueRange(_ b: Bytes, _ dict: Range<Int>, _ key: Word) -> Range<Int>? {
        let limit = dict.upperBound
        var at = dict.lowerBound
        var found: Int?
        while let f = find(key, in: b, from: at, to: limit) {
            at = f + 1
            let next = f + key.count
            if next < limit && isAlnum(b[next]) { continue }
            found = next
            break
        }
        guard var i = found else { return nil }
        while i < limit && isSpace(b[i]) { i += 1 }
        if i >= limit { return nil }
        let start = i
        let isArray = b[i] == 0x5B, isDict = b[i] == 0x3C && i + 1 < limit && b[i + 1] == 0x3C
        if isArray || isDict {
            let (open, close): (UInt8, UInt8) = isArray ? (0x5B, 0x5D) : (0x3C, 0x3E)
            let width = isArray ? 1 : 2
            var depth = 0
            while i < limit {
                if b[i] == open && (width == 1 || (i + 1 < limit && b[i + 1] == open)) {
                    depth += 1
                    if depth > maxDepth { return nil }
                    i += width
                } else if b[i] == close && (width == 1 || (i + 1 < limit && b[i + 1] == close)) {
                    depth -= 1
                    i += width
                    if depth == 0 { return start..<i }
                } else {
                    i += 1
                }
            }
            return nil // unbalanced
        }
        if let r = ref(b, at: i, end: limit) { return start..<r.end }
        while i < limit {
            let c = b[i]
            let isStop = c == 0x2F || c == 0x3E || c == 0x5B || c == 0x3C || c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09
            if isStop && !(i == start && c == 0x2F) { break }
            i += 1
        }
        return start..<i
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
    private static func find(_ needle: Word, in b: Bytes, from: Int, to: Int) -> Int? {
        guard let first = needle.first, from >= 0 else { return nil }
        var i = from
        let last = to - needle.count
        while i <= last {
            if b[i] == first {
                var k = 1
                while k < needle.count && b[i + k] == needle[k] { k += 1 }
                if k == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// The next "<id> <generation> obj" at or after `from`: the id's digits and where the object's text starts.
    private static func objectStart(_ b: Bytes, from: Int) -> (id: Range<Int>, after: Int)? {
        var at = from
        while let o = find(objWord, in: b, from: at, to: b.count) {
            at = o + 1
            let after = o + objWord.count
            if after < b.count && isWord(b[after]) { continue }
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
        while let s = find(streamWord, in: b, from: at, to: to) {
            at = s + 1
            if s > 0 && b[s - 1] >= 0x61 && b[s - 1] <= 0x7A { continue }
            var e = s + streamWord.count
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
        if i < end && isWord(b[i]) { return nil }
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
