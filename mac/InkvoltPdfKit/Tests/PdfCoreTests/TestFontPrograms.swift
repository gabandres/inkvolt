import Foundation

/// Font programs built byte by byte for the width checks (the Windows tests' `TestFontPrograms`): a CFF (name-keyed or
/// CID-keyed, with Private DICTs, local subroutines and FontMatrix) and a Type 1 program whose charstrings set their
/// widths with hsbw.
enum TestFontPrograms {
    /// A part of a charstring: a number or an operator.
    enum Part: ExpressibleByIntegerLiteral {
        case n(Int)
        case op(UInt8)
        init(integerLiteral v: Int) { self = .n(v) }
    }

    // Type 2 charstring operators used here.
    static let hStem = Part.op(1), callSubr = Part.op(10), `return` = Part.op(11), endChar = Part.op(14), rMoveTo = Part.op(21)

    /// A number as a Type 2 (and Type 1) charstring encodes it.
    static func num(_ v: Int) -> [UInt8] {
        switch v {
        case -107...107: return [UInt8(v + 139)]
        case 108...1131: return [UInt8(247 + (v - 108) / 256), UInt8((v - 108) % 256)]
        case -1131 ... -108: return [UInt8(251 + (-v - 108) / 256), UInt8((-v - 108) % 256)]
        default: return [28, UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
        }
    }

    /// A charstring from numbers and operators.
    static func cs(_ parts: Part...) -> [UInt8] { cs(parts) }

    static func cs(_ parts: [Part]) -> [UInt8] {
        parts.flatMap { p -> [UInt8] in
            switch p {
            case .n(let i): return num(i)
            case .op(let o): return [o]
            }
        }
    }

    private static func index(_ items: [[UInt8]]) -> [UInt8] {
        if items.isEmpty { return [0, 0] }
        var o: [UInt8] = [UInt8(items.count >> 8), UInt8(items.count & 255), 4]
        var off = 1
        o += int32(off)
        for it in items {
            off += it.count
            o += int32(off)
        }
        for it in items { o += it }
        return o
    }

    private static func int32(_ v: Int) -> [UInt8] {
        [UInt8(truncatingIfNeeded: v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    /// A DICT integer, always 5 bytes, so offsets can be filled in after the sizes are known.
    private static func int(_ v: Int) -> [UInt8] { [29] + int32(v) }

    /// A DICT real ("0.0005", "-1.5E-3").
    private static func real(_ s: String) -> [UInt8] {
        let chars = Array(s)
        var nibbles: [Int] = []
        for (i, c) in chars.enumerated() {
            switch c {
            case ".": nibbles.append(0xA)
            case "E" where i + 1 < chars.count && chars[i + 1] == "-": nibbles.append(0xC)
            case "E": nibbles.append(0xB)
            case "-" where i > 0 && chars[i - 1] == "E": break
            case "-": nibbles.append(0xE)
            default: nibbles.append(Int(String(c))!)
            }
        }
        nibbles.append(0xF)
        if nibbles.count % 2 == 1 { nibbles.append(0xF) }
        return [30] + (0..<nibbles.count / 2).map { UInt8(nibbles[2 * $0] << 4 | nibbles[2 * $0 + 1]) }
    }

    private static func matrix(_ scale: String) -> [UInt8] { real(scale) + [139, 139] + real(scale) + [139, 139, 12, 7] }

    /// One Private DICT: default and nominal widths, local subroutines (when any, right after it).
    struct Private {
        var defaultWidth: Int
        var nominalWidth: Int
        var subrs: [[UInt8]]?
        var fontMatrix: String?
        init(_ defaultWidth: Int, _ nominalWidth: Int, _ subrs: [[UInt8]]? = nil, fontMatrix: String? = nil) {
            (self.defaultWidth, self.nominalWidth, self.subrs, self.fontMatrix) = (defaultWidth, nominalWidth, subrs, fontMatrix)
        }
    }

    /// A CFF program. `glyphs`: per glyph after .notdef, its SID (name-keyed) or CID (CID-keyed) and charstring.
    /// Name-keyed: `privates[0]` is the font's. CID-keyed: one font DICT per Private, and `fdOfGlyph` (per glyph, .notdef
    /// included) says which, written as FDSelect format 3.
    static func cff(_ glyphs: [(id: Int, charString: [UInt8])], _ privates: [Private], cid: Bool = false, fdOfGlyph: [Int]? = nil,
                    topMatrix: String? = nil) -> [UInt8] {
        let header: [UInt8] = [1, 0, 4, 4]
        let name = index([Array("Test".utf8)])
        let strings = index([])
        let gsubrs = index([])
        var charset: [UInt8] = [0]
        for g in glyphs { charset += [UInt8(g.id >> 8), UInt8(g.id & 255)] }
        let charStrings = index([cs(endChar)] + glyphs.map(\.charString))

        func privateDict(_ p: Private, _ subrsAt: Int) -> [UInt8] {
            int(p.defaultWidth) + [20] + int(p.nominalWidth) + [21] + (p.subrs == nil ? [] : int(subrsAt) + [19])
        }
        // Private DICT (with its subroutines after it, at an offset relative to it) blocks, laid out from `at`.
        func lay(_ at: Int) -> (bytes: [UInt8], where: [(size: Int, offset: Int)]) {
            var bytes: [UInt8] = []
            var places: [(size: Int, offset: Int)] = []
            for p in privates {
                let size = privateDict(p, 0).count
                places.append((size, at + bytes.count))
                bytes += privateDict(p, size)
                if let s = p.subrs { bytes += index(s) }
            }
            return (bytes, places)
        }
        func top(_ charsetAt: Int, _ charStringsAt: Int, _ priv: (size: Int, offset: Int), _ fdArrayAt: Int, _ fdSelectAt: Int) -> [UInt8] {
            let m = topMatrix.map(matrix) ?? []
            if cid {
                return int(0) + int(0) + int(0) + [12, 30] + int(charsetAt) + [15] + int(charStringsAt) + [17] + int(fdArrayAt) + [12, 36]
                    + int(fdSelectAt) + [12, 37] + m
            }
            return int(charsetAt) + [15] + int(charStringsAt) + [17] + int(priv.size) + int(priv.offset) + [18] + m
        }
        func fdArray(_ places: [(size: Int, offset: Int)]) -> [UInt8] {
            index(privates.enumerated().map { i, p in int(places[i].size) + int(places[i].offset) + [18] + (p.fontMatrix.map(matrix) ?? []) })
        }
        func fdSelect() -> [UInt8] {
            let fds = fdOfGlyph ?? [Int](repeating: 0, count: glyphs.count + 1)
            var ranges: [UInt8] = []
            var count = 0
            for g in fds.indices where g == 0 || fds[g] != fds[g - 1] {
                ranges += [UInt8(g >> 8), UInt8(g & 255), UInt8(fds[g])]
                count += 1
            }
            return [3, UInt8(count >> 8), UInt8(count & 255)] + ranges + [UInt8(fds.count >> 8), UInt8(fds.count & 255)]
        }

        // Sizes don't depend on the offsets (5-byte integers), so lay out once with zeros, then for real.
        let topSize = index([top(0, 0, (0, 0), 0, 0)]).count
        let charsetAt = header.count + name.count + topSize + strings.count + gsubrs.count
        let charStringsAt = charsetAt + charset.count
        let privatesAt = charStringsAt + charStrings.count
        let (privateBytes, places) = lay(privatesAt)
        let fdArrayAt = privatesAt + privateBytes.count
        let fdArrayBytes = cid ? fdArray(places) : []
        let fdSelectAt = fdArrayAt + fdArrayBytes.count
        let topIndex = index([top(charsetAt, charStringsAt, places[0], fdArrayAt, fdSelectAt)])
        return header + name + topIndex + strings + gsubrs + charset + charStrings + privateBytes + fdArrayBytes + (cid ? fdSelect() : [])
    }

    /// A Type 1 program (cleartext, then the eexec-encrypted private part) whose CharStrings give each glyph its width with
    /// hsbw (or sbw), the charstrings encrypted as the spec says (key 4330, four leading bytes). `cutLast`: the last
    /// charstring says it is longer than the rest of the program.
    static func type1(_ glyphs: [(name: String, charString: [UInt8])], fontMatrix: String = "0.001", cutLast: Bool = false) -> [UInt8] {
        let clear = "%!PS-AdobeFont-1.0: Test\n/FontName /Test def\n/FontMatrix [\(fontMatrix) 0 0 \(fontMatrix) 0 0] readonly def\n/Encoding StandardEncoding def\ncurrentfile eexec\n"
        var priv = Array("abcd".utf8) + Array("dup /Private 8 dict dup begin /RD{string currentfile exch readstring pop}executeonly def /lenIV 4 def end\n".utf8)
        priv += Array("2 index /CharStrings \(glyphs.count) dict dup begin\n".utf8)
        for g in glyphs {
            let encrypted = encrypt(Array("wxyz".utf8) + g.charString, 4330)
            let length = cutLast && g.name == glyphs.last!.name ? 2_000_000_000 : encrypted.count
            priv += Array("/\(g.name) \(length) RD ".utf8)
            priv += encrypted
            priv += Array(" ND\n".utf8)
        }
        priv += Array("end\nend\nmark currentfile closefile\n".utf8)
        return Array(clear.utf8) + encrypt(priv, 55665) + Array(("\n" + String(repeating: "0", count: 64) + "\ncleartomark\n").utf8)
    }

    /// A Type 1 charstring: "sbx wx hsbw" then endchar (widths past ±1131 as 32-bit numbers, as Type 1 writes them).
    static func hsbw(_ width: Int) -> [UInt8] { num1(0) + num1(width) + [13, 14] }

    private static func num1(_ v: Int) -> [UInt8] { (-1131...1131).contains(v) ? num(v) : [255] + int32(v) }

    private static func encrypt(_ plain: [UInt8], _ key: UInt16) -> [UInt8] {
        var r = key
        return plain.map { p in
            let c = p ^ UInt8(r >> 8)
            r = (UInt16(c) &+ r) &* 52845 &+ 22719
            return c
        }
    }
}
