import Foundation
import Security

/// A credential belongs to an exact endpoint, never to whichever URL is edited next.
enum PolishKeychain {
    private static func query(_ endpoint: URL) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.rtranslate.final-polish",
         kSecAttrAccount as String: endpoint.absoluteString]
    }
    static func read(endpoint: URL) throws -> String {
        var q = query(endpoint)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        // No surprise Keychain permission dialog in the middle of finalizing dictation.
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeyError.status(status)
        }
        return key
    }
    static func save(_ key: String, endpoint: URL) throws {
        let data = Data(key.utf8)
        let q = query(endpoint)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = q
            attributes[kSecValueData as String] = data
            let added = SecItemAdd(attributes as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeyError.status(added) }
        } else if status != errSecSuccess { throw KeyError.status(status) }
    }
    static func delete(endpoint: URL) throws {
        let status = SecItemDelete(query(endpoint) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyError.status(status) }
    }
    enum KeyError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? { "无法访问润色服务密钥，请在设置中重新保存 API Key。" }
    }
}
