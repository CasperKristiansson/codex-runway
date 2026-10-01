import CryptoKit
import Foundation
import Security

struct LoginRecoveryRecord: Codable {
    let target: SavedLoginProfile
    let original: Data?
}

@MainActor
protocol LoginRecoveryStore {
    func load() throws -> LoginRecoveryRecord?
    func save(_ record: LoginRecoveryRecord) throws
    func clear() throws
}

/// A separate Keychain service prevents recovery secrets appearing in profile
/// listings or Runway exports. The durable record precedes the auth-file commit.
@MainActor
final class KeychainLoginRecoveryStore: LoginRecoveryStore {
    private let service: String
    init(home: URL) {
        let scope = SHA256.hash(data: Data(home.path.utf8)).map { String(format: "%02x", $0) }.joined()
        service = "com.casperkristiansson.codex-runway.login-recovery." + scope
    }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "pending-switch", kSecAttrSynchronizable as String: false]
    }
    func load() throws -> LoginRecoveryRecord? {
        var query = query
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LoginSwitchError.keychain(status) }
        guard let data = result as? Data, data.count <= 2_097_152,
              let record = try? JSONDecoder().decode(LoginRecoveryRecord.self, from: data) else {
            throw LoginSwitchError.recoveryRequired
        }
        return record
    }
    func save(_ record: LoginRecoveryRecord) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(record),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrLabel as String: "Codex Runway · interrupted switch recovery"]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw LoginSwitchError.keychain(added) }
        } else if status != errSecSuccess { throw LoginSwitchError.keychain(status) }
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LoginSwitchError.keychain(status) }
    }
}
