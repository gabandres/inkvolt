import Foundation

/// A file an editor saved over a longer copy of itself without cutting it to its new length keeps the old file's last bytes
/// after its own %%EOF: an old object's end, rows of the old xref table, the old trailer, and a startxref that now points
/// into the middle of the new file (the Windows app's `StaleTail`). MuPDF repairs such a file as it opens it, and the last
/// copy of an object wins: an old object in the tail would replace the real one, a field's value or the field itself.
/// `normalized` gives the file without that tail as a document opens. Mac difference: Windows keeps a tail with any object
/// in it and rebuilds the cross-reference; here a tail that doesn't start where an update would (an object or a table) is an
/// overwritten copy's leftovers, whatever it holds.
enum StaleTail {
    /// The most startxref keywords looked at, from the end: a real file's good one is the second to last.
    private static let maxCandidates = 64

    /// The most bytes read past all the offsets checked, so a file full of startxrefs is cheap to refuse.
    private static let maxScanBytes = 4 << 20

    private static let maxXrefDictBytes = 64 * 1024

    /// The bytes a document opens with: the file as it is, or without a stale tail when what remains opens soundly. A
    /// signed file keeps its bytes (`PdfEdit.open` reads it up to its last valid revision and appends after all of it).
    static func normalized(_ data: [UInt8]) -> [UInt8] {
        guard let cut = cut(data), !SignedEdits.looksSigned(data), let doc = try? MuDoc.open(cut), doc.canAppend,
              doc.needsPassword || ((try? doc.pageCount()) ?? 0) > 0 else { return data }
        return cut
    }

    /// The file up to the end of the last %%EOF whose startxref points at a cross-reference section, or nil when the last
    /// startxref already does, none does, or the bytes after that %%EOF start as a real (if broken) update would.
    static func cut(_ data: [UInt8]) -> [UInt8]? {
        let key = Array("startxref".utf8), eof = Array("%%EOF".utf8)
        var end = data.count
        var last = true
        var budget = maxScanBytes
        var candidates = 0
        while candidates < maxCandidates && budget > 0 && end > 0 {
            candidates += 1
            guard let r = data[..<end].lastRange(of: key) else { return nil }
            end = r.lowerBound
            guard let (at, after) = startXref(data, r.upperBound) else {
                last = false
                continue
            }
            let window = min(budget, maxXrefDictBytes)
            budget -= window
            if !isXref(data, at, window) {
                last = false
                continue
            }
            if last { return nil }
            guard let found = data[after...].firstRange(of: eof) else { return nil }
            var cut = found.upperBound
            if cut < data.count && data[cut] == 13 { cut += 1 }
            if cut < data.count && data[cut] == 10 { cut += 1 }
            if cut >= data.count || startsAsUpdate(data, cut) { return nil }
            return Array(data[..<cut])
        }
        return nil
    }

    private static func isWhite(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 || b == 12 || b == 0 }

    /// The offset after a startxref keyword, and where its digits end; nil when it names no place in the file.
    private static func startXref(_ data: [UInt8], _ from: Int) -> (at: Int, after: Int)? {
        var p = from
        while p < data.count && isWhite(data[p]) { p += 1 }
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
            while i < limit && isWhite(data[i]) { i += 1 }
            if i == spaces { return nil }
        }
        guard i + 3 <= limit, Array(data[i..<i + 3]) == Array("obj".utf8) else { return nil }
        return i + 3
    }

    /// A cross-reference table or stream at the offset.
    private static func isXref(_ data: [UInt8], _ at: Int, _ maxBytes: Int) -> Bool {
        let limit = min(data.count, at + maxBytes)
        var i = at
        while i < limit && isWhite(data[i]) { i += 1 }
        if i + 4 <= limit && Array(data[i..<i + 4]) == Array("xref".utf8) { return true }
        guard let dict = objectHeader(data, i, limit), let stream = data[dict..<limit].firstRange(of: Array("stream".utf8)) else { return false }
        return data[dict..<stream.lowerBound].firstRange(of: Array("/XRef".utf8)) != nil
    }

    /// A real update starts with an object or a table; a stale tail starts anywhere.
    private static func startsAsUpdate(_ data: [UInt8], _ from: Int) -> Bool {
        var i = from
        while i < data.count && isWhite(data[i]) { i += 1 }
        let limit = min(data.count, i + 64)
        if i + 4 <= limit && Array(data[i..<i + 4]) == Array("xref".utf8) { return true }
        return objectHeader(data, i, limit) != nil
    }
}
