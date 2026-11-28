import CoreText
import Foundation

/// A font program's own pair kerning (roadmap 2.1; the Windows app's `PairKerning`): the pair adjustments of the GPOS
/// table's 'kern' feature (pair positioning formats 1 and 2, through extension lookups too), else the 'kern' table's
/// first horizontal format 0 subtable, by glyph index, in font units. Read lazily from an sfnt's bytes; every offset and
/// count is checked against them and the lookups and subtables read are bounded, since an embedded program is hostile
/// input.
final class PairKerning: @unchecked Sendable {
    private static let maxLookups = 64, maxSubtables = 1024, maxCached = 65_536

    private let b: FontBytes
    /// Each 'kern' lookup's pair positioning subtables (absolute offsets), in lookup order.
    private let lookups: [[Int]]
    /// The 'kern' table's format 0 pairs: where the first is and how many there are (none: count 0).
    private let pairs: (at: Int, count: Int)
    private let lock = NSLock()
    private var cache: [Int: Int] = [:]

    let unitsPerEm: Double

    private init(_ b: FontBytes, _ upem: Double, _ lookups: [[Int]], _ pairs: (Int, Int)) {
        self.b = b
        unitsPerEm = upem
        self.lookups = lookups
        self.pairs = pairs
    }

    /// The kerning an sfnt (TrueType or OpenType) holds, or nil when it holds none that can be read.
    static func read(_ sfnt: [UInt8]) -> PairKerning? {
        guard let tables = TrueTypeProgram.tables(sfnt), let head = tables["head"], head.length >= 20 else { return nil }
        let b = FontBytes(sfnt)
        do {
            let upem = Double(try b.u16(head.offset + 18))
            if upem < 16 || upem > 16384 { return nil }
            let lookups = try tables["GPOS"].map { try kernLookups(b, $0.offset, $0.length) } ?? []
            var pairs = (0, 0)
            if lookups.isEmpty, let kern = tables["kern"] { pairs = try kernPairs(b, kern.offset, kern.length) }
            return !lookups.isEmpty || pairs.1 > 0 ? PairKerning(b, upem, lookups, pairs) : nil
        } catch {
            return nil
        }
    }

    /// An installed font's kerning, from the tables Core Text gives (head, GPOS, kern) put together as an sfnt.
    static func read(_ font: CTFont) -> PairKerning? {
        func table(_ tag: String) -> [UInt8]? {
            let code = tag.utf8.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return (CTFontCopyTable(font, CTFontTableTag(code), []) as Data?).map { [UInt8]($0) }
        }
        let found = ["GPOS", "head", "kern"].compactMap { tag in table(tag).map { (tag, $0) } }
        return read(sfnt(found))
    }

    /// An sfnt of the tables given (sorted by tag, as the directory wants them).
    static func sfnt(_ tables: [(tag: String, data: [UInt8])]) -> [UInt8] {
        let all = tables.sorted { $0.tag < $1.tag }
        func be16(_ v: Int) -> [UInt8] { [UInt8(v >> 8 & 255), UInt8(v & 255)] }
        func be32(_ v: Int) -> [UInt8] { be16(v >> 16 & 0xFFFF) + be16(v & 0xFFFF) }
        var dir: [UInt8] = be32(0x0001_0000) + be16(all.count) + be16(0) + be16(0) + be16(0)
        var body: [UInt8] = []
        let start = 12 + 16 * all.count
        for (tag, data) in all {
            dir += Array(tag.utf8.prefix(4)) + be32(0) + be32(start + body.count) + be32(data.count)
            body += data
            while body.count % 4 != 0 { body.append(0) }
        }
        return dir + body
    }

    /// The adjustment between two glyphs, in font units (negative: closer); 0 when the font has none.
    func kern(_ left: Int, _ right: Int) -> Int {
        guard left > 0, left <= 0xFFFF, right > 0, right <= 0xFFFF else { return 0 }
        let key = left << 16 | right
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[key] { return known }
        let k: Int
        do {
            if lookups.isEmpty {
                k = try fromKernTable(left, right)
            } else {
                var sum = 0
                for l in lookups { sum += try fromLookup(l, left, right) }
                k = sum
            }
        } catch {
            k = 0
        }
        if cache.count < Self.maxCached { cache[key] = k }
        return k
    }

