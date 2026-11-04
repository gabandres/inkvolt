import Foundation

/// What a licence key says: who it was issued to, when, and for which Inkvolt apps ("pdf", "print").
public struct ProLicence: Equatable, Sendable {
    public var name: String
    public var email: String
    /// The issue date as the key writes it, yyyy-MM-dd.
    public var issued: String
    public var products: [String]

    public init(name: String, email: String, issued: String, products: [String]) {
        self.name = name
        self.email = email
        self.issued = issued
        self.products = products
    }

    public func covers(_ product: String) -> Bool { products.contains(product) }

    /// The issue date as a date (noon UTC), for showing it in the user's locale; nil when `issued` isn't a real date.
    public var issuedDate: Date? {
        guard ProKeys.isDate(issued) else { return nil }
        let parts = issued.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

/// A key that can't be used, with the reason in plain words (shown as it is).
public struct ProKeyError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Where an app keeps the installed key (the app: its settings and the shared file; tests: memory).
public protocol ProStore: AnyObject, Sendable {
    func read() -> String?
    func write(_ key: String?)
}

public final class MemoryProStore: ProStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(_ key: String? = nil) { self.key = key }

    public func read() -> String? { lock.withLock { key } }
    public func write(_ key: String?) { lock.withLock { self.key = key } }
}

/// Checks a key's ECDSA P-256 signature (SHA-256 over the payload, r||s) against an uncompressed public point. PrintCore
/// is Foundation-only, so the check itself is the platform's: CryptoKit's `P256.Signing` in PrintMac (as PdfCore's
/// `ProKeys` does), a stand-in in the Windows-run tests.
public protocol ProSignatureVerifier: Sendable {
    func isValid(signature: [UInt8], for payload: [UInt8], publicKey: [UInt8]) -> Bool
}

/// Signs a payload (the issuing tool and the tests; the app never signs).
public protocol ProSigner {
    /// The uncompressed public point (0x04, X, Y: 65 bytes) of the private key that signs.
    var publicKey: [UInt8] { get }
    /// The 64-byte r||s signature of SHA-256(payload).
    func sign(_ payload: [UInt8]) -> [UInt8]
}

/// No verifier set: every key fails its signature check (an app that forgot to set one licenses nothing).
public struct NoProSignatureVerifier: ProSignatureVerifier {
    public init() {}
    public func isValid(signature: [UInt8], for payload: [UInt8], publicKey: [UInt8]) -> Bool { false }
}

/// The Inkvolt Pro licence key, the same for Inkvolt PDF and Inkvolt Print (the Windows suite's `ProKeys`): text a person
/// pastes, `INKVOLT-PRO-` followed by base32 (RFC 4648, A-Z and 2-7, no padding) in groups of five joined by hyphens. The
/// base32 decodes to a payload followed by a 64-byte signature. The payload is one version byte (1) and UTF-8 text of four
/// lines joined by "\n": name, email, issue date (yyyy-MM-dd), products (comma-separated: "pdf", "print"). The signature is
/// ECDSA P-256 over SHA-256 of the whole payload, as r||s; the public key is the uncompressed point. Documented, with a test
/// vector, in pdf/tools/pro-key/README.md.
public enum ProKeys {
    public static let prefix = "INKVOLT-PRO-"
    public static let version: UInt8 = 1
    public static let productPdf = "pdf"
    public static let productPrint = "print"
    public static let knownProducts = [productPdf, productPrint]

    /// Inkvolt's licence-signing public key (P-256, uncompressed point, base64). The private key is kept outside the repo.
    public static let publicKeyBase64 = "BEWmCvAPieAfsK5Me8N4rjUripueixRJ6g4R3qyY4O7IUNTUc5IUGpOFWUyZ7tTaveT94uIkXQV98EUl/vPXL0Y="
    public static let publicKey: [UInt8] = Array(Data(base64Encoded: publicKeyBase64) ?? Data())

    private static let signatureLength = 64
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let group = 5

    /// The app a product name stands for, as the refusals name it.
    public static func productName(_ product: String) -> String {
        switch product {
        case productPdf: "Inkvolt PDF"
        case productPrint: "Inkvolt Print"
        default: product
        }
    }

