import Foundation
import Security

struct KeychainManager {
    static let shared = KeychainManager()
    
    private let service = "com.roshanlodha.Wanderer"
    
    // MARK: - Token Keys
    
    enum TokenKey: String {
        case googleAccessToken = "google_access_token"
        case googleRefreshToken = "google_refresh_token"
        case microsoftAccessToken = "microsoft_access_token"
        case microsoftRefreshToken = "microsoft_refresh_token"
        case appleUserIdentifier = "apple_user_identifier"
    }
    
    // MARK: - Save
    
    @discardableResult
    func save(_ value: String, forKey key: TokenKey) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        
        // Delete existing value first to avoid duplicates
        delete(forKey: key)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]
        
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    // MARK: - Retrieve
    
    func get(forKey key: TokenKey) -> String? {
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
    
    // MARK: - Delete
    
    @discardableResult
    func delete(forKey key: TokenKey) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    // MARK: - Convenience
    
    func hasToken(forKey key: TokenKey) -> Bool {
        return get(forKey: key) != nil
    }
    
    func clearAllTokens() {
        for key in [TokenKey.googleAccessToken, .googleRefreshToken, .microsoftAccessToken, .microsoftRefreshToken] {
            delete(forKey: key)
        }
    }
}
