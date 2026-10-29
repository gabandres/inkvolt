import CoreText
import Foundation

/// An installed font that draws characters a page font lacks: the font and its name for the user ("Arial Bold").
struct StandInFont: Sendable, Equatable {
    let font: TrueTypeFont
    let name: String
}

/// Picks the installed font closest to a page font, for characters its embedded subset lacks (paragraph editing,
/// roadmap 2.1; the Windows app's `StandInFonts`): the same family when it is installed (the PDF's name, "Helvetica" as
/// Arial, "Times" as Times New Roman, as on Windows), else the nearest of 14 common macOS families by class (serif, sans,
/// monospaced), then weight and slant, then x-height and the widths of the characters both fonts have. Characters none
/// of them has come from Core Text's fallback for the character (never its last resort); past those, nothing (the
/// character is refused). Faces are found through Core Text's font descriptors (family and symbolic traits); a candidate's
/// class comes from its traits (monospace, the stylistic class) where Core Text knows it, else from the list. Any face
/// works, collections and AAT fonts too: stand-in text is embedded as Type 3 fonts drawn from Core Text's outlines.
enum StandInFonts {
    enum Kind: Sendable { case sans, serif, mono }

    private struct Family: Sendable {
        let name: String
        let kind: Kind
        let aliases: [String]
    }

    /// The Mac's counterparts of the Windows list (Segoe UI, Calibri, Cambria, Constantia, Consolas and Lucida Console
    /// aren't on macOS): the families every Mac has.
    private static let families: [Family] = [
        Family(name: "Arial", kind: .sans, aliases: ["Arial", "Helvetica", "Helv", "Arimo", "Liberation Sans", "Nimbus Sans", "Nimbus Sans L"]),
        Family(name: "Helvetica Neue", kind: .sans, aliases: ["Helvetica Neue"]),
        Family(name: "Verdana", kind: .sans, aliases: ["Verdana", "DejaVu Sans"]),
        Family(name: "Tahoma", kind: .sans, aliases: ["Tahoma"]),
        Family(name: "Trebuchet MS", kind: .sans, aliases: ["Trebuchet MS", "Trebuchet"]),
        Family(name: "Avenir Next", kind: .sans, aliases: ["Avenir Next", "Avenir"]),
        Family(name: "Gill Sans", kind: .sans, aliases: ["Gill Sans", "Gill Sans MT"]),
        Family(name: "Times New Roman", kind: .serif,
               aliases: ["Times New Roman", "Times", "Tinos", "Liberation Serif", "Nimbus Roman", "Nimbus Roman No9 L"]),
        Family(name: "Georgia", kind: .serif, aliases: ["Georgia"]),
        Family(name: "Palatino", kind: .serif, aliases: ["Palatino", "Palatino Linotype", "Book Antiqua", "URW Palladio L"]),
        Family(name: "Baskerville", kind: .serif, aliases: ["Baskerville", "Baskerville Old Face"]),
        Family(name: "Courier New", kind: .mono,
               aliases: ["Courier New", "Courier", "Cousine", "Liberation Mono", "Nimbus Mono", "Nimbus Mono L"]),
        Family(name: "Menlo", kind: .mono, aliases: ["Menlo", "DejaVu Sans Mono", "Bitstream Vera Sans Mono"]),
        Family(name: "Andale Mono", kind: .mono, aliases: ["Andale Mono"]),
    ]

    private static let serifWords = [
        "Times", "Serif", "Roman", "Georgia", "Garamond", "Cambria", "Palatino", "Book", "Minion", "Caslon", "Baskerville", "Bodoni",
        "Century", "Cheltenham", "Constantia", "Didot", "Goudy", "Janson", "Sabon", "Utopia", "Charter", "Bookman", "Schoolbook", "Antiqua",
        "Cochin", "Perpetua", "Rockwell", "Clarendon", "Merriweather", "Lora", "Tiempos", "Source Serif", "Noto Serif", "Libertine", "CMR", "LMRoman",
    ]

    private static let monoWords = ["Mono", "Courier", "Consol", "Code", "Typewriter", "Fixed", "Lucida Console", "Menlo", "Monaco", "CMTT", "LMMono"]

    private static let sansWords = [
        "Sans", "Arial", "Helvetica", "Gothic", "Grotesk", "Verdana", "Tahoma", "Calibri", "Segoe", "Futura", "Frutiger", "Myriad", "Univers", "Gill",
    ]