    /// Signs a licence: the key text to send.
    public static func issue(_ licence: ProLicence, _ signer: ProSigner) throws -> String {
        func bad(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty || s.contains("\n") || s.contains("\r") }
        if bad(licence.name) { throw ProKeyError("The name is empty or has a line break.") }
        if bad(licence.email) { throw ProKeyError("The email is empty or has a line break.") }
        if licence.products.isEmpty || licence.products.contains(where: { !knownProducts.contains($0) }) {
            throw ProKeyError("Products must be some of \(knownProducts.joined(separator: ", ")).")
        }
        return encode(payload(licence), signer)
    }

    /// The key text for a payload as it is (the tests make payloads `issue` refuses to).
    public static func encode(_ payload: [UInt8], _ signer: ProSigner) -> String {
        prefix + hyphenate(toBase32(payload + signer.sign(payload)))
    }

    /// The signed bytes of a licence: the version byte, then the four lines.
    public static func payload(_ licence: ProLicence) -> [UInt8] {
        let text = [licence.name.trimmingCharacters(in: .whitespaces), licence.email.trimmingCharacters(in: .whitespaces), licence.issued,
                    licence.products.joined(separator: ",")].joined(separator: "\n")
        return [version] + Array(text.utf8)
    }

    /// Reads and checks a key against `publicKey` (an uncompressed P-256 point; Inkvolt's by default).
    public static func parse(_ key: String, verifier: ProSignatureVerifier, publicKey: [UInt8] = ProKeys.publicKey) throws -> ProLicence {
        let compact = self.compact(key)
        if compact.isEmpty { throw ProKeyError("Paste the key you were sent.") }
        let head = self.compact(prefix)
        guard compact.hasPrefix(head) else { throw ProKeyError("That isn't an Inkvolt Pro key: a key starts with \(prefix).") }
        let body = Array(compact.dropFirst(head.count))
        if body.contains(where: { !alphabet.contains($0) }) {
            throw ProKeyError("The key has a character that doesn't belong in it (a key uses the letters A to Z and the digits 2 to 7). Paste it exactly as it was sent.")
        }
        let bytes = fromBase32(body)
        if bytes.count < 1 + signatureLength + 4 { throw ProKeyError("The key is incomplete: paste all of it.") }
        if bytes[0] != version { throw ProKeyError("This key was made for a newer version of the Inkvolt apps. Update the app, then enter it again.") }
        let payload = Array(bytes.dropLast(signatureLength))
        let signature = Array(bytes.suffix(signatureLength))
        guard publicKey.count == 65, publicKey[0] == 4 else { throw ProKeyError("The public key must be an uncompressed P-256 point (65 bytes).") }
        guard verifier.isValid(signature: signature, for: payload, publicKey: publicKey) else {
            throw ProKeyError("This key has been altered or didn't paste whole. Paste it exactly as it was sent, or ask for it again.")
        }
        guard let text = String(validating: payload.dropFirst(), as: UTF8.self) else {
            throw ProKeyError("The key's contents can't be read. Ask for it again.")
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count == 4, isDate(lines[2]) else { throw ProKeyError("The key's contents can't be read. Ask for it again.") }
        let products = lines[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ProLicence(name: lines[0], email: lines[1], issued: lines[2], products: products)
    }

    /// The key as it is shown and stored: the prefix, then groups of five, whatever spacing it was pasted with.
    public static func format(_ key: String) -> String {
        let compact = self.compact(key), head = self.compact(prefix)
        return compact.hasPrefix(head) ? prefix + hyphenate(String(compact.dropFirst(head.count))) : key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// yyyy-MM-dd, a real date (.NET's `DateOnly.TryParseExact`).
    static func isDate(_ s: String) -> Bool {
        let parts = s.split(separator: "-", omittingEmptySubsequences: false)
        guard s.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), (1...9999).contains(y), (1...12).contains(m), d >= 1 else { return false }
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        return d <= days
    }

    private static func compact(_ key: String) -> String {
        String(key.filter { !$0.isWhitespace && $0 != "-" }.uppercased())
    }

    private static func hyphenate(_ s: String) -> String {
        let chars = Array(s)
        return stride(from: 0, to: chars.count, by: group).map { String(chars[$0..<min($0 + group, chars.count)]) }.joined(separator: "-")
    }

    public static func toBase32(_ bytes: [UInt8]) -> String {
        var out = ""
        var buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8 | Int(b)) & 0xFFFF
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    public static func fromBase32(_ text: [Character]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.count * 5 / 8)
        var buffer = 0, bits = 0
        for c in text {
            buffer = (buffer << 5 | (alphabet.firstIndex(of: c) ?? 0)) & 0xFFFF
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((buffer >> (bits - 8)) & 255))
                bits -= 8
            }
        }
        return bytes
    }
}
