import Foundation
import Synchronization

/// The cryptography a PDF's password needs, from the system: PrintCore is Foundation only, so PrintMac's `ApplePdfCrypto`
/// (CryptoKit and CommonCrypto) implements it in the app, and the PC's tests use a stand-in of their own, as `SnmpCrypto`
/// does for SNMPv3. The standard security handler's logic (the hash of algorithm 2.B, the keys and the dictionary, which
/// strings are encrypted) is PrintCore's, in `PdfEncryption`.
public protocol PdfCrypto: Sendable {
    /// SHA-256 of `data` (32 bytes).
    func sha256(_ data: [UInt8]) -> [UInt8]

    /// SHA-384 of `data` (48 bytes).
    func sha384(_ data: [UInt8]) -> [UInt8]

    /// SHA-512 of `data` (64 bytes).
    func sha512(_ data: [UInt8]) -> [UInt8]

    /// AES in CBC mode, encrypting (FIPS 197, SP 800-38A): `key` 16 bytes (AES-128) or 32 (AES-256), `iv` 16. With `pad`,
    /// PKCS#7 padding; without, `data` is whole 16-byte blocks.
    func aesCbcEncrypt(key: [UInt8], iv: [UInt8], _ data: [UInt8], pad: Bool) -> [UInt8]
}

/// Why a new password can't be used yet (`PdfEncryption.checkNew`).
public enum NewPasswordProblem: Equatable, Sendable { case empty, mismatch }

/// A password on a PDF that `PdfWriter` writes: AES-256, the standard security handler's revision 6 (ISO 32000-2, 7.6.4.3 and
/// 7.6.4.4), as Inkvolt PDF's Protect writes it. One password opens the file and, everything being allowed, stands for the
/// owner's too. A new random file key every time; each string and stream gets its own random IV. The Windows core's
/// `PdfEncryption` (roadmap 4.18).
public struct PdfEncryption: Sendable {
    /// A password's bytes are cut to this many (7.6.4.3.3).
    public static let maxPasswordBytes = 127

    /// Every permission (bits 1 and 2 clear, as 7.6.4.2 requires): printing, copying, changing, all of it.
    static let allPermissions: Int32 = -4

    public enum Problem: Error, Equatable {
        /// No usable password (empty, or nothing left once normalized).
        case noPassword
        /// The system's cryptography isn't installed (`PdfEncryption.crypto`): nothing is written rather than written open.
        case noCryptography
        /// A string in an object's body isn't closed, or a hex string holds something else.
        case malformedString
    }

    private static let installed = Mutex<(any PdfCrypto)?>(nil)

    /// The system's cryptography, set once at launch (the app: PrintMac's `ApplePdfCrypto`; the tests: their own). Without
    /// one, a file with a password is never written. As `Usm.crypto` is set.
    public static var crypto: (any PdfCrypto)? {
        get { installed.withLock { $0 } }
        set { installed.withLock { $0 = newValue } }
    }

    private let key: [UInt8]
    private let crypto: any PdfCrypto
    let u: [UInt8], ue: [UInt8], o: [UInt8], oe: [UInt8], perms: [UInt8]

    private init(key: [UInt8], crypto: any PdfCrypto, u: [UInt8], ue: [UInt8], o: [UInt8], oe: [UInt8], perms: [UInt8]) {
        self.key = key
        self.crypto = crypto
        self.u = u
        self.ue = ue
        self.o = o
        self.oe = oe
        self.perms = perms
    }

    /// Whether a password can protect a file: not empty (an empty one opens it without asking).
    public static func usable(_ password: String?) -> Bool {
        guard let password, !password.isEmpty else { return false }
        return !passwordBytes(password).isEmpty
    }

    /// What stops a new password typed twice from being used, or nil: nothing typed, or the two differ.
    public static func checkNew(_ password: String?, _ again: String?) -> NewPasswordProblem? {
        if !usable(password) { return .empty }
        // Ordinal, as .NET compares: the UTF-16 units, not Swift's canonical equivalence.
        return Array(password!.utf16) == Array((again ?? "").utf16) ? nil : .mismatch
    }

