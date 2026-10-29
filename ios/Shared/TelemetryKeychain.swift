import Foundation
import Security

enum TelemetryKeychain {
    private static func query(accessGroup: String) throws -> [String: Any] {
        guard accessGroup == (try TelemetryConfiguration.keychainAccessGroup()) else {
            throw TelemetryError.invalidConfiguration
        }
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.khatibi.enterprise.telemetry.auth",
            kSecAttrAccount as String: "shared-command-token",
            kSecAttrAccessGroup as String: accessGroup
        ]
    }

    static func set(token: String, accessGroup: String) -> Bool {
        do {
            let query = try query(accessGroup: accessGroup)
            if token.isEmpty {
                let result = SecItemDelete(query as CFDictionary)
                return result == errSecSuccess || result == errSecItemNotFound
            }
            guard token.utf8.count <= 8192,
                  !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
                return false
            }
            let values: [String: Any] = [
                kSecValueData as String: Data(token.utf8),
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
            if status == errSecItemNotFound {
                return SecItemAdd(query.merging(values) { _, value in value } as CFDictionary, nil) == errSecSuccess
            }
            return status == errSecSuccess
        } catch { return false }
    }

    static func token() throws -> String {
        var query = try query(accessGroup: TelemetryConfiguration.keychainAccessGroup())
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8),
              !token.isEmpty, data.count <= 8192,
              !token.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
            throw TelemetryError.keychainFailure
        }
        return token
    }
}
