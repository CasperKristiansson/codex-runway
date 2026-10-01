import AppKit
import Foundation

struct CodexLoginConfiguration {
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
struct CodexProcessGuard {
    static func isCodexExecutable(_ path: String) -> Bool {
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return name == "codex" || name == "codex-cli" || name == "codex.exe" || name == "codex-cli.exe"
            || path.contains("/Codex.app/") || path.contains("/ChatGPT.app/")
            || path.contains("/CodexCLI.app/")
    }

    static func assertClosed() throws {
        var clients = Set(NSWorkspace.shared.runningApplications.compactMap { app -> String? in
            guard ["com.openai.codex", "com.openai.chat"].contains(app.bundleIdentifier ?? "") else { return nil }
            return app.localizedName ?? "Codex"
        })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // Executable paths only: never inspect or expose arguments or secrets.
        process.arguments = ["-axo", "comm="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw LoginSwitchError.processCheckFailed }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let listing = String(data: data, encoding: .utf8) else {
            throw LoginSwitchError.processCheckFailed
        }
        for line in listing.split(separator: "\n") {
            let path = line.trimmingCharacters(in: .whitespaces)
            if isCodexExecutable(path) { clients.insert("Codex desktop or CLI") }
        }
        guard clients.isEmpty else { throw LoginSwitchError.clientsRunning(clients.sorted()) }
    }
}

@MainActor
final class CodexLoginSwitcher {
    let authFile: CodexAuthFile
    private let vault: any SavedLoginStore
    private let assertClosed: () throws -> Void
    private let now: () -> Date

    init(home: URL = CodexAuthFile.defaultHome, vault: (any SavedLoginStore)? = nil,
         assertClosed: @escaping () throws -> Void = { try CodexProcessGuard.assertClosed() },
         now: @escaping () -> Date = { .now }) {
        let home = home.standardizedFileURL.resolvingSymlinksInPath()
        self.authFile = CodexAuthFile(home: home)
        self.vault = vault ?? KeychainSavedLoginStore(home: home)
        self.assertClosed = assertClosed
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
    func forget(id: String) throws { try vault.remove(id: id) }

    @discardableResult
    func saveCurrent(configuration: CodexLoginConfiguration) throws -> SavedLoginProfile {
        try assertClosed()
        try configuration.validate()
        let lock = try authFile.acquireOperationLock()
        defer { try? lock.close() }
        guard let data = try authFile.read() else { throw LoginSwitchError.missingCredentials }
        let cache = try CodexLoginCache(data)
        try configuration.validate(cache)
        let profile = cache.profile(home: authFile.home, now: now())
        try assertClosed()
        guard try authFile.read() == data else { throw LoginSwitchError.credentialsChanged }
        try vault.save(SavedCodexLogin(profile: profile, credentials: data))
        return profile
    }

    @discardableResult
    func activate(id: String, configuration: CodexLoginConfiguration,
                  verify: () async throws -> AccountReadResponse) async throws -> SavedLoginProfile {
        try assertClosed()
        try configuration.validate()
        let lock = try authFile.acquireOperationLock()
        defer { try? lock.close() }
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
        try authFile.replace(with: target.credentials, expecting: original, assertClosed: assertClosed)
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
            } catch { throw LoginSwitchError.recoveryRequired }
            throw LoginSwitchError.verificationFailed
        }
    }
}