    /// A new file key and the dictionary's values for `password`.
    /// - Throws: `Problem.noPassword` for an empty one, `Problem.noCryptography` when none is installed.
    public static func create(_ password: String, crypto: (any PdfCrypto)? = nil) throws -> PdfEncryption {
        guard usable(password) else { throw Problem.noPassword }
        guard let crypto = crypto ?? Self.crypto else { throw Problem.noCryptography }
        let pw = passwordBytes(password)
        let key = random(32)
        let userSalts = random(16)
        let u = hash(pw, Array(userSalts[0..<8]), [], crypto) + userSalts
        let ue = crypto.aesCbcEncrypt(key: hash(pw, Array(userSalts[8..<16]), [], crypto), iv: zeroIv, key, pad: false)
        let ownerSalts = random(16)
        let o = hash(pw, Array(ownerSalts[0..<8]), u, crypto) + ownerSalts
        let oe = crypto.aesCbcEncrypt(key: hash(pw, Array(ownerSalts[8..<16]), u, crypto), iv: zeroIv, key, pad: false)
        let p = UInt32(bitPattern: allPermissions)
        var perms: [UInt8] = [UInt8(p & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p >> 16 & 0xFF), UInt8(p >> 24)] // little-endian
        perms += [0xFF, 0xFF, 0xFF, 0xFF]
        perms += Array("Tadb".utf8) // T: the metadata is encrypted too
        perms += random(4)
        // One block in ECB is CBC with a zero IV.
        perms = crypto.aesCbcEncrypt(key: key, iv: zeroIv, perms, pad: false)
        return PdfEncryption(key: key, crypto: crypto, u: u, ue: ue, o: o, oe: oe, perms: perms)
    }

    /// The /Encrypt dictionary (its strings are never encrypted themselves).
    public func dictionary() -> String {
        "<< /Filter /Standard /V 5 /R 6 /Length 256 /CF << /StdCF << /Type /CryptFilter /CFM /AESV3 /AuthEvent /DocOpen /Length 32 >> >> "
            + "/StmF /StdCF /StrF /StdCF /P \(Self.allPermissions) /EncryptMetadata true "
            + "/O <\(Self.hex(o))> /U <\(Self.hex(u))> /OE <\(Self.hex(oe))> /UE <\(Self.hex(ue))> /Perms <\(Self.hex(perms))> >>"
    }

    /// A string's or a stream's bytes encrypted: a random 16-byte IV, then AES-256-CBC with PKCS#7 padding (7.6.3.2).
    public func encrypt(_ data: [UInt8]) -> [UInt8] {
        let iv = Self.random(16)
        return iv + crypto.aesCbcEncrypt(key: key, iv: iv, data, pad: true)
    }

