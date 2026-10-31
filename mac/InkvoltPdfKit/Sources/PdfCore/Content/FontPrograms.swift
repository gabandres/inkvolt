import Foundation

/// A font program that can't be read (out of its bounds, or not what its header says): the caller falls back to the
/// PDF's own tables (.NET's index and argument exceptions, which `FontProgram.Load` catches).
struct FontProgramDamaged: Error {}

/// Big-endian reads that throw at the end of the data rather than trapping.
struct FontBytes {
    let b: [UInt8]
    init(_ b: [UInt8]) { self.b = b }
    var count: Int { b.count }

    func u8(_ at: Int) throws -> Int {
        guard at >= 0 && at < b.count else { throw FontProgramDamaged() }
        return Int(b[at])
    }

    func u16(_ at: Int) throws -> Int {
        guard at >= 0 && at + 2 <= b.count else { throw FontProgramDamaged() }
        return Int(b[at]) << 8 | Int(b[at + 1])
    }

    func i16(_ at: Int) throws -> Int { Int(Int16(bitPattern: UInt16(try u16(at)))) }

    func u32(_ at: Int) throws -> Int {
        guard at >= 0 && at + 4 <= b.count else { throw FontProgramDamaged() }
        return Int(b[at]) << 24 | Int(b[at + 1]) << 16 | Int(b[at + 2]) << 8 | Int(b[at + 3])
    }
}

/// What an embedded font program holds, read just far enough to tell whether a glyph is really in it: subset fonts keep
/// only the glyphs the document used, so a character the PDF's tables name can still be missing from the font (the
/// Windows app's `FontProgram`).
class FontProgram: @unchecked Sendable {
    /// The embedded program of a font descriptor (FontFile2 TrueType, FontFile Type 1, FontFile3 CFF / OpenType), or nil.
    static func load(_ descriptor: PObj?) -> FontProgram? {
        guard let descriptor else { return nil }
        if let ff2 = descriptor.dict("FontFile2") { return ff2.streamData.flatMap { TrueTypeProgram.read($0) } }
        if let ff1 = descriptor.dict("FontFile") { return ff1.streamData.flatMap { Type1Program.read($0) } }
        if let ff3 = descriptor.dict("FontFile3"), let bytes = ff3.streamData {
            return ff3.name("Subtype") == "OpenType" ? openType(bytes) : CffProgram.read(bytes)
        }
        return nil
    }

    private static func openType(_ b: [UInt8]) -> FontProgram? {
        guard let tables = TrueTypeProgram.tables(b) else { return nil }
        if tables["glyf"] != nil { return TrueTypeProgram.read(b) }
        guard let cff = tables["CFF "] else { return nil }
        return CffProgram.read(Array(b[cff.offset..<cff.offset + cff.length]))
    }
}

/// A TrueType program: glyph count, which glyphs have outlines (loca), advances (hmtx) and the cmap subtables.
final class TrueTypeProgram: FontProgram, @unchecked Sendable {
    private let b: FontBytes
    private let loca: [Int]
    private let advances: [Int]
    private var cmaps: [Int: Int] = [:] // platform << 16 | encoding → subtable offset

    let numGlyphs: Int
    let unitsPerEm: Double

    private init(_ b: FontBytes, _ numGlyphs: Int, _ upem: Double, _ loca: [Int], _ advances: [Int]) {
        self.b = b
        self.numGlyphs = numGlyphs
        unitsPerEm = upem
        self.loca = loca
        self.advances = advances
    }

    /// The table directory: tag → (offset, length), lengths cut to the data.
    static func tables(_ data: [UInt8]) -> [String: (offset: Int, length: Int)]? {
        guard data.count >= 12 else { return nil }
        let b = FontBytes(data)
        guard let n = try? b.u16(4) else { return nil }
        var map: [String: (offset: Int, length: Int)] = [:]
        for i in 0..<n {
            let rec = 12 + i * 16
            if rec + 16 > data.count { break }
            let tag = latin1String(data[rec..<rec + 4])
            guard let off = try? b.u32(rec + 8), let len = try? b.u32(rec + 12), off <= data.count else { continue }
            map[tag] = (off, min(len, data.count - off))
        }
        return map
    }