    /// Lowercase and capitals most text has: what the widths are compared on.
    private static let sample = "etaoinshrdlucmfwypvbgkxqjzETAOINSHRDLUCM0123456789"

    private final class Faces: @unchecked Sendable {
        let lock = NSLock()
        var byStyle: [String: TrueTypeFont?] = [:]
    }

    private static let faces = Faces()

    /// What a page font is like: its class, weight and slant (from its name and descriptor flags).
    static func describe(_ font: TextFont) -> (kind: Kind, bold: Bool, italic: Bool) {
        let family = FontNames.family(font.name)
        func has(_ words: [String]) -> Bool {
            words.contains { font.name.range(of: $0, options: .caseInsensitive) != nil || family.range(of: $0, options: .caseInsensitive) != nil }
        }
        let kind: Kind
        if font.flags & 1 != 0 || has(monoWords) {
            kind = .mono
        } else if has(sansWords) {
            kind = .sans
        } else if font.flags & 2 != 0 || has(serifWords) {
            kind = .serif
        } else {
            kind = .sans
        }
        return (kind, font.bold, font.italic)
    }

    /// Installed fonts in the order they come closest to `font` (its own family first when installed).
    static func rankFor(_ font: TextFont) -> [StandInFont] { rankFor(font, font.bold, font.italic) }

    /// The same, for text of `font` made bold or italic (or not).
    static func rankFor(_ font: TextFont, _ bold: Bool, _ italic: Bool) -> [StandInFont] {
        font.standIns((bold ? 2 : 0) + (italic ? 1 : 0)) { rank(font, bold, italic) }
    }

    /// The installed families a look can name, by name ("Arial", "Georgia"): the ones on this Mac.
    static func installed() -> [String] { families.filter { face($0.name, false, false) != nil }.map(\.name) }

    /// The installed font for text of `font` given a look: `family` when it is one of the families here and installed
    /// (its bold or italic face when it has one), else the closest to the paragraph's font in that style; nil when no
    /// font here can draw it.
    static func styled(_ font: TextFont, _ family: String?, _ bold: Bool, _ italic: Bool) -> StandInFont? {
        if let family, let f = families.first(where: { $0.name.caseInsensitiveCompare(family) == .orderedSame
                                                         || $0.aliases.contains { $0.caseInsensitiveCompare(family) == .orderedSame } }),
           let found = closestFace(f, bold, italic) {
            return found.font
        }
        return rankFor(font, bold, italic).first
    }

    /// A family's face closest to the style asked (its regular one when it has no bold or italic), and how many of bold
    /// and italic it misses; nil when the family isn't installed.
    private static func closestFace(_ f: Family, _ bold: Bool, _ italic: Bool) -> (font: StandInFont, miss: Int)? {
        let tries: [(Bool, Bool)] = [(bold, italic), (bold, false), (false, italic), (false, false)]
        var seen = Set<Int>()
        for (b, i) in tries where seen.insert((b ? 2 : 0) + (i ? 1 : 0)).inserted {
            if let tt = face(f.name, b, i) {
                return (StandInFont(font: tt, name: tt.fullName), (b != bold ? 1 : 0) + (i != italic ? 1 : 0))
            }
        }
        return nil
    }

