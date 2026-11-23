@testable import PrintCore

/// The PC's tests' `PdfCrypto`: SHA-256 (`TestSnmpCrypto`'s), SHA-384 and SHA-512 (FIPS 180-4), and AES-128 and AES-256 in
/// CBC (FIPS 197, SP 800-38A) written out here, since PrintCore is Foundation only and CryptoKit isn't on the PC; the inverse
/// cipher too, for the tests that read a protected file back. Test-only: the app uses PrintMac's `ApplePdfCrypto`, checked
/// against the same vectors in PrintMacTests. Checked here against FIPS 180-4's "abc" and FIPS 197's appendix C
/// (`ScanArchiveTests`).
struct TestPdfCrypto: PdfCrypto {
    /// Installs the stand-in for the tests that write a password (the Mac's PrintMacTests may install the real one: both give
    /// files that open with the same password).
    static func install() {
        if PdfEncryption.crypto == nil { PdfEncryption.crypto = TestPdfCrypto() }
    }

    func sha256(_ data: [UInt8]) -> [UInt8] { Sha256.hash(data) }

    func sha384(_ data: [UInt8]) -> [UInt8] { Array(Sha512.hash(data, Sha512.h384).prefix(48)) }

    func sha512(_ data: [UInt8]) -> [UInt8] { Sha512.hash(data, Sha512.h512) }

    func aesCbcEncrypt(key: [UInt8], iv: [UInt8], _ data: [UInt8], pad: Bool) -> [UInt8] {
        var plain = data
        if pad {
            let n = 16 - plain.count % 16
            plain += [UInt8](repeating: UInt8(n), count: n)
        }
        precondition(plain.count % 16 == 0 && iv.count == 16)
        return TestAes.cbcEncrypt(key: key, iv: iv, plain)
    }

    /// AES-CBC decryption; `unpad` takes PKCS#7's padding off (nil when it isn't there).
    static func aesCbcDecrypt(key: [UInt8], iv: [UInt8], _ data: [UInt8], unpad: Bool) -> [UInt8]? {
        guard data.count % 16 == 0, iv.count == 16 else { return nil }
        let w = TestAes.expand(key)
        var out: [UInt8] = []
        var feedback = iv
        for at in stride(from: 0, to: data.count, by: 16) {
            let block = Array(data[at..<at + 16])
            out += zip(TestAes.decrypt(block, w), feedback).map { $0 ^ $1 }
            feedback = block
        }
        guard unpad else { return out }
        guard let n = out.last, n >= 1, n <= 16, out.count >= Int(n), out.suffix(Int(n)).allSatisfy({ $0 == n }) else { return nil }
        return Array(out.dropLast(Int(n)))
    }
}

enum Sha512 {
    static let h512: [UInt64] = [0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
                                 0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179]
    static let h384: [UInt64] = [0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939,
                                 0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4]
    static let k: [UInt64] = [
        0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc, 0x3956c25bf348b538, 0x59f111f1b605d019,
        0x923f82a4af194f9b, 0xab1c5ed5da6d8118, 0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2,
        0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694, 0xe49b69c19ef14ad2, 0xefbe4786384f25e3,
        0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65, 0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5,
        0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4, 0xc6e00bf33da88fc2, 0xd5a79147930aa725,
        0x06ca6351e003826f, 0x142929670a0e6e70, 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df,
        0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b, 0xa2bfe8a14cf10364, 0xa81a664bbc423001,
        0xc24b8b70d0f89791, 0xc76c51a30654be30, 0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8,
        0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8, 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb,
        0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3, 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec,
        0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b, 0xca273eceea26619c, 0xd186b8c721c0c207,
        0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178, 0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b,
        0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c, 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a,
        0x5fcb6fab3ad6faec, 0x6c44198c4a475817,
    ]

    static func hash(_ message: [UInt8], _ start: [UInt64]) -> [UInt8] {
        var h = start
        var data = message
        let bits = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 128 != 112 { data.append(0) }
        data += [UInt8](repeating: 0, count: 8) // the length's high 64 bits
        for i in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bits >> UInt64(i))) }
        var w = [UInt64](repeating: 0, count: 80)
        data.withUnsafeBufferPointer { bytes in
            w.withUnsafeMutableBufferPointer { w in
                k.withUnsafeBufferPointer { k in
                    h.withUnsafeMutableBufferPointer { h in
                        for chunk in stride(from: 0, to: bytes.count, by: 128) {
                            for t in 0..<16 {
                                var v: UInt64 = 0
                                for b in 0..<8 { v = v << 8 | UInt64(bytes[chunk + 8 * t + b]) }
                                w[t] = v
                            }
                            for t in 16..<80 {
                                let s0 = rotr(w[t - 15], 1) ^ rotr(w[t - 15], 8) ^ (w[t - 15] >> 7)
                                let s1 = rotr(w[t - 2], 19) ^ rotr(w[t - 2], 61) ^ (w[t - 2] >> 6)
                                w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
                            }
                            var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
                            for t in 0..<80 {
                                let s1 = rotr(e, 14) ^ rotr(e, 18) ^ rotr(e, 41)
                                let ch = (e & f) ^ (~e & g)
                                let t1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
                                let s0 = rotr(a, 28) ^ rotr(a, 34) ^ rotr(a, 39)
                                let maj = (a & b) ^ (a & c) ^ (b & c)
                                let t2 = s0 &+ maj
                                hh = g
                                g = f
                                f = e
                                e = d &+ t1
                                d = c
                                c = b
                                b = a
                                a = t1 &+ t2
                            }
                            h[0] &+= a
                            h[1] &+= b
                            h[2] &+= c
                            h[3] &+= d
                            h[4] &+= e
                            h[5] &+= f
                            h[6] &+= g
                            h[7] &+= hh
                        }
                    }
                }
            }
        }
        return h.flatMap { v in (0..<8).map { UInt8(truncatingIfNeeded: v >> UInt64(56 - 8 * $0)) } }
    }

    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }
}