    static func read(_ data: [UInt8]) -> TrueTypeProgram? { try? parse(data) }

    private static func parse(_ data: [UInt8]) throws -> TrueTypeProgram? {
        guard let t = tables(data), let head = t["head"], let maxp = t["maxp"] else { return nil }
        let b = FontBytes(data)
        var upem = Double(try b.u16(head.offset + 18))
        if upem <= 0 { upem = 1000 }
        let longLoca = try b.i16(head.offset + 50) == 1
        let numGlyphs = try b.u16(maxp.offset + 4)
        var loca: [Int] = []
        if let l = t["loca"], t["glyf"] != nil {
            let count = min(numGlyphs + 1, l.length / (longLoca ? 4 : 2))
            loca.reserveCapacity(count)
            for i in 0..<count { loca.append(longLoca ? try b.u32(l.offset + 4 * i) : 2 * (try b.u16(l.offset + 2 * i))) }
        }
        var advances: [Int] = []
        if let hhea = t["hhea"], let hmtx = t["hmtx"] {
            let nHm = try b.u16(hhea.offset + 34)
            let count = min(nHm, hmtx.length / 4)
            advances.reserveCapacity(count)
            for i in 0..<count { advances.append(try b.u16(hmtx.offset + 4 * i)) }
        }
        let font = TrueTypeProgram(b, numGlyphs, upem, loca, advances)
        if let cmap = t["cmap"] {
            let n = try b.u16(cmap.offset + 2)
            for i in 0..<n {
                let rec = cmap.offset + 4 + i * 8
                if rec + 8 > data.count { break }
                let platform = try b.u16(rec), encoding = try b.u16(rec + 2)
                let sub = cmap.offset + (try b.u32(rec + 4))
                if sub < 0 || sub + 4 > data.count { continue }
                let format = try b.u16(sub)
                let key = platform << 16 | encoding
                if [0, 4, 6, 12].contains(format) && font.cmaps[key] == nil { font.cmaps[key] = sub }
            }
        }
        return font
    }

    func hasCmap(_ platform: Int, _ encoding: Int) -> Bool { cmaps[platform << 16 | encoding] != nil }

    /// How many cmap subtables were read (formats 0, 4, 6 and 12).
    var cmapCount: Int { cmaps.count }

    /// Whether the font has a Unicode cmap (3,1), (3,10) or (0,*).
    var hasUnicodeCmap: Bool { cmaps.keys.contains { $0 >> 16 == 0 || $0 == (3 << 16 | 1) || $0 == (3 << 16 | 10) } }

    /// The glyph for a code in a cmap subtable (0: none).
    func lookup(_ platform: Int, _ encoding: Int, _ code: Int) -> Int {
        guard let sub = cmaps[platform << 16 | encoding] else { return 0 }
        return lookup(sub, code)
    }

    /// The glyph for a code point through the best Unicode cmap (0: none).
    func lookupUnicode(_ cp: Int) -> Int {
        for (p, e) in [(3, 10), (0, 4), (0, 6), (3, 1), (0, 3), (0, 0), (0, 1), (0, 2)] {
            if let sub = cmaps[p << 16 | e] {
                let g = lookup(sub, cp)
                if g > 0 { return g }
            }
        }
        return 0
    }

    private func lookup(_ sub: Int, _ code: Int) -> Int { (try? find(sub, code)) ?? 0 } // a truncated subtable: no glyph

