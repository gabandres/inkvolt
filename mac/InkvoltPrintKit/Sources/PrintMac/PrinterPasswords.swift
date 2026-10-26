import Foundation
import Security

/// The printers' admin passwords (their web page's, which device settings need), in the user's login keychain: one
/// generic password per printer id, readable only by Inkvolt Print. Never in the state file or a log. Any thread.
public enum PrinterPasswords {
    static let service = "com.bermudezsystems.InkvoltPrint.printer-admin"

    public static func password(for printerId: String) -> String? {
        var query = base(printerId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores (or replaces) the password; false when the keychain refused.
    @discardableResult
    public static func set(_ password: String, for printerId: String) -> Bool {
        let data = Data(password.utf8)
        let update = SecItemUpdate(base(printerId) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = base(printerId)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        add[kSecAttrLabel as String] = "Inkvolt Print: printer admin password"
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func remove(for printerId: String) {
        SecItemDelete(base(printerId) as CFDictionary)
    }

    private static func base(_ printerId: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: printerId.lowercased()]
    }
}
