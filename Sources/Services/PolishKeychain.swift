import Foundation
import LocalAuthentication
import Security

/// A credential belongs to an exact endpoint, never to whichever URL is edited next.
enum PolishKeychain {
    static let service = "com.saylane.final-polish"
    /// Pre-0.3 service name; items found there are moved on first read.
    static let legacyService = "com.rtranslate.final-polish"

    private static func query(_ endpoint: URL, service: String = PolishKeychain.service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: endpoint.absoluteString]
    }
    static func read(endpoint: URL) throws -> String {
        if let key = try read(endpoint: endpoint, service: service) { return key }
        guard let legacy = try read(endpoint: endpoint, service: legacyService) else { return "" }
        // Migrate silently, but delete the only durable copy only after the new
        // service has accepted it.  A signing/ACL failure must remain retryable.
        do {
            try save(legacy, endpoint: endpoint)
            _ = SecItemDelete(query(endpoint, service: legacyService) as CFDictionary)
        } catch { /* keep the legacy item; this read can still proceed */ }
        return legacy
    }
    private static func read(endpoint: URL, service: String) throws -> String? {
        var q = query(endpoint, service: service)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        // No surprise Keychain permission dialog in the middle of finalizing dictation.
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
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
        for service in [service, legacyService] {
            let status = SecItemDelete(query(endpoint, service: service) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeyError.status(status) }
        }
    }
    enum KeyError: LocalizedError {
        case status(OSStatus)
        var errorDescription: String? { String(localized: "无法访问润色服务密钥，请在设置中重新保存 API Key。") }
    }
}
