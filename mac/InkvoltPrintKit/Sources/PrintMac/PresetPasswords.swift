import Foundation
import Security
import Synchronization

/// The passwords scan presets put on their PDFs (`ScanPreset.password`, roadmap 4.18), by preset id: in the user's login
/// keychain, readable only by Inkvolt Print, or (demo mode) in memory. Never in the presets or the state file. A preset
/// deleted, or whose password was turned off, loses its saved password when the editor saves
/// (`ScanPresets.passwordsToForget`). Windows keeps them in Credential Manager. Any thread.
public final class PresetPasswords: Sendable {
    static let service = "com.bermudezsystems.InkvoltPrint.preset-pdf"

    private let inMemory: Bool
    private let memory = Mutex<[String: String]>([:])

    /// `inMemory`: demo mode's, nothing written to the keychain.
    public init(inMemory: Bool) { self.inMemory = inMemory }

    public func password(for presetId: String) -> String? {
        if inMemory { return memory.withLock { $0[presetId] } }
        var query = Self.base(presetId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores (or replaces) the password; false when the keychain refused.
    @discardableResult
    public func set(_ password: String, for presetId: String) -> Bool {
        if inMemory {
            memory.withLock { $0[presetId] = password }
            return true
        }
        let data = Data(password.utf8)
        let update = SecItemUpdate(Self.base(presetId) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = Self.base(presetId)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Inkvolt Print: a scan preset's PDF password"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func remove(for presetId: String) {
        if inMemory {
            memory.withLock { $0[presetId] = nil }
            return
        }
        SecItemDelete(Self.base(presetId) as CFDictionary)
    }

    private static func base(_ presetId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: presetId]
    }
}