    /// An object's dictionary or array as `PdfWriter` wrote it, with every string in it encrypted and written as hex. Literal
    /// strings (escapes and balanced parentheses) and hex strings are read; names, numbers and `<<` pass through.
    /// - Throws: `Problem.malformedString` for an unclosed string or a hex string that isn't one.
    public func encryptStrings(_ body: String) throws -> String {
        let s = Array(body.unicodeScalars)
        var out = String.UnicodeScalarView()
        func append(_ text: String) { out.append(contentsOf: text.unicodeScalars) }
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "(" {
                let (bytes, end) = try Self.literal(s, i)
                append("<\(Self.hex(encrypt(bytes)))>")
                i = end
            } else if c == "<" && i + 1 < s.count && s[i + 1] == "<" {
                append("<<")
                i += 2
            } else if c == "<" {
                guard let close = s[(i + 1)...].firstIndex(of: ">") else { throw Problem.malformedString }
                var digits = s[(i + 1)..<close].filter { !$0.properties.isWhitespace }
                if digits.count % 2 == 1 { digits.append("0") }
                var bytes: [UInt8] = []
                bytes.reserveCapacity(digits.count / 2)
                for k in stride(from: 0, to: digits.count, by: 2) {
                    guard let hi = Self.hexValue(digits[k]), let lo = Self.hexValue(digits[k + 1]) else { throw Problem.malformedString }
                    bytes.append(hi << 4 | lo)
                }
                append("<\(Self.hex(encrypt(bytes)))>")
                i = close + 1
            } else {
                out.append(c)
                i += 1
            }
        }
        return String(out)
    }

    /// A literal string at `start` (its opening parenthesis): its bytes and the index after its closing one.
    private static func literal(_ s: [Unicode.Scalar], _ start: Int) throws -> (bytes: [UInt8], end: Int) {
        var bytes: [UInt8] = []
        var depth = 0
        var i = start
        while i < s.count {
            let c = s[i]
            if c == "\\" && i + 1 < s.count {
                i += 1
                let n = s[i]
                switch n {
                case "n": bytes.append(0x0A)
                case "r": bytes.append(0x0D)
                case "t": bytes.append(0x09)
                case "b": bytes.append(0x08)
                case "f": bytes.append(0x0C)
                case "0"..."7":
                    var value = Int(n.value) - 48
                    var k = 0
                    while k < 2 && i + 1 < s.count && ("0"..."7").contains(s[i + 1]) {
                        i += 1
                        value = value * 8 + Int(s[i].value) - 48
                        k += 1
                    }
                    bytes.append(UInt8(truncatingIfNeeded: value))
                case "\r", "\n": break // a line continued
                default: bytes.append(UInt8(truncatingIfNeeded: n.value))
                }
                i += 1
                continue
            }
            if c == "(" {
                depth += 1
                if depth == 1 {
                    i += 1
                    continue
                }
            } else if c == ")" {
                depth -= 1
                if depth == 0 { return (bytes, i + 1) }
            }
            bytes.append(UInt8(truncatingIfNeeded: c.value))
            i += 1
        }
        throw Problem.malformedString
    }

    /// A password's bytes: UTF-8 of its compatibility form (NFKC; SASLprep's normalization, 7.6.4.3.3), at most
    /// `maxPasswordBytes`, never cutting a character in two.
    public static func passwordBytes(_ password: String) -> [UInt8] {
        let bytes = Array(password.precomposedStringWithCompatibilityMapping.utf8)
        if bytes.count <= maxPasswordBytes { return bytes }
        var cut = maxPasswordBytes
        while cut > 0 && bytes[cut] & 0xC0 == 0x80 { cut -= 1 }
        return Array(bytes[0..<cut])
    }

    /// Algorithm 2.B (7.6.4.3.4): the hash of a password with a salt and, for the owner's values, the user's 48 bytes.
    static func hash(_ password: [UInt8], _ salt: [UInt8], _ userKey: [UInt8], _ crypto: any PdfCrypto) -> [UInt8] {
        var k = crypto.sha256(password + salt + userKey)
        var e: [UInt8] = []
        var round = 0
        while round < 64 || Int(e[e.count - 1]) > round - 32 {
            let one = password + k + userKey
            var k1: [UInt8] = []
            k1.reserveCapacity(one.count * 64)
            for _ in 0..<64 { k1 += one }
            e = crypto.aesCbcEncrypt(key: Array(k[0..<16]), iv: Array(k[16..<32]), k1, pad: false)
            var sum = 0
            for b in 0..<16 { sum += Int(e[b]) }
            switch sum % 3 {
            case 0: k = crypto.sha256(e)
            case 1: k = crypto.sha384(e)
            default: k = crypto.sha512(e)
            }
            round += 1
        }
        return Array(k[0..<32])
    }

    private static let zeroIv = [UInt8](repeating: 0, count: 16)

    /// Bytes from the system's secure generator (arc4random on the Mac, BCryptGenRandom on Windows).
    static func random(_ count: Int) -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) }
    }

    /// Upper-case hex, as .NET's Convert.ToHexString.
    static func hex(_ bytes: [UInt8]) -> String { Digest.hex(bytes, uppercase: true) }

    private static func hexValue(_ c: Unicode.Scalar) -> UInt8? {
        switch c {
        case "0"..."9": UInt8(c.value - 48)
        case "a"..."f": UInt8(c.value - 87)
        case "A"..."F": UInt8(c.value - 55)
        default: nil
        }
    }
}
