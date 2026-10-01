import Foundation
import Darwin
import AppKit

struct RateLimitsReadResponse: Decodable {
    let accountId: String?
    let rateLimits: RateLimitSnapshot
    let rateLimitResetCredits: ResetCredits?
}

struct ActiveCodexAccount {
    let identity: AccountReadResponse
    let rateLimits: RateLimitsReadResponse
}

struct ActiveAccountProfile {
    let identity: AccountReadResponse
    let usage: ProfileUsageResponse
}

private struct AnalyticsThreadListResponse: Decodable {
    let data: [AnalyticsThreadSummary]
    let nextCursor: String?
}

struct AccountReadResponse: Decodable, Equatable {
    let account: ChatGPTAccount?
}

struct ChatGPTAccount: Decodable, Equatable {
    let type: String
    let email: String?
    let planType: String?
}

struct RateLimitSnapshot: Decodable {
    let primary: LimitWindow
    let planType: String?
    var secondary: LimitWindow? = nil
}

struct LimitWindow: Decodable {
    let usedPercent: Double
    let resetsAt: TimeInterval?
    var windowDurationMins: Int? = nil
}

struct ResetCredits: Decodable {
    let availableCount: Int
}

enum CodexAppServerError: LocalizedError {
    case executableNotFound
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "Codex CLI was not found. Set its path in Settings."
        case .invalidResponse:
            return "Codex returned an invalid usage response."
        case .server(let message):
            return message
        }
    }
}

