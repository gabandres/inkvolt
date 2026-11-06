import Foundation
import Synchronization

/// How Inkvolt Print signs in to one printer's SNMP agent: a read community (v1, v2c). A secret: kept by an `SnmpLogins`
/// store (the Keychain in the app), never in `state.json`, a recording or the log; its description and mirror name no
/// secret. A printer with nothing kept is asked with `public`. The Windows Core's `SnmpLogin`.
public struct SnmpLogin: Equatable, Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The longest community taken, in bytes of UTF-8 (RFC 3417's OCTET STRING has no limit; net-snmp's agents stop at 255).
    public static let maxCommunity = 255

    /// The v1/v2c community.
    public let community: String

    private init(community: String) {
        self.community = community
    }

    /// "public", the read community nearly every printer ships with.
    public static let `public` = SnmpLogin(community: SnmpClient.defaultCommunity)

    /// Nothing to keep: the community every printer is asked with anyway.
    public var isDefault: Bool { community == SnmpClient.defaultCommunity }

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

    /// The login as one string, for an `SnmpLogins` store to keep (and only for that).
    public func toSecret() -> String { "community:" + community }

    /// A login kept by `toSecret`; nil for anything else (a damaged or unknown entry: asked with public).
    public static func fromSecret(_ secret: String?) -> SnmpLogin? {
        guard let secret else { return nil }
        if secret.hasPrefix("community:") { return try? forCommunity(String(secret.dropFirst("community:".count))) }
        return nil
    }

    /// For logs: never the community.
    public var description: String { isDefault ? "SNMP community public" : "SNMP community (kept)" }

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