    private func find(_ sub: Int, _ code: Int) throws -> Int {
        switch try b.u16(sub) {
        case 0:
            return (0..<256).contains(code) ? try b.u8(sub + 6 + code) : 0
        case 6:
            let first = try b.u16(sub + 6), count = try b.u16(sub + 8)
            return code >= first && code < first + count ? try b.u16(sub + 10 + 2 * (code - first)) : 0
        case 4:
            if code > 0xFFFF { return 0 }
            let segX2 = try b.u16(sub + 6)
            let ends = sub + 14
            let starts = ends + segX2 + 2
            let deltas = starts + segX2
            let ranges = deltas + segX2
            for i in 0..<segX2 / 2 {
                let end = try b.u16(ends + 2 * i)
                if code > end { continue }
                let start = try b.u16(starts + 2 * i)
                if code < start { return 0 }
                let delta = try b.i16(deltas + 2 * i)
                let rangeAt = ranges + 2 * i
                let range = try b.u16(rangeAt)
                if range == 0 { return (code + delta) & 0xFFFF }
                let addr = rangeAt + range + 2 * (code - start)
                if addr + 2 > b.count { return 0 }
                let g = try b.u16(addr)
                return g == 0 ? 0 : (g + delta) & 0xFFFF
            }
            return 0
        case 12:
            let count = try b.u32(sub + 12)
            var lo = 0, hi = count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let g = sub + 16 + mid * 12
                let startCode = try b.u32(g), endCode = try b.u32(g + 4)
                if code < startCode {
                    hi = mid - 1
                } else if code > endCode {
                    lo = mid + 1
                } else {
                    return try b.u32(g + 8) + code - startCode
                }
            }
            return 0
        default:
            return 0
        }
    }

    /// Whether the glyph is in the font with an outline (subsets keep the glyph's slot but drop its outline). A blank
    /// glyph (a space) has no outline, so for those only the slot is checked.
    func hasGlyph(_ gid: Int, blank: Bool) -> Bool {
        if gid <= 0 || gid >= numGlyphs { return false }
        if blank || loca.isEmpty { return true }
        return gid + 1 < loca.count && loca[gid + 1] > loca[gid]
    }

    /// The glyph's advance in thousandths of an em (nil when the font has no metrics).
    func advance(_ gid: Int) -> Double? {
        if advances.isEmpty || gid < 0 || gid >= numGlyphs { return nil }
        return Double(advances[min(gid, advances.count - 1)]) * 1000 / unitsPerEm
    }
}

/// A CFF program (FontFile3 / Type1C / CIDFontType0C): glyph names (charset) or, CID-keyed, the CIDs it holds.
final class CffProgram: FontProgram, @unchecked Sendable {
    private(set) var numGlyphs = 0
    private(set) var isCid = false
    private(set) var names: Set<String> = []
    private(set) var cids: Set<Int> = []

    private var blank: Set<Int> = []
    private var glyphNames: [String?] = []

    /// The CIDs of a CID-keyed program, 0 (.notdef) left out.
    var cidList: [Int] { cids.sorted() }

    /// The glyph draws nothing (a space): by CID in a CID-keyed program, by glyph index in a name-keyed one.
    func isBlank(_ glyph: Int) -> Bool { blank.contains(glyph) }

    /// A name-keyed program's glyph name at a glyph index (nil for CID-keyed programs and unknown names).
    func nameOfGlyph(_ gid: Int) -> String? { gid >= 0 && gid < glyphNames.count ? glyphNames[gid] : nil }

    func hasName(_ name: String) -> Bool { !isCid && names.contains(name) }
    func hasCid(_ cid: Int) -> Bool { isCid ? cids.contains(cid) : cid > 0 && cid < numGlyphs }

    static func read(_ data: [UInt8]) -> CffProgram? { try? parse(data) }

    /// A Type 2 charstring that ends before drawing: at most a width, then endchar (with four more operands it is an accented seac).
    private static func blankCharString(_ b: [UInt8], _ start: Int, _ length: Int) -> Bool {
        var operands = 0
        var p = start
        while p >= 0 && p < start + length && p < b.count {
            let v = b[p]
            if v == 28 {
                p += 3
            } else if (32...246).contains(v) {
                p += 1
            } else if (247...254).contains(v) {
                p += 2
            } else if v == 255 {
                p += 5
            } else {
                return v == 14 && operands <= 1
            }
            operands += 1
        }
        return false
    }

