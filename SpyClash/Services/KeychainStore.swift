import Foundation
import Security

enum KeychainStore {
    private static let service = "com.spyclash.ios"
    private static let legacyService = "com.spyclash.app"
    private static let account = "base44_access_token"

    static func saveToken(_ token: String) {
        guard storeToken(token, service: service) else { return }
        deleteToken(service: legacyService)
    }

    @discardableResult
    private static func storeToken(_ token: String, service: String) -> Bool {
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(identityQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var addQuery = identityQuery
        attributes.forEach { addQuery[$0.key] = $0.value }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    static func readToken() -> String? {
        if let token = readToken(service: service) {
            return token
        }

        guard let legacyToken = readToken(service: legacyService) else {
            return nil
        }

        if storeToken(legacyToken, service: service) {
            deleteToken(service: legacyService)
        }
        return legacyToken
    }

    private static func readToken(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func clearToken() {
        deleteToken(service: service)
        deleteToken(service: legacyService)
    }

    private static func deleteToken(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
