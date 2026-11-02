import Foundation

/// A TrueType font program cut down to the glyphs a document draws, for embedding (the Windows app's
/// `HbSubset.SubsetUnicodes`, which uses HarfBuzz's subsetter). Glyph numbers stay as they are: the glyphs not asked for
/// (nor used by a composite glyph that is) are emptied, `loca` and `glyf` are written anew, and the `cmap` maps only
/// the code points asked for (Windows (3,1), format 4; with `symbolic`, (3,0), the codes asked for at 0xF000 + code, where a
/// symbolic font's codes are looked up: ISO 32000-1, 9.6.6.4). The tables a PDF viewer reads are kept (`head`, `hhea`, `maxp`,
/// `hmtx`, `name`, `OS/2`, the hinting in `cvt `, `fpgm`, `prep`, `gasp`); `post` keeps its header without glyph names
/// (format 3); layout tables (GSUB, GPOS, kern, morx...) and the rest are dropped. MuPDF's own
/// `fz_subset_ttf_for_gids` renumbers glyphs but maps code points beyond the font's glyph count to the old numbers
/// (MuPDF 1.25.2's `make_cmap`), which would draw the wrong glyph for ’ or €, so it isn't used. Foundation only.
enum TrueTypeSubset {
    private static let kept: Set<String> = ["head", "hhea", "maxp", "hmtx", "name", "OS/2", "cvt ", "fpgm", "prep", "gasp"]

    /// Whether the font's OS/2 embedding bits allow embedding a subset of it in a document (fsType: 0 installable, 4
    /// preview and print, 8 editable; several bits, as in macOS's ZapfDingbats (14), mean the least restrictive; 0x100
    /// forbids subsets, 0x200 outlines). Not when it has no such table.
    static func allowsEmbedding(_ font: [UInt8]) -> Bool {
        guard font.count >= 12 else { return false }
        for i in 0..<u16(font, 4) where 12 + 16 * (i + 1) <= font.count {
            let r = 12 + 16 * i
            guard String(decoding: font[r..<r + 4], as: UTF8.self) == "OS/2" else { continue }
            let at = u32(font, r + 8)
            guard at + 10 <= font.count else { return false }
            let bits = u16(font, at + 8)
            return bits & 0x300 == 0 && (bits & 0xF == 0 || bits & 0xC != 0)
        }
        return false
    }

    /// The subset program for `glyphs` (code point, glyph number) in `font` (a TrueType file, not a collection); nil when
    /// the file isn't one this can read (CFF outlines, a collection, damaged tables).
    static func subset(_ font: [UInt8], _ glyphs: [(codePoint: UInt32, glyph: Int)], symbolic: Bool = false) -> [UInt8]? {
        guard font.count >= 12, u32(font, 0) == 0x0001_0000 || u32(font, 0) == 0x7472_7565 else { return nil } // 1.0 or 'true'
        var tables: [String: [UInt8]] = [:]
        let numTables = u16(font, 4)
        guard font.count >= 12 + 16 * numTables else { return nil }
        for i in 0..<numTables {
            let r = 12 + 16 * i
            let tag = String(decoding: font[r..<r + 4], as: UTF8.self)
            let offset = u32(font, r + 8), length = u32(font, r + 12)
            guard offset + length <= font.count else { return nil }
            tables[tag] = Array(font[offset..<offset + length])
        }
        guard var head = tables["head"], head.count >= 54, let maxp = tables["maxp"], maxp.count >= 6, let loca = tables["loca"],
              let glyf = tables["glyf"], tables["hhea"] != nil, tables["hmtx"] != nil else { return nil }
        let numGlyphs = u16(maxp, 4)
        let longLoca = s16(head, 50) == 1
        guard loca.count >= (numGlyphs + 1) * (longLoca ? 4 : 2) else { return nil }
        func start(_ g: Int) -> Int { longLoca ? u32(loca, 4 * g) : 2 * u16(loca, 2 * g) }
        func data(_ g: Int) -> ArraySlice<UInt8>? {
            let a = start(g), b = start(g + 1)
            guard a <= b, b <= glyf.count else { return nil }
            return glyf[a..<b]
        }

        // The glyphs asked for, .notdef, and every component of a composite among them.
        var keep: Set<Int> = [0]
        var work = glyphs.map(\.glyph).filter { $0 > 0 && $0 < numGlyphs }
        while let g = work.popLast() {
            guard keep.insert(g).inserted else { continue }
            guard let d = data(g) else { return nil }
            for c in components(Array(d)) where c < numGlyphs && !keep.contains(c) { work.append(c) }
        }

        var newGlyf: [UInt8] = []
        var newLoca: [UInt8] = []
        for g in 0..<numGlyphs {
            append32(&newLoca, newGlyf.count)
            if keep.contains(g), let d = data(g) {
                newGlyf += d
                while newGlyf.count % 4 != 0 { newGlyf.append(0) }
            }
        }
        append32(&newLoca, newGlyf.count)
        put16(&head, 50, 1) // long loca offsets
        put32(&head, 8, 0) // checkSumAdjustment, set below

        var out: [String: [UInt8]] = tables.filter { kept.contains($0.key) }
        out["head"] = head
        out["glyf"] = newGlyf
        out["loca"] = newLoca
        out["cmap"] = cmap(glyphs.filter { $0.glyph > 0 && $0.glyph < numGlyphs && $0.codePoint <= 0xFFFF }, encoding: symbolic ? 0 : 1)
        if let post = tables["post"], post.count >= 32 {
            var p = Array(post[0..<32])
            put32(&p, 0, 0x0003_0000)
            out["post"] = p
        }
        var file = write(out)
        let adjustment = 0xB1B0_AFBA &- checksum(file[...])
        let headAt = headOffset(file)
        put32(&file, headAt + 8, Int(adjustment))
        return file
    }