    private static func parse(_ data: [UInt8]) throws -> CffProgram? {
        guard data.count >= 4, data[0] == 1 else { return nil }
        let b = FontBytes(data)
        var p = Int(data[2])
        _ = try index(b, &p) // names
        let tops = try index(b, &p)
        let strings = try index(b, &p)
        guard let first = tops.first else { return nil }
        let top = try dict(b, first.offset, first.offset + first.length)
        let cid = top[1230] != nil
        guard let cs = top[17], let csFirst = cs.first else { return nil }
        var csAt = Int(csFirst)
        let charStrings = try index(b, &csAt)
        let n = charStrings.count
        let font = CffProgram()
        font.numGlyphs = n
        font.isCid = cid
        let charset = top[15]?.first.map { Int($0) } ?? 0
        var sids = [Int](repeating: 0, count: n)
        if charset > 2 {
            var q = charset
            let format = try b.u8(q)
            q += 1
            var gid = 1
            while gid < n {
                if format == 0 {
                    sids[gid] = try b.u16(q)
                    gid += 1
                    q += 2
                } else if format == 1 || format == 2 {
                    let firstSid = try b.u16(q)
                    let left = format == 1 ? try b.u8(q + 2) : try b.u16(q + 2)
                    q += format == 1 ? 3 : 4
                    var k = 0
                    while k <= left && gid < n {
                        sids[gid] = firstSid + k
                        gid += 1
                        k += 1
                    }
                } else {
                    return nil
                }
            }
        } else if charset == 0 {
            for gid in stride(from: 1, to: n, by: 1) { sids[gid] = gid } // ISOAdobe: SID = glyph index
        } else {
            return font.isCid ? nil : font // Expert charsets: names unknown here
        }
        if !cid { font.glyphNames = [String?](repeating: nil, count: n) }
        for gid in stride(from: 1, to: n, by: 1) {
            if cid {
                font.cids.insert(sids[gid])
            } else if let name = sid(sids[gid], data, strings) {
                font.names.insert(name)
                font.glyphNames[gid] = name
            }
            if blankCharString(data, charStrings[gid].offset, charStrings[gid].length) { font.blank.insert(cid ? sids[gid] : gid) }
        }
        return font
    }

    private static func sid(_ sid: Int, _ data: [UInt8], _ strings: [(offset: Int, length: Int)]) -> String? {
        if sid < standardStrings.count { return standardStrings[sid] }
        if sid < 391 { return nil } // expert names: not text glyphs
        let i = sid - 391
        return i < strings.count ? latin1String(data[strings[i].offset..<strings[i].offset + strings[i].length]) : nil
    }

    private static func index(_ b: FontBytes, _ p: inout Int) throws -> [(offset: Int, length: Int)] {
        var list: [(offset: Int, length: Int)] = []
        let count = try b.u16(p)
        p += 2
        if count == 0 { return list }
        let offSize = try b.u8(p)
        p += 1
        let at = p
        func off(_ i: Int) throws -> Int {
            var v = 0
            for k in 0..<offSize { v = v << 8 | (try b.u8(at + i * offSize + k)) }
            return v
        }
        let data = p + (count + 1) * offSize - 1
        for i in 0..<count {
            let start = data + (try off(i)), end = data + (try off(i + 1))
            if start < 0 || end > b.count || end < start { throw FontProgramDamaged() }
            list.append((start, end - start))
        }
        p = data + (try off(count))
        return list
    }

    /// A DICT's operators (12 x as 1200 + x) with their operands.
    private static func dict(_ b: FontBytes, _ from: Int, _ end: Int) throws -> [Int: [Double]] {
        var d: [Int: [Double]] = [:]
        var operands: [Double] = []
        var p = from
        while p < end {
            let v = try b.u8(p)
            if v <= 21 {
                var op = v
                if v == 12 {
                    p += 1
                    op = 1200 + (try b.u8(p))
                }
                p += 1
                d[op] = operands
                operands = []
            } else if v == 28 {
                operands.append(Double(Int16(bitPattern: UInt16(try b.u16(p + 1)))))
                p += 3
            } else if v == 29 {
                operands.append(Double(Int32(truncatingIfNeeded: try b.u32(p + 1))))
                p += 5
            } else if v == 30 {
                p += 1 // a real number: nibbles until 0xf
                while p < end, let x = try? b.u8(p), x & 0x0F != 0x0F && x & 0xF0 != 0xF0 { p += 1 }
                p += 1
                operands.append(0)
            } else if (32...246).contains(v) {
                operands.append(Double(v - 139))
                p += 1
            } else if (247...250).contains(v) {
                operands.append(Double((v - 247) * 256 + (try b.u8(p + 1)) + 108))
                p += 2
            } else if (251...254).contains(v) {
                operands.append(Double(-(v - 251) * 256 - (try b.u8(p + 1)) - 108))
                p += 2
            } else {
                p += 1
            }
        }
        return d
    }

