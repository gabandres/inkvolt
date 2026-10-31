import Foundation
import Security

/// The API key being edited in Settings › AI assistant, tied to one endpoint. A typed key, or "remove the saved key",
/// belongs to the endpoint it was entered for: changing the endpoint (preset or address) drops both, so a key for one
/// service is never tested against, sent to, saved for or removed from another.
public final class AiKeyDraft {
    /// The endpoint (`AiEndpoint.key`) the draft belongs to; nil while the address is invalid.
    public private(set) var endpointKey: String?
    /// A key typed for `endpointKey`, or nil.
    public private(set) var typed: String?
    /// True when the saved key of `endpointKey` is to be removed.
    public private(set) var remove = false

    public init(_ endpointKey: String?) { self.endpointKey = endpointKey }

    /// The address changed. Returns true when it is another endpoint, and so the typed key and removal were dropped.
    @discardableResult
    public func endpointChanged(_ key: String?) -> Bool {
        if key?.lowercased() == endpointKey?.lowercased() { return false }
        endpointKey = key
        typed = nil
        remove = false
        return true
    }

    public func type(_ key: String?) {
        let trimmed = AiText.trim(key ?? "")
        typed = trimmed.isEmpty ? nil : trimmed
        if typed != nil { remove = false }
    }

    public func removeSaved() {
        typed = nil
        remove = true
    }

    /// The key a request to `endpointKey` uses now: the typed one, else the saved one unless it is being removed.
    public func keyToUse(_ saved: (String) -> String?) -> String? {
        guard let endpointKey else { return nil }
        return typed ?? (remove ? nil : saved(endpointKey))
    }
}

/// Where API keys are kept, one per endpoint (a key goes only to the endpoint it was entered for), by the endpoint's
/// `AiEndpoint.key`, compared without regard to case.
public protocol AiKeyStore: Sendable {
    func get(_ endpointKey: String) -> String?
    /// Saves (or with nil, forgets) the key for an endpoint.
    /// - Throws: `AiError` with a message for the user when it couldn't be saved.
    func set(_ endpointKey: String, _ apiKey: String?) throws
}

extension AiKeyStore {
    public func has(_ endpointKey: String) -> Bool { !(get(endpointKey) ?? "").isEmpty }
}

/// The Keychain store (the Windows app's DPAPI file): each key is a generic password in the user's login keychain, under
/// the app's service name, with the endpoint as its account. Never in UserDefaults or a file of ours, never logged; the
/// Keychain's access list ties it to this app's signature. The file-based keychain, not the data protection one, which
/// needs an entitlement the DMG app doesn't have.
public struct AiKeychainStore: AiKeyStore, @unchecked Sendable {
    public static let appService = "com.bermudezsystems.InkvoltPdf.ai-key"
    private let service: String
    /// For tests: a keychain of their own (a `SecKeychain`), so they never touch the user's.
    private let keychain: AnyObject?

    public init(service: String = AiKeychainStore.appService, keychain: AnyObject? = nil) {
        self.service = service
        self.keychain = keychain
    }

    private func query(_ endpointKey: String) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: endpointKey.lowercased(),
        ]
        if let keychain { q[kSecMatchSearchList as String] = [keychain] }
        return q
    }

    public func get(_ endpointKey: String) -> String? {
        var q = query(endpointKey)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func set(_ endpointKey: String, _ apiKey: String?) throws {
        let trimmed = AiText.trim(apiKey ?? "")
        if trimmed.isEmpty {
            let status = SecItemDelete(query(endpointKey) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Self.notSaved(status) }
            return
        }
        let secret = Data(trimmed.utf8)
        let updated = SecItemUpdate(query(endpointKey) as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw Self.notSaved(updated) }
        var add = query(endpointKey)
        add[kSecMatchSearchList as String] = nil
        if let keychain { add[kSecUseKeychain as String] = keychain }
        add[kSecValueData as String] = secret
        add[kSecAttrLabel as String] = "Inkvolt PDF: AI assistant key"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Self.notSaved(status) }
    }

    /// The status number only, never the key.
    private static func notSaved(_ status: OSStatus) -> AiError {
        AiError("The API key couldn't be saved in your keychain (error \(status)).")
    }
}

/// Keys in memory, for tests and the self-test.
public final class AiMemoryKeyStore: AiKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    public init() {}

    public func get(_ endpointKey: String) -> String? {
        lock.withLock { keys[endpointKey.lowercased()] }
    }

    public func set(_ endpointKey: String, _ apiKey: String?) throws {
        let trimmed = AiText.trim(apiKey ?? "")
        lock.withLock { keys[endpointKey.lowercased()] = trimmed.isEmpty ? nil : trimmed }
    }
}
