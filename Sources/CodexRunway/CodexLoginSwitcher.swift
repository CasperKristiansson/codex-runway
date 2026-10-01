import AppKit
import Foundation

struct CodexLoginConfiguration: Sendable {
    let storage: String
    var forcedLoginMethod: String? = nil
    var forcedWorkspaceID: String? = nil

    func validate(_ cache: CodexLoginCache? = nil) throws {
        guard storage == "file" else { throw LoginSwitchError.unsupportedStorage }
        guard forcedLoginMethod == nil || forcedLoginMethod == "chatgpt" else { throw LoginSwitchError.restrictedLogin }
        if let cache, let forcedWorkspaceID, cache.accountID != forcedWorkspaceID {
            throw LoginSwitchError.restrictedLogin
        }
    }
}

@MainActor
final class CodexLoginSwitcher {
    let authFile: CodexAuthFile
    private let vault: any SavedLoginStore
    private let assertClosed: () throws -> Void
    private let now: () -> Date
    private let recovery: any LoginRecoveryStore

    init(home: URL = CodexAuthFile.defaultHome, vault: (any SavedLoginStore)? = nil,
         recovery: (any LoginRecoveryStore)? = nil,
         assertClosed: (() throws -> Void)? = nil,
         now: @escaping () -> Date = { .now }) {
        let home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.authFile = CodexAuthFile(home: home)
        self.vault = vault ?? KeychainSavedLoginStore(home: home)
        self.assertClosed = assertClosed ?? { try CodexProcessGuard.assertClosed(home: home) }
        self.recovery = recovery ?? KeychainLoginRecoveryStore(home: home)
        self.now = now
    }

    func requireClosed() throws { try assertClosed() }
    func requireCurrent(_ profile: SavedLoginProfile) throws {
        try assertClosed()
        guard let data = try authFile.read(),
              let cache = try? CodexLoginCache(data), cache.matches(profile, home: authFile.home) else {
            throw LoginSwitchError.credentialsChanged
        }
    }
    func profiles() throws -> [SavedLoginProfile] { try vault.profiles() }

    func isCurrent(_ profile: SavedLoginProfile) throws -> Bool {
        guard let data = try authFile.read() else { return false }
        return try CodexLoginCache(data).matches(profile, home: authFile.home)
    }

