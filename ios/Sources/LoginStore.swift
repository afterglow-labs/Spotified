import Foundation
import Security

enum LoginStore {
    private static func query(origin: String, username: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.afterglowlabs.spotified.ios.server",
         kSecAttrAccount as String: origin + "|" + username]
    }

    static func read(origin: String, username: String) -> String? {
        var query = query(origin: origin, username: username)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String, origin: String, username: String) throws {
        let query = query(origin: origin, username: username)
        let values = [kSecValueData as String: Data(password.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query.merging(values) { _, new in new }
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(entry as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    static func delete(origin: String, username: String) {
        SecItemDelete(query(origin: origin, username: username) as CFDictionary)
    }
}
