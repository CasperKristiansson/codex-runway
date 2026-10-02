import Darwin
import Foundation

@MainActor
private final class MemoryLoginStore: SavedLoginStore {
    var values: [String: SavedCodexLogin] = [:]
    var failSave = false
    func profiles() throws -> [SavedLoginProfile] { values.values.map(\.profile) }
    func save(_ login: SavedCodexLogin) throws {
        if failSave { throw LoginSwitchError.keychain(-1) }
        values[login.profile.id] = login
    }
    func load(id: String) throws -> SavedCodexLogin {
        guard let login = values[id] else { throw LoginSwitchError.missingSavedLogin }
        return login
    }
    func remove(id: String) throws { values.removeValue(forKey: id) }
}

@MainActor
private final class MemoryRecoveryStore: LoginRecoveryStore {
    var record: LoginRecoveryRecord?
    var failSave = false
    var failClear = false
    func load() throws -> LoginRecoveryRecord? { record }
    func save(_ record: LoginRecoveryRecord) throws {
        if failSave { throw LoginSwitchError.keychain(-1) }
        self.record = record
    }
    func clear() throws {
        if failClear { throw LoginSwitchError.keychain(-1) }
        record = nil
    }
}

@MainActor
private final class Fixture {
    var open = false
    var checks = 0
    var failAt: Int?
    var hook: (() throws -> Void)?
    func assertClosed() throws {
        checks += 1
        try hook?()
        if open || checks == failAt { throw LoginSwitchError.clientsRunning(["Synthetic Codex"]) }
    }
}

@MainActor
private final class LifecycleFixture {
    var closes = 0
    var opens = 0
    var isOpen = true
    var revoked = false
    var declineQuit = false
    var failLaunch = false
    var browserOpened = false
}

