import Foundation
import Security

/// Thin wrapper over the macOS Keychain for storing the Jev API key as a
/// generic password under service `com.alllllenshi.TimeSink`, keyed by
/// `account`. Never touched by unit tests -- only reached from
/// `JevService`'s default key provider and the Settings Jev pane.
public enum Keychain {
    private static let service = "com.alllllenshi.TimeSink"

    /// Upserts `value` for `account`: updates the existing item if present,
    /// otherwise adds a new one.
    public static func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            guard update == errSecSuccess else { throw KeychainError.osStatus(update) }
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let add = SecItemAdd(addQuery as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError.osStatus(add) }
        }
    }

    /// Returns the stored value for `account`, or nil if absent or on any error.
    public static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the stored item for `account`, if any. Swallows errors.
    public static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum KeychainError: Error {
    case osStatus(OSStatus)
}
