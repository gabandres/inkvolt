import CryptoKit
import Foundation
import MuPDFShim

/// Names over PDF/A's limit of 127 bytes (ISO 19005-2, 6.1.13; a structure role made from Word's styles). MuPDF cuts a name
/// to 127 bytes as it reads it, so two long names can become one and PObj never shows one: this reads the objects' own
/// text, each object where the cross-reference table says it is now (a file's stale revisions and its streams' bytes aren't
/// looked at), and puts each such object back through MuPDF with the name replaced by the same shorter unique one wherever
/// it stands, as Windows' `ShortenLongNames` does, before anything else reads the document. A name in page content refers
/// to its resources by name and refuses instead (`PdfA.Pass.scanContent`).
enum LongNames {
    static let limit = 127

    /// An object whose text holds a name over the limit.
    private struct Holder {
        var num: Int
        var text: [UInt8]
        var names: [(range: Range<Int>, name: [UInt8])]
        var inObjectStream: Bool
    }

    /// Whether the name, without its slash, is over the limit. `name`'s characters are its bytes as Latin-1 (`ContentLexer`).
    static func isTooLong(contentName name: String) -> Bool { name.unicodeScalars.count > limit }

    /// Whether any object of the opened `doc` (read from `data`) holds a name over the limit.
    static func present(_ doc: MuDoc, _ data: [UInt8]) -> Bool { !holders(doc, data, firstOnly: true).isEmpty }

    /// The file with its long names shortened, and how many different ones there were; the same bytes and 0 when it has none,
    /// or when it can't be opened for an edit (what comes next says why).
    static func shorten(_ data: [UInt8], _ password: String?) throws -> (data: [UInt8], count: Int) {
        guard let doc = try? PdfEdit.open(data, password) else { return (data, 0) }
        let found = holders(doc, data, firstOnly: false)
        if found.isEmpty { return (data, 0) }
        var distinct = Set<[UInt8]>()
        for holder in found {
            var out: [UInt8] = []
            var at = 0
            for (range, name) in holder.names {
                distinct.insert(name)
                out += holder.text[at..<range.lowerBound]
                out += written(shorter(name))
                at = range.upperBound
            }
            out += holder.text[at...]
            doc.note { err in
                out.withUnsafeBufferPointer { inkv_obj_replace(doc.ctx, doc.doc, Int32(holder.num), $0.baseAddress, $0.count, holder.inObjectStream ? 0 : 1, err) }
            }
        }
        try doc.checkFailure()
        return (try PdfEdit.writeWhole(doc, password: password), distinct.count)
    }

    /// The name's start, whole characters up to 118 bytes, then "~" and eight of its hash's hex digits: 127 bytes at most.
    static func shorter(_ name: [UInt8]) -> [UInt8] {
        var keep = min(name.count, 118)
        while keep > 0 && name[keep] & 0xC0 == 0x80 { keep -= 1 } // not inside a UTF-8 character
        let hash = SHA256.hash(data: name).prefix(4).map { String(format: "%02X", $0) }.joined()
        return Array(name[..<keep]) + Array("~\(hash)".utf8)
    }