    /// Inactive usage refresh never replaces the desktop credential file. Its
    /// per-operation home and token rotations belong solely to this saved login.
    func readSavedUsage(id: String, configuration: CodexLoginConfiguration,
                        read: @MainActor (URL, CodexLoginConfiguration) async throws -> ActiveCodexAccount = {
                            try await CodexAppServerClient().readActiveAccount(home: $0, configuration: $1)
                        }) async throws -> ActiveCodexAccount {
        let lock = try authFile.acquireOperationLock()
        defer { try? lock.close() }
        guard try !hasPendingRecovery() else { throw LoginSwitchError.recoveryRequired }
        let login = try vault.load(id: id)
        let cache = try CodexLoginCache(login.credentials)
        guard cache.matches(login.profile, home: authFile.home) else { throw LoginSwitchError.invalidCredentials }
        try configuration.validate(cache)
        guard try !isCurrent(login.profile) else { throw LoginSwitchError.alreadyCurrentLogin }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("runway-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: home) }
        let isolated = CodexAuthFile(home: home)
        try isolated.replace(with: login.credentials, expecting: nil, assertClosed: {})

        func retainRotations() throws {
            guard let latest = try isolated.read(), let updated = try? CodexLoginCache(latest),
                  updated.matches(login.profile, home: authFile.home) else { throw LoginSwitchError.invalidCredentials }
            // If another client selected this identity meanwhile, retain its
            // current cache instead of overwriting the vault with our clone.
            if try isCurrent(login.profile) {
                if let current = try authFile.read() {
                    let currentCache = try CodexLoginCache(current)
                    guard currentCache.matches(login.profile, home: authFile.home) else { throw LoginSwitchError.credentialsChanged }
                    try vault.save(SavedCodexLogin(profile: currentCache.profile(home: authFile.home, now: now()), credentials: current))
                }
                throw LoginSwitchError.credentialsChanged
            }
            // The lock covers other Runway instances; reject external vault updates too.
            guard try vault.load(id: id).credentials == login.credentials else { throw LoginSwitchError.credentialsChanged }
            try vault.save(SavedCodexLogin(profile: updated.profile(home: authFile.home, now: now()), credentials: latest))
        }

        let response: ActiveCodexAccount
        do {
            try Task.checkCancellation()
            response = try await read(home, configuration)
        } catch {
            // Authentication can rotate tokens even when fetching usage fails.
            try retainRotations()
            throw error
        }
        try retainRotations()
        guard response.identity.account?.type == "chatgpt",
              response.identity.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == cache.email,
              response.rateLimits.accountId == nil || response.rateLimits.accountId == cache.accountID else {
            throw CodexAppServerError.invalidResponse
        }
        return response
    }
    func forget(id: String) throws {
        guard try !hasPendingRecovery() else { throw LoginSwitchError.recoveryRequired }
        try vault.remove(id: id)
    }
    func hasPendingRecovery() throws -> Bool { try recovery.load() != nil }

    /// Validate the target and filesystem before asking the desktop to quit.
    func preflight(id: String, configuration: CodexLoginConfiguration) throws -> Bool {
        guard try !hasPendingRecovery() else { throw LoginSwitchError.recoveryRequired }
        let target = try vault.load(id: id)
        let cache = try CodexLoginCache(target.credentials)
        guard cache.matches(target.profile, home: authFile.home) else { throw LoginSwitchError.invalidCredentials }
        try configuration.validate(cache)
        guard let current = try authFile.read() else { return false }
        return try CodexLoginCache(current).matches(target.profile, home: authFile.home)
    }

    func importLogin(_ data: Data, configuration: CodexLoginConfiguration) throws -> SavedLoginProfile {
        let lock = try authFile.acquireOperationLock()
        defer { try? lock.close() }
        guard try !hasPendingRecovery() else { throw LoginSwitchError.recoveryRequired }
        let cache = try CodexLoginCache(data)
        try configuration.validate(cache)
        let profile = cache.profile(home: authFile.home, now: now())
        // Adding the currently active identity must retain its freshest token chain.
        if let current = try authFile.read(), let active = try? CodexLoginCache(current), active.matches(profile, home: authFile.home) {
            throw LoginSwitchError.alreadyCurrentLogin
        }
        try vault.save(SavedCodexLogin(profile: profile, credentials: data))
        return profile
    }

    func syncCurrentIfSaved() throws {
        let lock = try authFile.acquireOperationLock()
        defer { try? lock.close() }
        guard try !hasPendingRecovery(), let data = try authFile.read(), let cache = try? CodexLoginCache(data),
              try vault.profiles().contains(where: { cache.matches($0, home: authFile.home) }) else { return }
        guard try authFile.read() == data else { return }
        try vault.save(SavedCodexLogin(profile: cache.profile(home: authFile.home, now: now()), credentials: data))
    }

    @discardableResult
    func saveCurrent(configuration: CodexLoginConfiguration) throws -> SavedLoginProfile {
        guard try !hasPendingRecovery() else { throw LoginSwitchError.recoveryRequired }
        try configuration.validate()
        let lock = try authFile.acquireOperationLock()
        defer { try? lock.close() }
        guard try !hasPendingRecovery() else { throw LoginSwitchError.recoveryRequired }
        guard let data = try authFile.read() else { throw LoginSwitchError.missingCredentials }
        let cache = try CodexLoginCache(data)
        try configuration.validate(cache)
        let profile = cache.profile(home: authFile.home, now: now())
        guard try authFile.read() == data else { throw LoginSwitchError.credentialsChanged }
        try vault.save(SavedCodexLogin(profile: profile, credentials: data))
        return profile
    }

    @discardableResult
    func activate(id: String, configuration: CodexLoginConfiguration,
                  verify: () async throws -> AccountReadResponse,
                  progress: (String) -> Void = { _ in }) async throws -> SavedLoginProfile {
        try assertClosed()
        guard try !hasPendingRecovery() else { throw LoginSwitchError.recoveryRequired }
        try configuration.validate()
        let lock = try authFile.acquireOperationLock()
        defer { try? lock.close() }
        guard try !hasPendingRecovery() else { throw LoginSwitchError.recoveryRequired }
        let target = try vault.load(id: id)
        let cache = try CodexLoginCache(target.credentials)
        guard cache.matches(target.profile, home: authFile.home) else { throw LoginSwitchError.invalidCredentials }
        try configuration.validate(cache)
        let original = try authFile.read()
        if let original {
            // Preserve rotated refresh tokens before replacing the active cache.
            let outgoing = try CodexLoginCache(original)
            try configuration.validate(outgoing)
            try vault.save(SavedCodexLogin(profile: outgoing.profile(home: authFile.home, now: now()), credentials: original))
            // Re-select from the latest cache if this is already the current login.
            if outgoing.matches(target.profile, home: authFile.home) {
                try assertClosed()
                do {
                    let verified = try await verify()
                    try assertClosed()
                    guard verified.account?.type == "chatgpt",
                          verified.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == outgoing.email,
                          let latest = try authFile.read(),
                          let latestCache = try? CodexLoginCache(latest),
                          latestCache.matches(target.profile, home: authFile.home) else { throw LoginSwitchError.currentVerificationFailed }
                    let profile = latestCache.profile(home: authFile.home, now: now())
                    try vault.save(SavedCodexLogin(profile: profile, credentials: latest))
                    return profile
                } catch { throw LoginSwitchError.currentVerificationFailed }
            }
        }
        try Task.checkCancellation()
        progress("Switching account…")
        try recovery.save(LoginRecoveryRecord(target: target.profile, original: original))
        do {
            try authFile.replace(with: target.credentials, expecting: original, assertClosed: assertClosed)
        } catch {
            // A failed pre-commit assertion did not change the credentials.
            try recovery.clear()
            throw error
        }
        progress("Verifying selected account…")
        do {
            try assertClosed()
            let verified = try await verify()
            try assertClosed()
            guard verified.account?.type == "chatgpt",
                  verified.account?.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == cache.email,
                  let refreshed = try authFile.read(),
                  let refreshedCache = try? CodexLoginCache(refreshed),
                  refreshedCache.matches(target.profile, home: authFile.home) else {
                throw LoginSwitchError.verificationFailed
            }
            let profile = refreshedCache.profile(home: authFile.home, now: now())
            try vault.save(SavedCodexLogin(profile: profile, credentials: refreshed))
            try recovery.clear()
            return profile
        } catch {
            // Never overwrite a third party's replacement, or change auth while
            // a newly opened client may be using it. Keep target token rotations.
            do {
                try assertClosed()
                guard let current = try authFile.read(),
                      let currentCache = try? CodexLoginCache(current),
                      currentCache.matches(target.profile, home: authFile.home) else {
                    throw LoginSwitchError.recoveryRequired
                }
                // This may fail (e.g. locked Keychain). Restore the old login
                // anyway; its cache was already saved before the commit.
                try? vault.save(SavedCodexLogin(profile: currentCache.profile(home: authFile.home, now: now()), credentials: current))
                try authFile.replace(with: original, expecting: current, assertClosed: assertClosed)
                try recovery.clear()
            } catch { throw LoginSwitchError.recoveryRequired }
            throw LoginSwitchError.verificationFailed
        }
    }

    /// Explicit recovery verifies the login currently on disk. An unrelated
    /// replacement is preserved; only the interrupted target may be rolled back.
    func recover(configuration: CodexLoginConfiguration, verify: () async throws -> AccountReadResponse) async throws -> SavedLoginProfile? {
        try assertClosed()
        let lock = try authFile.acquireOperationLock()
        defer { try? lock.close() }
        guard let record = try recovery.load() else { return nil }
        let originalCache = try record.original.map { try CodexLoginCache($0) }
        try configuration.validate()
        let current = try authFile.read()
        if current == record.original {
            try recovery.clear()
            return originalCache?.profile(home: authFile.home, now: now())
        }
        guard let current, let cache = try? CodexLoginCache(current) else { throw LoginSwitchError.recoveryRequired }
        try configuration.validate(cache)
        if let originalCache, cache.accountID == originalCache.accountID, cache.email == originalCache.email {
            let profile = cache.profile(home: authFile.home, now: now())
            try vault.save(SavedCodexLogin(profile: profile, credentials: current))
            try recovery.clear()
            return profile
        }
        let currentProfile = cache.profile(home: authFile.home, now: now())
        do {
            let identity = try await verify()
            try assertClosed()
            guard identity.account?.type == "chatgpt", identity.account?.email?.lowercased() == cache.email,
                  let latest = try authFile.read(), let updated = try? CodexLoginCache(latest),
                  updated.matches(currentProfile, home: authFile.home) else { throw LoginSwitchError.verificationFailed }
            let profile = updated.profile(home: authFile.home, now: now())
            try vault.save(SavedCodexLogin(profile: profile, credentials: latest))
            try recovery.clear()
            return profile
        } catch {
            do {
                try assertClosed()
                if let originalCache { try configuration.validate(originalCache) }
                guard let latest = try authFile.read(), let updated = try? CodexLoginCache(latest),
                      updated.matches(record.target, home: authFile.home) else { throw LoginSwitchError.recoveryRequired }
                try? vault.save(SavedCodexLogin(profile: updated.profile(home: authFile.home, now: now()), credentials: latest))
                try authFile.replace(with: record.original, expecting: latest, assertClosed: assertClosed)
                try recovery.clear()
            } catch { throw LoginSwitchError.recoveryRequired }
            throw LoginSwitchError.verificationFailed
        }
    }
}
