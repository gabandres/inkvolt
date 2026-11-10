import CoreText
import Foundation

/// An installed font that draws characters a page font lacks: the font and its name for the user ("Arial Bold").
final class StandInFont: @unchecked Sendable {
    let font: TrueTypeFont
    let name: String

    init(_ font: TrueTypeFont, _ name: String) {
        self.font = font
        self.name = name
    }
}

/// Picks the installed font closest to a page font, for characters its embedded subset lacks (paragraph editing,
/// roadmap 2.1; the Windows app's `StandInFonts`): the same family when it is installed (the PDF's name, "Helvetica" as
/// Arial, "Times" as Times New Roman), else the nearest of the common families by class (serif, sans, monospaced), then
/// weight and slant, then x-height and the widths of the characters both fonts have. Characters none of them has come
/// from Core Text's fallback for the character (its cascade list); past that, nothing (the character is refused).
///
/// Mac differences: the families are the ones macOS ships (Windows' Segoe UI, Calibri, Cambria, Constantia, Consolas,
/// Palatino Linotype and Lucida Console aren't on a Mac; Helvetica Neue, Gill Sans, Palatino, Baskerville, Hoefler Text,
/// Menlo and Andale Mono are), each face found by family and traits through Core Text rather than by file name; any
/// family Core Text lists can be named by a look (stand-ins are written as Type 3 fonts from Core Text's outlines, so
/// CFF and collection fonts work too, where Windows embeds TrueType files only).
enum StandInFonts {
    enum Kind { case sans, serif, mono }

    private struct Family {
        var name: String
        var kind: Kind
        var aliases: [String]
    }

    private static let families: [Family] = [
        Family(name: "Arial", kind: .sans,
               aliases: ["Arial", "Helvetica", "Helv", "Arimo", "Liberation Sans", "Nimbus Sans", "Nimbus Sans L", "NimbusSanL", "NimbusSans"]),
        Family(name: "Helvetica Neue", kind: .sans, aliases: ["Helvetica Neue"]),
        Family(name: "Verdana", kind: .sans, aliases: ["Verdana", "DejaVu Sans"]),
        Family(name: "Tahoma", kind: .sans, aliases: ["Tahoma"]),
        Family(name: "Trebuchet MS", kind: .sans, aliases: ["Trebuchet MS", "Trebuchet"]),
        Family(name: "Gill Sans", kind: .sans, aliases: ["Gill Sans", "GillSans", "Gill Sans MT"]),
        Family(name: "Times New Roman", kind: .serif,
               aliases: ["Times New Roman", "Times", "Tinos", "Liberation Serif", "Nimbus Roman", "Nimbus Roman No9 L", "NimbusRomNo9L", "NimbusRoman"]),
        Family(name: "Georgia", kind: .serif, aliases: ["Georgia"]),
        Family(name: "Palatino", kind: .serif, aliases: ["Palatino", "Palatino Linotype", "Book Antiqua", "URW Palladio L"]),
        Family(name: "Baskerville", kind: .serif, aliases: ["Baskerville"]),
        Family(name: "Hoefler Text", kind: .serif, aliases: ["Hoefler Text"]),
        Family(name: "Courier New", kind: .mono,
               aliases: ["Courier New", "Courier", "Cousine", "Liberation Mono", "Nimbus Mono", "Nimbus Mono L", "NimbusMonL", "NimbusMono"]),
        Family(name: "Menlo", kind: .mono, aliases: ["Menlo", "Consolas", "Inconsolata", "DejaVu Sans Mono"]),
        Family(name: "Andale Mono", kind: .mono, aliases: ["Andale Mono", "Lucida Console"]),
    ]

    private static let serifWords = [
        "Times", "Serif", "Roman", "NimbusRom", "Georgia", "Garamond", "Cambria", "Palatino", "Minion", "Caslon", "Baskerville", "Bodoni",
        "Century", "Cheltenham", "Constantia", "Didot", "Goudy", "Janson", "Sabon", "Utopia", "Charter", "Bookman", "Schoolbook", "Antiqua",
        "Cochin", "Perpetua", "Rockwell", "Clarendon", "Merriweather", "Lora", "Tiempos", "Source Serif", "Noto Serif", "Libertine", "CMR",
        "CMBX", "CMTI", "CMSL", "SFRM", "STIX", "LMRoman", "Hoefler",
    ]

