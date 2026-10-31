import Foundation

extension AccessibilityCheck {
    /// The CMaps a PDF reader knows without the file embedding them (ISO 32000-1, 9.7.5.2, Table 118).
    static let predefinedCMaps: Set<String> = [
        "GB-EUC-H", "GB-EUC-V", "GBpc-EUC-H", "GBpc-EUC-V", "GBK-EUC-H", "GBK-EUC-V", "GBKp-EUC-H", "GBKp-EUC-V", "GBK2K-H", "GBK2K-V",
        "UniGB-UCS2-H", "UniGB-UCS2-V", "UniGB-UTF16-H", "UniGB-UTF16-V", "B5pc-H", "B5pc-V", "HKscs-B5-H", "HKscs-B5-V", "ETen-B5-H",
        "ETen-B5-V", "ETenms-B5-H", "ETenms-B5-V", "CNS-EUC-H", "CNS-EUC-V", "UniCNS-UCS2-H", "UniCNS-UCS2-V", "UniCNS-UTF16-H",
        "UniCNS-UTF16-V", "83pv-RKSJ-H", "90ms-RKSJ-H", "90ms-RKSJ-V", "90msp-RKSJ-H", "90msp-RKSJ-V", "90pv-RKSJ-H", "Add-RKSJ-H",
        "Add-RKSJ-V", "EUC-H", "EUC-V", "Ext-RKSJ-H", "Ext-RKSJ-V", "H", "V", "UniJIS-UCS2-H", "UniJIS-UCS2-V", "UniJIS-UCS2-HW-H",
        "UniJIS-UCS2-HW-V", "UniJIS-UTF16-H", "UniJIS-UTF16-V", "KSC-EUC-H", "KSC-EUC-V", "KSCms-UHC-H", "KSCms-UHC-V", "KSCms-UHC-HW-H",
        "KSCms-UHC-HW-V", "KSCpc-EUC-H", "UniKS-UCS2-H", "UniKS-UCS2-V", "UniKS-UTF16-H", "UniKS-UTF16-V", "Identity-H", "Identity-V",
    ]

    /// The character collection a predefined CMap uses ("Japan1"), or nil for Identity.
    static func orderingOf(_ cmap: String) -> String? {
        if cmap == "Identity-H" || cmap == "Identity-V" { return nil }
        if cmap.contains("GB") { return "GB1" }
        if cmap.contains("CNS") || cmap.contains("B5") { return "CNS1" }
        if cmap.contains("KS") { return "Korea1" }
        return "Japan1"
    }

    /// The number in the first `/WMode <n> def` of a CMap's data; nil when there is none, 0 when it is too long to be one
    /// (Windows notes that font as unreadable).
    static func wMode(_ b: [UInt8]) -> Int? {
        func isSpace(_ c: UInt8) -> Bool { c == 32 || (9...13).contains(c) }
        let mark = Array("/WMode".utf8), def = Array("def".utf8)
        var i = 0
        while i + mark.count < b.count {
            guard b[i] == mark[0], b[i..<i + mark.count].elementsEqual(mark) else {
                i += 1
                continue
            }
            var p = i + mark.count
            let spaces = p
            while p < b.count && isSpace(b[p]) { p += 1 }
            let digits = p
            while p < b.count && (48...57).contains(b[p]) { p += 1 }
            let end = p
            while p < b.count && isSpace(b[p]) { p += 1 }
            if digits > spaces && end > digits && p > end && p + 3 <= b.count && b[p..<p + 3].elementsEqual(def) {
                return Int(String(decoding: b[digits..<end], as: UTF8.self)) ?? 0
            }
            i += mark.count
        }
        return nil
    }
}

extension AccessibilityChecker {
    func checkFonts() throws {
        for use in fontOrder {
            try cancel.check()
            font(use)
        }
    }

    private static func fontName(_ font: PObj) -> String {
        if let n = font.name("BaseFont"), !n.isEmpty { return n }
        return "(unnamed)"
    }

    private static func isSubset(_ name: String) -> Bool {
        let u = Array(name.utf8)
        return u.count > 7 && u[6] == 43 && u[0..<6].allSatisfy { (65...90).contains($0) }
    }

    private static func embedded(_ descriptor: PObj?) -> Bool {
        guard let descriptor else { return false }
        return descriptor.has("FontFile") || descriptor.has("FontFile2") || descriptor.has("FontFile3")
    }

    /// `(^|\+)(ZapfDingbats|Symbol)`.
    private static func isSymbolName(_ name: String) -> Bool {
        name.hasPrefix("ZapfDingbats") || name.hasPrefix("Symbol") || name.contains("+ZapfDingbats") || name.contains("+Symbol")
    }