    /// CFF standard strings 0-228 (the ISOAdobe glyph names).
    private static let standardStrings: [String] = (
        ".notdef space exclam quotedbl numbersign dollar percent ampersand quoteright parenleft parenright asterisk plus comma "
        + "hyphen period slash zero one two three four five six seven eight nine colon semicolon less equal greater question at "
        + "A B C D E F G H I J K L M N O P Q R S T U V W X Y Z bracketleft backslash bracketright asciicircum underscore quoteleft "
        + "a b c d e f g h i j k l m n o p q r s t u v w x y z braceleft bar braceright asciitilde exclamdown cent sterling "
        + "fraction yen florin section currency quotesingle quotedblleft guillemotleft guilsinglleft guilsinglright fi fl endash "
        + "dagger daggerdbl periodcentered paragraph bullet quotesinglbase quotedblbase quotedblright guillemotright ellipsis "
        + "perthousand questiondown grave acute circumflex tilde macron breve dotaccent dieresis ring cedilla hungarumlaut ogonek "
        + "caron emdash AE ordfeminine Lslash Oslash OE ordmasculine ae dotlessi lslash oslash oe germandbls onesuperior "
        + "logicalnot mu trademark Eth onehalf plusminus Thorn onequarter divide brokenbar degree thorn threequarters twosuperior "
        + "registered minus eth multiply threesuperior copyright Aacute Acircumflex Adieresis Agrave Aring Atilde Ccedilla Eacute "
        + "Ecircumflex Edieresis Egrave Iacute Icircumflex Idieresis Igrave Ntilde Oacute Ocircumflex Odieresis Ograve Otilde "
        + "Scaron Uacute Ucircumflex Udieresis Ugrave Yacute Ydieresis Zcaron aacute acircumflex adieresis agrave aring atilde "
        + "ccedilla eacute ecircumflex edieresis egrave iacute icircumflex idieresis igrave ntilde oacute ocircumflex odieresis "
        + "ograve otilde scaron uacute ucircumflex udieresis ugrave yacute ydieresis zcaron").split(separator: " ").map(String.init)

    static var standardStringCount: Int { standardStrings.count }
}

/// A Type 1 program (FontFile): the glyph names in its CharStrings and its built-in encoding.
final class Type1Program: FontProgram, @unchecked Sendable {
    private(set) var names: Set<String> = []

    /// The program's own encoding (code → glyph name); nil for StandardEncoding or when it can't be read.
    private(set) var builtIn: [String?]?

    func hasName(_ name: String) -> Bool { names.contains(name) }

    static func read(_ data: [UInt8]) -> Type1Program? {
        var b = data
        // PFB segments (0x80 0x01 / 0x80 0x02) or a plain cleartext + binary eexec part.
        if b.count > 6 && b[0] == 0x80 { b = unwrap(b) }
        guard let eexec = b.firstRange(of: Array("eexec".utf8))?.lowerBound else { return nil }
        let font = Type1Program()
        font.readEncoding(latin1String(b[..<eexec]))
        var p = eexec + 5
        while p < b.count && [9, 10, 13, 32].contains(b[p]) { p += 1 }
        var encrypted = Array(b[p...])
        // Hex eexec (rare): the first four bytes are hex digits.
        if encrypted.count >= 4 && encrypted.prefix(4).allSatisfy(isHexDigit) {
            let hex = encrypted.filter(isHexDigit)
            var bytes: [UInt8] = []
            var i = 0
            while i + 1 < hex.count {
                bytes.append(UInt8(hexValue(hex[i]) << 4 | hexValue(hex[i + 1])))
                i += 2
            }
            encrypted = bytes
        }
        font.readCharStrings(decrypt(encrypted, 55665, 4))
        return font.names.isEmpty ? nil : font
    }

