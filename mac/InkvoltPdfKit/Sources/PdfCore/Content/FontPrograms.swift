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

    // What the advance widths are read from (CFF spec, Adobe TN 5176; Type 2 charstrings, TN 5177).
    private var b: [UInt8] = []
    private var charStrings: [(offset: Int, length: Int)] = []
    private var globalSubrs: [(offset: Int, length: Int)] = []
    private var gidOfName: [String: Int] = [:]
    private var gidOfCid: [Int: Int] = [:]
    /// The Private DICTs (one, or one per FDArray font of a CID-keyed program) and, per glyph, which (FDSelect).
    private var privates: [PrivateDict] = []
    private var fdOfGlyph: [UInt8]?
    /// Each glyph's advance once read (nan: can't be told), made with the program; read and written under `gate`.
    private var advances: [Double?] = []
    private let gate = NSLock()

    /// A Private DICT's widths and local subroutines, with the scale of its font's FontMatrix (to thousandths of an em).
    fileprivate struct PrivateDict {
        let defaultWidth: Double, nominalWidth: Double
        let subrs: [(offset: Int, length: Int)]
        let scale: Double
    }

    /// A name-keyed program's advance for a glyph name, in thousandths of an em; nil when it isn't there or can't be read.
    func advance(_ name: String) -> Double? { !isCid ? gidOfName[name].flatMap(advanceOfGlyph) : nil }

    /// A CID-keyed program's advance for a CID (a name-keyed one's for a glyph index, as a CID font uses it), in
    /// thousandths of an em.
    func advanceOfCid(_ cid: Int) -> Double? { isCid ? gidOfCid[cid].flatMap(advanceOfGlyph) : advanceOfGlyph(cid) }

    /// The advance of a glyph (by index) its charstring gives, in thousandths of an em; nil when it can't be told.
    func advanceOfGlyph(_ gid: Int) -> Double? {
        guard gid >= 0 && gid < charStrings.count && gid < advances.count && !privates.isEmpty else { return nil }
        gate.lock()
        defer { gate.unlock() }
        if let known = advances[gid] { return known.isNaN ? nil : known }
        let fd = fdOfGlyph.map { gid < $0.count ? Int($0[gid]) : -1 } ?? 0
        var width: Double?
        if fd >= 0 && fd < privates.count, let w = WidthRun.read(b, charStrings[gid], globalSubrs, privates[fd]) {
            width = w * privates[fd].scale
        }
        let v = width.flatMap { $0.isFinite ? $0 : nil } ?? .nan
        advances[gid] = v
        return v.isNaN ? nil : v
    }

    /// A Type 2 charstring's advance (TN 5177, 3.1): the first stack-clearing operator (a hint, a move or endchar) finds
    /// an odd value more than it takes when a width leads, the nominal width plus that value; else the default width.
    /// Subroutines called before it are followed. Bounded (depth, steps, stack): a program built to loop gives no width.
    private struct WidthRun {
        static let maxDepth = 10, maxSteps = 2000, maxStack = 48
        let b: [UInt8]
        let globals: [(offset: Int, length: Int)]
        let priv: PrivateDict
        var stack: [Double] = []
        var steps = 0
        var width: Double?

        static func read(_ b: [UInt8], _ charString: (offset: Int, length: Int), _ globals: [(offset: Int, length: Int)], _ priv: PrivateDict) -> Double? {
            var run = WidthRun(b: b, globals: globals, priv: priv)
            return run.run(charString.offset, charString.length, 0) == 1 ? run.width : nil
        }

        static func bias(_ count: Int) -> Int { count < 1240 ? 107 : count < 33900 ? 1131 : 32768 }

        /// 1: the width is known; 0: a subroutine returned; -1: it can't be told.
        mutating func run(_ start: Int, _ length: Int, _ depth: Int) -> Int {
            if depth > Self.maxDepth || start < 0 || length < 0 || start > b.count - length { return -1 }
            let end = start + length
            var p = start
            while p < end {
                steps += 1
                if steps > Self.maxSteps { return -1 }
                let v = Int(b[p])
                var number: Double?
                if v >= 32 && v <= 246 {
                    number = Double(v - 139)
                    p += 1
                } else if v >= 247 && v <= 250 && p + 1 < end {
                    number = Double((v - 247) * 256 + Int(b[p + 1]) + 108)
                    p += 2
                } else if v >= 251 && v <= 254 && p + 1 < end {
                    number = Double(-(v - 251) * 256 - Int(b[p + 1]) - 108)
                    p += 2
                } else if v == 28 && p + 2 < end {
                    number = Double(Int16(bitPattern: UInt16(b[p + 1]) << 8 | UInt16(b[p + 2])))
                    p += 3
                } else if v == 255 && p + 4 < end {
                    let raw = UInt32(b[p + 1]) << 24 | UInt32(b[p + 2]) << 16 | UInt32(b[p + 3]) << 8 | UInt32(b[p + 4])
                    number = Double(Int32(bitPattern: raw)) / 65536
                    p += 5
                }
                if let n = number {
                    if stack.count == Self.maxStack { return -1 }
                    stack.append(n)
                    continue
                }
                p += 1
                switch v {
                case 10, 29: // callsubr, callgsubr
                    let subrs = v == 10 ? priv.subrs : globals
                    guard let last = stack.popLast() else { return -1 }
                    let index = last + Double(Self.bias(subrs.count))
                    guard index >= 0 && index < Double(subrs.count) else { return -1 }
                    let called = run(subrs[Int(index)].offset, subrs[Int(index)].length, depth + 1)
                    if called != 0 { return called }
                case 11: // return
                    return 0
                case 1, 3, 18, 23, 19, 20: // hstem, vstem, hstemhm, vstemhm, hintmask, cntrmask
                    return found(stack.count % 2 == 1)
                case 21: // rmoveto
                    return found(stack.count > 2)
                case 4, 22: // vmoveto, hmoveto
                    return found(stack.count > 1)
                case 14: // endchar (four more operands: an accented seac)
                    return found(stack.count == 1 || stack.count == 5)
                default:
                    return -1 // drawing before a move, or an operator no width comes before
                }
            }
            return 0
        }

        mutating func found(_ leads: Bool) -> Int {
            width = leads ? priv.nominalWidth + stack[0] : priv.defaultWidth
            return 1
        }
    }

    /// A DICT offset or size as an index into `b`, or -1 when it can't be one.
    private static func at(_ dict: [Int: [Double]], _ op: Int, _ k: Int, _ b: [UInt8]) -> Int {
        guard let v = dict[op], v.count > k, v[k] >= 0, v[k] <= Double(b.count) else { return -1 }
        return Int(v[k])
    }

    /// The Private DICT a font DICT names, with the scale its FontMatrix (else `scale`) gives.
    private static func readPrivate(_ b: [UInt8], _ font: [Int: [Double]], _ scale: Double) throws -> PrivateDict {
        let size = at(font, 18, 0, b), offset = at(font, 18, 1, b)
        if size < 0 || offset < 0 || offset > b.count - size { return PrivateDict(defaultWidth: 0, nominalWidth: 0, subrs: [], scale: scale) }
        let priv = try dict(FontBytes(b), offset, offset + size)
        func number(_ op: Int) -> Double { priv[op].flatMap { $0.first }.flatMap { $0.isFinite ? $0 : nil } ?? 0 }
        var subrs: [(offset: Int, length: Int)] = []
        if let s = priv[19]?.first, s >= 0, s <= Double(b.count - offset) {
            var p = offset + Int(s)
            subrs = try index(FontBytes(b), &p)
        }
        return PrivateDict(defaultWidth: number(20), nominalWidth: number(21), subrs: subrs, scale: scale)
    }

    /// A FontMatrix's horizontal scale (the default is 0.001); nil without one or a bad one.
    private static func matrixScale(_ dict: [Int: [Double]]) -> Double? {
        guard let m = dict[1207]?.first, m.isFinite, abs(m) > 1e-9, abs(m) < 1e3 else { return nil }
        return m
    }

    /// A CID-keyed program's glyph scale from its Top DICT's FontMatrix and its font DICT's (each 0.001 when missing), to
    /// thousandths of an em, as FreeType combines them: multiplied, except that when both scale down (an em of units each,
    /// [0.001 …] in both is common) the em counts once, so the smaller one is the scale.
    static func combinedScale(_ top: Double?, _ font: Double?) -> Double {
        let t = top ?? 0.001, f = font ?? 0.001
        return 1000 * (abs(t) < 1 && abs(f) < 1 ? t * f / max(abs(t), abs(f)) : t * f)
    }

    /// The Private DICTs widths come from: the Top DICT's, or a CID-keyed program's one per FDArray font with FDSelect
    /// saying which glyph uses which. Anything that can't be read leaves no Private DICT, so no widths (the glyphs are
    /// still known).
    private func readPrivates(_ top: [Int: [Double]], _ cid: Bool) {
        do {
            let topScale = Self.matrixScale(top)
            if !cid {
                privates = [try Self.readPrivate(b, top, 1000 * (topScale ?? 0.001))]
                return
            }
            var fdArray = Self.at(top, 1236, 0, b)
            let fdSelect = Self.at(top, 1237, 0, b)
            if fdArray < 0 || fdSelect < 0 { return }
            let fonts = try Self.index(FontBytes(b), &fdArray)
            if fonts.isEmpty || fonts.count > 256 { return }
            privates = try fonts.map { f in
                let d = try Self.dict(FontBytes(b), f.offset, f.offset + f.length)
                return try Self.readPrivate(b, d, Self.combinedScale(topScale, Self.matrixScale(d)))
            }
            let n = charStrings.count
            var select = [UInt8](repeating: 0, count: n)
            let bytes = FontBytes(b)
            var q = fdSelect
            let format = try bytes.u8(q)
            q += 1
            switch format {
            case 0:
                if q > b.count - n { throw FontProgramDamaged() }
                select = Array(b[q..<q + n])
            case 3:
                let ranges = try bytes.u16(q)
                q += 2
                // Ranges in order, each up to the next one's first glyph; overlapping ones set each glyph once at most.
                var r = 0, done = 0
                while r < ranges && done < n {
                    let first = try bytes.u16(q), fd = try bytes.u8(q + 2), next = try bytes.u16(q + 3)
                    var g = max(first, done)
                    while g < next && g < n {
                        select[g] = UInt8(fd)
                        g += 1
                    }
                    done = max(done, min(next, n))
                    r += 1
                    q += 3
                }
            default:
                throw FontProgramDamaged()
            }
            fdOfGlyph = select
        } catch {
            privates = []
        }
    }

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
        // A program cut short after its strings: its glyphs are still known, a subroutine call gives no width.
        let globalSubrs = (try? index(b, &p)) ?? []
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
        font.b = data
        font.charStrings = charStrings
        font.globalSubrs = globalSubrs
        font.advances = [Double?](repeating: nil, count: n)
        font.readPrivates(top, cid)
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
                if font.gidOfCid[sids[gid]] == nil { font.gidOfCid[sids[gid]] = gid }
            } else if let name = sid(sids[gid], data, strings) {
                font.names.insert(name)
                font.glyphNames[gid] = name
                if font.gidOfName[name] == nil { font.gidOfName[name] = gid }
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
                // A real number: nibbles (0-9, a ".", b "E", c "E-", e "-") until an f, at most 64 of them.
                p += 1
                var text = ""
                var done = false
                while p < end && !done && text.count < 64 {
                    let x = try b.u8(p)
                    for nibble in [x >> 4, x & 0x0F] {
                        if nibble == 0x0F {
                            done = true
                            break
                        }
                        switch nibble {
                        case 0..<10: text += String(nibble)
                        case 0x0A: text += "."
                        case 0x0B: text += "E"
                        case 0x0C: text += "E-"
                        case 0x0E: text += "-"
                        default: break
                        }
                    }
                    p += 1
                }
                operands.append(Double(text) ?? 0)
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

    private var plain: [UInt8] = []
    private var charStrings: [String: (offset: Int, length: Int)] = [:]
    private var advances: [String: Double?] = [:]
    private let gate = NSLock()
    private var lenIV = 4
    private var scale = 1.0

    /// A glyph's advance, in thousandths of an em: the width its charstring's hsbw or sbw sets (Type 1 spec, 6.4), scaled
    /// by the FontMatrix. Nil when the glyph isn't there or its charstring doesn't start with one.
    func advance(_ name: String) -> Double? {
        gate.lock()
        defer { gate.unlock() }
        if let known = advances[name] { return known }
        var width: Double?
        if let cs = charStrings[name], cs.length > 0 {
            let bytes = Array(plain[cs.offset..<cs.offset + cs.length])
            width = Self.width(lenIV < 0 ? bytes : Self.decrypt(bytes, 4330, lenIV)) // lenIV -1: not encrypted
        }
        if let w = width { width = (w * scale).isFinite ? w * scale : nil }
        if advances.count < 65536 { advances[name] = width }
        return width
    }

    /// The wx of the hsbw (sbx wx) or sbw (sbx sby wx wy) a charstring starts with; numbers may be divided (div) first.
    private static func width(_ cs: [UInt8]) -> Double? {
        var stack: [Double] = []
        var p = 0
        while p < cs.count {
            let v = Int(cs[p])
            var number: Double?
            if v >= 32 && v <= 246 {
                number = Double(v - 139)
                p += 1
            } else if v >= 247 && v <= 250 && p + 1 < cs.count {
                number = Double((v - 247) * 256 + Int(cs[p + 1]) + 108)
                p += 2
            } else if v >= 251 && v <= 254 && p + 1 < cs.count {
                number = Double(-(v - 251) * 256 - Int(cs[p + 1]) - 108)
                p += 2
            } else if v == 255 && p + 4 < cs.count {
                number = Double(Int32(bitPattern: UInt32(cs[p + 1]) << 24 | UInt32(cs[p + 2]) << 16 | UInt32(cs[p + 3]) << 8 | UInt32(cs[p + 4])))
                p += 5
            }
            if let n = number {
                if stack.count == 24 { return nil }
                stack.append(n)
                continue
            }
            if v == 13 { return stack.count == 2 ? stack[1] : nil } // hsbw
            if v != 12 || p + 1 >= cs.count { return nil }
            let escaped = cs[p + 1]
            p += 2
            if escaped == 7 { return stack.count == 4 ? stack[2] : nil } // sbw
            if escaped != 12 || stack.count < 2 || stack[stack.count - 1] == 0 { return nil } // div
            stack[stack.count - 2] /= stack[stack.count - 1]
            stack.removeLast()
        }
        return nil
    }

    private static let fontMatrix = try! NSRegularExpression(pattern: #"/FontMatrix\s*[\[{]\s*([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)"#)
    private static let lenIVEntry = try! NSRegularExpression(pattern: #"/lenIV\s+(-?\d{1,3})\b"#)

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
        let plain = decrypt(encrypted, 55665, 4)
        font.readCharStrings(plain)
        font.plain = plain
        // The FontMatrix (cleartext) scales the widths; lenIV (private part) is how many random bytes lead a charstring.
        let clear = latin1String(b[..<eexec])
        if let m = fontMatrix.firstMatch(in: clear, range: NSRange(location: 0, length: (clear as NSString).length)),
           let a = Double((clear as NSString).substring(with: m.range(at: 1))), abs(a) > 1e-9, abs(a) < 1e3 {
            font.scale = a * 1000
        }
        let head = latin1String(plain.prefix(1 << 16))
        if let m = lenIVEntry.firstMatch(in: head, range: NSRange(location: 0, length: (head as NSString).length)),
           let n = Int((head as NSString).substring(with: m.range(at: 1))) {
            font.lenIV = n
        }
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
            if len > plain.count - p {
                names.insert(name) // cut short: the glyph is named, its charstring isn't all there
                break
            }
            if charStrings[name] == nil { charStrings[name] = (p, len) }
            p += len
            while p < plain.count && isSpace(plain[p]) { p += 1 }
            while p < plain.count && !isSpace(plain[p]) { p += 1 } // ND or |-
            names.insert(name)
        }
    }
}
