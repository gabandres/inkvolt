import Foundation

/// A keyword in a whole file's bytes, without going through a generic collection byte by byte: `DataProtocol.firstRange`
/// spent a quarter of a form fill on a 575 KB file looking for /ByteRange.
enum PdfBytes {
    /// Where `key` first is at or after `from`, before `to`.
    static func first(_ key: [UInt8], in data: [UInt8], from: Int = 0, to: Int? = nil) -> Int? {
        let end = min(to ?? data.count, data.count)
        guard from >= 0, from < end, !key.isEmpty else { return nil }
        return data.withUnsafeBytes { all -> Int? in
            key.withUnsafeBytes { k -> Int? in
                guard let base = all.baseAddress, let found = memmem(base + from, end - from, k.baseAddress, key.count) else { return nil }
                return base.distance(to: UnsafeRawPointer(found))
            }
        }
    }

    /// Where `key` last starts before `end`.
    static func last(_ key: [UInt8], in data: [UInt8], before end: Int) -> Int? {
        guard !key.isEmpty, end >= key.count else { return nil }
        return data.withUnsafeBufferPointer { b -> Int? in
            var i = min(end, b.count) - key.count
            while i >= 0 {
                if b[i] == key[0] {
                    var k = 1
                    while k < key.count && b[i + k] == key[k] { k += 1 }
                    if k == key.count { return i }
                }
                i -= 1
            }
            return nil
        }
    }

    static func isWhite(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 || b == 12 || b == 0 }
}

/// Bytes after a file's last good revision, which every reader leaves out (the Windows app's `StaleTail`). Two kinds:
/// - **A stale tail**: a file an editor saved over a longer copy of itself without cutting it to its new length keeps the old
///   file's last bytes after its own %%EOF (an old object's end, rows of the old table, its trailer, a startxref into the
///   middle of the new file). MuPDF's repair takes the last copy of an object, so an old object there replaced the real one
///   (a field's value, or the field itself).
/// - **Junk** after a last startxref that is good (a mail gateway's padding): MuPDF looks for startxref only near the end and
///   repairs the file, and an update it appends counts its offsets from the end of the revision it read.
///
/// `keepLength` is what MuPDF is given, as every document is opened (`MuDoc.open`, `PdfEngine.open`), so the view, the readers
/// and the edits all see the same objects; an update goes right after it (`MuDoc.appendsAfter`). Never left out: a tail that
/// starts as an update would (an object or a table, after white space and comments), junk holding an object, or anything a
/// signature's /ByteRange covers. A tail holding objects is dropped only as a repair (`PdfRepair`: the person is told, and
/// signatures made before it aren't shown valid). Mac difference: Windows keeps a tail holding an object and rebuilds the
/// cross-reference, where the old object would win.
enum StaleTail {
    struct Tail: Equatable {
        /// The bytes before it.
        var keep: Int
        /// It holds an object header: what it hides is told as a repair.
        var hidesObjects: Bool
    }

    /// The most startxref keywords looked at, from the end: a real file's good one is the second to last.
    private static let maxCandidates = 64
    /// The most bytes read past all the offsets checked, so a file full of startxrefs is cheap to refuse.
    private static let maxScanBytes = 4 << 20
    private static let maxXrefDictBytes = 64 * 1024
    /// White space after the last %%EOF that is left alone (MuPDF finds startxref within the last 1024 bytes).
    private static let whiteTailKept = 512

    private static let startxref = Array("startxref".utf8), eof = Array("%%EOF".utf8), xref = Array("xref".utf8)
    private static let objKey = Array("obj".utf8), stream = Array("stream".utf8), xrefType = Array("/XRef".utf8)
    private static let byteRange = Array("/ByteRange".utf8)

    /// How many of the file's bytes a reader is given.
    static func keepLength(_ data: [UInt8]) -> Int { find(data)?.keep ?? data.count }

    /// The bytes a reader is given: `data` itself, or (rarely) its first `keepLength`.
    static func openable(_ data: [UInt8]) -> [UInt8] {
        guard let tail = find(data) else { return data }
        return Array(data[..<tail.keep])
    }

    /// The bytes after the file's last good revision a reader leaves out, nil when there are none.
    static func find(_ data: [UInt8]) -> Tail? {
        guard let found = lastGoodEnd(data) else { return nil }
        var i = found.end
        while i < data.count && PdfBytes.isWhite(data[i]) { i += 1 }
        // White space alone is left as it is, unless there's more of it than MuPDF looks past for the last startxref.
        if i >= data.count && data.count - found.end <= whiteTailKept { return nil }
        let hides = holdsObjects(data, from: found.end)
        // After the last startxref, only junk: an object there may be a revision whose table is lost.
        if found.isLast && hides { return nil }
        if !found.isLast && startsAsUpdate(data, found.end) { return nil }
        if signedEnd(data) > found.end { return nil }
        return Tail(keep: found.end, hidesObjects: hides)
    }

