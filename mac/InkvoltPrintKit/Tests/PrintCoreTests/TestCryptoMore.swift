import Foundation
@testable import PrintCore

/// MD5 (RFC 1321), for the PC's SNMPv3 tests (HMAC-MD5-96, MD5 keys): test-only, as `Sha256`.
enum Md5 {
    private static let s: [UInt32] = [7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                      5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
                                      4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                      6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21]

    /// K[i] = floor(2³² × |sin(i + 1)|), worked out rather than typed in.
    private static let k: [UInt32] = (0..<64).map { i in UInt32(truncatingIfNeeded: Int64(abs(sin(Double(i + 1))) * 4_294_967_296.0)) }

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var a0: UInt32 = 0x67452301, b0: UInt32 = 0xefcdab89, c0: UInt32 = 0x98badcfe, d0: UInt32 = 0x10325476
        var data = message
        let bits = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in 0..<8 { data.append(UInt8(truncatingIfNeeded: bits >> UInt64(8 * i))) }
        var m = [UInt32](repeating: 0, count: 16)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for t in 0..<16 {
                let i = chunk + 4 * t
                m[t] = UInt32(data[i]) | UInt32(data[i + 1]) << 8 | UInt32(data[i + 2]) << 16 | UInt32(data[i + 3]) << 24
            }
            var a = a0, b = b0, c = c0, d = d0
            for i in 0..<64 {
                var f: UInt32
                let g: Int
                switch i {
                case 0..<16:
                    f = (b & c) | (~b & d)
                    g = i
                case 16..<32:
                    f = (d & b) | (~d & c)
                    g = (5 * i + 1) % 16
                case 32..<48:
                    f = b ^ c ^ d
                    g = (3 * i + 5) % 16
                default:
                    f = c ^ (b | ~d)
                    g = (7 * i) % 16
                }
                f = f &+ a &+ k[i] &+ m[g]
                a = d
                d = c
                c = b
                b = b &+ ((f << s[i]) | (f >> (32 - s[i])))
            }
            a0 = a0 &+ a
            b0 = b0 &+ b
            c0 = c0 &+ c
            d0 = d0 &+ d
        }
        return [a0, b0, c0, d0].flatMap { v in (0..<4).map { UInt8(truncatingIfNeeded: v >> UInt32(8 * $0)) } }
    }
}

/// SHA-1 (FIPS 180-4), for the PC's SNMPv3 tests: test-only, as `Sha256`.
enum Sha1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var data = message
        let bits = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bits >> UInt64(i))) }
        var w = [UInt32](repeating: 0, count: 80)
        for chunk in stride(from: 0, to: data.count, by: 64) {
            for t in 0..<16 {
                let i = chunk + 4 * t
                w[t] = UInt32(data[i]) << 24 | UInt32(data[i + 1]) << 16 | UInt32(data[i + 2]) << 8 | UInt32(data[i + 3])
            }
            for t in 16..<80 { w[t] = rotl(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1) }
            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4]
            for t in 0..<80 {
                let f: UInt32, k: UInt32
                switch t {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
                }
                let temp = rotl(a, 5) &+ f &+ e &+ k &+ w[t]
                e = d
                d = c
                c = rotl(b, 30)
                b = a
                a = temp
            }
            h[0] &+= a
            h[1] &+= b
            h[2] &+= c
            h[3] &+= d
            h[4] &+= e
        }
        return h.flatMap { [UInt8($0 >> 24), UInt8(truncatingIfNeeded: $0 >> 16), UInt8(truncatingIfNeeded: $0 >> 8), UInt8(truncatingIfNeeded: $0)] }
    }

    private static func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { (x << n) | (x >> (32 - n)) }
}

