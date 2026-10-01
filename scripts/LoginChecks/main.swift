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
        let switcher = CodexLoginSwitcher(home: root, vault: vault, assertClosed: { try fixture.assertClosed() })
        func response(_ email: String) -> AccountReadResponse {
            AccountReadResponse(account: ChatGPTAccount(type: "chatgpt", email: email, planType: "pro"))
        }
        try write(first)
        fixture.open = true
        do { try switcher.saveCurrent(configuration: config); preconditionFailure("Open app must block capture") }
        catch LoginSwitchError.clientsRunning {}
        try check(vault.values.isEmpty && (try read()) == first)
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
        precondition(CodexProcessGuard.isCodexExecutable("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        precondition(!CodexProcessGuard.isCodexExecutable("/Applications/Codex Runway.app/Contents/MacOS/CodexRunway"))

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
            }, verifyLogin: { response("second@example.com") }, readAccount: {
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
            elif method == 'config/read': result = {'config': {'cli_auth_credentials_store': 'file'}}
            elif method == 'account/read':
                assert request['params']['refreshToken'] is True
                result = {'account': {'type': 'chatgpt', 'email': 'second@example.com', 'planType': 'pro'}}
            else: raise RuntimeError('Unexpected method')
            print(json.dumps({'id': request['id'], 'result': result}), flush=True)
        """
        try Data(program.utf8).write(to: server)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: server.path)
        let client = CodexAppServerClient()
        for _ in 0..<3 {
            let readConfiguration = try await client.readLoginConfiguration(executablePath: server.path)
            precondition(readConfiguration.storage == "file")
            let identity = try await client.verifyLogin(executablePath: server.path)
            precondition(identity.account?.email == "second@example.com")
        }
        if ProcessInfo.processInfo.environment["RUNWAY_KEYCHAIN_CHECK"] == "1" {
            // Disposable service scope; never enumerate the real Codex home.
            let keychain = KeychainSavedLoginStore(home: root)
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
        print("Synthetic saved-login, process guard, token rotation, rollback, file safety, and refresh exclusion checks passed")
    }
}
