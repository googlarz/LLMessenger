// LLMessenger/Core/Keychain/KeychainStore.swift
import Foundation
import Security

enum KeychainError: Error, LocalizedError {
    case itemNotFound
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .itemNotFound:            return "Keychain item not found"
        case .unexpectedStatus(let s): return "Keychain error: status \(s)"
        case .invalidData:             return "Keychain data is not valid UTF-8"
        }
    }
}

// All credentials are stored as a single JSON blob under one keychain item so
// macOS only prompts once (and after "Always Allow", never again).
// Legacy per-account items are migrated automatically on first read/write.
struct KeychainStore {
    static let service = "LLMessenger"
    static let account = "credentials"

    // MARK: - Public interface (same as before — callers unchanged)

    func set(account key: String, value: String) throws {
        var bag = load()
        bag[key] = value
        try save(bag)
    }

    func get(account key: String) throws -> String {
        let bag = load()
        guard let value = bag[key] else { throw KeychainError.itemNotFound }
        return value
    }

    func delete(account key: String) throws {
        var bag = load()
        guard bag[key] != nil else { return }
        bag.removeValue(forKey: key)
        try save(bag)
    }

    // MARK: - Migration from individual items

    /// Call once at startup: reads any per-account legacy items (old service names),
    /// merges them into the single blob, then deletes the originals.
    func migrateIfNeeded(account: String, legacyService: String) {
        // Already in the blob?
        if (try? get(account: account)) != nil { return }
        // Try to read from the old per-item store.
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return }
        try? set(account: account, value: value)
        // Clean up old item.
        let del: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: legacyService,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(del as CFDictionary)
    }

    // MARK: - Private

    private func load() -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let bag = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return bag
    }

    private func save(_ bag: [String: String]) throws {
        guard let data = try? JSONEncoder().encode(bag) else {
            throw KeychainError.invalidData
        }
        let searchQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
        let updateStatus = SecItemUpdate(
            searchQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = searchQuery
            addQuery[kSecValueData as String]      = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }
        throw KeychainError.unexpectedStatus(updateStatus)
    }
}