    /// The pair positioning subtables of the lookups the GPOS table's 'kern' features name, in lookup order.
    private static func kernLookups(_ b: FontBytes, _ g: Int, _ length: Int) throws -> [[Int]] {
        var result: [[Int]] = []
        if length < 10 { return result }
        if try b.u16(g) != 1 { return result }
        let features = g + (try b.u16(g + 6))
        let lookupList = g + (try b.u16(g + 8))
        var wanted = Set<Int>()
        let count = try b.u16(features)
        func isKern(_ i: Int) -> Bool {
            let rec = features + 2 + 6 * i
            guard i < count, rec + 6 <= b.count else { return false }
            return b.b[rec] == 0x6B && b.b[rec + 1] == 0x65 && b.b[rec + 2] == 0x72 && b.b[rec + 3] == 0x6E // "kern"
        }
        func add(_ i: Int) throws {
            let feature = features + (try b.u16(features + 2 + 6 * i + 4))
            let n = try b.u16(feature + 2)
            var k = 0
            while k < n && wanted.count < maxLookups {
                wanted.insert(try b.u16(feature + 4 + 2 * k))
                k += 1
            }
        }
        // Only the features of one language system, as a shaper applies them to Latin text: Latin's (latn), else the
        // default script's (DFLT), else each other script's in turn; its default language, else its first one; the first
        // of those that has a kern feature. Another script's or language's kern feature may hold the same pairs again.
        var chosen = false
        for langSys in try langSystems(b, g + (try b.u16(g + 4))) {
            let n = try b.u16(langSys + 4)
            for k in 0..<n {
                let i = try b.u16(langSys + 6 + 2 * k)
                if isKern(i) {
                    try add(i)
                    chosen = true
                }
            }
            if chosen { break }
        }
        if !chosen {
            // No language system with one: the first kern feature.
            for i in 0..<count where isKern(i) {
                try add(i)
                break
            }
        }
        let lookupCount = try b.u16(lookupList)
        var subtables = 0
        for index in wanted.sorted() where index < lookupCount {
            let lookup = lookupList + (try b.u16(lookupList + 2 + 2 * index))
            let type = try b.u16(lookup)
            let n = try b.u16(lookup + 4)
            var list: [Int] = []
            var k = 0
            while k < n && subtables < maxSubtables {
                defer {
                    k += 1
                    subtables += 1
                }
                var sub = lookup + (try b.u16(lookup + 6 + 2 * k))
                if type == 9 {
                    let format = try b.u16(sub), extended = try b.u16(sub + 2)
                    guard format == 1 && extended == 2 else { continue }
                    sub += min(try b.u32(sub + 4), Int(Int32.max) / 2)
                } else if type != 2 {
                    continue
                }
                guard sub > 0 && sub + 10 <= b.count else { continue }
                let format = try b.u16(sub)
                if format == 1 || format == 2 { list.append(sub) }
            }
            if !list.isEmpty { result.append(list) }
        }
        return result
    }

    /// The language systems a shaper would apply to Latin text, in the order they are tried: latn's, DFLT's, then each
    /// other script's; of each script its default language system, else its first. At most 64 scripts are looked at.
    private static func langSystems(_ b: FontBytes, _ scripts: Int) throws -> [Int] {
        let n = min(try b.u16(scripts), 64)
        func find(_ tag: String) -> Int? {
            let t = Array(tag.utf8)
            for i in 0..<n {
                let rec = scripts + 2 + 6 * i
                if rec + 6 > b.count { return nil }
                if Array(b.b[rec..<rec + 4]) == t { return i }
            }
            return nil
        }
        var order: [Int] = []
        if let latn = find("latn") { order.append(latn) }
        if let dflt = find("DFLT") { order.append(dflt) }
        for i in 0..<n where !order.contains(i) { order.append(i) }
        var result: [Int] = []
        for i in order {
            let script = scripts + (try b.u16(scripts + 2 + 6 * i + 4))
            let def = try b.u16(script)
            if def != 0 {
                result.append(script + def)
            } else if try b.u16(script + 2) > 0 {
                result.append(script + (try b.u16(script + 4 + 4)))
            }
        }
        return result
    }

    /// A lookup's adjustment for a pair: its first subtable that covers the pair decides.
    private func fromLookup(_ subtables: [Int], _ left: Int, _ right: Int) throws -> Int {
        for sub in subtables {
            let at = try coverage(sub + (try b.u16(sub + 2)), left)
            if at < 0 { continue }
            let vf1 = try b.u16(sub + 4), vf2 = try b.u16(sub + 6)
            let size1 = 2 * (vf1 & 0xFF).nonzeroBitCount, size2 = 2 * (vf2 & 0xFF).nonzeroBitCount
            // The first glyph's x advance is what kerning sets (other fields move glyphs, not the pen).
            let advance = vf1 & 4 == 0 ? -1 : 2 * (vf1 & 3).nonzeroBitCount
            if try b.u16(sub) == 1 {
                let sets = try b.u16(sub + 8)
                if at >= sets { continue }
                let set = sub + (try b.u16(sub + 10 + 2 * at))
                let n = try b.u16(set)
                let rec = 2 + size1 + size2
                // Pair value records sorted by the second glyph.
                var lo = 0, hi = n - 1
                while lo <= hi {
                    let mid = (lo + hi) / 2
                    let r = set + 2 + rec * mid
                    let second = try b.u16(r)
                    if second == right { return try advance < 0 ? 0 : b.i16(r + 2 + advance) }
                    if second < right { lo = mid + 1 } else { hi = mid - 1 }
                }
            } else {
                let c1 = try classOf(sub + (try b.u16(sub + 8)), left)
                let c2 = try classOf(sub + (try b.u16(sub + 10)), right)
                let n1 = try b.u16(sub + 12), n2 = try b.u16(sub + 14)
                if c1 >= n1 || c2 >= n2 { continue }
                if advance < 0 { return 0 }
                let r = sub + 16 + (c1 * n2 + c2) * (size1 + size2)
                return try r + advance + 2 <= b.count ? b.i16(r + advance) : 0
            }
        }
        return 0
    }