/// AES (FIPS 197) for 16- and 32-byte keys, both ways, one block at a time.
enum TestAes {
    /// The S-box, made from its definition (the multiplicative inverse in GF(2⁸), then the affine map), not typed in.
    static let sbox: [UInt8] = {
        var s = [UInt8](repeating: 0, count: 256)
        var p: UInt8 = 1, q: UInt8 = 1
        func rotl(_ x: UInt8, _ n: UInt8) -> UInt8 { (x << n) | (x >> (8 - n)) }
        repeat {
            p = p ^ (p << 1) ^ (p & 0x80 != 0 ? 0x1B : 0) // p × 3
            q ^= q << 1 // q ÷ 3
            q ^= q << 2
            q ^= q << 4
            if q & 0x80 != 0 { q ^= 0x09 }
            s[Int(p)] = q ^ rotl(q, 1) ^ rotl(q, 2) ^ rotl(q, 3) ^ rotl(q, 4) ^ 0x63
        } while p != 1
        s[0] = 0x63
        return s
    }()

    static let inverse: [UInt8] = {
        var inv = [UInt8](repeating: 0, count: 256)
        for (i, v) in sbox.enumerated() { inv[Int(v)] = UInt8(i) }
        return inv
    }()

    private static func xtime(_ a: UInt8) -> UInt8 { (a << 1) ^ (a & 0x80 != 0 ? 0x1B : 0) }

    private static func mul(_ a: UInt8, _ b: UInt8) -> UInt8 {
        var (a, b, r) = (a, b, UInt8(0))
        while b != 0 {
            if b & 1 != 0 { r ^= a }
            a = xtime(a)
            b >>= 1
        }
        return r
    }

    /// The round keys, 16 bytes a round (11 for AES-128, 15 for AES-256).
    static func expand(_ key: [UInt8]) -> [UInt8] {
        precondition(key.count == 16 || key.count == 32)
        let nk = key.count / 4, rounds = nk + 6
        var w = key
        var rcon: UInt8 = 1
        while w.count < 16 * (rounds + 1) {
            var t = Array(w[(w.count - 4)...])
            let word = w.count / 4
            if word % nk == 0 {
                t = [sbox[Int(t[1])] ^ rcon, sbox[Int(t[2])], sbox[Int(t[3])], sbox[Int(t[0])]]
                rcon = xtime(rcon)
            } else if nk == 8 && word % nk == 4 {
                t = t.map { sbox[Int($0)] }
            }
            for j in 0..<4 { w.append(w[w.count - 4 * nk] ^ t[j]) }
        }
        return w
    }

    /// ShiftRows: byte `i` of the new state is byte `shift[i]` of the old.
    private static let shift = (0..<16).map { i in i % 4 + 4 * ((i / 4 + i % 4) % 4) }

    /// The forward round as four tables of words (SubBytes, ShiftRows and MixColumns at once, FIPS 197 §5.2.1's usual
    /// form): the tests write megabytes through algorithm 2.B, and a byte-at-a-time cipher in a debug build kept the Mac's
    /// cores busy long enough to fail other suites' timing tests.
    private static let te: [UInt32] = {
        var t = [UInt32](repeating: 0, count: 1024)
        for x in 0..<256 {
            let s = sbox[x]
            let word = UInt32(xtime(s)) << 24 | UInt32(s) << 16 | UInt32(s) << 8 | UInt32(xtime(s) ^ s)
            t[x] = word
            t[256 + x] = word >> 8 | word << 24
            t[512 + x] = word >> 16 | word << 16
            t[768 + x] = word >> 24 | word << 8
        }
        return t
    }()