    /// An installed family's face with exactly the bold and italic asked, the plainest of them (regular weight and
    /// width), through Core Text's descriptors; nil when it has none.
    static func face(_ family: String, _ bold: Bool, _ italic: Bool) -> TrueTypeFont? {
        let key = "\(family)|\(bold)|\(italic)"
        faces.lock.lock()
        if let hit = faces.byStyle[key] {
            faces.lock.unlock()
            return hit
        }
        faces.lock.unlock()
        var found: TrueTypeFont?
        let request = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let mandatory = Set([kCTFontFamilyNameAttribute as String]) as CFSet
        let matches = (CTFontDescriptorCreateMatchingFontDescriptors(request, mandatory) as? [CTFontDescriptor]) ?? []
        var best: (score: Double, descriptor: CTFontDescriptor)?
        for d in matches {
            guard let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [CFString: Any] else { continue }
            let symbolic = CTFontSymbolicTraits(rawValue: (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0)
            guard symbolic.contains(.traitBold) == bold && symbolic.contains(.traitItalic) == italic else { continue }
            let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let width = (traits[kCTFontWidthTrait] as? NSNumber)?.doubleValue ?? 0
            let score = abs(weight - (bold ? 0.4 : 0)) + 2 * abs(width)
            if best == nil || score < best!.score { best = (score, d) }
        }
        if let best { found = SystemFonts.wrap(CTFontCreateWithFontDescriptor(best.descriptor, 1000, nil)) }
        faces.lock.lock()
        faces.byStyle[key] = .some(found)
        faces.lock.unlock()
        return found
    }

    /// A candidate's class from Core Text's traits (monospace, the stylistic class), else the list's.
    private static func kindOf(_ tt: TrueTypeFont, _ listed: Kind) -> Kind {
        let traits = CTFontGetSymbolicTraits(tt.font)
        if traits.contains(.traitMonoSpace) { return .mono }
        // The stylistic class is the top four bits (kCTFontClassMaskShift): 8 sans serif; 1-5 and 7 the serif classes.
        switch traits.rawValue >> 28 {
        case 8: return .sans
        case 1, 2, 3, 4, 5, 7: return .serif
        default: return listed
        }
    }

    private static func rank(_ font: TextFont, _ bold: Bool, _ italic: Bool) -> [StandInFont] {
        let kind = describe(font).kind
        let family = FontNames.family(font.name)
        // The widths the page font gives the sample characters it has (ems).
        var widths: [(cp: UInt32, w: Double)] = []
        for ch in sample.unicodeScalars {
            let enc = font.encode(String(ch))
            if enc.missing.isEmpty, enc.codes.count == 1, enc.codes[0] >= 0, font.hasGlyph(enc.codes[0]) {
                let w = font.widthOf(enc.codes[0])
                if w > 0 { widths.append((ch.value, w / 1000)) }
            }
        }
        var scored: [(score: Double, order: Int, font: StandInFont)] = []
        for (order, f) in families.enumerated() {
            guard let found = closestFace(f, bold, italic) else { continue }
            let face = found.font, styleMiss = found.miss
            let tt = face.font
            var score: Double
            if f.aliases.contains(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) {
                score = -1000 + 10 * Double(styleMiss) // its own family
            } else {
                let theirs = kindOf(tt, f.kind)
                score = (theirs == kind ? 0 : kind == .mono || theirs == .mono ? 200 : 100) + 30 * Double(styleMiss)
                if widths.count >= 3 {
                    let diffs = widths.map { x -> Double in
                        let a = tt.advance(x.cp)
                        return tt.has(x.cp) && a > 0 ? abs(log(x.w / a)) : 0.5
                    }
                    score += 100 * diffs.reduce(0, +) / Double(diffs.count)
                }
                if let xh = font.xHeight, let th = tt.xHeight { score += 100 * abs(log(xh / th)) }
            }
            scored.append((score, order, face))
        }
        return scored.sorted { $0.score != $1.score ? $0.score < $1.score : $0.order < $1.order }.map(\.font)
    }

    /// The font Core Text falls back to for a character when `primary` lacks it (never its last resort); nil when none
    /// here has it.
    static func fallback(_ codePoint: UInt32, _ primary: TrueTypeFont?) -> TrueTypeFont? {
        guard let f = SystemFonts.forCodePoint(codePoint, primary), !f.isLastResort, f.has(codePoint) else { return nil }
        return f
    }

    /// The closest installed font that has every one of `codePoints`; else, for each, the closest that has it or Core
    /// Text's fallback. Characters no font here has are left out of the map.
    static func forCodePoints(_ font: TextFont, _ codePoints: [UInt32]) -> [UInt32: StandInFont] {
        var map: [UInt32: StandInFont] = [:]
        if codePoints.isEmpty { return map }
        let ranked = rankFor(font)
        if let all = ranked.first(where: { f in codePoints.allSatisfy { f.font.has($0) } }) {
            for cp in codePoints { map[cp] = all }
            return map
        }
        for cp in codePoints {
            if let one = ranked.first(where: { $0.font.has(cp) }) {
                map[cp] = one
            } else if let fb = fallback(cp, nil) {
                map[cp] = StandInFont(font: fb, name: fb.fullName)
            }
        }
        return map
    }
}
