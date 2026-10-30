import Foundation

/// What the glyphs of TeX's fonts are, as text (the Windows app's `TexGlyphs`): the names Computer Modern and the AMS fonts
/// give glyphs outside the Adobe Glyph List (parenleftbig, summationdisplay, arrowhookleft…; a big delimiter or operator
/// reads as its base character, a piece of an extensible one as the Unicode piece), and the TeX math encodings (OML for
/// CMMI, OMS for CMSY, OMX for CMEX) for fonts whose glyphs have no names in the PDF. Make Accessible writes them into a
/// ToUnicode CMap (`FontUnicode`), so the pdfTeX papers' math reads aloud and passes Matterhorn 31-027.
enum TexGlyphs {
    // Names outside the Adobe Glyph List (or that it maps into the Private Use Area), with the character TeX means.
    private static let names =
        // CMMI (OML)
        "epsilon1 3B5 pi1 3D6 rho1 3F1 arrowlefttophalf 21BC arrowleftbothalf 21BD arrowrighttophalf 21C0 arrowrightbothalf 21C1 "
        + "arrowhookleft 21AA arrowhookright 21A9 triangleright 25B7 triangleleft 25C1 zerooldstyle 30 oneoldstyle 31 twooldstyle 32 "
        + "threeoldstyle 33 fouroldstyle 34 fiveoldstyle 35 sixoldstyle 36 sevenoldstyle 37 eightoldstyle 38 nineoldstyle 39 "
        + "star 22C6 flat 266D natural 266E sharp 266F slurbelow 2323 slurabove 2322 lscript 2113 dotlessj 237 vector 20D7 tie 2040 "
        // CMSY (OMS)
        + "diamondmath 22C4 minusplus 2213 circleminus 2296 circledivide 2298 circledot 2299 circlecopyrt 25EF equivasymptotic 224D "
        + "precedesequal 2AAF followsequal 2AB0 lessmuch 226A greatermuch 226B precedes 227A follows 227B arrownortheast 2197 "
        + "arrowsoutheast 2198 similarequal 2243 arrownorthwest 2196 arrowsouthwest 2199 prime 2032 owner 220B triangle 25B3 "
        + "triangleinv 25BD negationslash 338 mapsto 21A6 Rfractur 211C Ifractur 2111 latticetop 22A4 unionmulti 228E "
        + "turnstileleft 22A2 turnstileright 22A3 floorleft 230A floorright 230B ceilingleft 2308 ceilingright 2309 "
        + "angbracketleft 27E8 angbracketright 27E9 bardbl 2225 arrowbothv 2195 arrowdblbothv 21D5 wreathproduct 2240 "
        + "coproduct 2210 nabla 2207 unionsq 2294 intersectionsq 2293 subsetsqequal 2291 supersetsqequal 2292 contintegral 222E "
        // CMEX (OMX) pieces
        + "vextendsingle 2223 vextenddouble 2225 radicalbt 23B7 radicalvertex 2502 radicaltp 250C arrowvertexdbl 2016 arrowtp 2191 "
        + "arrowbt 2193 arrowdbltp 21D1 arrowdblbt 21D3 bracehtipdownleft 23DE bracehtipdownright 23DE bracehtipupleft 23DF "
        + "bracehtipupright 23DF "
        // OT1 text fonts
        + "suppress 337 visiblespace 2423 cwm 200C "
        // AMS symbols (MSAM, MSBM) most used
        + "square 25A1 squaresolid 25A0 checkmark 2713 maltese 2720 Finv 2132 Game 2141 planckover2pi 210F planckover2pi1 210F "
        + "lessorequalslant 2A7D greaterorequalslant 2A7E notlessequal 2270 notgreaterequal 2271 notsubseteql 2288 notsupersetequal 2289 "
        + "therefore 2234 because 2235 emptysetstroke 2205"

    /// Big operators (CMEX's text and display sizes): the n-ary character, not the binary one.
    private static let bigOperators =
        "unionsq 2A06 circledot 2A00 circleplus 2A01 circlemultiply 2A02 union 22C3 intersection 22C2 unionmulti 2A04 "
        + "logicaland 22C0 logicalor 22C1 summation 2211 product 220F coproduct 2210 integral 222B contintegral 222E"

    private static let byName = read(names)
    private static let operators = read(bigOperators)

    private static func read(_ list: String) -> [String: String] {
        let parts = list.split(separator: " ").map(String.init)
        var map: [String: String] = [:]
        var i = 0
        while i + 1 < parts.count {
            if let v = UInt32(parts[i + 1], radix: 16), let u = Unicode.Scalar(v) { map[parts[i]] = String(Character(u)) }
            i += 2
        }
        return map
    }

