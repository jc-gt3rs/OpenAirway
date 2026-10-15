//
//  KeychainStore.swift
//
//
//  Created by John Cris Antor on 6/20/2026.
//

import Foundation
import Security

/// Minimal keychain wrapper for storing and retrieving the license JWT.
///
/// Uses `kSecClassGenericPassword` with a fixed service + account pair.
/// The token is stored as UTF-8 data and is accessible after first device unlock,
/// ensuring availability during headless login-item launches.
enum KeychainStore {
    private static let service = "com.airway.app.license"
    private static let account = "token"

    /// Stores or overwrites the current license JWT in the keychain.
    @discardableResult
    static func save(token: String) -> Bool {
        guard let data = token.data(using: .utf8) else { return false }

        // Try to update an existing entry first — avoids a delete+add race.
        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        // No existing entry — add a new one.
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            NSLog("[Airway] Keychain save failed: \(addStatus)")
        }
        return addStatus == errSecSuccess
    }

    /// Retrieves the stored license JWT, or `nil` if none exists.
    static func loadToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Removes the stored license JWT from the keychain.
    @discardableResult
    static func deleteToken() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
