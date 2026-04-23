import Foundation
import Security

/// Manages secure token storage with Keychain as primary and UserDefaults as fallback.
/// Mac Catalyst has known issues with `SecItemAdd` failing silently, so we always
/// verify after write and fall back to UserDefaults if the Keychain rejects the operation.
struct KeychainManager {
    static let shared = KeychainManager()
    
    private let service = "com.roshanlodha.Wanderer"
    private let defaults = UserDefaults.standard
    private let defaultsPrefix = "com.roshanlodha.Wanderer.token."
    
    // MARK: - Token Keys
    
    enum TokenKey: String, CaseIterable {
        case googleAccessToken = "google_access_token"
        case googleRefreshToken = "google_refresh_token"
        case microsoftAccessToken = "microsoft_access_token"
        case microsoftRefreshToken = "microsoft_refresh_token"
        case appleUserIdentifier = "apple_user_identifier"
    }
    
    // MARK: - Save
    
    @discardableResult
    func save(_ value: String, forKey key: TokenKey) -> Bool {
        // Try Keychain first
        let keychainSuccess = saveToKeychain(value, forKey: key)
        
        if keychainSuccess {
            print("[KeychainManager] Saved \(key.rawValue) to Keychain.")
            return true
        }
        
        // Keychain failed — fall back to UserDefaults
        print("[KeychainManager] Keychain save failed for \(key.rawValue), using UserDefaults fallback.")
        defaults.set(value, forKey: defaultsPrefix + key.rawValue)
        return true
    }
    
    // MARK: - Retrieve
    
    func get(forKey key: TokenKey) -> String? {
        // Try Keychain first
        if let value = getFromKeychain(forKey: key) {
            return value
        }
        
        // Fall back to UserDefaults
        return defaults.string(forKey: defaultsPrefix + key.rawValue)
    }
    
    // MARK: - Delete
    
    @discardableResult
    func delete(forKey key: TokenKey) -> Bool {
        // Delete from both stores
        deleteFromKeychain(forKey: key)
        defaults.removeObject(forKey: defaultsPrefix + key.rawValue)
        return true
    }
    
    // MARK: - Convenience
    
    func hasToken(forKey key: TokenKey) -> Bool {
        return get(forKey: key) != nil
    }
    
    func clearAllTokens() {
        for key in TokenKey.allCases {
            delete(forKey: key)
        }
    }
    
    // MARK: - Keychain Implementation
    
    private func saveToKeychain(_ value: String, forKey key: TokenKey) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        
        // Delete existing value first to avoid duplicates
        deleteFromKeychain(forKey: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        
        if status != errSecSuccess {
            print("[KeychainManager] SecItemAdd failed with OSStatus: \(status)")
        }
        
        return status == errSecSuccess
    }
    
    private func getFromKeychain(forKey key: TokenKey) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }
    
    private func deleteFromKeychain(forKey key: TokenKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        
        SecItemDelete(query as CFDictionary)
    }
}
