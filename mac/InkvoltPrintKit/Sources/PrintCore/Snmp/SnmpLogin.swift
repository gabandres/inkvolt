import Foundation
import Synchronization

/// How Inkvolt Print signs in to one printer's SNMP agent: a read community (v1, v2c), or (Inkvolt Pro) an SNMPv3 user with
/// its two passphrases (`SnmpV3User`: SHA-256 authentication, AES-128 privacy). A secret: kept by an `SnmpLogins` store
/// (the Keychain in the app), never in `state.json`, a recording or the log; its description and mirror name no secret. A
/// printer with nothing kept is asked with `public`. The Windows Core's `SnmpLogin`.
public struct SnmpLogin: Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The longest community taken, in bytes of UTF-8 (RFC 3417's OCTET STRING has no limit; net-snmp's agents stop at 255).
    public static let maxCommunity = 255

    /// The v1/v2c community; empty for an SNMPv3 login.
    public let community: String

    /// The SNMPv3 user (an Inkvolt Pro feature); nil for a community.
    public let user: SnmpV3User?

    private init(community: String, user: SnmpV3User? = nil) {
        self.community = community
        self.user = user
    }

    /// "public", the read community nearly every printer ships with.
    public static let `public` = SnmpLogin(community: SnmpClient.defaultCommunity)

    /// Nothing to keep: the community every printer is asked with anyway.
    public var isDefault: Bool { user == nil && community == SnmpClient.defaultCommunity }

    /// An SNMPv3 user as typed: a name (1 to 32 bytes of UTF-8, RFC 3414's limit, so an accented one is measured as the
    /// agent does) and two passphrases of `SnmpV3User.minPassphrase` to `maxPassphrase` characters (RFC 3414 §11.2), none
    /// with control characters. Throws, saying why, otherwise.
    public static func forUser(_ name: String?, _ authPassphrase: String?, _ privPassphrase: String?) throws -> SnmpLogin {
        let name = name ?? "", auth = authPassphrase ?? "", priv = privPassphrase ?? ""
        let min = SnmpV3User.minPassphrase, max = SnmpV3User.maxPassphrase
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw SnmpLoginError("Enter the SNMPv3 user name.") }
        if name.utf8.count > SnmpV3User.maxName || name.unicodeScalars.contains(where: SnmpValue.isControl) {
            throw SnmpLoginError("The user name is 1 to \(SnmpV3User.maxName) characters, without control characters.")
        }
        if auth.utf16.count < min { throw SnmpLoginError("The authentication passphrase has at least \(min) characters.") }
        if priv.utf16.count < min { throw SnmpLoginError("The privacy passphrase has at least \(min) characters.") }
        if auth.utf16.count > max || priv.utf16.count > max { throw SnmpLoginError("A passphrase can have at most \(max) characters.") }
        if (auth + priv).unicodeScalars.contains(where: SnmpValue.isControl) {
            throw SnmpLoginError("The passphrases can't have tabs, line breaks or other control characters.")
        }
        return SnmpLogin(community: "", user: SnmpV3User(name: name, authPassphrase: auth, privPassphrase: priv))
    }

    /// A community as typed: blank is `public`; otherwise as it is (spaces count: an agent compares bytes). Throws, saying
    /// why, for one that can't be sent (control characters, longer than `maxCommunity` bytes).
    public static func forCommunity(_ text: String?) throws -> SnmpLogin {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .public }
        if text.unicodeScalars.contains(where: SnmpValue.isControl) {
            throw SnmpLoginError("The community can't have tabs, line breaks or other control characters.")
        }
        if text.utf8.count > maxCommunity { throw SnmpLoginError("The community can be at most \(maxCommunity) characters.") }
        return SnmpLogin(community: text)
    }

    /// The login as one string, for an `SnmpLogins` store to keep (and only for that): `community:` and the community, or
    /// `usm:` and the user's name and passphrases in base64, separated by colons (Windows' form).
    public func toSecret() -> String {
        guard let user else { return "community:" + community }
        let parts = [user.name, user.authPassphrase, user.privPassphrase].map { Data($0.utf8).base64EncodedString() }
        return "usm:" + parts.joined(separator: ":")
    }

    /// A login kept by `toSecret`; nil for anything else (a damaged or unknown entry: asked with public).
    public static func fromSecret(_ secret: String?) -> SnmpLogin? {
        guard let secret else { return nil }
        if secret.hasPrefix("community:") { return try? forCommunity(String(secret.dropFirst("community:".count))) }
        guard secret.hasPrefix("usm:") else { return nil }
        let parts = secret.dropFirst(4).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var texts: [String] = []
        for part in parts {
            guard let data = Data(base64Encoded: String(part)), let text = String(data: data, encoding: .utf8) else { return nil }
            texts.append(text)
        }
        return try? forUser(texts[0], texts[1], texts[2])
    }

    /// For logs: never the community, a user name or a passphrase.
    public var description: String {
        user != nil ? "SNMPv3 user (kept)" : isDefault ? "SNMP community public" : "SNMP community (kept)"
    }

    public var debugDescription: String { description }

    /// Nothing for `dump` or a reflecting description to show.
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// A login that can't be used, and why (in the user's words; it names no secret).
public struct SnmpLoginError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
}

/// Where each printer's `SnmpLogin` is kept, by printer id: the Keychain (PrintMac's `SnmpLoginKeychain`), or memory (demo
/// mode, tests). The Windows Core's `ISnmpLogins`.
public protocol SnmpLogins: Sendable {
    /// The printer's login; nil when none is kept (asked with `SnmpLogin.public`) or it can't be read.
    func get(_ printerId: String) -> SnmpLogin?

    /// Keeps `login` for the printer (replacing what was kept, which stays when the store refuses); `isDefault` deletes what
    /// was kept instead. False when the store refused.
    @discardableResult
    func save(_ login: SnmpLogin, for printerId: String) -> Bool

    func delete(_ printerId: String)
}

extension SnmpLogins {
    /// Moves a printer's login to its new id; never overwrites one kept there.
    public func rename(_ oldId: String, to newId: String) {
        guard let login = get(oldId) else { return }
        if get(newId) == nil { save(login, for: newId) }
        delete(oldId)
    }

    /// The printer's login as it may be used now (what every reader of a printer asks: the app, `status --all`): an SNMPv3
    /// user only while Inkvolt Pro allows it (`Pro.allows(.snmpV3)`), else none (public); a community always (free). What
    /// is kept stays, for when a licence comes. Windows' `SnmpLoginRules.Usable`.
    public func usable(_ printerId: String) -> SnmpLogin? {
        guard let login = get(printerId) else { return nil }
        return login.user != nil && !Pro.allows(.snmpV3) ? nil : login
    }
}

/// Logins kept for this run only: demo mode writes nothing to the Keychain; the tests' store.
public final class MemorySnmpLogins: SnmpLogins {
    private let kept = Mutex<[String: String]>([:])

    public init() {}

    public func get(_ printerId: String) -> SnmpLogin? {
        SnmpLogin.fromSecret(kept.withLock { $0[printerId.lowercased()] })
    }

    @discardableResult
    public func save(_ login: SnmpLogin, for printerId: String) -> Bool {
        kept.withLock { $0[printerId.lowercased()] = login.isDefault ? nil : login.toSecret() }
        return true
    }

    public func delete(_ printerId: String) {
        kept.withLock { _ = $0.removeValue(forKey: printerId.lowercased()) }
    }

    /// How many printers have a login kept (tests).
    public var count: Int { kept.withLock { $0.count } }
}