    private static let monoWords = ["Mono", "Courier", "Consol", "Code", "Typewriter", "Fixed", "Lucida Console", "Menlo", "Monaco", "CMTT", "LMMono"]

    private static let sansWords = [
        "Sans", "NimbusSan", "CMSS", "Arial", "Helvetica", "Gothic", "Gotham", "Grotesk", "Proxima", "Whitney", "Avenir", "Verdana",
        "Tahoma", "Calibri", "Aptos", "Segoe", "Roboto", "Lato", "Futura", "Frutiger", "Myriad", "Univers", "Gill",
    ]

    /// Lowercase and capitals most text has: what the widths are compared on.
    private static let sample = "etaoinshrdlucmfwypvbgkxqjzETAOINSHRDLUCM0123456789"

    /// A font's class from its name and descriptor flags (a subset's name is matched without its tag).
    static func kindOf(_ name: String, _ flags: Int) -> Kind {
        let family = FontNames.family(name)
        func has(_ words: [String]) -> Bool {
            words.contains { name.range(of: $0, options: .caseInsensitive) != nil || family.range(of: $0, options: .caseInsensitive) != nil }
        }
        if flags & 1 != 0 || has(monoWords) { return .mono }
        if has(sansWords) { return .sans }
        return flags & 2 != 0 || has(serifWords) ? .serif : .sans
    }