    /// A glyph's index in a coverage table, or -1.
    private func coverage(_ table: Int, _ glyph: Int) throws -> Int {
        let format = try b.u16(table)
        let n = try b.u16(table + 2)
        var lo = 0, hi = n - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if format == 1 {
                let g = try b.u16(table + 4 + 2 * mid)
                if g == glyph { return mid }
                if g < glyph { lo = mid + 1 } else { hi = mid - 1 }
            } else if format == 2 {
                let r = table + 4 + 6 * mid
                let start = try b.u16(r), end = try b.u16(r + 2)
                if glyph < start {
                    hi = mid - 1
                } else if glyph > end {
                    lo = mid + 1
                } else {
                    return try b.u16(r + 4) + glyph - start
                }
            } else {
                return -1
            }
        }
        return -1
    }

    /// A glyph's class in a class definition table (0 when it lists none).
    private func classOf(_ table: Int, _ glyph: Int) throws -> Int {
        let format = try b.u16(table)
        if format == 1 {
            let start = try b.u16(table + 2), n = try b.u16(table + 4)
            return try glyph >= start && glyph - start < n ? b.u16(table + 6 + 2 * (glyph - start)) : 0
        }
        if format != 2 { return 0 }
        var lo = 0, hi = try b.u16(table + 2) - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = table + 4 + 6 * mid
            let start = try b.u16(r), end = try b.u16(r + 2)
            if glyph < start {
                hi = mid - 1
            } else if glyph > end {
                lo = mid + 1
            } else {
                return try b.u16(r + 4)
            }
        }
        return 0
    }

    /// The 'kern' table's first horizontal format 0 subtable that isn't minimum or cross-stream: where its pairs start
    /// and how many fit.
    private static func kernPairs(_ b: FontBytes, _ at: Int, _ length: Int) throws -> (Int, Int) {
        if length < 4 { return (0, 0) }
        if try b.u16(at) != 0 { return (0, 0) } // Apple's version 1 tables aren't read
        let n = try b.u16(at + 2)
        var sub = at + 4
        let end = at + length
        var i = 0
        while i < n && sub + 6 <= end {
            let subLength = try b.u16(sub + 2)
            let coverage = try b.u16(sub + 4)
            if coverage >> 8 == 0 && coverage & 0x7 == 1 {
                let pairs = try b.u16(sub + 6)
                // The subtable's own length overflows 16 bits in big tables: the pairs are counted against the table's.
                return (sub + 14, min(pairs, max(0, (end - (sub + 14)) / 6)))
            }
            if subLength < 6 { break }
            sub += subLength
            i += 1
        }
        return (0, 0)
    }

    private func fromKernTable(_ left: Int, _ right: Int) throws -> Int {
        let key = left << 16 | right
        var lo = 0, hi = pairs.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = pairs.at + 6 * mid
            let k = (try b.u16(r)) << 16 | (try b.u16(r + 2))
            if k == key { return try b.i16(r + 4) }
            if k < key { lo = mid + 1 } else { hi = mid - 1 }
        }
        return 0
    }
}

/// The kerning a page font's own table gives two of its codes, for text a paragraph edit lays out (roadmap 2.1; the
/// Windows app's `FontKerning`): the embedded TrueType program's when it kept its tables, else the installed face of the
/// font's own family (its PDF name, "Helvetica" as Arial; its tables from Core Text) when its widths are the page
/// font's; by glyph or by the characters the codes stand for. A word space has none. As a TJ adjustment: thousandths of
/// an em, positive to set the pair closer.
final class FontKerning: @unchecked Sendable {
    /// A page font's kerning, found once (`TextFont.kerningSlot`).
    final class Slot: @unchecked Sendable {
        fileprivate let lock = NSLock()
        fileprivate var found = false
        fileprivate var value: FontKerning?
    }

    private final class TwinCache: @unchecked Sendable {
        let lock = NSLock()
        var tables: [ObjectIdentifier: PairKerning?] = [:]
    }

