import Foundation
import PrintCore
import Security

/// Each printer's SNMP login (`SnmpLogin`) in the user's keychain, as the admin passwords are (`PrinterPasswords`): one
/// generic password per printer id, readable only by Inkvolt Print. Nothing is kept for "public". Never in the state file or
/// a log. Reading never throws: a login that can't be read is asked with public. Any thread. The Windows app's
/// `SnmpLoginStore` (Credential Manager).
public struct SnmpLoginKeychain: SnmpLogins {
    static let service = "com.bermudezsystems.InkvoltPrint.snmp"

    public init() {}

    public func get(_ printerId: String) -> SnmpLogin? {
        var query = Self.base(printerId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return SnmpLogin.fromSecret(String(data: data, encoding: .utf8))
    }

    /// Replaces what's kept in place (an update, never a delete first), so a login the keychain refuses leaves the one that
    /// worked; public deletes it.
    @discardableResult
    public func save(_ login: SnmpLogin, for printerId: String) -> Bool {
        if login.isDefault {
            delete(printerId)
            return true
        }
        let data = Data(login.toSecret().utf8)
        let update = SecItemUpdate(Self.base(printerId) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = Self.base(printerId)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Inkvolt Print: printer SNMP login"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public func delete(_ printerId: String) {
        SecItemDelete(Self.base(printerId) as CFDictionary)
    }

    private static func base(_ printerId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: printerId.lowercased()]
    }
}