    /// Where the last revision whose startxref points at a cross-reference section ends (past its %%EOF and line end), and
    /// whether that startxref is the file's last one.
    private static func lastGoodEnd(_ data: [UInt8]) -> (end: Int, isLast: Bool)? {
        var end = data.count
        var isLast = true
        var budget = maxScanBytes
        var candidates = 0
        while candidates < maxCandidates && budget > 0 && end > 0 {
            candidates += 1
            guard let at = PdfBytes.last(startxref, in: data, before: end) else { return nil }
            end = at
            guard let (offset, after) = startXref(data, at + startxref.count) else {
                isLast = false
                continue
            }
            let window = min(budget, maxXrefDictBytes)
            budget -= window
            guard isXref(data, offset, window) else {
                isLast = false
                continue
            }
            var i = after
            while i < data.count && PdfBytes.isWhite(data[i]) { i += 1 }
            guard starts(data, eof, i, data.count) else { return nil }
            var cut = i + eof.count
            if cut < data.count && data[cut] == 13 { cut += 1 }
            if cut < data.count && data[cut] == 10 { cut += 1 }
            return (cut, isLast)
        }
        return nil
    }

    /// Whether the bytes from `from` on hold an object header (a revision, whole or broken, not just junk): any "obj" keyword
    /// standing alone, as MuPDF's repair reads one. Its lexer takes comments for white space and reads signed numbers, so
    /// "5 0 %note↵obj" and "+5 +0 obj" are objects to it: no look back at the numbers, only at the word ("endobj",
    /// "objects" aren't one).
    static func holdsObjects(_ data: [UInt8], from: Int) -> Bool {
        var at = from
        while let found = PdfBytes.first(objKey, in: data, from: at) {
            let end = found + objKey.count
            let alone = (found == 0 || !isRegular(data[found - 1])) && (end >= data.count || !isRegular(data[end]))
            if alone { return true }
            at = end
        }
        return false
    }

    /// A byte that is neither white space nor a delimiter: part of a keyword, name or number.
    private static func isRegular(_ b: UInt8) -> Bool {
        !PdfBytes.isWhite(b) && !"()<>[]{}/%".utf8.contains(b)
    }

    /// Where the bytes the file's signatures cover end: the largest end of any /ByteRange in it, 0 without one.
    static func signedEnd(_ data: [UInt8]) -> Int {
        var end = 0
        var at = 0
        while let found = PdfBytes.first(byteRange, in: data, from: at) {
            at = found + byteRange.count
            var i = at
            let limit = min(data.count, i + 128)
            var numbers: [Int] = []
            while i < limit && numbers.count < 4 {
                let c = data[i]
                if c >= 48 && c <= 57 {
                    var v = 0, n = 0
                    while i < limit && data[i] >= 48 && data[i] <= 57 && n < 15 {
                        v = v * 10 + Int(data[i] - 48)
                        i += 1
                        n += 1
                    }
                    numbers.append(v)
                } else if PdfBytes.isWhite(c) || c == UInt8(ascii: "[") {
                    i += 1
                } else {
                    break
                }
            }
            if numbers.count == 4 { end = max(end, numbers[2] + numbers[3]) }
        }
        return end
    }

    /// The offset after a startxref keyword, and where its digits end; nil when it names no place in the file.
    private static func startXref(_ data: [UInt8], _ from: Int) -> (at: Int, after: Int)? {
        var p = from
        while p < data.count && PdfBytes.isWhite(data[p]) { p += 1 }
        var at = 0, digits = 0
        while p < data.count && data[p] >= 48 && data[p] <= 57 && digits < 18 {
            at = at * 10 + Int(data[p] - 48)
            p += 1
            digits += 1
        }
        return digits > 0 && at > 0 && at < data.count ? (at, p) : nil
    }

    /// Past "<number> <number> obj" at `from`, nil when it isn't one.
    private static func objectHeader(_ data: [UInt8], _ from: Int, _ limit: Int) -> Int? {
        var i = from
        for _ in 0..<2 {
            let start = i
            while i < limit && i - start < 10 && data[i] >= 48 && data[i] <= 57 { i += 1 }
            if i == start { return nil }
            let spaces = i
            while i < limit && PdfBytes.isWhite(data[i]) { i += 1 }
            if i == spaces { return nil }
        }
        return starts(data, objKey, i, limit) ? i + objKey.count : nil
    }

    private static func starts(_ data: [UInt8], _ key: [UInt8], _ at: Int, _ limit: Int) -> Bool {
        guard at + key.count <= limit else { return false }
        for k in key.indices where data[at + k] != key[k] { return false }
        return true
    }

    /// A cross-reference table or stream at the offset.
    private static func isXref(_ data: [UInt8], _ at: Int, _ maxBytes: Int) -> Bool {
        let limit = min(data.count, at + maxBytes)
        var i = at
        while i < limit && PdfBytes.isWhite(data[i]) { i += 1 }
        if starts(data, xref, i, limit) { return true }
        guard let dict = objectHeader(data, i, limit), let body = PdfBytes.first(stream, in: data, from: dict, to: limit) else { return false }
        return PdfBytes.first(xrefType, in: data, from: dict, to: body) != nil
    }

    /// A real update starts with an object or a table, after white space and comments; a stale tail starts anywhere.
    private static func startsAsUpdate(_ data: [UInt8], _ from: Int) -> Bool {
        var i = from
        let scanLimit = min(data.count, from + 4096)
        while i < scanLimit {
            if PdfBytes.isWhite(data[i]) {
                i += 1
            } else if data[i] == UInt8(ascii: "%") {
                while i < scanLimit && data[i] != 10 && data[i] != 13 { i += 1 }
            } else {
                break
            }
        }
        let limit = min(data.count, i + 64)
        return starts(data, xref, i, limit) || objectHeader(data, i, limit) != nil
    }
}