    // ---- Faces ----

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var faces: [String: StandInFont?] = [:]
        var installed: [String]?
    }

    private static let cache = Cache()

    /// A family's face closest to the style asked (its regular one when it has no bold or italic face), through Core
    /// Text; nil when the family isn't installed.
    static func face(_ family: String, _ bold: Bool, _ italic: Bool) -> StandInFont? {
        let key = "\(family.lowercased())|\(bold)|\(italic)"
        cache.lock.lock()
        if let hit = cache.faces[key] {
            cache.lock.unlock()
            return hit
        }
        cache.lock.unlock()
        let found = findFace(family, bold, italic)
        cache.lock.lock()
        cache.faces[key] = .some(found)
        cache.lock.unlock()
        return found
    }

    private static func findFace(_ family: String, _ bold: Bool, _ italic: Bool) -> StandInFont? {
        let attributes = [kCTFontFamilyNameAttribute: family] as CFDictionary
        let collection = CTFontCollectionCreateWithFontDescriptors([CTFontDescriptorCreateWithAttributes(attributes)] as CFArray, nil)
        guard let members = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor], !members.isEmpty else { return nil }
        var best: (score: Double, desc: CTFontDescriptor, bold: Bool, italic: Bool)?
        for d in members {
            guard let name = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String,
                  name.caseInsensitiveCompare(family) == .orderedSame else { continue }
            let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
            let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let width = (traits[kCTFontWidthTrait] as? NSNumber)?.doubleValue ?? 0
            let isItalic = symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0
            let isBold = symbolic & CTFontSymbolicTraits.traitBold.rawValue != 0
            let wantWeight: Double = bold ? 0.4 : 0
            var score: Double = abs(weight - wantWeight) + abs(width) + (isItalic == italic ? 0 : 1)
            if isBold != bold { score += 0.5 }
            if best == nil || score < best!.score { best = (score, d, isBold, isItalic) }
        }
        guard let best else { return nil }
        let font = SystemFonts.wrap(CTFontCreateWithFontDescriptor(best.desc, 1000, nil))
        let style = best.bold ? (best.italic ? " Bold Italic" : " Bold") : (best.italic ? " Italic" : "")
        return StandInFont(font, family + style)
    }

    /// The installed families a look can name, by name ("Arial", "Georgia", "Comic Sans MS"): every family Core Text
    /// lists but the system's hidden ones, sorted.
    static func installed() -> [String] {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let known = cache.installed { return known }
        let all = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        var seen = Set<String>()
        var list: [String] = []
        for f in all where !f.hasPrefix(".") && f != "LastResort" && seen.insert(f.lowercased()).inserted { list.append(f) }
        list.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        cache.installed = list
        return list
    }

    /// The installed font for text of `font` given a look: `family` when it is one of the families here (or an alias)
    /// or one Core Text lists, and installed (its bold or italic face when it has one), else the closest to the
    /// paragraph's font in that style; nil only when no font is installed at all.
    static func styled(_ font: TextFont, _ family: String?, _ bold: Bool, _ italic: Bool) -> StandInFont? {
        if let family {
            let known = families.first { $0.name.caseInsensitiveCompare(family) == .orderedSame || $0.aliases.contains { $0.caseInsensitiveCompare(family) == .orderedSame } }
            if let f = known, let face = face(f.name, bold, italic) { return face }
            if let face = face(family, bold, italic) { return face }
        }
        return rankFor(font, bold, italic).first
    }

    // ---- Ranking ----

    /// Installed fonts in the order they come closest to `font` (its own family first when installed).
    static func rankFor(_ font: TextFont) -> [StandInFont] { rankFor(font, font.bold, font.italic) }

    /// The same, for text of `font` made bold or italic (or not).
    static func rankFor(_ font: TextFont, _ bold: Bool, _ italic: Bool) -> [StandInFont] {
        let key = (bold ? 2 : 0) + (italic ? 1 : 0)
        if let known = font.standInRanks(key) { return known }
        let list = rank(font, bold, italic)
        font.setStandInRanks(key, list)
        return list
    }

    private static func rank(_ font: TextFont, _ bold: Bool, _ italic: Bool) -> [StandInFont] {
        let kind = kindOf(font.name, font.flags)
        let family = FontNames.family(font.name)
        // The widths the page font gives the sample characters it has (ems).
        var widths: [(cp: UInt32, w: Double)] = []
        for ch in sample.unicodeScalars {
            let enc = font.encode(String(ch))
            guard enc.missing.isEmpty, enc.codes.count == 1, enc.codes[0] >= 0, font.hasGlyph(enc.codes[0]) else { continue }
            let w = font.widthOf(enc.codes[0])
            if w > 0 { widths.append((ch.value, w / 1000)) }
        }
        var scored: [(score: Double, font: StandInFont)] = []
        for f in families {
            guard let face = face(f.name, bold, italic) else { continue }
            let tt = face.font
            let gotBold = face.name.contains(" Bold"), gotItalic = face.name.hasSuffix("Italic")
            let styleMiss: Double = (gotBold == bold ? 0 : 1) + (gotItalic == italic ? 0 : 1)
            var score: Double
            if f.aliases.contains(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) {
                score = -1000 + 10 * styleMiss // its own family
            } else {
                score = (f.kind == kind ? 0 : kind == .mono || f.kind == .mono ? 200 : 100) + 30 * styleMiss
                if widths.count >= 3 {
                    var sum = 0.0
                    for x in widths {
                        let a = tt.has(x.cp) ? tt.advance(x.cp) : 0
                        sum += a > 0 ? abs(log(x.w / a)) : 0.5
                    }
                    score += 100 * sum / Double(widths.count)
                }
                if let xh = font.xHeight, tt.xHeight > 0 { score += 100 * abs(log(xh / tt.xHeight)) }
            }
            scored.append((score, face))
        }
        return scored.enumerated().sorted { ($0.element.score, $0.offset) < ($1.element.score, $1.offset) }.map(\.element.font)
    }

    /// The closest installed font that has every one of `codePoints`; else, for each, the closest that has it or Core
    /// Text's fallback for it. Characters no font here has are left out of the map.
    static func forFont(_ font: TextFont, _ codePoints: [UInt32]) -> [UInt32: StandInFont] {
        var map: [UInt32: StandInFont] = [:]
        if codePoints.isEmpty { return map }
        let ranked = rankFor(font)
        if let all = ranked.first(where: { f in codePoints.allSatisfy { f.font.drawsOutline($0) } }) {
            for cp in codePoints { map[cp] = all }
            return map
        }
        for cp in codePoints {
            if let one = ranked.first(where: { $0.font.drawsOutline(cp) }) {
                map[cp] = one
            } else if let fb = fallback(cp) {
                map[cp] = fb
            }
        }
        return map
    }

    /// Core Text's font for a character none of the families has, named by its family; else one of the Mac's broad symbol
    /// fonts that has it. Only fonts that draw it by an outline (a stand-in is written as Type 3 outlines: a color font's
    /// bitmap, such as Apple Color Emoji's, would come out blank), never the LastResort font (its glyphs only say which
    /// block a character is in); nil when none has it, and the character is refused as missing.
    private static func fallback(_ cp: UInt32) -> StandInFont? {
        var candidates: [TrueTypeFont] = []
        if let fb = SystemFonts.forCodePoint(cp, nil) { candidates.append(fb) }
        for name in ["Apple Symbols", "Arial Unicode MS", "STIX Two Math"] {
            candidates.append(SystemFonts.wrap(CTFontCreateWithName(name as CFString, 1000, nil)))
        }
        for f in candidates where f.family != "LastResort" && !f.postScriptName.hasPrefix("LastResort") && f.drawsOutline(cp) {
            return StandInFont(f, f.family)
        }
        return nil
    }

    /// A character that draws nothing: white space, a format character (U+200B-U+200D, U+2060, U+FEFF…), a variation
    /// selector or another default-ignorable one. Its glyph is empty in any font, so it needs no outline.
    static func inkless(_ codePoint: UInt32) -> Bool {
        guard let s = Unicode.Scalar(codePoint) else { return false }
        let p = s.properties
        return p.isWhitespace || p.isDefaultIgnorableCodePoint || p.isVariationSelector || p.generalCategory == .format
    }

    /// Whether a text element is only characters with no ink.
    static func inkless(_ element: String) -> Bool { element.unicodeScalars.allSatisfy { inkless($0.value) } }

    /// The character a text element's stand-in is chosen by: its first inked one (a cluster is judged by its ink).
    static func key(_ element: String) -> UInt32 {
        let points = TrueTypeFont.codePoints(element)
        return points.first { !inkless($0) } ?? points[0]
    }

    /// A stand-in stretch shaped in `font`. An emoji presentation selector (U+FE0F) is left out of the shaping, so Core
    /// Text draws the character in `font` (an outline) rather than switch to the color emoji font (a bitmap a Type 3 font
    /// can't carry); it stays in the text the glyph stands for, so the copy is what was typed.
    static func shape(_ text: String, _ font: TrueTypeFont) -> ShapedLine {
        guard text.unicodeScalars.contains(where: { $0.value == 0xFE0F }) else { return TextShaper.shape(text, font) }
        var shaped = ""
        var held: [(at: Int, s: String)] = [] // a selector after the character at this UTF-16 offset of `shaped`
        for u in text.unicodeScalars {
            if u.value == 0xFE0F {
                held.append((shaped.utf16.count, String(u)))
            } else {
                shaped.unicodeScalars.append(u)
            }
        }
        var line = TextShaper.shape(shaped, font)
        line.text = text
        // Each selector goes with the last glyph standing for text before it.
        for h in held {
            var consumed = 0
            var target = -1
            for (i, g) in line.glyphs.enumerated() {
                consumed += g.text.utf16.count
                if consumed <= h.at && !g.text.isEmpty { target = i }
                if consumed >= h.at { target = max(target, i); break }
            }
            if target >= 0 { line.glyphs[target].text += h.s }
        }
        return line
    }

    /// Whether a text element comes out drawn when shaped in `font` (as `shape` does): each glyph Core Text picks (the
    /// font's, or its fallback's) has an outline, or stands for characters with no ink.
    static func drawable(_ element: String, _ font: TrueTypeFont) -> Bool {
        if inkless(element) { return true }
        let line = shape(element, font)
        return !line.glyphs.isEmpty && line.glyphs.allSatisfy { $0.font.hasOutline($0.glyph) || inkless($0.text) }
    }
}
