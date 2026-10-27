import Foundation

/// The part of the Unicode bidirectional algorithm (UAX #9) single-line text needs (the Windows app's `Bidi`): the
/// paragraph level from the first strong character, weak-type rules W1–W7 (numbers stay left-to-right inside
/// right-to-left text), neutral rules N1–N2, implicit levels I1–I2 and the trailing-whitespace reset L1. Explicit
/// embeddings, overrides and isolates are not handled (their control characters are treated as ignorable). Core Text
/// lays the runs out (`TextShaper`); these levels decide a line's paragraph direction.
enum Bidi {
    enum Cls: UInt8 { case L, R, AL, EN, ES, ET, AN, CS, NSM, BN, WS, ON }

    /// The embedding level of every UTF-16 unit of `text`, and the paragraph level (0 = left to right, 1 = right to left).
    static func levels(_ text: String, paragraphLevel: Int? = nil) -> (levels: [UInt8], paragraph: Int) {
        let units = Array(text.utf16)
        let n = units.count
        var types = [Cls](repeating: .ON, count: n)
        var i = 0
        while i < n {
            if UTF16.isLeadSurrogate(units[i]), i + 1 < n, UTF16.isTrailSurrogate(units[i + 1]) {
                let cp = 0x10000 + ((UInt32(units[i]) - 0xD800) << 10) + (UInt32(units[i + 1]) - 0xDC00)
                types[i] = classify(cp)
                types[i + 1] = types[i]
                i += 2
            } else {
                types[i] = classify(UInt32(units[i]))
                i += 1
            }
        }
        let original = types

        let para = paragraphLevel ?? firstStrong(types)
        let e: Cls = para % 2 == 0 ? .L : .R

        // W1 (and X9: boundary neutrals and joiners take the previous type)
        var prev = e
        for k in 0..<n {
            if types[k] == .NSM || types[k] == .BN { types[k] = prev }
            prev = types[k]
        }
        // W2, W3
        var lastStrong = e
        for k in 0..<n {
            switch types[k] {
            case .L, .R, .AL: lastStrong = types[k]
            case .EN where lastStrong == .AL: types[k] = .AN
            default: break
            }
        }
        for k in 0..<n where types[k] == .AL { types[k] = .R }
        // W4
        if n > 2 {
            for k in 1..<(n - 1) {
                if types[k] == .ES && types[k - 1] == .EN && types[k + 1] == .EN {
                    types[k] = .EN
                } else if types[k] == .CS && types[k - 1] == types[k + 1] && (types[k - 1] == .EN || types[k - 1] == .AN) {
                    types[k] = types[k - 1]
                }
            }
        }
        // W5
        var k = 0
        while k < n {
            if types[k] != .ET {
                k += 1
                continue
            }
            var j = k
            while j < n && types[j] == .ET { j += 1 }
            if (k > 0 && types[k - 1] == .EN) || (j < n && types[j] == .EN) {
                for m in k..<j { types[m] = .EN }
            }
            k = j
        }
        // W6
        for m in 0..<n where types[m] == .ES || types[m] == .ET || types[m] == .CS { types[m] = .ON }
        // W7
        lastStrong = e
        for m in 0..<n {
            if types[m] == .L || types[m] == .R {
                lastStrong = types[m]
            } else if types[m] == .EN && lastStrong == .L {
                types[m] = .L
            }
        }
        // N1, N2: EN and AN act as R.
        func dir(_ c: Cls) -> Cls { c == .L ? .L : .R }
        k = 0
        while k < n {
            if types[k] != .WS && types[k] != .ON {
                k += 1
                continue
            }
            var j = k
            while j < n && (types[j] == .WS || types[j] == .ON) { j += 1 }
            let before = k == 0 ? e : dir(types[k - 1])
            let after = j == n ? e : dir(types[j])
            let resolved = before == after ? before : e
            for m in k..<j { types[m] = resolved }
            k = j
        }
        // I1, I2
        var levels = [UInt8](repeating: 0, count: n)
        for m in 0..<n {
            let level: Int
            if para % 2 == 0 {
                switch types[m] {
                case .R: level = para + 1
                case .AN, .EN: level = para + 2
                default: level = para
                }
            } else {
                switch types[m] {
                case .L, .EN, .AN: level = para + 1
                default: level = para
                }
            }
            levels[m] = UInt8(level)
        }
        // L1: trailing whitespace goes back to the paragraph level.
        var m = n - 1
        while m >= 0 && (original[m] == .WS || original[m] == .BN) {
            levels[m] = UInt8(para)
            m -= 1
        }
        return (levels, para)
    }

    private static func firstStrong(_ types: [Cls]) -> Int {
        for t in types {
            if t == .L { return 0 }
            if t == .R || t == .AL { return 1 }
        }
        return 0
    }

    /// Whether the text starts (its first strong character) right to left.
    static func isRtl(_ text: String) -> Bool { levels(text).paragraph == 1 }

    static func classify(_ cp: UInt32) -> Cls {
        switch cp {
        case 0x30...0x39: return .EN
        case 0x0660...0x0669, 0x066B, 0x066C: return .AN
        case 0x06F0...0x06F9: return .EN
        case 0x2B, 0x2D, 0x2212: return .ES
        case 0x23, 0x24, 0x25, 0xA2...0xA5, 0xB0, 0xB1, 0x066A, 0x2030, 0x20A0...0x20CF: return .ET
        case 0x2C, 0x2E, 0x2F, 0x3A, 0xA0, 0x060C, 0x202F: return .CS
        case 0x200E: return .L
        case 0x200F: return .R
        case 0x061C: return .AL
        case 0x200B, 0x200C, 0x200D, 0xFEFF, 0x202A...0x202E, 0x2066...0x2069, 0xAD: return .BN
        default: break
        }
        guard let scalar = Unicode.Scalar(cp) else { return .ON }
        let cat = scalar.properties.generalCategory
        if cat == .nonspacingMark || cat == .enclosingMark { return .NSM }
        if cat == .spaceSeparator || cat == .lineSeparator || cat == .paragraphSeparator || cp == 9 { return .WS }
        switch cp {
        case 0x0600...0x07BF, 0x0860...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF, 0x1EC70...0x1EEFF: return .AL
        case 0x0590...0x05FF, 0x07C0...0x085F, 0xFB1D...0xFB4F, 0x10800...0x10FFF, 0x1E800...0x1EC6F: return .R
        default: break
        }
        switch cat {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .spacingMark, .decimalNumber,
             .letterNumber, .privateUse:
            return .L
        case .otherNumber: return .EN
        case .control, .format: return .BN
        default: return .ON
        }
    }
}
