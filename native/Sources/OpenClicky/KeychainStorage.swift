//
//  KeychainStorage.swift
//  Thin wrapper around Security.framework for storing small secrets
//  scoped to the OpenClicky bundle. Used by the ElevenLabs settings sheet
//  so API keys never hit a plaintext file.
//
//  Items are stored as `kSecClassGenericPassword` with:
//    - kSecAttrService = "com.kagantemizkan.openclicky.elevenlabs"
//    - kSecAttrAccount = the field name ("apiKey" / "voiceId")
//  Values live in the login keychain, locked when the Mac is locked.
//
//  This is intentionally the smallest Keychain surface that does the
//  job. No kSecAttrAccessGroup, no iCloud sharing, no access-control
//  policies — matches the security level we can promise at the app's
//  current signing (Apple Development cert, no Developer ID).
//

import Foundation
import Security

enum KeychainStorage {
    /// Reads the value for (service, account). Returns nil when absent
    /// or when the fetch fails for any reason (logged at debug level).
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]
        var item: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// Writes the value, replacing any existing entry. Empty strings
    /// delete the entry — convenient for "save empty to clear".
    @discardableResult
    static func write(service: String, account: String, value: String) -> Bool {
        guard !value.isEmpty else {
            return delete(service: service, account: account)
        }
        let data = Data(value.utf8)

        let baseQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Try update first; on "not found" fall through to add.
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    @discardableResult
    static func delete(service: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
