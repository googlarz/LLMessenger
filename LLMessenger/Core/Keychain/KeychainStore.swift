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

struct KeychainStore {
    let service: String

    init(service: String = "com.llmessenger.app") {
        self.service = service
    }

    func set(account: String, value: String) throws {
        let data = Data(value.utf8)
        // Search query omits kSecAttrAccessible so it matches items regardless of
        // how they were originally stored (including pre-existing items without the attribute).
        let searchQuery: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Update payload sets the accessibility class, migrating legacy items on first write.
        let updateAttributes: [String: Any] = [
            kSecValueData as String:        data,
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(searchQuery as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = searchQuery
            addQuery[kSecValueData as String]      = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(addStatus)
            }
            return
        }
        throw KeychainError.unexpectedStatus(updateStatus)
    }

    func get(account: String) throws -> String {
        // kSecAttrAccessible is intentionally omitted from the search query —
        // including it would filter out items stored without that attribute.
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw KeychainError.itemNotFound }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
        guard let data = result as? Data,
              let str = String(data: data, encoding: .utf8) else {
            throw KeychainError.invalidData
        }
        return str
    }

    func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError.unexpectedStatus(status)
    }
}
