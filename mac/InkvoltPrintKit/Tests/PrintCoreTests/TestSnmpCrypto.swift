@testable import PrintCore

/// The PC's tests' `SnmpCrypto`: SHA-256 (FIPS 180-4), HMAC (RFC 2104) and AES-128's forward cipher (FIPS 197) written out
/// here, since PrintCore is Foundation only and CryptoKit isn't on the PC. Test-only: the app uses PrintMac's
/// `AppleSnmpCrypto`, tested against the same vectors in PrintMacTests. Checked here against RFC 4231, NIST SP 800-38A and
/// the SHA-256 key vector (`SnmpV3Tests`).
struct TestSnmpCrypto: SnmpCrypto {
    /// Installs the stand-in for the SNMPv3 tests (the Mac's PrintMacTests may install the real one: both give the same bytes).
    static func install() {
        if Usm.crypto == nil { Usm.crypto = TestSnmpCrypto() }
    }

    func sha256(_ data: [UInt8]) -> [UInt8] { Sha256.hash(data) }

    func hmacSha256(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var k = key.count > 64 ? sha256(key) : key
        k += [UInt8](repeating: 0, count: 64 - k.count)
        let inner = sha256(k.map { $0 ^ 0x36 } + data)
        return sha256(k.map { $0 ^ 0x5C } + inner)
    }

    func aes128(key: [UInt8], block: [UInt8]) -> [UInt8] { Aes128.encrypt(block, key: key) }
}

private enum Sha256 {
    static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var data = message
        let bits = UInt64(message.count) &* 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for i in stride(from: 56, through: 0, by: -8) { data.append(UInt8(truncatingIfNeeded: bits >> UInt64(i))) }
        var w = [UInt32](repeating: 0, count: 64)
        data.withUnsafeBufferPointer { bytes in
            w.withUnsafeMutableBufferPointer { w in
                k.withUnsafeBufferPointer { k in
                    for chunk in stride(from: 0, to: bytes.count, by: 64) {
                        for t in 0..<16 {
                            let i = chunk + 4 * t
                            w[t] = UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
                        }
                        for t in 16..<64 {
                            let s0 = rotr(w[t - 15], 7) ^ rotr(w[t - 15], 18) ^ (w[t - 15] >> 3)
                            let s1 = rotr(w[t - 2], 17) ^ rotr(w[t - 2], 19) ^ (w[t - 2] >> 10)
                            w[t] = w[t - 16] &+ s0 &+ w[t - 7] &+ s1
                        }
                        var a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
                        for t in 0..<64 {
                            let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                            let ch = (e & f) ^ (~e & g)
                            let t1 = hh &+ s1 &+ ch &+ k[t] &+ w[t]
                            let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
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
        return h.flatMap { [UInt8($0 >> 24), UInt8(truncatingIfNeeded: $0 >> 16), UInt8(truncatingIfNeeded: $0 >> 8), UInt8(truncatingIfNeeded: $0)] }
    }

    private static func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
}

private enum Aes128 {
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

    private static func xtime(_ a: UInt8) -> UInt8 { (a << 1) ^ (a & 0x80 != 0 ? 0x1B : 0) }

    static func encrypt(_ block: [UInt8], key: [UInt8]) -> [UInt8] {
        precondition(block.count == 16 && key.count == 16)
        var w = key
        var rcon: UInt8 = 1
        while w.count < 176 {
            var t = Array(w[(w.count - 4)...])
            if w.count % 16 == 0 {
                t = [sbox[Int(t[1])] ^ rcon, sbox[Int(t[2])], sbox[Int(t[3])], sbox[Int(t[0])]]
                rcon = xtime(rcon)
            }
            for j in 0..<4 { w.append(w[w.count - 16] ^ t[j]) }
        }
        var s = block
        func addRoundKey(_ round: Int) { for i in 0..<16 { s[i] ^= w[round * 16 + i] } }
        addRoundKey(0)
        for round in 1...10 {
            for i in 0..<16 { s[i] = sbox[Int(s[i])] }
            let shifted = (0..<16).map { i -> UInt8 in
                let r = i % 4, c = i / 4
                return s[r + 4 * ((c + r) % 4)]
            }
            s = shifted
            if round < 10 {
                for c in 0..<4 {
                    let a0 = s[4 * c], a1 = s[4 * c + 1], a2 = s[4 * c + 2], a3 = s[4 * c + 3]
                    s[4 * c] = xtime(a0) ^ xtime(a1) ^ a1 ^ a2 ^ a3
                    s[4 * c + 1] = a0 ^ xtime(a1) ^ xtime(a2) ^ a2 ^ a3
                    s[4 * c + 2] = a0 ^ a1 ^ xtime(a2) ^ xtime(a3) ^ a3
                    s[4 * c + 3] = xtime(a0) ^ a0 ^ a1 ^ a2 ^ xtime(a3)
                }
            }
            addRoundKey(round)
        }
        return s
    }
}
