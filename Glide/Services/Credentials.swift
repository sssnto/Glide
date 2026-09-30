import Foundation
import Security

enum Credentials {
    static func save(_ secret: String, for id: UUID) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Glide.servers", kSecAttrAccount as String: id.uuidString]
        let values: [String: Any] = [kSecValueData as String: Data(secret.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        let result = update == errSecItemNotFound ? SecItemAdd(query.merging(values) { _, b in b } as CFDictionary, nil) : update
        guard result == errSecSuccess else { throw MediaError.message("无法将凭据保存到钥匙串（\(result)）。") }
    }
    static func read(_ id: UUID) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Glide.servers", kSecAttrAccount as String: id.uuidString, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func delete(_ id: UUID) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Glide.servers", kSecAttrAccount as String: id.uuidString] as CFDictionary)
    }
}