    private static func isHexDigit(_ c: UInt8) -> Bool { (48...57).contains(c) || (65...70).contains(c) || (97...102).contains(c) }
    private static func hexValue(_ c: UInt8) -> Int { c <= 57 ? Int(c) - 48 : Int(c | 0x20) - 87 }

    private static func unwrap(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var p = 0
        while p + 6 <= b.count && b[p] == 0x80 && (b[p + 1] == 1 || b[p + 1] == 2) {
            let len = Int(Int32(bitPattern: UInt32(b[p + 2]) | UInt32(b[p + 3]) << 8 | UInt32(b[p + 4]) << 16 | UInt32(b[p + 5]) << 24))
            p += 6
            if len < 0 || p + len > b.count { break }
            out += b[p..<p + len]
            p += len
        }
        return out
    }

    static func decrypt(_ data: [UInt8], _ key: UInt16, _ skip: Int) -> [UInt8] {
        var r = key
        var o = [UInt8](repeating: 0, count: max(0, data.count - skip))
        for (i, c) in data.enumerated() {
            let p = c ^ UInt8(r >> 8)
            r = (UInt16(c) &+ r) &* 52845 &+ 22719
            if i >= skip { o[i - skip] = p }
        }
        return o
    }

    private static let encodingEntry = try! NSRegularExpression(pattern: #"dup\s+(\d+)\s*/([^\s/\[\]{}()<>%]+)\s+put"#)

    private func readEncoding(_ clear: String) {
        let ns = clear as NSString
        let at = ns.range(of: "/Encoding")
        if at.location == NSNotFound || ns.substring(from: at.location).hasPrefix("/Encoding StandardEncoding") { return }
        var enc = [String?](repeating: nil, count: 256)
        var any = false
        // "dup 65 /A put" entries up to "readonly def" / "def".
        let def = ns.range(of: " def", range: NSRange(location: at.location, length: ns.length - at.location))
        let end = def.location == NSNotFound ? ns.length : min(ns.length, def.location + 4 + 20000)
        let body = NSRange(location: at.location, length: end - at.location)
        for m in Self.encodingEntry.matches(in: clear, range: body) {
            guard let code = Int(ns.substring(with: m.range(at: 1))), (0..<256).contains(code) else { continue }
            enc[code] = ns.substring(with: m.range(at: 2))
            any = true
        }
        if any { builtIn = enc }
    }

    /// Reads "/name len RD <len bytes> ND" entries after /CharStrings.
    private func readCharStrings(_ plain: [UInt8]) {
        guard let at = plain.firstRange(of: Array("/CharStrings".utf8))?.lowerBound,
              let begin = plain[at...].firstRange(of: Array("begin".utf8))?.lowerBound else { return }
        func isSpace(_ c: UInt8) -> Bool { c == 9 || c == 10 || c == 13 || c == 32 }
        var p = begin + 5
        while p < plain.count {
            while p < plain.count && isSpace(plain[p]) { p += 1 }
            if p >= plain.count || plain[p] != 47 { break } // "end": done
            p += 1
            var q = p
            while q < plain.count && !isSpace(plain[q]) { q += 1 }
            let name = latin1String(plain[p..<q])
            p = q
            while p < plain.count && isSpace(plain[p]) { p += 1 }
            let n0 = p
            while p < plain.count && plain[p] >= 48 && plain[p] <= 57 { p += 1 }
            guard p > n0, let len = Int(latin1String(plain[n0..<p])) else { break }
            while p < plain.count && isSpace(plain[p]) { p += 1 }
            while p < plain.count && !isSpace(plain[p]) { p += 1 } // RD or -|
            p += 1 // the single space before the binary
            p += len
            while p < plain.count && isSpace(plain[p]) { p += 1 }
            while p < plain.count && !isSpace(plain[p]) { p += 1 } // ND or |-
            names.insert(name)
        }
    }
}