    /// Installed fonts' tables, read once each (`SystemFonts` keeps one object per font for the process).
    private static let twins = TwinCache()

    private let font: TextFont
    private let table: PairKerning
    /// Nil: the table is the embedded program's, by glyph; else the installed twin's, by character.
    private let twin: TrueTypeFont?

    private init(_ font: TextFont, _ table: PairKerning, _ twin: TrueTypeFont?) {
        self.font = font
        self.table = table
        self.twin = twin
    }

    /// The kerning of a page font's own family, or nil when neither its program nor an installed twin has any.
    static func of(_ font: TextFont) -> FontKerning? {
        let slot = font.kerningSlot
        slot.lock.lock()
        defer { slot.lock.unlock() }
        if slot.found { return slot.value }
        slot.value = find(font)
        slot.found = true
        return slot.value
    }

    private static func find(_ font: TextFont) -> FontKerning? {
        if let tt = font.program as? TrueTypeProgram, let own = PairKerning.read(tt.bytes) { return FontKerning(font, own, nil) }
        guard let twin = StandInFonts.twin(font), sameWidths(font, twin.font), let table = tableOf(twin.font) else { return nil }
        return FontKerning(font, table, twin.font)
    }

    private static func tableOf(_ font: TrueTypeFont) -> PairKerning? {
        let key = ObjectIdentifier(font)
        twins.lock.lock()
        if let known = twins.tables[key] {
            twins.lock.unlock()
            return known
        }
        twins.lock.unlock()
        let table = PairKerning.read(font.font)
        twins.lock.lock()
        twins.tables[key] = .some(table)
        twins.lock.unlock()
        return table
    }

    /// The installed face draws the page font's letters at its widths (within 1.5%, on most letters it has): the same
    /// design, so its kerning is the page font's own.
    private static func sameWidths(_ font: TextFont, _ twin: TrueTypeFont) -> Bool {
        var same = 0, compared = 0
        for ch in "aeinorstAEHNOTVWY".unicodeScalars {
            let enc = font.encode(String(ch))
            guard enc.missing.isEmpty, enc.codes.count == 1, enc.codes[0] >= 0, font.hasGlyph(enc.codes[0]), twin.has(ch.value) else { continue }
            let w = font.widthOf(enc.codes[0])
            guard w > 0 else { continue }
            compared += 1
            let a = twin.advance(ch.value)
            if abs(w / 1000 - a) <= 0.015 * max(0.3, a) { same += 1 }
        }
        return compared >= 5 && Double(same) >= 0.8 * Double(compared)
    }

    /// The adjustment between two codes (TJ units; 0: none). A space on either side, or a pair past a quarter em, gets none.
    func pair(_ left: Int, _ right: Int) -> Double {
        if left < 0 || right < 0 { return 0 }
        let a: Int, b: Int
        if let twin {
            guard let ca = single(left), let cb = single(right) else { return 0 }
            a = twin.glyphOf(ca)
            b = twin.glyphOf(cb)
        } else {
            a = font.glyphIdOf(left)
            b = font.glyphIdOf(right)
        }
        if a <= 0 || b <= 0 || blank(left) || blank(right) { return 0 }
        let k = -Double(table.kern(a, b)) * 1000 / table.unitsPerEm
        return abs(k) < 0.5 || abs(k) > 250 ? 0 : (k * 10).rounded() / 10
    }

    private func blank(_ code: Int) -> Bool {
        guard let t = font.unicodeOf(code), !t.isEmpty else { return true }
        return t.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    /// The one character a code stands for, or nil.
    private func single(_ code: Int) -> UInt32? {
        guard let t = font.unicodeOf(code) else { return nil }
        let scalars = Array(t.unicodeScalars)
        return scalars.count == 1 ? scalars[0].value : nil
    }
}

extension ContentEditor {
    /// The kerning new text gets between two codes of a font: the adjustment the original text carried for the pair
    /// (`kerning`), else, when that text was kerned at all, the font's own (`FontKerning`: its GPOS or kern table, or its
    /// installed twin's). Text a generator set without kerning gets none, so edited lines look like the lines around them.
    /// The font's table (and an installed twin) is found only when a new pair first asks for it, not while a page's
    /// paragraphs are read.
    struct Kerns: Sendable {
        let seen: [CodePair: Double]
        let font: TextFont?

        static func of(_ seen: [CodePair: Double], _ font: TextFont?) -> Kerns { Kerns(seen: seen, font: seen.isEmpty ? nil : font) }

        func get(_ left: Int, _ right: Int) -> Double? {
            if let k = seen[CodePair(a: left, b: right)] { return k }
            guard let font, let k = FontKerning.of(font)?.pair(left, right), k != 0 else { return nil }
            return k
        }
    }
}