@main
struct LoginChecks {
    static func credentials(_ email: String, account: String, rotation: Int = 0) throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: ["email": email,
            "https://api.openai.com/auth": ["chatgpt_account_id": account]])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(),
            "tokens": ["account_id": account, "id_token": "synthetic.\(payload).signature",
                       "access_token": "synthetic-access-\(rotation)", "refresh_token": "synthetic-refresh-\(rotation)"]])
    }

    static func check(_ value: @autoclosure () throws -> Bool) throws { let result = try value(); precondition(result) }

    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("runway-login-checks-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let url = root.appendingPathComponent("auth.json")
        let first = try credentials("first@example.com", account: "account-one")
        let second = try credentials("second@example.com", account: "account-two")
        let rotatedFirst = try credentials("first@example.com", account: "account-one", rotation: 1)
        let rotatedSecond = try credentials("second@example.com", account: "account-two", rotation: 2)
        let third = try credentials("third@example.com", account: "account-three")
        func write(_ data: Data) throws {
            try data.write(to: url)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        func read() throws -> Data { try Data(contentsOf: url) }
        let config = CodexLoginConfiguration(storage: "file")
        let vault = MemoryLoginStore()
        let fixture = Fixture()
        let recovery = MemoryRecoveryStore()
        let switcher = CodexLoginSwitcher(home: root, vault: vault, recovery: recovery, assertClosed: { try fixture.assertClosed() })
        func response(_ email: String) -> AccountReadResponse {
            AccountReadResponse(account: ChatGPTAccount(type: "chatgpt", email: email, planType: "pro"))
        }
        try write(first)
        fixture.open = true
        try switcher.saveCurrent(configuration: config)
        try check(vault.values.count == 1 && (try read()) == first)
        fixture.open = false
        let firstProfile = try switcher.saveCurrent(configuration: config)
        try write(second)
        let secondProfile = try switcher.saveCurrent(configuration: config)
        precondition(firstProfile.id != secondProfile.id && vault.values.count == 2)
        try write(rotatedFirst)
        fixture.open = true
        do { try await switcher.activate(id: secondProfile.id, configuration: config) { response("second@example.com") }; preconditionFailure() }
        catch LoginSwitchError.clientsRunning {}
        try check((try read()) == rotatedFirst)
        fixture.open = false

        // Latest outgoing and refreshed incoming tokens survive the round trip.
        var verificationCalls = 0
        let selected = try await switcher.activate(id: secondProfile.id, configuration: config) {
            verificationCalls += 1
            try check((try read()) == second)
            try write(rotatedSecond)
            return response("second@example.com")
        }
        precondition(selected.id == secondProfile.id && verificationCalls == 1)
        precondition(vault.values[firstProfile.id]?.credentials == rotatedFirst)
        precondition(vault.values[secondProfile.id]?.credentials == rotatedSecond)
        let permissions = try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        precondition(permissions == 0o600)
        try await switcher.activate(id: firstProfile.id, configuration: config) { response("first@example.com") }
        try check((try read()) == rotatedFirst)

        // Re-selecting the current login must never restore an older vault copy.
        try write(try credentials("first@example.com", account: "account-one", rotation: 9))
        try await switcher.activate(id: firstProfile.id, configuration: config) { response("first@example.com") }
        try check(vault.values[firstProfile.id]?.credentials == (try read()))
        let previous = try read()
        do {
            try await switcher.activate(id: secondProfile.id, configuration: config) {
                try write(rotatedSecond)
                throw LoginSwitchError.invalidCredentials
            }
            preconditionFailure("Failed verification must restore the previous login")
        } catch LoginSwitchError.verificationFailed {}
        try check((try read()) == previous)
        do {
            try await switcher.activate(id: secondProfile.id, configuration: config) { response("wrong@example.com") }
            preconditionFailure("Wrong identity must rollback")
        } catch LoginSwitchError.verificationFailed {}
        try check((try read()) == previous)

        // Never rollback over a concurrent third-party replacement.
        do {
            try await switcher.activate(id: secondProfile.id, configuration: config) {
                try write(third)
                throw LoginSwitchError.invalidCredentials
            }
            preconditionFailure()
        } catch LoginSwitchError.recoveryRequired {}
        try check((try read()) == third)
        try write(previous)
        _ = try await switcher.recover(configuration: config) { response("first@example.com") }

        // Recheck the process assertion immediately before atomic replacement.
        fixture.checks = 0
        fixture.failAt = 2
        do { try await switcher.activate(id: secondProfile.id, configuration: config) { response("second@example.com") }; preconditionFailure() }
        catch LoginSwitchError.clientsRunning {}
        fixture.failAt = nil
        try check((try read()) == previous)
        // A client opening during verification prevents rollback writes.
        do {
            try await switcher.activate(id: secondProfile.id, configuration: config) {
                fixture.open = true
                return response("second@example.com")
            }
            preconditionFailure()
        } catch LoginSwitchError.recoveryRequired {}
        try check((try read()) == rotatedSecond)
        fixture.open = false
        try write(previous)
        _ = try await switcher.recover(configuration: config) { response("first@example.com") }

        for storage in ["keyring", "auto", "ephemeral", "unknown"] {
            do { try switcher.saveCurrent(configuration: CodexLoginConfiguration(storage: storage)); preconditionFailure() }
            catch LoginSwitchError.unsupportedStorage {}
        }
        do { try await switcher.activate(id: secondProfile.id,
            configuration: CodexLoginConfiguration(storage: "file", forcedWorkspaceID: "account-one")) { response("second@example.com") }; preconditionFailure() }
        catch LoginSwitchError.restrictedLogin {}
        do { try switcher.saveCurrent(configuration: CodexLoginConfiguration(storage: "file", forcedLoginMethod: "api")); preconditionFailure() }
        catch LoginSwitchError.restrictedLogin {}
        vault.failSave = true
        do { try await switcher.activate(id: secondProfile.id, configuration: config) { response("second@example.com") }; preconditionFailure() }
        catch LoginSwitchError.keychain {}
        vault.failSave = false
        try check((try read()) == previous)

        // Unsafe files, malformed caches, cross-home metadata and missing refresh
        // tokens are rejected before any authentication change.
        try write(Data(#"{"OPENAI_API_KEY":"synthetic-key"}"#.utf8))
        do { try switcher.saveCurrent(configuration: config); preconditionFailure() }
        catch LoginSwitchError.invalidCredentials {}
        try write(previous)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        do { try switcher.saveCurrent(configuration: config); preconditionFailure() }
        catch LoginSwitchError.unsafeFile {}
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try fm.moveItem(at: url, to: elsewhere)
        try fm.createSymbolicLink(at: url, withDestinationURL: elsewhere)
        do { try switcher.saveCurrent(configuration: config); preconditionFailure() }
        catch LoginSwitchError.unsafeFile {}
        try fm.removeItem(at: url)
        try fm.moveItem(at: elsewhere, to: url)
        let otherHomeProfile = try CodexLoginCache(second).profile(home: root.appendingPathComponent("other"))
        vault.values[otherHomeProfile.id] = SavedCodexLogin(profile: otherHomeProfile, credentials: second)
        do { try await switcher.activate(id: otherHomeProfile.id, configuration: config) { response("second@example.com") }; preconditionFailure() }
        catch LoginSwitchError.invalidCredentials {}
        try switcher.forget(id: otherHomeProfile.id)

        // Compare-before-replace rejects a cache altered after the initial read.
        let auth = CodexAuthFile(home: root)
        do { try auth.replace(with: second, expecting: first, assertClosed: {}); preconditionFailure() }
        catch LoginSwitchError.credentialsChanged {}
        try check((try read()) == previous)
        let lock = try auth.acquireOperationLock()
        do { try switcher.saveCurrent(configuration: config); preconditionFailure() }
        catch LoginSwitchError.refreshRunning {}
        try lock.close()
        // Missing original files are removed again after failed verification.
        try fm.removeItem(at: url)
        do { try await switcher.activate(id: secondProfile.id, configuration: config) { throw LoginSwitchError.invalidCredentials }; preconditionFailure() }
        catch LoginSwitchError.verificationFailed {}
        precondition(!fm.fileExists(atPath: url.path))
        try write(previous)

        precondition(CodexProcessGuard.isCodexExecutable("/opt/homebrew/bin/codex"))
        precondition(CodexProcessGuard.isCodexExecutable("/Applications/Renamed.app/Contents/Resources/codex-cli"))
        precondition(!CodexProcessGuard.isCodexExecutable("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        precondition(!CodexProcessGuard.isCodexExecutable("/Applications/Codex Runway.app/Contents/MacOS/CodexRunway"))

        func savedUsage(_ id: String, _ configuration: CodexLoginConfiguration) throws -> ActiveCodexAccount {
            let login = try vault.load(id: id)
            return ActiveCodexAccount(identity: response(login.profile.email),
                rateLimits: RateLimitsReadResponse(accountId: login.profile.accountID,
                    rateLimits: RateLimitSnapshot(primary: LimitWindow(usedPercent: 0, resetsAt: nil), planType: "pro"), rateLimitResetCredits: nil))
        }
        // Store-level exclusion covers manual, scheduled and queued refreshes.
        let suite = "runway-login-checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var readCalls = 0
        var store: RunwayStore!
        store = RunwayStore(defaults: defaults, analyticsEnabled: false, loginSwitcher: switcher,
            readLoginConfiguration: {
                precondition(store.isManagingLogin)
                let refreshed = await store.refreshActiveAccount()
                precondition(!refreshed && readCalls == 0)
                await store.refreshProfile()
                await store.refreshAnalyticsForSignedInAccount()
                try await Task.sleep(for: .milliseconds(10))
                return config
            }, verifyLogin: { response("second@example.com") }, readSavedUsage: savedUsage, closeDesktop: { fixture.open = false; return false }, openDesktop: {}, readAccount: {
                readCalls += 1
                throw CodexAppServerError.invalidResponse
            })
        await store.saveCurrentLogin()
        precondition(!store.isManagingLogin && !store.loginStatusIsError && !store.savedLogins.isEmpty)
        await store.switchLogin(id: secondProfile.id, openCodex: false)
        try check(!store.isManagingLogin && !store.loginStatusIsError && (try read()) == rotatedSecond)
        store.forgetLogin(id: firstProfile.id)
        precondition(!store.savedLogins.contains { $0.id == firstProfile.id })
        try check((try read()) == rotatedSecond)
        let preferences = defaults.dictionaryRepresentation()
        precondition(!preferences.keys.contains { $0.localizedCaseInsensitiveContains("credential") || $0.localizedCaseInsensitiveContains("token") })
        try check(!(try fm.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix(".runway-auth-") && $0.hasSuffix(".tmp") })
        // Scope decisions require positive evidence of a different credential home.
        let independent = CodexClientProcess(pid: 999, parent: 1, executable: "/opt/homebrew/bin/codex", home: root.appendingPathComponent("independent"))
        precondition(!CodexProcessGuard.blocks(independent, home: root, desktopPIDs: []))
        precondition(CodexProcessGuard.blocks(CodexClientProcess(pid: 999, parent: 1, executable: independent.executable, home: nil), home: root, desktopPIDs: []))
        precondition(CodexProcessGuard.blocks(CodexClientProcess(pid: 999, parent: 1, executable: independent.executable, home: root), home: root, desktopPIDs: []))
        precondition(CodexProcessGuard.blocks(independent, home: root, desktopPIDs: [999]))
        do { try await CodexDesktopLifecycle.waitForExit(timeout: .milliseconds(1)) { true }; preconditionFailure() }
        catch LoginSwitchError.quitTimedOut {}
        let quitWait = Task { try await CodexDesktopLifecycle.waitForExit { true } }
        quitWait.cancel()
        do { try await quitWait.value; preconditionFailure() } catch is CancellationError {}

        // Managed desktop lifecycle and failure outcomes without touching a real app.
        try vault.save(SavedCodexLogin(profile: firstProfile, credentials: previous))
        try write(previous)
        let lifecycle = LifecycleFixture()
        let lifecycleStore = RunwayStore(defaults: defaults, analyticsEnabled: false, loginSwitcher: switcher,
            readLoginConfiguration: { config }, verifyLogin: {
                precondition(recovery.record != nil)
                precondition(!lifecycle.isOpen)
                return response("second@example.com")
            }, readSavedUsage: { id, config in
                if lifecycle.revoked { throw CodexAppServerError.authenticationExpired }
                return try savedUsage(id, config)
            }, closeDesktop: {
                lifecycle.closes += 1
                if lifecycle.declineQuit { throw LoginSwitchError.quitFailed }
                let wasOpen = lifecycle.isOpen
                lifecycle.isOpen = false
                fixture.open = false
                return wasOpen
            }, openDesktop: {
                lifecycle.opens += 1
                if lifecycle.failLaunch { throw LoginSwitchError.reopenFailed }
                lifecycle.isOpen = true
            }, desktopIsOpen: { lifecycle.isOpen }, signIn: { _ in third })
        fixture.open = true
        await lifecycleStore.switchLogin(id: firstProfile.id)
        precondition(lifecycle.closes == 0 && lifecycle.opens == 0 && !lifecycleStore.loginStatusIsError)
        // Revoked sessions fail before Codex is closed or credentials replaced.
        lifecycle.revoked = true
        await lifecycleStore.switchLogin(id: secondProfile.id)
        try check(lifecycle.closes == 0 && lifecycle.opens == 0 && lifecycleStore.loginStatusIsError && (try read()) == previous)
        precondition(lifecycleStore.loginStatusMessage?.contains("Add Account") == true)
        lifecycle.revoked = false
        lifecycle.declineQuit = true
        await lifecycleStore.switchLogin(id: secondProfile.id)
        try check(lifecycle.closes == 1 && lifecycle.opens == 0 && lifecycleStore.loginStatusIsError && (try read()) == previous)
        lifecycle.declineQuit = false
        lifecycle.failLaunch = true
        await lifecycleStore.switchLogin(id: secondProfile.id)
        try check(lifecycle.closes == 2 && lifecycle.opens == 1 && lifecycleStore.loginStatusIsError && (try read()) == rotatedSecond)
        precondition(recovery.record == nil && !lifecycleStore.loginRecoveryPending)
        precondition(lifecycleStore.loginStatusMessage?.contains("Open Codex manually") == true)
        // Re-select a closed active account lifecycle.opens it without another quit.
        lifecycle.failLaunch = false
        await lifecycleStore.switchLogin(id: secondProfile.id)
        precondition(lifecycle.closes == 2 && lifecycle.opens == 2 && !lifecycleStore.loginStatusIsError)
        let beforeAdd = try read()
        await lifecycleStore.addLogin()
        try check((try read()) == beforeAdd && lifecycleStore.savedLogins.contains { $0.email == "third@example.com" })

        // A cancellation during graceful quit cannot reach the auth transaction.
        let cancellingStore = RunwayStore(defaults: defaults, analyticsEnabled: false, loginSwitcher: switcher,
            readLoginConfiguration: { config }, readSavedUsage: savedUsage, closeDesktop: {
                try await CodexDesktopLifecycle.waitForExit { true }
                return true
            }, openDesktop: {})
        let switching = Task { await cancellingStore.switchLogin(id: firstProfile.id) }
        while !cancellingStore.loginCanCancel { try await Task.sleep(for: .milliseconds(1)) }
        cancellingStore.cancelLoginOperation()
        await switching.value
        try check((try read()) == beforeAdd && recovery.record == nil && !cancellingStore.isManagingLogin)
        precondition(cancellingStore.loginStatusMessage?.contains("Cancelled") == true)

        // Durable recovery survives a new switcher/store instance and blocks refresh.
        fixture.open = false
        try write(previous)
        try recovery.save(LoginRecoveryRecord(target: secondProfile, original: previous))
        let restarted = CodexLoginSwitcher(home: root, vault: vault, recovery: recovery, assertClosed: { try fixture.assertClosed() })
        _ = try await restarted.recover(configuration: config) { preconditionFailure("Pre-commit crash must not authenticate") }
        try check((try read()) == previous && recovery.record == nil)
        try recovery.save(LoginRecoveryRecord(target: secondProfile, original: previous))
        try write(rotatedSecond)
        var recoveryReads = 0
        let recoveryStore = RunwayStore(defaults: defaults, analyticsEnabled: false, loginSwitcher: restarted,
            readLoginConfiguration: { config }, verifyLogin: {
                try write(try credentials("second@example.com", account: "account-two", rotation: 20))
                return response("second@example.com")
            }, closeDesktop: { false }, openDesktop: {}, readAccount: {
                recoveryReads += 1
                throw CodexAppServerError.invalidResponse
            })
        recoveryStore.reloadSavedLogins()
        precondition(recoveryStore.loginRecoveryPending)
        let didRefresh = await recoveryStore.refreshActiveAccount()
        precondition(!didRefresh && recoveryReads == 0)
        await recoveryStore.recoverLogin()
        try check(!recoveryStore.loginRecoveryPending && !recoveryStore.loginStatusIsError && recovery.record == nil)
        try check(vault.values[secondProfile.id]?.credentials == (try read()))
        try recovery.save(LoginRecoveryRecord(target: secondProfile, original: previous))
        try write(rotatedSecond)
        do { _ = try await restarted.recover(configuration: config) { throw LoginSwitchError.invalidCredentials }; preconditionFailure() }
        catch LoginSwitchError.verificationFailed {}
        try check((try read()) == previous && recovery.record == nil)
        // Preserve a third party's login; explicit recovery can verify/adopt it.
        try recovery.save(LoginRecoveryRecord(target: secondProfile, original: previous))
        try write(third)
        do { _ = try await restarted.recover(configuration: config) { throw LoginSwitchError.invalidCredentials }; preconditionFailure() }
        catch LoginSwitchError.recoveryRequired {}
        try check((try read()) == third && recovery.record != nil)
        let adopted = try await restarted.recover(configuration: config) { response("third@example.com") }
        try check(adopted?.email == "third@example.com" && (try read()) == third && recovery.record == nil)
        // Failure to persist the journal prevents a credential replacement.
        try write(previous)
        recovery.failSave = true
        do { try await restarted.activate(id: secondProfile.id, configuration: config) { response("second@example.com") }; preconditionFailure() }
        catch LoginSwitchError.keychain {}
        recovery.failSave = false
        try check((try read()) == previous)

        // Isolated onboarding removes the private directory after success, failure and cancellation.
        var onboardingHome: URL?
        let imported = try await CodexAccountOnboarding().add(configuration: config) { home, _ in
            onboardingHome = home
            precondition(home != root)
            let mode = try fm.attributesOfItem(atPath: home.path)[.posixPermissions] as? Int
            precondition(mode == 0o700)
            let file = CodexAuthFile(home: home)
            try file.replace(with: third, expecting: nil, assertClosed: {})
        }
        try check(imported == third && !fm.fileExists(atPath: onboardingHome!.path) && (try read()) == previous)
        do {
            _ = try await CodexAccountOnboarding().add(configuration: config) { home, _ in
                onboardingHome = home
                throw LoginSwitchError.signInFailed
            }
            preconditionFailure()
        } catch LoginSwitchError.signInFailed {}
        precondition(!fm.fileExists(atPath: onboardingHome!.path))
        let onboarding = Task {
            try await CodexAccountOnboarding().add(configuration: config) { home, _ in
                onboardingHome = home
                try await Task.sleep(for: .seconds(30))
            }
        }
        let earlierHome = onboardingHome
        while onboardingHome == earlierHome { try await Task.sleep(for: .milliseconds(1)) }
        onboarding.cancel()
        do { _ = try await onboarding.value; preconditionFailure() } catch is CancellationError {}
        precondition(!fm.fileExists(atPath: onboardingHome!.path))

        // Manual inactive usage: isolated files, latest tokens on success/failure,
        // and no process-quitting assertion even with the desktop still open.
        func usage(_ email: String, id: String, used: Double = 32) -> ActiveCodexAccount {
            ActiveCodexAccount(identity: response(email), rateLimits: RateLimitsReadResponse(accountId: id,
                rateLimits: RateLimitSnapshot(primary: LimitWindow(usedPercent: used, resetsAt: 1_900_000_000, windowDurationMins: 10080), planType: "pro"), rateLimitResetCredits: nil))
        }
        try write(previous)
        try vault.save(SavedCodexLogin(profile: secondProfile, credentials: second))
        fixture.open = true
        let initialProcessChecks = fixture.checks
        var isolatedUsageHome: URL?
        let savedResponse = try await switcher.readSavedUsage(id: secondProfile.id, configuration: config) { home, _ in
            isolatedUsageHome = home
            precondition(home != root)
            try check(try CodexAuthFile(home: home).read() == second)
            try CodexAuthFile(home: home).replace(with: rotatedSecond, expecting: second, assertClosed: {})
            return usage("second@example.com", id: "account-two")
        }
        try check(savedResponse.rateLimits.rateLimits.primary.usedPercent == 32 && (try read()) == previous)
        precondition(fixture.open && fixture.checks == initialProcessChecks && !fm.fileExists(atPath: isolatedUsageHome!.path))
        try check(try vault.load(id: secondProfile.id).credentials == rotatedSecond)
        let newerSecond = try credentials("second@example.com", account: "account-two", rotation: 30)
        do {
            _ = try await switcher.readSavedUsage(id: secondProfile.id, configuration: config) { home, _ in
                isolatedUsageHome = home
                try CodexAuthFile(home: home).replace(with: newerSecond, expecting: rotatedSecond, assertClosed: {})
                throw CodexAppServerError.invalidResponse
            }
            preconditionFailure()
        } catch CodexAppServerError.invalidResponse {}
        try check(try vault.load(id: secondProfile.id).credentials == newerSecond)
        precondition(!fm.fileExists(atPath: isolatedUsageHome!.path))
        do {
            _ = try await switcher.readSavedUsage(id: firstProfile.id, configuration: config) { _, _ in preconditionFailure("Never clone the active session") }
            preconditionFailure()
        } catch LoginSwitchError.alreadyCurrentLogin {}
        do {
            _ = try await switcher.readSavedUsage(id: secondProfile.id, configuration: config) { _, _ in usage("first@example.com", id: "account-one") }
            preconditionFailure()
        } catch CodexAppServerError.invalidResponse {}
        try check((try read()) == previous)

        // Store updates only the clicked row's statistics, preserves active ID,
        // excludes other requests, and rejects mismatched server identity.
        let usageSuite = "runway-usage-checks.\(UUID().uuidString)"
        let usageDefaults = UserDefaults(suiteName: usageSuite)!
        defer { usageDefaults.removePersistentDomain(forName: usageSuite) }
        let activeRow = CodexAccount(name: "First", email: "first@example.com", planName: "Pro", externalAccountID: "account-one")
        let inactiveRow = CodexAccount(name: "Second", email: "second@example.com", planName: "Pro", externalAccountID: "account-two")
        usageDefaults.set(try JSONEncoder().encode([activeRow, inactiveRow]), forKey: "codex-runway.accounts.v1")
        var quotaCalls = 0
        var savedQuotaCalls = 0
        var failQuota = false
        var wrongQuotaIdentity = false
        var usageStore: RunwayStore!
        usageStore = RunwayStore(defaults: usageDefaults,
            forecastJournal: ForecastJournal(directory: root.appendingPathComponent("usage-journal")),
            analyticsEnabled: false, loginSwitcher: switcher, readLoginConfiguration: { config },
            readSavedUsage: { id, _ in
                savedQuotaCalls += 1
                precondition(id == secondProfile.id && usageStore.refreshingSavedAccountID == inactiveRow.id)
                let autoRefreshed = await usageStore.refreshActiveAccount()
                precondition(!autoRefreshed && quotaCalls == 1)
                await usageStore.refreshUsage(accountID: inactiveRow.id)
                precondition(savedQuotaCalls == 1 || failQuota || wrongQuotaIdentity)
                if failQuota { throw CodexAppServerError.invalidResponse }
                return wrongQuotaIdentity ? usage("first@example.com", id: "account-one") : usage("second@example.com", id: "account-two")
            }, synchronizeSavedLogin: {}, readProfile: { throw CodexAppServerError.invalidResponse }, readAccount: {
                quotaCalls += 1
                return usage("first@example.com", id: "account-one", used: 18)
            })
        usageStore.reloadSavedLogins()
        let activeRefreshed = await usageStore.refreshActiveAccount()
        precondition(activeRefreshed && usageStore.activeAccountID == activeRow.id)
        let activeBefore = usageStore.accounts.first { $0.id == activeRow.id }!
        await usageStore.refreshUsage(accountID: inactiveRow.id)
        precondition(savedQuotaCalls == 1 && usageStore.refreshingSavedAccountID == nil && usageStore.activeAccountID == activeRow.id)
        precondition(usageStore.accounts.first { $0.id == inactiveRow.id }!.snapshots.count == 1)
        precondition(usageStore.accounts.first { $0.id == activeRow.id }! == activeBefore)
        let afterUsage = usageStore.accounts
        failQuota = true
        await usageStore.refreshUsage(accountID: inactiveRow.id)
        precondition(usageStore.accounts == afterUsage && usageStore.savedUsageErrors[inactiveRow.id] != nil && usageStore.activeAccountID == activeRow.id)
        failQuota = false
        wrongQuotaIdentity = true
        await usageStore.refreshUsage(accountID: inactiveRow.id)
        precondition(usageStore.accounts == afterUsage && usageStore.activeAccountID == activeRow.id)
        // Clicking a stale "inactive" marker for the actual current login routes
        // through the shared active cache, not an isolated session copy.
        await usageStore.refreshUsage(accountID: activeRow.id)
        precondition(quotaCalls == 2 && savedQuotaCalls == 3 && usageStore.activeAccountID == activeRow.id)
        try check((try read()) == previous)
        fixture.open = false

        // Exercise the actual App Server transport with a synthetic child.
        // Sequential reuse must not receive a stale child's exit notification.
        let server = root.appendingPathComponent("synthetic-app-server")
        let program = """
        #!/usr/bin/python3
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            method = request['method']
            if method == 'initialize': result = {}
            elif method == 'config/read': result = {'config': {'cli_auth_credentials_store': 'file'}, 'padding': 'fragmented-response-' * 20000}
            elif method == 'account/read':
                result = {'account': {'type': 'chatgpt', 'email': 'second@example.com', 'planType': 'pro'}}
            elif method == 'account/rateLimits/read': result = {'rateLimits': {}}
            else: raise RuntimeError('Unexpected method')
            response = json.dumps({'id': request['id'], 'result': result}) + '\\n'
            # Force many pipe reads, with unsolicited messages alongside responses.
            for offset in range(0, len(response), 1024):
                sys.stdout.write(response[offset:offset + 1024]); sys.stdout.flush()
            print(json.dumps({'method': 'diagnostic/notification', 'params': {}}), flush=True)
        """
        try Data(program.utf8).write(to: server)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let client = CodexAppServerClient()
        for _ in 0..<20 {
            let readConfiguration = try await client.readLoginConfiguration(executablePath: server.path)
            precondition(readConfiguration.storage == "file")
            let identity = try await client.verifyLogin(executablePath: server.path)
            precondition(identity.account?.email == "second@example.com")
        }
        // Cached identity is insufficient: a revoked quota request must fail
        // verification and produce an actionable error without raw server JSON.
        let revokedServer = root.appendingPathComponent("synthetic-revoked-server")
        let revokedProgram = program.replacingOccurrences(
            of: "elif method == 'account/rateLimits/read': result = {'rateLimits': {}}",
            with: "elif method == 'account/rateLimits/read':\n        print(json.dumps({'id': request['id'], 'error': {'message': '401 Unauthorized token_revoked'}}), flush=True); continue")
        try Data(revokedProgram.utf8).write(to: revokedServer)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: revokedServer.path)
        do {
            _ = try await client.verifyLogin(executablePath: revokedServer.path)
            preconditionFailure("Cached account identity must not validate a revoked session")
        } catch CodexAppServerError.authenticationExpired {}
        // Real transport: isolated environment, early completion notification,
        // normal OAuth params, and cancellation while waiting for the browser.
        let loginServer = root.appendingPathComponent("synthetic-login-server")
        let encodedThird = third.base64EncodedString()
        let loginProgram = """
        #!/usr/bin/python3
        import base64, json, os, sys
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            method = request['method']
            if method == 'initialize': result = {}
            elif method == 'account/login/start':
                assert request['params']['type'] == 'chatgpt'
                assert 'cli_auth_credentials_store="file"' in sys.argv
                home = os.environ['CODEX_HOME']
                assert home != '\(root.path)'
                with open(os.path.join(home, 'auth.json'), 'wb') as f:
                    f.write(base64.b64decode('\(encodedThird)'))
                os.chmod(os.path.join(home, 'auth.json'), 0o600)
                if 'stall' not in sys.argv[0]:
                    print(json.dumps({'method': 'account/login/completed', 'params': {'loginId': 'synthetic-login', 'success': True}}), flush=True)
                result = {'type': 'chatgpt', 'loginId': 'synthetic-login', 'authUrl': 'https://auth.openai.com/oauth/authorize?synthetic=1'}
            elif method == 'account/read':
                assert request['params']['refreshToken'] is False
                result = {'account': {'type': 'chatgpt', 'email': 'third@example.com', 'planType': 'pro'}}
            else: raise RuntimeError('Unexpected method')
            print(json.dumps({'id': request['id'], 'result': result}), flush=True)
        """
        try Data(loginProgram.utf8).write(to: loginServer)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: loginServer.path)
        let transportLogin = try await CodexAccountOnboarding().add(configuration: config) { home, configuration in
            try await client.signIn(home: home, configuration: configuration, executablePath: loginServer.path, openBrowser: { url in
                precondition(url.host == "auth.openai.com")
            })
        }
        try check(transportLogin == third && (try read()) == previous)
        let stalledServer = root.appendingPathComponent("synthetic-login-stall-server")
        try Data(loginProgram.utf8).write(to: stalledServer)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stalledServer.path)
        let stalledLogin = Task {
            try await CodexAccountOnboarding().add(configuration: config) { home, configuration in
                onboardingHome = home
                try await client.signIn(home: home, configuration: configuration, executablePath: stalledServer.path, openBrowser: { _ in lifecycle.browserOpened = true })
            }
        }
        while !lifecycle.browserOpened { try await Task.sleep(for: .milliseconds(1)) }
        stalledLogin.cancel()
        do { _ = try await stalledLogin.value; preconditionFailure() } catch is CancellationError {}
        precondition(!fm.fileExists(atPath: onboardingHome!.path))
        // The cancelled client's child has exited; a new request must work immediately.
        _ = try await client.verifyLogin(executablePath: server.path)
        // Platform binaries can hide their environment. Use our own disposable
        // executable to test positive scope detection, rather than /bin/sleep.
        let scopedSource = root.appendingPathComponent("scoped-client.c")
        let scopedExecutable = root.appendingPathComponent("scoped-client")
        try Data("#include <stdlib.h>\n#include <unistd.h>\nint main(void) { if (!getenv(\"CODEX_HOME\")) return 42; sleep(10); return 0; }\n".utf8).write(to: scopedSource)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = [scopedSource.path, "-o", scopedExecutable.path]
        try compiler.run()
        compiler.waitUntilExit()
        precondition(compiler.terminationStatus == 0)
        let scopedChild = Process()
        scopedChild.executableURL = scopedExecutable
        scopedChild.environment = ["CODEX_HOME": root.path]
        try scopedChild.run()
        defer { if scopedChild.isRunning { scopedChild.terminate(); scopedChild.waitUntilExit() } }
        if let detected = CodexProcessGuard.credentialHome(pid: scopedChild.processIdentifier) {
            precondition(detected.path == root.path)
        } else {
            // The sandbox may deny KERN_PROCARGS2. The production guard must then block.
            precondition(CodexProcessGuard.blocks(CodexClientProcess(pid: scopedChild.processIdentifier, parent: 1, executable: "codex", home: nil), home: root, desktopPIDs: []))
            precondition(ProcessInfo.processInfo.environment["RUNWAY_PROCESS_SCOPE_CHECK"] != "1")
        }
        scopedChild.terminate()
        scopedChild.waitUntilExit()

        let usageServer = root.appendingPathComponent("synthetic-usage-server")
        let usageProgram = """
        #!/usr/bin/python3
        import base64, json, os, sys
        home = os.environ['CODEX_HOME']
        assert home != '\(root.path)'
        assert 'cli_auth_credentials_store="file"' in sys.argv
        identity_reads = 0
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            method = request['method']
            if method == 'initialize': result = {}
            elif method == 'account/read':
                identity_reads += 1
                assert request['params']['refreshToken'] is (identity_reads == 1)
                with open(os.path.join(home, 'auth.json'), 'wb') as f:
                    f.write(base64.b64decode('\(newerSecond.base64EncodedString())'))
                os.chmod(os.path.join(home, 'auth.json'), 0o600)
                result = {'account': {'type': 'chatgpt', 'email': 'second@example.com', 'planType': 'pro'}}
            elif method == 'account/rateLimits/read':
                result = {'accountId': 'account-two', 'rateLimits': {'primary': {'usedPercent': 32, 'resetsAt': 1900000000, 'windowDurationMins': 10080}}}
            else: raise RuntimeError('Only usage and identity requests allowed')
            print(json.dumps({'id': request['id'], 'result': result}), flush=True)
        """
        try Data(usageProgram.utf8).write(to: usageServer)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: usageServer.path)
        let transportUsage = try await switcher.readSavedUsage(id: secondProfile.id, configuration: config) { home, configuration in
            try await client.readActiveAccount(executablePath: usageServer.path, home: home, configuration: configuration)
        }
        try check(transportUsage.rateLimits.accountId == "account-two" && (try read()) == previous)

        if ProcessInfo.processInfo.environment["RUNWAY_KEYCHAIN_CHECK"] == "1" {
            // Disposable service scope; never enumerate the real Codex home.
            let keychain = KeychainSavedLoginStore(home: root)
            let keychainRecovery = KeychainLoginRecoveryStore(home: root)
            defer { try? keychainRecovery.clear() }
            try keychainRecovery.save(LoginRecoveryRecord(target: secondProfile, original: previous))
            try check(try keychainRecovery.load()?.original == previous)
            // A new instance sees the same durable record; profile listings exclude it.
            try check(try KeychainLoginRecoveryStore(home: root).load()?.target == secondProfile)
            defer { try? keychain.remove(id: firstProfile.id); try? keychain.remove(id: secondProfile.id) }
            try keychain.save(SavedCodexLogin(profile: firstProfile, credentials: first))
            try check(try keychain.profiles().contains { $0.id == firstProfile.id })
            try check(try keychain.load(id: firstProfile.id).credentials == first)
            try keychain.save(SavedCodexLogin(profile: firstProfile, credentials: rotatedFirst))
            try check(try keychain.load(id: firstProfile.id).credentials == rotatedFirst)
            try keychain.save(SavedCodexLogin(profile: secondProfile, credentials: second))
            try check(try keychain.profiles().count == 2)
            try keychain.remove(id: firstProfile.id)
            try keychain.remove(id: secondProfile.id)
            try check(try keychain.profiles().isEmpty)
            try keychainRecovery.clear()
            try check(try keychainRecovery.load() == nil)
            print("Disposable macOS Keychain create, list, read, update, and cleanup checks passed")
        }
        if ProcessInfo.processInfo.environment["RUNWAY_PROCESS_GUARD_CHECK"] == "1" {
            do {
                try CodexProcessGuard.assertClosed()
                print("Production process guard: no Codex clients running")
            } catch LoginSwitchError.clientsRunning {
                print("Production process guard: running Codex clients blocked")
            }
        }
        print("Synthetic isolated usage, active identity/history preservation, managed restart, sign-in cancellation, scoped processes, recovery, rotation, rollback and refresh exclusion checks passed")
    }
}