    private static let sizedPattern = try! NSRegularExpression(pattern: "^([A-Za-z]+?)(big|Big|bigg|Bigg|text|display|wide|wider|widest)$")
    private static let familyPattern = try! NSRegularExpression(pattern: #"^(?:[A-Z]{6}\+)?(CMMIB?|CMB?SY|CMEX)\d+$"#)

    private static func groups(_ regex: NSRegularExpression, _ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    /// The text a glyph name stands for: the Adobe Glyph List's (`GlyphNames`), else TeX's; nil when unknown.
    static func toUnicode(_ name: String) -> String? {
        if let agl = GlyphNames.toUnicode(name) { return agl }
        if let tex = byName[name] { return tex }
        // CMEX's sizes: parenleftbig … parenleftBigg, summationtext/display, hatwide/wider/widest.
        if let m = groups(sizedPattern, name) {
            let root = m[1], size = m[2]
            if size == "text" || size == "display", let op = operators[root] { return op }
            if size.hasPrefix("wide") { return root == "hat" ? "\u{302}" : root == "tilde" ? "\u{303}" : nil }
            return GlyphNames.toUnicode(root) ?? byName[root]
        }
        return nil
    }

    /// The glyph name of `code` in a TeX math font's own encoding, by its name (CMMI, CMMIB: OML; CMSY, CMBSY: OMS; CMEX:
    /// OMX; a subset's "ABCDEF+" prefix allowed), or nil for other fonts and codes outside 0-127.
    static func nameIn(_ baseFont: String, _ code: Int) -> String? {
        guard (0...127).contains(code), let m = groups(familyPattern, baseFont) else { return nil }
        switch m[1] {
        case "CMMI", "CMMIB": return oml[code]
        case "CMSY", "CMBSY": return oms[code]
        default: return omx[code]
        }
    }

    private static let oml = vector(
        "Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega alpha beta gamma delta epsilon1 zeta eta theta iota kappa "
            + "lambda mu nu xi pi rho sigma tau upsilon phi chi psi omega epsilon theta1 pi1 rho1 sigma1 phi1 arrowlefttophalf "
            + "arrowleftbothalf arrowrighttophalf arrowrightbothalf arrowhookleft arrowhookright triangleright triangleleft zerooldstyle "
            + "oneoldstyle twooldstyle threeoldstyle fouroldstyle fiveoldstyle sixoldstyle sevenoldstyle eightoldstyle nineoldstyle "
            + "period comma less slash greater star partialdiff A B C D E F G H I J K L M N O P Q R S T U V W X Y Z flat natural sharp "
            + "slurbelow slurabove lscript a b c d e f g h i j k l m n o p q r s t u v w x y z dotlessi dotlessj weierstrass vector tie")

    private static let oms = vector(
        "minus periodcentered multiply asteriskmath divide diamondmath plusminus minusplus circleplus circleminus circlemultiply "
            + "circledivide circledot circlecopyrt openbullet bullet equivasymptotic equivalence reflexsubset reflexsuperset lessequal "
            + "greaterequal precedesequal followsequal similar approxequal propersubset propersuperset lessmuch greatermuch precedes "
            + "follows arrowleft arrowright arrowup arrowdown arrowboth arrownortheast arrowsoutheast similarequal arrowdblleft "
            + "arrowdblright arrowdblup arrowdbldown arrowdblboth arrownorthwest arrowsouthwest proportional prime infinity element "
            + "owner triangle triangleinv negationslash mapsto universal existential logicalnot emptyset Rfractur Ifractur latticetop "
            + "perpendicular aleph A B C D E F G H I J K L M N O P Q R S T U V W X Y Z union intersection unionmulti logicaland "
            + "logicalor turnstileleft turnstileright floorleft floorright ceilingleft ceilingright braceleft braceright angbracketleft "
            + "angbracketright bar bardbl arrowbothv arrowdblbothv backslash wreathproduct radical coproduct nabla integral unionsq "
            + "intersectionsq subsetsqequal supersetsqequal section dagger daggerdbl paragraph club diamond heart spade")

    private static let omx = vector(
        "parenleftbig parenrightbig bracketleftbig bracketrightbig floorleftbig floorrightbig ceilingleftbig ceilingrightbig "
            + "braceleftbig bracerightbig angbracketleftbig angbracketrightbig vextendsingle vextenddouble slashbig backslashbig "
            + "parenleftBig parenrightBig parenleftbigg parenrightbigg bracketleftbigg bracketrightbigg floorleftbigg floorrightbigg "
            + "ceilingleftbigg ceilingrightbigg braceleftbigg bracerightbigg angbracketleftbigg angbracketrightbigg slashbigg "
            + "backslashbigg parenleftBigg parenrightBigg bracketleftBigg bracketrightBigg floorleftBigg floorrightBigg ceilingleftBigg "
            + "ceilingrightBigg braceleftBigg bracerightBigg angbracketleftBigg angbracketrightBigg slashBigg backslashBigg slashBig "
            + "backslashBig parenlefttp parenrighttp bracketlefttp bracketrighttp bracketleftbt bracketrightbt bracketleftex "
            + "bracketrightex bracelefttp bracerighttp braceleftbt bracerightbt braceleftmid bracerightmid braceex arrowvertex "
            + "parenleftbt parenrightbt parenleftex parenrightex angbracketleftBig angbracketrightBig unionsqtext unionsqdisplay "
            + "contintegraltext contintegraldisplay circledottext circledotdisplay circleplustext circleplusdisplay circlemultiplytext "
            + "circlemultiplydisplay summationtext producttext integraltext uniontext intersectiontext unionmultitext logicalandtext "
            + "logicalortext summationdisplay productdisplay integraldisplay uniondisplay intersectiondisplay unionmultidisplay "
            + "logicalanddisplay logicalordisplay coproducttext coproductdisplay hatwide hatwider hatwidest tildewide tildewider "
            + "tildewidest bracketleftBig bracketrightBig floorleftBig floorrightBig ceilingleftBig ceilingrightBig braceleftBig "
            + "bracerightBig radicalbig radicalBig radicalbigg radicalBigg radicalbt radicalvertex radicaltp arrowvertexdbl arrowtp "
            + "arrowbt bracehtipdownleft bracehtipdownright bracehtipupleft bracehtipupright arrowdbltp arrowdblbt")

    private static func vector(_ names: String) -> [String] {
        let v = names.split(separator: " ").map(String.init)
        precondition(v.count == 128, "A TeX encoding has \(v.count) names, not 128.")
        return v
    }
}
