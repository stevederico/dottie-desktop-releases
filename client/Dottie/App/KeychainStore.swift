//
//  KeychainStore.swift
//  Dottie
//
//  Typed, strict wrapper over the macOS Security framework for storing cloud
//  provider API keys in the login Keychain (kSecClassGenericPassword) instead of
//  plaintext UserDefaults. Account name is the provider's `apiKeyStorageKey`
//  (e.g. "xaiAPIKey") so call sites stay unchanged.
//
//  Includes a one-time, lazy migration: the first `get(forAccount:)` for a
//  provider copies any legacy UserDefaults value into the Keychain and removes
//  the UserDefaults entry, so old installs upgrade transparently on first read.
//
//  Never logs or prints a key.
//

import Foundation
import Security

/// Stores per-provider API keys in the macOS Keychain.
enum KeychainStore {
    /// Shared service identifier — matches the app's bundle id.
    private static let service = "com.example.dottie"

    /// Reads the value for an account, migrating a legacy UserDefaults value into
    /// the Keychain on first access. Returns `nil` (never throws) when absent.
    ///
    /// Migration: if no Keychain item exists but a non-empty UserDefaults value
    /// is present under the same key, it is copied into the Keychain and the
    /// UserDefaults entry is removed before returning.
    /// - Parameter account: The Keychain account name (provider `apiKeyStorageKey`).
    static func get(forAccount account: String) -> String? {
        guard !account.isEmpty else { return nil }

        if let value = read(account: account) {
            return value
        }

        // One-time migration from legacy plaintext UserDefaults storage.
        if let legacy = UserDefaults.standard.string(forKey: account), !legacy.isEmpty {
            set(legacy, forAccount: account)
            UserDefaults.standard.removeObject(forKey: account)
            AppLogger.shared.info("[Keychain] Migrated legacy API key for '\(account)' from UserDefaults")
            return legacy
        }

        return nil
    }

    /// Writes (insert or update) the value for an account. An empty value deletes
    /// the item so an explicitly-cleared key doesn't linger in the Keychain.
    /// - Parameters:
    ///   - value: The secret to store.
    ///   - account: The Keychain account name (provider `apiKeyStorageKey`).
    static func set(_ value: String, forAccount account: String) {
        guard !account.isEmpty else { return }
        guard !value.isEmpty else {
            delete(forAccount: account)
            return
        }
        guard let data = value.data(using: .utf8) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        // Try to update an existing item first; if none exists, add it.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                AppLogger.shared.error("[Keychain] add failed for '\(account)' (OSStatus \(addStatus))")
            }
        } else if updateStatus != errSecSuccess {
            AppLogger.shared.error("[Keychain] update failed for '\(account)' (OSStatus \(updateStatus))")
        }
    }

    /// Deletes the item for an account. No-op (and not an error) when absent.
    /// - Parameter account: The Keychain account name (provider `apiKeyStorageKey`).
    static func delete(forAccount account: String) {
        guard !account.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            AppLogger.shared.error("[Keychain] delete failed for '\(account)' (OSStatus \(status))")
        }
    }

    /// Reads the raw Keychain item for an account, decoding it as UTF-8.
    /// Returns `nil` on any miss or read failure — never throws, never logs the value.
    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                AppLogger.shared.error("[Keychain] read failed for '\(account)' (OSStatus \(status))")
            }
            return nil
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }
}