/// Uses Codex's documented local App Server protocol. It only asks for the currently signed-in
/// account's rate-limit and profile summaries; it never reads browser cookies or authentication files.
actor CodexAppServerClient {
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 1
    private var loginNotifications: [Data] = []
    private var loginWaiter: CheckedContinuation<Data, Error>?

    func signIn(home: URL, configuration: CodexLoginConfiguration, executablePath: String? = nil,
                openBrowser: @escaping @MainActor @Sendable (URL) throws -> Void = { url in
                    guard NSWorkspace.shared.open(url) else { throw LoginSwitchError.signInFailed }
                }) async throws {
        try configuration.validate()
        try start(executablePath: executablePath, home: home, configuration: configuration)
        defer { stop() }
        _ = try await request(method: "initialize", params: ["clientInfo": ["name": "codex-runway", "version": "0.1.0"]])
        notify(method: "initialized")
        let start = try await request(method: "account/login/start", params: ["type": "chatgpt", "useHostedLoginSuccessPage": true, "appBrand": "codex"])
        guard let object = try JSONSerialization.jsonObject(with: start) as? [String: Any],
              let loginID = object["loginId"] as? String,
              let authURL = object["authUrl"] as? String, let url = URL(string: authURL),
              url.scheme == "https", url.host == "auth.openai.com", url.user == nil, url.password == nil else {
            throw LoginSwitchError.signInFailed
        }
        try Task.checkCancellation()
        try await openBrowser(url)
        let completion = try await waitForLogin()
        guard let result = try JSONSerialization.jsonObject(with: completion) as? [String: Any],
              result["loginId"] as? String == loginID, result["success"] as? Bool == true else {
            throw LoginSwitchError.signInFailed
        }
        let identity = try JSONDecoder().decode(AccountReadResponse.self,
            from: await request(method: "account/read", params: ["refreshToken": false]))
        guard let data = try CodexAuthFile(home: home).read(),
              let cache = try? CodexLoginCache(data), identity.account?.type == "chatgpt",
              identity.account?.email?.lowercased() == cache.email else { throw LoginSwitchError.signInFailed }
        try configuration.validate(cache)
    }

    private func waitForLogin() async throws -> Data {
        try Task.checkCancellation()
        if !loginNotifications.isEmpty { return loginNotifications.removeFirst() }
        let timeout = Task {
            try await Task.sleep(for: .seconds(600))
            failLogin(with: LoginSwitchError.signInFailed)
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { loginWaiter = $0 }
        } onCancel: { Task { await self.failLogin(with: CancellationError()) } }
    }

    private func failLogin(with error: Error) {
        loginWaiter?.resume(throwing: error)
        loginWaiter = nil
    }

    /// Local effective configuration only; no authentication or quota refresh.
    func readLoginConfiguration(executablePath: String? = nil) async throws -> CodexLoginConfiguration {
        let environment = ProcessInfo.processInfo.environment
        guard ["OPENAI_API_KEY", "CODEX_ACCESS_TOKEN"].allSatisfy({ environment[$0]?.isEmpty != false }) else {
            throw LoginSwitchError.unsupportedStorage
        }
        try start(executablePath: executablePath)
        defer { stop() }
        _ = try await request(method: "initialize", params: ["clientInfo": ["name": "codex-runway", "version": "0.1.0"]])
        notify(method: "initialized")
        let data = try await request(method: "config/read", params: ["includeLayers": false])
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any],
              let storage = config["cli_auth_credentials_store"] as? String else {
            throw LoginSwitchError.unsupportedStorage
        }
        return CodexLoginConfiguration(storage: storage,
            forcedLoginMethod: config["forced_login_method"] as? String,
            forcedWorkspaceID: config["forced_chatgpt_workspace_id"] as? String)
    }

    /// Verifies just the selected login, allowing Codex to refresh its tokens.
    /// Does not fetch quota, profile history, or other accounts.
    func verifyLogin(executablePath: String? = nil) async throws -> AccountReadResponse {
        try start(executablePath: executablePath)
        defer { stop() }
        _ = try await request(method: "initialize", params: ["clientInfo": ["name": "codex-runway", "version": "0.1.0"]])
        notify(method: "initialized")
        return try JSONDecoder().decode(AccountReadResponse.self,
            from: await request(method: "account/read", params: ["refreshToken": true]))
    }

    func readActiveProfile(executablePath: String? = nil) async throws -> ActiveAccountProfile {
        try start(executablePath: executablePath)
        defer { stop() }
        _ = try await request(method: "initialize", params: [
            "clientInfo": ["name": "codex-runway", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true]
        ])
        notify(method: "initialized")
        let before = try JSONDecoder().decode(AccountReadResponse.self,
            from: await request(method: "account/read", params: ["refreshToken": false]))
        let usage = try JSONDecoder().decode(ProfileUsageResponse.self,
            from: await request(method: "account/usage/read", params: [:]))
        let after = try JSONDecoder().decode(AccountReadResponse.self,
            from: await request(method: "account/read", params: ["refreshToken": false]))
        guard before == after, before.account?.email?.isEmpty == false else {
            throw CodexAppServerError.server("Account changed during profile refresh. Try again.")
        }
        return ActiveAccountProfile(identity: before, usage: usage)
    }

    func readActiveAccount(executablePath: String? = nil) async throws -> ActiveCodexAccount {
        try start(executablePath: executablePath)
        defer { stop() }

        let initialization = try await request(
            method: "initialize",
            params: ["clientInfo": ["name": "codex-runway", "version": "0.1.0"]]
        )
        guard !initialization.isEmpty else { throw CodexAppServerError.invalidResponse }
        notify(method: "initialized")
        let accountData = try await request(method: "account/read", params: ["refreshToken": false])
        let rateLimitData = try await request(method: "account/rateLimits/read", params: nil)
        return ActiveCodexAccount(
            identity: try JSONDecoder().decode(AccountReadResponse.self, from: accountData),
            rateLimits: try JSONDecoder().decode(RateLimitsReadResponse.self, from: rateLimitData)
        )
    }

    /// Reads task metadata from the local App Server. The Analytics backend
    /// decides which of these task IDs have usage for the active account.
    func readAnalyticsThreads(since: Date, limit: Int = 600, executablePath: String? = nil) async throws -> [AnalyticsThreadSummary] {
        try start(executablePath: executablePath)
        defer { stop() }
        _ = try await request(method: "initialize", params: [
            "clientInfo": ["name": "codex-runway", "version": "0.1.0"]
        ])
        notify(method: "initialized")
        var result: [AnalyticsThreadSummary] = []
        for archived in [false, true] {
            var cursor: String?
            repeat {
                var params: [String: Any] = [
                    "limit": 100, "sortKey": "updated_at", "sortDirection": "desc",
                    "sourceKinds": [], "modelProviders": [], "archived": archived,
                    "useStateDbOnly": true
                ]
                if let cursor { params["cursor"] = cursor }
                let response = try JSONDecoder().decode(AnalyticsThreadListResponse.self,
                    from: await request(method: "thread/list", params: params))
                let recent = response.data.filter { ($0.activityTimestamp ?? 0) >= since.timeIntervalSince1970 }
                result.append(contentsOf: recent)
                cursor = recent.count == response.data.count ? response.nextCursor : nil
            } while cursor != nil && result.count < limit
            if result.count >= limit { break }
        }
        return Array(result.prefix(limit))
    }

    private func start(executablePath: String?, home: URL? = nil, configuration: CodexLoginConfiguration? = nil) throws {
        guard process == nil else { throw LoginSwitchError.refreshRunning }
        let executable = executablePath ?? Self.defaultExecutablePath()
        guard let executable, FileManager.default.isExecutableFile(atPath: executable) else {
            throw CodexAppServerError.executableNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        if let home {
            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = home.path
            process.environment = environment
            var overrides = ["-c", "cli_auth_credentials_store=\"file\""]
            if let workspace = configuration?.forcedWorkspaceID {
                let encoded = String(decoding: try JSONEncoder().encode(workspace), as: UTF8.self)
                overrides += ["-c", "forced_chatgpt_workspace_id=\(encoded)"]
            }
            process.arguments = overrides + ["app-server", "--stdio"]
        }
        buffer.removeAll()
        loginNotifications.removeAll()
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
            let data = handle.availableData
            guard !data.isEmpty, let pid = process?.processIdentifier else { return }
            Task { await self?.receive(data, pid: pid) }
        }
        process.terminationHandler = { [weak self] child in
            let pid = child.processIdentifier
            Task { await self?.handleTermination(pid: pid) }
        }

        try process.run()
        self.process = process
        stdin = input.fileHandleForWriting
    }

    private func stop() {
        failLogin(with: CancellationError())
        for continuation in pending.values {
            continuation.resume(throwing: CancellationError())
        }
        pending.removeAll()
        process?.standardOutput.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        process?.terminationHandler = nil
        try? stdin?.close()
        if let process {
            let pid = process.processIdentifier
            func exited() -> Bool {
                var status: Int32 = 0
                let result = waitpid(pid, &status, WNOHANG)
                // Foundation may already have reaped the child. Never signal
                // an ECHILD PID, which could have been reused by another process.
                return result == pid || (result == -1 && errno == ECHILD)
            }
            if !exited() {
                kill(pid, SIGTERM)
                var didExit = false
                for _ in 0..<50 {
                    if exited() { didExit = true; break }
                    usleep(10_000)
                }
                if !didExit {
                    kill(pid, SIGKILL)
                    for _ in 0..<100 {
                        if exited() { break }
                        usleep(10_000)
                    }
                }
            }
            // NSConcreteTask.waitUntilExit can hang after its exit event races
            // with shutdown. Only our direct child is checked/signalled above.
        }
        process = nil
        stdin = nil
    }

    private func request(method: String, params: Any?) async throws -> Data {
        let id = nextID
        nextID += 1
        var object: [String: Any] = ["id": id, "method": method]
        if let params { object["params"] = params }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let stdin else { throw CodexAppServerError.server("Codex App Server did not start.") }

        // A stalled server must not block every future automatic refresh.
        let timeout = Task {
            try await Task.sleep(for: .seconds(30))
            pending.removeValue(forKey: id)?.resume(
                throwing: CodexAppServerError.server("Codex refresh timed out. It will retry automatically.")
            )
        }
        defer { timeout.cancel() }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                stdin.write(data)
                stdin.write(Data([0x0A]))
            }
        } onCancel: { Task { await self.cancelRequest(id: id) } }
    }

    private func cancelRequest(id: Int) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }

    private func notify(method: String) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: ["method": method]) else { return }
        stdin.write(data)
        stdin.write(Data([0x0A]))
    }

    private func receive(_ data: Data, pid: Int32) {
        guard process?.processIdentifier == pid else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            handleLine(Data(line))
        }
    }

    private func handleLine(_ line: Data) {
        if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
           message["method"] as? String == "account/login/completed", let params = message["params"],
           let data = try? JSONSerialization.data(withJSONObject: params) {
            if let waiter = loginWaiter {
                loginWaiter = nil
                waiter.resume(returning: data)
            } else if loginNotifications.count < 8 { loginNotifications.append(data) }
            return
        }
        guard
            let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let id = value["id"] as? Int,
            let continuation = pending.removeValue(forKey: id)
        else { return }

        if let error = value["error"] as? [String: Any], let message = error["message"] as? String {
            continuation.resume(throwing: CodexAppServerError.server(message))
            return
        }
        guard let result = value["result"], JSONSerialization.isValidJSONObject(result), let data = try? JSONSerialization.data(withJSONObject: result) else {
            continuation.resume(throwing: CodexAppServerError.invalidResponse)
            return
        }
        continuation.resume(returning: data)
    }

    private func handleTermination(pid: Int32) {
        guard process?.processIdentifier == pid else { return }
        failPending(with: CodexAppServerError.server("Codex App Server stopped unexpectedly."))
        failLogin(with: LoginSwitchError.signInFailed)
    }

    private func failPending(with error: Error) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(throwing: error) }
    }

    private static func defaultExecutablePath() -> String? {
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
