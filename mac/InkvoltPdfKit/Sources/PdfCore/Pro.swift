import CryptoKit
import Foundation

/// The features Inkvolt Pro unlocks (pdf/ROADMAP.md, "Free and Pro").
public enum ProFeature: CaseIterable, Sendable {
    /// Saving, importing and exporting batch presets (Batch itself stays free).
    case batchPresets
    /// Watched folders, in the app and from the command line.
    case watchedFolders
    /// `--batch` and `--watch` on the command line.
    case commandLine
}

/// What a licence key says: who it was issued to, when (yyyy-MM-dd), and for which Inkvolt apps ("pdf", "print").
public struct ProLicence: Equatable, Sendable {
    public var name: String
    public var email: String
    public var issued: String
    public var products: [String]

    public init(_ name: String, _ email: String, _ issued: String, _ products: [String]) {
        self.name = name
        self.email = email
        self.issued = issued
        self.products = products
    }

    public func covers(_ product: String) -> Bool { products.contains(product) }

    /// The issue date as a date (noon UTC), for showing it in the user's locale.
    public var issuedDate: Date? { ProKeys.parseDate(issued) }
}

/// A key that can't be used, with the reason in plain words (shown as it is; the Windows app's `ProKeyException`).
public struct ProKeyError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Where the installed key is kept (the app: its settings; tests: memory).
public protocol ProStore: AnyObject, Sendable {
    func read() -> String?
    func write(_ key: String?)
}

public final class MemoryProStore: ProStore, @unchecked Sendable {
    private let lock = NSLock()
    private var key: String?

    public init(_ key: String? = nil) { self.key = key }

    public func read() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return key
    }

    public func write(_ key: String?) {
        lock.lock()
        self.key = key
        lock.unlock()
    }
}

/// The Pro entitlement check (the Windows app's `Pro`): the one place that decides whether a Pro feature runs. Every
/// Pro feature asks `allows` and nowhere else. The licence is a key (`ProKeys`) signed with our private key and checked
/// here against the public key: no server is asked, nothing is sent, the key works offline and survives reinstalling (it
/// lives in the app's settings). Removing it never takes away a result already made: presets saved, files a watched
/// folder or the command line produced and their logs stay where they are.
public enum Pro {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var enforced = false
        var store: ProStore = MemoryProStore()
        var licence: ProLicence?
        var problem: String?
        var loaded = false
    }

    private static let state = State()

    /// The one switch. While it is false, everything is free: `allows` says yes to everyone (a key is still verified and
    /// shown in Help › Inkvolt Pro, and the purchase is a way to support the project or to get a licence a business can
    /// invoice). It flips to true, in a release noted in WHATS-NEW, once Inkvolt PDF has a few thousand installs or about
    /// 50 Store ratings; from then on the Pro features ask for a key. Tests set it either way.
    public static var enforced: Bool {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.enforced
        }
        set {
            state.lock.lock()
            state.enforced = newValue
            state.lock.unlock()
        }
    }

    public static let product = ProKeys.productPdf
    public static let priceText = "$19"
    public static let buyUrl = "https://bermudezsystems.com/products/inkvolt/pro"

    /// Where the key is kept. Setting it forgets what was read from the previous store.
    public static var store: ProStore {
        get {
            state.lock.lock()
            defer { state.lock.unlock() }
            return state.store
        }
        set {
            state.lock.lock()
            state.store = newValue
            state.loaded = false
            state.lock.unlock()
        }
    }

    /// The installed licence, or nil (none, or the stored key no longer checks out: `problem`).
    public static var licence: ProLicence? {
        state.lock.lock()
        defer { state.lock.unlock() }
        load()
        return state.licence
    }

    /// Why the stored key doesn't count, when there is one and it doesn't; nil otherwise.
    public static var problem: String? {
        state.lock.lock()
        defer { state.lock.unlock() }
        load()
        return state.problem
    }

    /// True when `feature` may run: always while `enforced` is off, else with a licence.
    public static func allows(_ feature: ProFeature) -> Bool { !enforced || licence != nil }

    /// Checks `key`, keeps it in the `store` and returns its licence; refuses with a reason.
    @discardableResult
    public static func install(_ key: String) throws -> ProLicence {
        let licence = try ProKeys.parse(key)
        if !licence.covers(product) {
            throw ProKeyError("This key is for Inkvolt Print, not Inkvolt PDF. A key for Inkvolt PDF lists it.")
        }
        state.lock.lock()
        state.store.write(ProKeys.format(key))
        state.licence = licence
        state.problem = nil
        state.loaded = true
        state.lock.unlock()
        return licence
    }

    /// Forgets the key. What the Pro features made stays.
    public static func remove() {
        state.lock.lock()
        state.store.write(nil)
        state.licence = nil
        state.problem = nil
        state.loaded = true
        state.lock.unlock()
    }

    /// Call under the lock.
    private static func load() {
        if state.loaded { return }
        state.loaded = true
        state.licence = nil
        state.problem = nil
        guard let stored = state.store.read(), !stored.isEmpty else { return }
        do {
            let licence = try ProKeys.parse(stored)
            if licence.covers(product) { state.licence = licence } else { state.problem = "The saved key is for Inkvolt Print, not Inkvolt PDF." }
        } catch let e as ProKeyError {
            state.problem = "The saved key no longer checks out: \(e.message)"
        } catch {
            state.problem = "The saved key no longer checks out: \(error)"
        }
    }

    /// The feature's name as the window shows it.
    public static func title(_ feature: ProFeature) -> String {
        switch feature {
        case .batchPresets: "Batch presets"
        case .watchedFolders: "Watched folders"
        case .commandLine: "Command line"
        }
    }

    /// What the feature does, for a person who hasn't unlocked it.
    public static func describe(_ feature: ProFeature) -> String {
        switch feature {
        case .batchPresets:
            "Save the list of Batch actions with their settings under a name and pick it next time; export a preset to share it or for the command line, import one from someone else."
        case .watchedFolders:
            "Drop PDFs or images into a folder and Inkvolt PDF runs a preset on each one once it has finished copying, moves the original to \"done\" or \"failed\" and logs a line for it."
        case .commandLine:
            "inkvoltpdf --batch runs a preset on files or folders without a window; inkvoltpdf --watch watches a folder from a terminal or a scheduled task."
        }
    }

    /// What a person is told when a feature isn't unlocked.
    public static func locked(_ feature: ProFeature) -> String {
        switch feature {
        case .batchPresets: "Saved batch presets are part of Inkvolt Pro."
        case .watchedFolders: "Watched folders are part of Inkvolt Pro."
        case .commandLine: "The command line is part of Inkvolt Pro."
        }
    }

    /// Where to get a key and where to enter it (after `locked` on the command line).
    public static var howToGet: String {
        "Inkvolt Pro is a one-time purchase (\(priceText)) at \(buyUrl); Help › Inkvolt Pro… in Inkvolt PDF enters the key."
    }
}

