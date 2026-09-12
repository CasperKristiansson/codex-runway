import Foundation

struct RateLimitsReadResponse: Decodable {
    let accountId: String?
    let rateLimits: RateLimitSnapshot
    let rateLimitResetCredits: ResetCredits?
}

struct ActiveCodexAccount {
    let identity: AccountReadResponse
    let rateLimits: RateLimitsReadResponse
}

struct AccountReadResponse: Decodable {
    let account: ChatGPTAccount?
}

struct ChatGPTAccount: Decodable {
    let type: String
    let email: String?
    let planType: String?
}

struct RateLimitSnapshot: Decodable {
    let primary: LimitWindow
    let planType: String?
}

struct LimitWindow: Decodable {
    let usedPercent: Double
    let resetsAt: TimeInterval
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
/// account's rate-limit summary; it never reads browser cookies or authentication files.
actor CodexAppServerClient {
    private var process: Process?
    private var stdin: FileHandle?
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var nextID = 1

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

    private func start(executablePath: String?) throws {
        let executable = executablePath ?? Self.defaultExecutablePath()
        guard let executable, FileManager.default.isExecutableFile(atPath: executable) else {
            throw CodexAppServerError.executableNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            Task { await self?.failPending(with: CodexAppServerError.server("Codex App Server stopped unexpectedly.")) }
        }

        try process.run()
        self.process = process
        stdin = input.fileHandleForWriting
    }

    private func stop() {
        for continuation in pending.values {
            continuation.resume(throwing: CancellationError())
        }
        pending.removeAll()
        process?.standardOutput.map { ($0 as? Pipe)?.fileHandleForReading.readabilityHandler = nil }
        if process?.isRunning == true { process?.terminate() }
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

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            stdin.write(data)
            stdin.write(Data([0x0A]))
        }
    }

    private func notify(method: String) {
        guard let stdin, let data = try? JSONSerialization.data(withJSONObject: ["method": method]) else { return }
        stdin.write(data)
        stdin.write(Data([0x0A]))
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            handleLine(Data(line))
        }
    }

    private func handleLine(_ line: Data) {
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