    /// AES-CBC encryption of whole blocks.
    static func cbcEncrypt(key: [UInt8], iv: [UInt8], _ data: [UInt8]) -> [UInt8] {
        let w = expand(key)
        let rounds = w.count / 16 - 1
        let rk: [UInt32] = (0..<w.count / 4).map { UInt32(w[4 * $0]) << 24 | UInt32(w[4 * $0 + 1]) << 16 | UInt32(w[4 * $0 + 2]) << 8 | UInt32(w[4 * $0 + 3]) }
        var out = [UInt8](repeating: 0, count: data.count)
        func word(_ p: UnsafeBufferPointer<UInt8>, _ at: Int) -> UInt32 {
            UInt32(p[at]) << 24 | UInt32(p[at + 1]) << 16 | UInt32(p[at + 2]) << 8 | UInt32(p[at + 3])
        }
        data.withUnsafeBufferPointer { input in
            iv.withUnsafeBufferPointer { ivp in
                out.withUnsafeMutableBufferPointer { output in
                    te.withUnsafeBufferPointer { t in
                        sbox.withUnsafeBufferPointer { s in
                            rk.withUnsafeBufferPointer { k in
                                var c0 = word(ivp, 0), c1 = word(ivp, 4), c2 = word(ivp, 8), c3 = word(ivp, 12)
                                var at = 0
                                while at < input.count {
                                    var s0 = c0 ^ word(input, at) ^ k[0], s1 = c1 ^ word(input, at + 4) ^ k[1]
                                    var s2 = c2 ^ word(input, at + 8) ^ k[2], s3 = c3 ^ word(input, at + 12) ^ k[3]
                                    for r in 1..<rounds {
                                        let t0 = t[Int(s0 >> 24)] ^ t[256 + Int(s1 >> 16 & 0xFF)] ^ t[512 + Int(s2 >> 8 & 0xFF)] ^ t[768 + Int(s3 & 0xFF)] ^ k[4 * r]
                                        let t1 = t[Int(s1 >> 24)] ^ t[256 + Int(s2 >> 16 & 0xFF)] ^ t[512 + Int(s3 >> 8 & 0xFF)] ^ t[768 + Int(s0 & 0xFF)] ^ k[4 * r + 1]
                                        let t2 = t[Int(s2 >> 24)] ^ t[256 + Int(s3 >> 16 & 0xFF)] ^ t[512 + Int(s0 >> 8 & 0xFF)] ^ t[768 + Int(s1 & 0xFF)] ^ k[4 * r + 2]
                                        let t3 = t[Int(s3 >> 24)] ^ t[256 + Int(s0 >> 16 & 0xFF)] ^ t[512 + Int(s1 >> 8 & 0xFF)] ^ t[768 + Int(s2 & 0xFF)] ^ k[4 * r + 3]
                                        (s0, s1, s2, s3) = (t0, t1, t2, t3)
                                    }
                                    func last(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32, _ key: UInt32) -> UInt32 {
                                        (UInt32(s[Int(a >> 24)]) << 24 | UInt32(s[Int(b >> 16 & 0xFF)]) << 16
                                            | UInt32(s[Int(c >> 8 & 0xFF)]) << 8 | UInt32(s[Int(d & 0xFF)])) ^ key
                                    }
                                    c0 = last(s0, s1, s2, s3, k[4 * rounds])
                                    c1 = last(s1, s2, s3, s0, k[4 * rounds + 1])
                                    c2 = last(s2, s3, s0, s1, k[4 * rounds + 2])
                                    c3 = last(s3, s0, s1, s2, k[4 * rounds + 3])
                                    func put(_ v: UInt32, _ i: Int) {
                                        output[i] = UInt8(v >> 24)
                                        output[i + 1] = UInt8(v >> 16 & 0xFF)
                                        output[i + 2] = UInt8(v >> 8 & 0xFF)
                                        output[i + 3] = UInt8(v & 0xFF)
                                    }
                                    put(c0, at)
                                    put(c1, at + 4)
                                    put(c2, at + 8)
                                    put(c3, at + 12)
                                    at += 16
                                }
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    static func decrypt(_ block: [UInt8], _ w: [UInt8]) -> [UInt8] {
        let rounds = w.count / 16 - 1
        var s = block
        for i in 0..<16 { s[i] ^= w[rounds * 16 + i] }
        for round in stride(from: rounds - 1, through: 0, by: -1) {
            var shifted = s
            for i in 0..<16 { shifted[shift[i]] = s[i] }
            s = shifted.map { inverse[Int($0)] }
            for i in 0..<16 { s[i] ^= w[round * 16 + i] }
            if round > 0 {
                for c in 0..<4 {
                    let a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3]
                    s[4 * c] = mul(a0, 14) ^ mul(a1, 11) ^ mul(a2, 13) ^ mul(a3, 9)
                    s[4 * c + 1] = mul(a0, 9) ^ mul(a1, 14) ^ mul(a2, 11) ^ mul(a3, 13)
                    s[4 * c + 2] = mul(a0, 13) ^ mul(a1, 9) ^ mul(a2, 14) ^ mul(a3, 11)
                    s[4 * c + 3] = mul(a0, 11) ^ mul(a1, 13) ^ mul(a2, 9) ^ mul(a3, 14)
                }
            }
        }
        return s
    }
}