/// The licence key (the Windows app's `ProKeys`): text a person pastes, `INKVOLT-PRO-` followed by base32 (RFC 4648,
/// A-Z and 2-7, no padding) in groups of five joined by hyphens. The base32 decodes to a payload followed by a 64-byte
/// signature. The payload is one version byte (1) and UTF-8 text of four lines joined by "\n": name, email, issue date
/// (yyyy-MM-dd), products (comma-separated: "pdf", "print"). The signature is ECDSA P-256 over SHA-256 of the whole
/// payload, as r||s (IEEE P1363; CryptoKit's raw representation). The public key is the uncompressed point (0x04, X, Y:
/// 65 bytes). Documented, with a test vector, in pdf/tools/pro-key/README.md; Windows verifies the same key with .NET.
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

    /// Signs a licence with the private key: the key text to send.
    /// - Throws: `PdfEditError` for a licence that can't be issued (an empty name, an unknown product).
    public static func issue(_ licence: ProLicence, _ privateKey: P256.Signing.PrivateKey) throws -> String {
        if licence.name.trimmingCharacters(in: .whitespaces).isEmpty || hasLineBreak(licence.name) { throw PdfEditError("The name is empty or has a line break.") }
        if licence.email.trimmingCharacters(in: .whitespaces).isEmpty || hasLineBreak(licence.email) { throw PdfEditError("The email is empty or has a line break.") }
        if licence.products.isEmpty || licence.products.contains(where: { !knownProducts.contains($0) }) {
            throw PdfEditError("Products must be some of \(knownProducts.joined(separator: ", ")).")
        }
        return try encode(payload(licence), privateKey)
    }

    static func payload(_ licence: ProLicence) -> [UInt8] {
        let text = [licence.name.trimmingCharacters(in: .whitespaces), licence.email.trimmingCharacters(in: .whitespaces), licence.issued,
                    licence.products.joined(separator: ",")].joined(separator: "\n")
        return [version] + Array(text.utf8)
    }

    static func encode(_ payload: [UInt8], _ privateKey: P256.Signing.PrivateKey) throws -> String {
        let signature = try privateKey.signature(for: Data(payload))
        return prefix + hyphenate(toBase32(payload + Array(signature.rawRepresentation)))
    }

    /// Reads and checks a key against Inkvolt's public key.
    public static func parse(_ key: String) throws -> ProLicence { try parse(key, publicKey) }

    /// Reads and checks a key against `publicKey` (an uncompressed P-256 point).
    public static func parse(_ key: String, _ publicKey: [UInt8]) throws -> ProLicence {
        let compact = compact(key)
        if compact.isEmpty { throw ProKeyError("Paste the key you were sent.") }
        let prefixCompact = Self.compact(prefix)
        guard compact.hasPrefix(prefixCompact) else { throw ProKeyError("That isn't an Inkvolt Pro key: a key starts with \(prefix).") }
        let body = Array(compact.dropFirst(prefixCompact.count))
        if body.contains(where: { !alphabet.contains($0) }) {
            throw ProKeyError("The key has a character that doesn't belong in it (a key uses the letters A to Z and the digits 2 to 7). Paste it exactly as it was sent.")
        }
        let bytes = fromBase32(String(body))
        if bytes.count < 1 + signatureLength + 4 { throw ProKeyError("The key is incomplete: paste all of it.") }
        if bytes[0] != version {
            throw ProKeyError("This key was made for a newer version of Inkvolt PDF. Update Inkvolt PDF, then enter it again.")
        }
        let payload = Array(bytes[..<(bytes.count - signatureLength)])
        let signature = Array(bytes[(bytes.count - signatureLength)...])
        guard publicKey.count == 65, publicKey[0] == 4, let key = try? P256.Signing.PublicKey(x963Representation: Data(publicKey)) else {
            throw PdfEditError("The public key must be an uncompressed P-256 point (65 bytes).")
        }
        guard let sig = try? P256.Signing.ECDSASignature(rawRepresentation: Data(signature)), key.isValidSignature(sig, for: Data(payload)) else {
            throw ProKeyError("This key has been altered or didn't paste whole. Paste it exactly as it was sent, or ask for it again.")
        }
        guard let text = String(bytes: payload[1...], encoding: .utf8) else { throw ProKeyError("The key's contents can't be read. Ask for it again.") }
        let lines = text.components(separatedBy: "\n")
        guard lines.count == 4, parseDate(lines[2]) != nil else { throw ProKeyError("The key's contents can't be read. Ask for it again.") }
        let products = lines[3].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return ProLicence(lines[0], lines[1], lines[2], products)
    }

    /// The key as it is shown and stored: the prefix, then groups of five, whatever spacing it was pasted with.
    public static func format(_ key: String) -> String {
        let compact = compact(key)
        let prefixCompact = Self.compact(prefix)
        return compact.hasPrefix(prefixCompact) ? prefix + hyphenate(String(compact.dropFirst(prefixCompact.count))) : key.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A yyyy-MM-dd date (noon UTC), or nil when it isn't one.
    static func parseDate(_ text: String) -> Date? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour) = (y, m, d, 12)
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let date = cal.date(from: c), cal.component(.month, from: date) == m, cal.component(.day, from: date) == d else { return nil }
        return date
    }

    private static func compact(_ key: String) -> String {
        String(key.filter { !$0.isWhitespace && $0 != "-" }).uppercased()
    }

    private static func hasLineBreak(_ s: String) -> Bool { s.contains("\n") || s.contains("\r") }

    private static func hyphenate(_ s: String) -> String {
        let chars = Array(s)
        return stride(from: 0, to: chars.count, by: group).map { String(chars[$0..<min($0 + group, chars.count)]) }.joined(separator: "-")
    }

    static func toBase32(_ bytes: [UInt8]) -> String {
        var out = ""
        var buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }

    static func fromBase32(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var buffer = 0, bits = 0
        for c in text {
            buffer = (buffer << 5) | (alphabet.firstIndex(of: c) ?? 0)
            bits += 5
            if bits >= 8 {
                bytes.append(UInt8((buffer >> (bits - 8)) & 255))
                bits -= 8
            }
        }
        return bytes
    }
}