    private func font(_ use: AccessibilityFontUse) {
        let font = use.font
        let name = Self.fontName(font)
        func fail(_ condition: String, _ problem: String) { add(condition, problem, page: use.page, box: use.box, element: "Font \(name)") }

        let subtype = font.name("Subtype") ?? ""
        let cid = subtype == "Type0" ? font.array("DescendantFonts")?[0].flatMap { $0.isDict ? $0 : nil } : nil
        let descriptor = (cid ?? font).dict("FontDescriptor")
        let embedded = Self.embedded(descriptor)
        let tf = textFont(font)
        let flags = descriptor?.int("Flags") ?? 0
        let symbolic = flags & 4 != 0

        if subtype != "Type3" && !use.shown.isEmpty && !embedded {
            fail("31-009", "The font \(name) isn't embedded, so the text may show in another font, or not at all, on other computers.")
        }

        // Glyph by glyph.
        var missing = 0, notdef = 0, unmapped = 0, zero = 0, bom = 0, widths = 0
        // A font of one of the Adobe CJK collections (its own or its CMap's) gets its characters from the collection.
        let collections: Set<String> = ["GB1", "CNS1", "Japan1", "Korea1"]
        let ordering = cid.flatMap { Self.text($0.dict("CIDSystemInfo")?["Ordering"]) }
        var cmapOrdering: String?
        if cid != nil, let e = font["Encoding"] {
            if e.kind == .name {
                cmapOrdering = e.name.flatMap(AccessibilityCheck.orderingOf)
            } else if e.isDict {
                cmapOrdering = Self.text(e.dict("CIDSystemInfo")?["Ordering"])
            }
        }
        let collection = ordering.map { collections.contains($0) } == true || cmapOrdering.map { collections.contains($0) } == true
        // A symbolic Type 1 font without an Encoding uses its program's own: a CFF program's isn't read here (its glyphs
        // and characters aren't judged), and without a program nothing tells which glyph or character a code is.
        let ownEncoding = (subtype == "Type1" || subtype == "MMType1") && !font.has("Encoding") && !(tf.program is Type1Program)
            && (symbolic || (descriptor == nil && Self.isSymbolName(name)))
        // A composite font with a CMap other than Identity: its codes aren't its CIDs, and CMaps aren't read here, so its
        // glyphs and widths aren't judged (its characters still are, through ToUnicode).
        let encodingName = font.name("Encoding")
        let cidCodes = cid == nil || encodingName == "Identity-H" || encodingName == "Identity-V"
        for code in use.codes where code >= 0 {
            let shown = use.shown.contains(code) && cidCodes
            if ownEncoding && tf.toUnicodeOf(code) == nil {
                if !embedded { unmapped += 1 }
                continue
            }
            if shown, embedded, subtype != "Type3", let program = tf.program {
                if let tt = program as? TrueTypeProgram {
                    let gid = tf.glyphIdOf(code)
                    if gid == 0 {
                        notdef += 1
                    } else if gid < 0 || gid >= tt.numGlyphs {
                        missing += 1
                    }
                } else if let cff = program as? CffProgram, cff.isCid {
                    if code == 0 {
                        notdef += 1
                    } else if !cff.hasCid(code) {
                        missing += 1
                    }
                } else if let glyph = tf.glyphNameOf(code) {
                    if glyph == ".notdef" {
                        notdef += 1
                    } else if let t1 = program as? Type1Program {
                        if !t1.hasName(glyph) { missing += 1 }
                    } else if let cff = program as? CffProgram, !cff.hasName(glyph) {
                        missing += 1
                    }
                }
            } else if !embedded && tf.glyphNameOf(code) == ".notdef" {
                notdef += 1
            }
            let raw = tf.toUnicodeOf(code)
            if tf.unicodeOf(code) == nil && !(collection && raw == nil) { unmapped += 1 }
            if let raw {
                if raw.unicodeScalars.contains("\0") { zero += 1 }
                if raw.unicodeScalars.contains("\u{FEFF}") || raw.unicodeScalars.contains("\u{FFFE}") { bom += 1 }
            }
            if shown, let dw = tf.dictionaryWidth(code), let pw = tf.programWidth(code), abs(dw - pw) > 1 { widths += 1 }
        }
        if missing > 0 { fail("31-011", "The embedded font \(name) lacks \(Self.count(missing, "glyph")) the text uses, so \(missing == 1 ? "that character" : "those characters") can't be drawn as meant.") }
        if notdef > 0 { fail("31-030", "Text in the font \(name) draws the .notdef glyph (an empty box) \(Self.count(notdef, "time")): those characters aren't in the font.") }
        if unmapped > 0 {
            fail("31-027", "\(Self.count(unmapped, "character")) in the font \(name) can't be turned into text (no ToUnicode entry or known glyph name), so screen readers can't read \(unmapped == 1 ? "it" : "them").")
        }
        if zero > 0 { fail("31-028", "The font \(name)'s ToUnicode map gives \(Self.count(zero, "character")) the value 0.") }
        if bom > 0 { fail("31-029", "The font \(name)'s ToUnicode map gives \(Self.count(bom, "character")) the value U+FEFF or U+FFFE.") }
        if widths > 0 { fail("31-016", "\(Self.count(widths, "glyph")) of the font \(name) \(widths == 1 ? "has" : "have") a different width in the PDF than in the font itself.") }

        if subtype == "TrueType" {
            trueType(font, tf, symbolic, embedded, name, fail)
        } else if subtype == "Type0" {
            composite(font, cid, descriptor, tf, embedded, name, fail)
        } else if subtype == "Type1" || subtype == "MMType1", embedded, Self.isSubset(name), let charSet = Self.text(descriptor?["CharSet"]) {
            let listed = Set(charSet.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            var held: Set<String>?
            if let t1 = tf.program as? Type1Program {
                held = t1.names
            } else if let cff = tf.program as? CffProgram, !cff.isCid {
                held = cff.names
            }
            if let held {
                let absent = held.filter { $0 != ".notdef" && !listed.contains($0) }.prefix(3)
                let extra = listed.filter { $0 != ".notdef" && !held.contains($0) }.prefix(3)
                if !absent.isEmpty { fail("31-012", "The font \(name)'s CharSet doesn't list every glyph in it (such as \(absent.joined(separator: ", "))).") }
                if !extra.isEmpty { fail("31-013", "The font \(name)'s CharSet lists glyphs it doesn't have (such as \(extra.joined(separator: ", "))).") }
            }
        }
    }

    private func trueType(_ font: PObj, _ tf: TextFont, _ symbolic: Bool, _ embedded: Bool, _ name: String, _ fail: (String, String) -> Void) {
        let encoding = font["Encoding"]
        let tt = embedded ? tf.program as? TrueTypeProgram : nil
        let cmaps = tt?.cmapCount ?? 0
        let has30 = tt?.hasCmap(3, 0) == true
        if !symbolic {
            if tt != nil && !(has30 ? cmaps > 1 : cmaps > 0) {
                fail("31-017", "The TrueType font \(name) has no Unicode (3,1) or Mac (1,0) character map, so its glyphs can't be looked up.")
            }
            guard let encoding, encoding.kind != .null else {
                fail("31-019", "The TrueType font \(name) has no Encoding.")
                return
            }
            if encoding.kind == .name {
                let n = encoding.name ?? ""
                if n != "WinAnsiEncoding" && n != "MacRomanEncoding" { fail("31-021", "The TrueType font \(name)'s encoding is \(n), not WinAnsi or MacRoman.") }
            } else if encoding.isDict {
                if let base = encoding.name("BaseEncoding") {
                    if base != "WinAnsiEncoding" && base != "MacRomanEncoding" { fail("31-021", "The TrueType font \(name)'s base encoding is \(base), not WinAnsi or MacRoman.") }
                } else {
                    fail("31-020", "The TrueType font \(name)'s Encoding has no base encoding (WinAnsi or MacRoman).")
                }
                if let diffs = encoding.array("Differences") {
                    let odd = diffs.elements.lazy.compactMap(\.name).filter { $0 != ".notdef" && GlyphNames.toUnicode($0) == nil }.prefix(3)
                    if !odd.isEmpty { fail("31-022", "The TrueType font \(name)'s Differences name glyphs outside the Adobe Glyph List (such as \(odd.joined(separator: ", "))).") }
                }
            }
        } else {
            if encoding != nil && encoding?.kind != .null { fail("31-024", "The symbolic TrueType font \(name) has an Encoding, which symbolic TrueType fonts mustn't have.") }
            if tt != nil && cmaps != 1 && !has30 {
                fail(cmaps == 0 ? "31-025" : "31-026", cmaps == 0
                    ? "The symbolic TrueType font \(name) has no character map (cmap)."
                    : "The symbolic TrueType font \(name) has several character maps but no Windows Symbol (3,0) one.")
            }
        }
    }

    private func composite(_ font: PObj, _ cid: PObj?, _ descriptor: PObj?, _ tf: TextFont, _ embedded: Bool, _ name: String, _ fail: (String, String) -> Void) {
        var cmapRegistry: String?, cmapOrdering: String?
        var cmapSupplement: Int?
        var identity = false
        if let encoding = font["Encoding"] {
            if encoding.kind == .name {
                let cmap = encoding.name ?? ""
                identity = cmap == "Identity-H" || cmap == "Identity-V"
                if !AccessibilityCheck.predefinedCMaps.contains(cmap) {
                    fail("31-006", "The font \(name) uses the CMap \(cmap), which is neither a standard one nor embedded.") // its collection is unknown too
                } else if !identity {
                    cmapRegistry = "Adobe"
                    cmapOrdering = AccessibilityCheck.orderingOf(cmap)
                }
            } else if encoding.isStream {
                let info = encoding.dict("CIDSystemInfo")
                cmapRegistry = Self.text(info?["Registry"])
                cmapOrdering = Self.text(info?["Ordering"])
                cmapSupplement = info?.int("Supplement")
                let dictMode = encoding.int("WMode") ?? 0
                if (AccessibilityCheck.wMode(encoding.streamData ?? []) ?? 0) != dictMode {
                    fail("31-007", "The font \(name)'s embedded CMap gives two different writing modes (WMode).")
                }
                if let used = encoding["UseCMap"], used.kind == .name, let n = used.name, !AccessibilityCheck.predefinedCMaps.contains(n) {
                    fail("31-008", "The font \(name)'s CMap uses the CMap \(n), which isn't a standard one.")
                }
            }
        }
        guard let cid else { return }
        if !identity {
            let info = cid.dict("CIDSystemInfo")
            let registry = Self.text(info?["Registry"]), ordering = Self.text(info?["Ordering"])
            if registry != cmapRegistry { fail("31-001", "The font \(name)'s character collection registry (\(registry ?? "none")) differs from its CMap's (\(cmapRegistry ?? "none")).") }
            if ordering != cmapOrdering { fail("31-002", "The font \(name)'s character collection ordering (\(ordering ?? "none")) differs from its CMap's (\(cmapOrdering ?? "none")).") }
            if let s = info?.int("Supplement"), let cs = cmapSupplement, s > cs { fail("31-003", "The font \(name)'s character collection supplement (\(s)) is higher than its CMap's (\(cs)).") }
        }
        let cidType = cid.name("Subtype")
        let map = cid["CIDToGIDMap"]
        if cidType == "CIDFontType2" && embedded {
            if map == nil || map?.kind == .null {
                fail("31-005", "The TrueType CID font \(name) has no glyph map (CIDToGIDMap).")
            } else if map?.isStream != true && map?.name != "Identity" {
                fail("31-004", "The TrueType CID font \(name)'s glyph map (CIDToGIDMap) is neither a stream nor Identity.")
            }
        }

        // A subset's CIDSet must list every glyph the program holds.
        guard embedded, Self.isSubset(name), let cidSet = descriptor?.dict("CIDSet"), cidSet.isStream else { return }
        let bits = cidSet.streamData ?? []
        func listed(_ c: Int) -> Bool { c / 8 < bits.count && bits[c / 8] & (0x80 >> UInt8(c % 8)) != 0 }
        // The CIDs the program holds (.notdef left out): a CFF program's charset; a TrueType program's every glyph slot
        // reached through the glyph map (subsets that keep empty slots count them, as veraPDF does). Past `limit` it holds none.
        let holds: (Int) -> Bool
        let limit: Int
        var unlisted = 0
        switch tf.program {
        case let cff as CffProgram where cff.isCid:
            holds = { cff.hasCid($0) }
            limit = (cff.cids.max() ?? 0) + 1
            unlisted = cff.cids.filter { $0 != 0 && !listed($0) }.count
        case let tt as TrueTypeProgram where cidType == "CIDFontType2":
            if let ms = map, ms.isStream {
                let b = ms.streamData ?? []
                let count = b.count / 2
                let numGlyphs = tt.numGlyphs
                holds = { $0 > 0 && $0 < count && (Int(b[2 * $0]) << 8 | Int(b[2 * $0 + 1])) < numGlyphs }
                limit = count
            } else {
                let numGlyphs = tt.numGlyphs
                holds = { $0 > 0 && $0 < numGlyphs }
                limit = numGlyphs
            }
            if limit > 1 { unlisted = (1..<limit).filter { holds($0) && !listed($0) }.count }
        default:
            return
        }
        // Everything listed past `limit` is extra, whatever its number: counted by bytes, so a crafted set of a gigabyte is quick.
        let total = bits.count * 8
        var extra = 0
        var c = 1
        while c < total {
            if c % 8 == 0 && bits[c / 8] == 0 {
                c += 8
            } else if c >= limit && c % 8 == 0 {
                extra += bits[c / 8].nonzeroBitCount
                c += 8
            } else {
                if listed(c) && !holds(c) { extra += 1 }
                c += 1
            }
        }
        if unlisted > 0 { fail("31-014", "The font \(name)'s CIDSet doesn't list \(Self.count(unlisted, "glyph")) that the font holds.") }
        if extra > 0 { fail("31-015", "The font \(name)'s CIDSet lists \(Self.count(extra, "glyph")) that the font doesn't hold.") }
    }
}