    /// A name as PDF syntax: its slash, and #xx for what can't stand as it is.
    private static func written(_ name: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x2F]
        for b in name {
            if b > 0x20 && b < 0x7F && b != 0x23 && ContentLexer.isRegular(b) {
                out.append(b)
            } else {
                out += Array(String(format: "#%02X", b).utf8)
            }
        }
        return out
    }

    private static func holders(_ doc: MuDoc, _ data: [UInt8], firstOnly: Bool) -> [Holder] {
        var found: [Holder] = []
        var inStreams: [Int: Set<Int>] = [:]
        var budget = 2 * data.count + (1 << 26) // an unterminated string can't make each object read the rest of the file
        for num in 1..<max(doc.objectCount, 1) {
            var offset: Int64 = 0
            switch inkv_obj_location(doc.ctx, doc.doc, Int32(num), &offset) {
            case 1:
                guard offset > 0, offset < data.count, let start = afterObjKeyword(data, Int(offset)) else { continue }
                let scan = scanObject(data, start, data.count, &budget)
                if !scan.names.isEmpty {
                    let text = Array(data[start..<scan.end])
                    found.append(Holder(num: num, text: text, names: scan.names.map { ($0.range.lowerBound - start..<$0.range.upperBound - start, $0.name) }, inObjectStream: false))
                }
            case 2:
                inStreams[Int(offset), default: []].insert(num)
            default:
                continue
            }
            if firstOnly && !found.isEmpty { return found }
        }
        for stream in inStreams.keys.sorted() {
            let container = doc.object(stream)
            guard container.isStream, let first = container.int("First"), first > 0, let bytes = container.streamData, first <= bytes.count else { continue }
            let table = headerNumbers(bytes, first)
            for i in stride(from: 0, to: table.count - 1, by: 2) where inStreams[stream]?.contains(table[i]) == true {
                let start = first + table[i + 1]
                let end = i + 3 < table.count ? first + table[i + 3] : bytes.count
                guard start >= first, start < end, end <= bytes.count else { continue }
                let scan = scanObject(bytes, start, end, &budget)
                if !scan.names.isEmpty {
                    let text = Array(bytes[start..<scan.end])
                    found.append(Holder(num: table[i], text: text, names: scan.names.map { ($0.range.lowerBound - start..<$0.range.upperBound - start, $0.name) }, inObjectStream: true))
                    if firstOnly { return found }
                }
            }
        }
        return found
    }

    /// The numbers before an object stream's first object: each object's number and its offset.
    private static func headerNumbers(_ b: [UInt8], _ first: Int) -> [Int] {
        var out: [Int] = []
        var p = 0
        while p < first {
            while p < first && ContentLexer.isSpace(b[p]) { p += 1 }
            var value = 0
            let start = p
            while p < first, (48...57).contains(b[p]), value < 1 << 40 {
                value = value * 10 + Int(b[p]) - 48
                p += 1
            }
            if p == start { break }
            out.append(value)
        }
        return out
    }

    /// Where the object's value starts: after "N G obj" at `at`.
    private static func afterObjKeyword(_ b: [UInt8], _ at: Int) -> Int? {
        let keyword = Array("obj".utf8)
        var p = at
        while p + 3 <= b.count, p < at + 64 {
            if b[p] == keyword[0], b[p + 1] == keyword[1], b[p + 2] == keyword[2] { return p + 3 }
            p += 1
        }
        return nil
    }

    /// The names over the limit in the object starting at `start`, and where its value ends: at the end of its first complete
    /// value, or before "endobj" or "stream" (strings and comments aren't names).
    private static func scanObject(_ b: [UInt8], _ start: Int, _ end: Int, _ budget: inout Int) -> (names: [(range: Range<Int>, name: [UInt8])], end: Int) {
        var names: [(range: Range<Int>, name: [UInt8])] = []
        var depth = 0
        var p = start
        defer { budget -= p - start }
        scan: while p < end, budget - (p - start) > 0 {
            let c = b[p]
            switch c {
            case 0x25: // a comment
                while p < end, b[p] != 10, b[p] != 13 { p += 1 }
            case 0x28: // a string
                var nested = 1
                p += 1
                while p < end, nested > 0 {
                    switch b[p] {
                    case 0x5C: p += 1
                    case 0x28: nested += 1
                    case 0x29: nested -= 1
                    default: break
                    }
                    p += 1
                }
                if depth == 0 { break scan }
            case 0x3C: // << or a hex string
                if p + 1 < end, b[p + 1] == 0x3C {
                    depth += 1
                    p += 2
                } else {
                    while p < end, b[p] != 0x3E { p += 1 }
                    p += 1
                    if depth == 0 { break scan }
                }
            case 0x3E: // >>
                p += p + 1 < end && b[p + 1] == 0x3E ? 2 : 1
                depth -= 1
                if depth <= 0 { break scan }
            case 0x5B:
                depth += 1
                p += 1
            case 0x5D:
                p += 1
                depth -= 1
                if depth <= 0 { break scan }
            case 0x2F: // a name
                let from = p
                p += 1
                var name: [UInt8] = []
                while p < end, ContentLexer.isRegular(b[p]) {
                    if b[p] == 0x23, p + 2 < end, let h = hex(b[p + 1]), let l = hex(b[p + 2]) {
                        name.append(UInt8(h * 16 + l))
                        p += 3
                    } else {
                        name.append(b[p])
                        p += 1
                    }
                }
                if name.count > limit { names.append((from..<p, name)) }
                if depth == 0 { break scan }
            default:
                if ContentLexer.isRegular(c) {
                    let from = p
                    while p < end, ContentLexer.isRegular(b[p]) { p += 1 }
                    let word = b[from..<p]
                    if word.elementsEqual("endobj".utf8) || word.elementsEqual("stream".utf8) {
                        p = from
                        break scan
                    }
                } else {
                    p += 1
                }
            }
        }
        return (names, min(p, end))
    }

    private static func hex(_ c: UInt8) -> Int? {
        switch c {
        case 48...57: Int(c) - 48
        case 65...70: Int(c) - 55
        case 97...102: Int(c) - 87
        default: nil
        }
    }
}
