import CryptoKit
import Foundation
import Security

struct SavedLoginProfile: Codable, Identifiable, Equatable {
    let id: String
    let email: String
    let accountID: String
    let savedAt: Date
}

struct SavedCodexLogin {
    let profile: SavedLoginProfile
    let credentials: Data
}

enum LoginSwitchError: LocalizedError {
    case clientsRunning([String])
    case processCheckFailed
    case refreshRunning
    case unsupportedStorage
    case restrictedLogin
    case invalidCredentials
    case missingCredentials
    case unsafeFile
    case credentialsChanged
    case fileOperationFailed
    case keychain(OSStatus)
    case missingSavedLogin
    case currentVerificationFailed
    case verificationFailed
    case recoveryRequired
    case quitFailed
    case quitTimedOut
    case reopenFailed
    case signInFailed
    case alreadyCurrentLogin

    var errorDescription: String? {
        switch self {
        case .clientsRunning(let names): "Close these Codex clients before switching: \(names.joined(separator: ", ")). Clients with an unknown credential location must also be closed."
        case .processCheckFailed: "Runway could not check running Codex clients. No login was changed."
        case .refreshRunning: "Wait for Runway's refresh to finish, then try again."
        case .unsupportedStorage: "Switching requires Codex's file-based credential storage. Runway will not change your authentication settings."
        case .restrictedLogin: "This login does not match Codex's required login method or workspace."
        case .invalidCredentials: "This is not a reusable ChatGPT login. Sign in again in Codex, then save the login."
        case .missingCredentials: "No Codex login was found. Sign in again in Codex, then save the login."
        case .unsafeFile: "The Codex credential file or folder is not a safe, private file owned by you. No login was changed."
        case .credentialsChanged: "Codex credentials changed during the operation. Try again with all Codex clients closed."
        case .fileOperationFailed: "The Codex credential file could not be updated."
        case .keychain(let status): "Saved logins could not be accessed in macOS Keychain (\(status))."
        case .missingSavedLogin: "This saved login is unavailable. Save it again after signing in normally."
        case .currentVerificationFailed: "Your current login could not be verified. Sign in again in Codex, then save the login."
        case .verificationFailed: "The selected login could not be verified. Your previous login was restored. Sign in normally to the selected account and save it again."
        case .recoveryRequired: "Switching could not finish safely. Close all Codex clients and check the selected account before reopening Codex. Your saved logins remain in Keychain."
        case .quitFailed: "Codex declined the quit request. Finish or stop its active tasks, then try again. The login has not changed."
        case .quitTimedOut: "Codex did not finish quitting within 30 seconds. Finish or stop its active tasks, then try again. The login has not changed."
        case .reopenFailed: "The login was selected, but Codex could not be opened. Open Codex manually."
        case .signInFailed: "Sign-in did not complete. Your current Codex login has not changed."
        case .alreadyCurrentLogin: "This account is already selected in Codex. Use Save to update this login."
        }
    }
}

/// Parses identity labels from a locally authenticated cache. JWT claims are
/// labels, not proof of authentication; the App Server verifies after switching.
struct CodexLoginCache {
    let data: Data
    let email: String
    let accountID: String

    init(_ data: Data) throws {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["OPENAI_API_KEY"] == nil || root["OPENAI_API_KEY"] is NSNull,
              root["auth_mode"] == nil || root["auth_mode"] as? String == "chatgpt",
              let tokens = root["tokens"] as? [String: Any],
              let accountID = tokens["account_id"] as? String, !accountID.isEmpty,
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty,
              let idToken = tokens["id_token"] as? String,
              let claims = Self.claims(idToken),
              let email = claims["email"] as? String, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              auth["chatgpt_account_id"] as? String == accountID else {
            throw LoginSwitchError.invalidCredentials
        }
        self.data = data
        self.email = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.accountID = accountID
    }

    private static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func profile(home: URL, now: Date = .now) -> SavedLoginProfile {
        let key = home.path + "\u{0}" + accountID + "\u{0}" + email
        let id = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return SavedLoginProfile(id: id, email: email, accountID: accountID, savedAt: now)
    }

    func matches(_ profile: SavedLoginProfile, home: URL) -> Bool {
        self.profile(home: home).id == profile.id && email == profile.email && accountID == profile.accountID
    }
}

@MainActor
protocol SavedLoginStore {
    func profiles() throws -> [SavedLoginProfile]
    func save(_ login: SavedCodexLogin) throws
    func load(id: String) throws -> SavedCodexLogin
    func remove(id: String) throws
}

/// Credentials live only in device-local Keychain items, never preferences,
/// Runway archives, exports, logs, or its unencrypted ZIP backups.
@MainActor
final class KeychainSavedLoginStore: SavedLoginStore {
    private let service: String

    init(home: URL) {
        let scope = SHA256.hash(data: Data(home.path.utf8)).map { String(format: "%02x", $0) }.joined()
        service = "com.casperkristiansson.codex-runway.saved-logins." + scope
    }

    private func query(id: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrSynchronizable as String: false]
        if let id { query[kSecAttrAccount as String] = id }
        return query
    }

    func profiles() throws -> [SavedLoginProfile] {
        var query = query()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw LoginSwitchError.keychain(status) }
        guard let items = result as? [[String: Any]] else { throw LoginSwitchError.missingSavedLogin }
        return try items.map { item in
            guard let data = item[kSecAttrGeneric as String] as? Data,
                  let profile = try? JSONDecoder().decode(SavedLoginProfile.self, from: data),
                  item[kSecAttrAccount as String] as? String == profile.id else { throw LoginSwitchError.missingSavedLogin }
            return profile
        }.sorted { $0.email == $1.email ? $0.accountID < $1.accountID : $0.email < $1.email }
    }

    func save(_ login: SavedCodexLogin) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: login.credentials,
            kSecAttrGeneric as String: try JSONEncoder().encode(login.profile),
            kSecAttrLabel as String: "Codex Runway · \(login.profile.email)",
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let status = SecItemUpdate(query(id: login.profile.id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query(id: login.profile.id).merging(attributes) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw LoginSwitchError.keychain(added) }
        } else if status != errSecSuccess { throw LoginSwitchError.keychain(status) }
    }

    func load(id: String) throws -> SavedCodexLogin {
        var query = query(id: id)
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw LoginSwitchError.missingSavedLogin }
        guard status == errSecSuccess else { throw LoginSwitchError.keychain(status) }
        guard let item = result as? [String: Any], let credentials = item[kSecValueData as String] as? Data,
              let metadata = item[kSecAttrGeneric as String] as? Data,
              let profile = try? JSONDecoder().decode(SavedLoginProfile.self, from: metadata), profile.id == id else {
            throw LoginSwitchError.missingSavedLogin
        }
        return SavedCodexLogin(profile: profile, credentials: credentials)
    }

    func remove(id: String) throws {
        let status = SecItemDelete(query(id: id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LoginSwitchError.keychain(status) }
    }
}