/// DES (FIPS 46-3) on one block, for the PC's SNMPv3 tests (CBC-DES): test-only, written from the standard's tables.
enum Des {
    private static let ip: [Int] = [58, 50, 42, 34, 26, 18, 10, 2, 60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6,
                                    64, 56, 48, 40, 32, 24, 16, 8, 57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
                                    61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7]
    private static let fp: [Int] = [40, 8, 48, 16, 56, 24, 64, 32, 39, 7, 47, 15, 55, 23, 63, 31, 38, 6, 46, 14, 54, 22, 62, 30,
                                    37, 5, 45, 13, 53, 21, 61, 29, 36, 4, 44, 12, 52, 20, 60, 28, 35, 3, 43, 11, 51, 19, 59, 27,
                                    34, 2, 42, 10, 50, 18, 58, 26, 33, 1, 41, 9, 49, 17, 57, 25]
    private static let e: [Int] = [32, 1, 2, 3, 4, 5, 4, 5, 6, 7, 8, 9, 8, 9, 10, 11, 12, 13, 12, 13, 14, 15, 16, 17,
                                   16, 17, 18, 19, 20, 21, 20, 21, 22, 23, 24, 25, 24, 25, 26, 27, 28, 29, 28, 29, 30, 31, 32, 1]
    private static let p: [Int] = [16, 7, 20, 21, 29, 12, 28, 17, 1, 15, 23, 26, 5, 18, 31, 10,
                                   2, 8, 24, 14, 32, 27, 3, 9, 19, 13, 30, 6, 22, 11, 4, 25]
    private static let pc1: [Int] = [57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35, 27, 19, 11, 3,
                                     60, 52, 44, 36, 63, 55, 47, 39, 31, 23, 15, 7, 62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37,
                                     29, 21, 13, 5, 28, 20, 12, 4]
    private static let pc2: [Int] = [14, 17, 11, 24, 1, 5, 3, 28, 15, 6, 21, 10, 23, 19, 12, 4, 26, 8, 16, 7, 27, 20, 13, 2,
                                     41, 52, 31, 37, 47, 55, 30, 40, 51, 45, 33, 48, 44, 49, 39, 56, 34, 53, 46, 42, 50, 36, 29, 32]
    private static let shifts: [Int] = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1]
    private static let sboxes: [[UInt8]] = [
        [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8,
         4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
        [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 14, 12, 0, 1, 10, 6, 9, 11, 5,
         0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
        [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1,
         13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
        [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9,
         10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 1, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
        [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6,
         4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
        [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8,
         9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
        [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6,
         1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
        [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2,
         7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11],
    ]

    /// Bits numbered from 1, the first byte's most significant first (the standard's numbering).
    private static func permute(_ input: UInt64, _ inBits: Int, _ table: [Int]) -> UInt64 {
        var out: UInt64 = 0
        for position in table { out = out << 1 | (input >> UInt64(inBits - position) & 1) }
        return out
    }

    static func crypt(_ block: [UInt8], key: [UInt8], encrypt: Bool) -> [UInt8] {
        precondition(block.count == 8 && key.count == 8)
        let k = key.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        var cd = permute(k, 64, pc1) // 56 bits
        var subkeys: [UInt64] = []
        for shift in shifts {
            var c = cd >> 28, d = cd & 0xFFFFFFF
            c = (c << UInt64(shift) | c >> UInt64(28 - shift)) & 0xFFFFFFF
            d = (d << UInt64(shift) | d >> UInt64(28 - shift)) & 0xFFFFFFF
            cd = c << 28 | d
            subkeys.append(permute(cd, 56, pc2))
        }
        if !encrypt { subkeys.reverse() }
        let b = permute(block.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }, 64, ip)
        var l = b >> 32, r = b & 0xFFFFFFFF
        for subkey in subkeys {
            let x = permute(r, 32, e) ^ subkey // 48 bits
            var s: UInt64 = 0
            for i in 0..<8 {
                let six = Int(x >> UInt64(42 - 6 * i) & 0x3F)
                let row = (six & 0x20) >> 4 | six & 1, column = (six >> 1) & 0xF
                s = s << 4 | UInt64(sboxes[i][row * 16 + column])
            }
            (l, r) = (r, l ^ permute(s, 32, p))
        }
        let out = permute(r << 32 | l, 64, fp)
        return (0..<8).map { UInt8(truncatingIfNeeded: out >> UInt64(56 - 8 * $0)) }
    }
}