    /// The glyphs a composite glyph is made of (none for a simple glyph).
    static func components(_ g: [UInt8]) -> [Int] {
        guard g.count >= 10, s16(g, 0) < 0 else { return [] }
        var out: [Int] = []
        var i = 10
        while i + 4 <= g.count {
            let flags = u16(g, i)
            out.append(u16(g, i + 2))
            i += 4 + (flags & 1 != 0 ? 4 : 2)
            if flags & 8 != 0 { i += 2 } else if flags & 0x40 != 0 { i += 4 } else if flags & 0x80 != 0 { i += 8 }
            if flags & 0x20 == 0 { break }
        }
        return out
    }

    /// A cmap with one Windows subtable (3,`encoding`), format 4: a segment per run of code points whose glyphs follow on,
    /// then the closing 0xFFFF segment.
    private static func cmap(_ glyphs: [(codePoint: UInt32, glyph: Int)], encoding: Int) -> [UInt8] {
        var map: [Int: Int] = [:]
        for (cp, g) in glyphs { map[Int(cp)] = g }
        var segments: [(start: Int, end: Int, delta: Int)] = []
        for cp in map.keys.sorted() {
            let delta = map[cp]! - cp
            if let last = segments.last, last.end == cp - 1, last.delta == delta {
                segments[segments.count - 1].end = cp
            } else {
                segments.append((cp, cp, delta))
            }
        }
        segments.append((0xFFFF, 0xFFFF, 1))
        let n = segments.count
        var entrySelector = 0
        while 1 << (entrySelector + 1) <= n { entrySelector += 1 }
        let searchRange = 2 * (1 << entrySelector)
        var sub: [UInt8] = []
        append16(&sub, 4)
        append16(&sub, 16 + 8 * n)
        append16(&sub, 0) // language
        append16(&sub, 2 * n)
        append16(&sub, searchRange)
        append16(&sub, entrySelector)
        append16(&sub, 2 * n - searchRange)
        for s in segments { append16(&sub, s.end) }
        append16(&sub, 0) // reserved pad
        for s in segments { append16(&sub, s.start) }
        for s in segments { append16(&sub, (s.delta + 65536) % 65536) }
        for _ in segments { append16(&sub, 0) } // idRangeOffset: deltas only
        var t: [UInt8] = []
        append16(&t, 0) // version
        append16(&t, 1) // one subtable
        append16(&t, 3)
        append16(&t, encoding)
        append32(&t, 12)
        return t + sub
    }

    /// The tables as a font file: the directory sorted by tag, each table 4-byte aligned with its checksum.
    private static func write(_ tables: [String: [UInt8]]) -> [UInt8] {
        let tags = tables.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
        let n = tags.count
        var entrySelector = 0
        while 1 << (entrySelector + 1) <= n { entrySelector += 1 }
        let searchRange = 16 * (1 << entrySelector)
        var file: [UInt8] = []
        append32(&file, 0x0001_0000)
        append16(&file, n)
        append16(&file, searchRange)
        append16(&file, entrySelector)
        append16(&file, 16 * n - searchRange)
        let offset = 12 + 16 * n
        var body: [UInt8] = []
        for tag in tags {
            let t = tables[tag]!
            file += Array(tag.utf8)
            append32(&file, Int(checksum(t[...])))
            append32(&file, offset + body.count)
            append32(&file, t.count)
            body += t
            while body.count % 4 != 0 { body.append(0) }
        }
        return file + body
    }

    private static func headOffset(_ file: [UInt8]) -> Int {
        let n = u16(file, 4)
        for i in 0..<n where String(decoding: file[12 + 16 * i..<16 + 16 * i], as: UTF8.self) == "head" { return u32(file, 20 + 16 * i) }
        return 0
    }

    /// The sum of the data as big-endian 32-bit words (the last one padded with zeros).
    private static func checksum(_ d: ArraySlice<UInt8>) -> UInt32 {
        var sum: UInt32 = 0
        var i = d.startIndex
        while i < d.endIndex {
            var word: UInt32 = 0
            for k in 0..<4 { word = word << 8 | UInt32(i + k < d.endIndex ? d[i + k] : 0) }
            sum = sum &+ word
            i += 4
        }
        return sum
    }

    private static func u16(_ d: [UInt8], _ at: Int) -> Int { at + 2 <= d.count ? Int(d[at]) << 8 | Int(d[at + 1]) : 0 }
    private static func s16(_ d: [UInt8], _ at: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(d, at)))) }
    private static func u32(_ d: [UInt8], _ at: Int) -> Int {
        at + 4 <= d.count ? Int(d[at]) << 24 | Int(d[at + 1]) << 16 | Int(d[at + 2]) << 8 | Int(d[at + 3]) : 0
    }

    private static func put16(_ d: inout [UInt8], _ at: Int, _ v: Int) {
        d[at] = UInt8((v >> 8) & 0xFF)
        d[at + 1] = UInt8(v & 0xFF)
    }

    private static func put32(_ d: inout [UInt8], _ at: Int, _ v: Int) {
        put16(&d, at, (v >> 16) & 0xFFFF)
        put16(&d, at + 2, v & 0xFFFF)
    }

    private static func append16(_ d: inout [UInt8], _ v: Int) { d += [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }
    private static func append32(_ d: inout [UInt8], _ v: Int) {
        append16(&d, (v >> 16) & 0xFFFF)
        append16(&d, v & 0xFFFF)
    }
}
