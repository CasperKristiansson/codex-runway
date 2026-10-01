import AppKit
import Darwin
import Foundation

struct CodexClientProcess {
    let pid: Int32
    let parent: Int32
    let executable: String
    let home: URL?
}

@MainActor
struct CodexProcessGuard {
    static func isCodexExecutable(_ path: String) -> Bool {
        ["codex", "codex-cli", "codex.exe", "codex-cli.exe"].contains(URL(fileURLWithPath: path).lastPathComponent.lowercased())
            || path.contains("/Codex.app/") || path.contains("/CodexCLI.app/")
    }

    static func blocks(_ client: CodexClientProcess, home: URL, desktopPIDs: Set<Int32>) -> Bool {
        if desktopPIDs.contains(client.pid) { return true }
        guard isCodexExecutable(client.executable) else { return false }
        // Unknown scopes are blockers; only positively identified independent homes are exempt.
        return client.home == nil || client.home?.standardizedFileURL.resolvingSymlinksInPath().path == home.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func assertClosed(home: URL = CodexAuthFile.defaultHome) throws {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" }
        let desktops = Set(apps.map(\.processIdentifier))
        let clients = try processes()
        let blockers = clients.filter { blocks($0, home: home, desktopPIDs: desktops) }
        var names = blockers.map { "\(URL(fileURLWithPath: $0.executable).lastPathComponent) (PID \($0.pid))" }
        // A desktop remains a blocker even if ps races with startup.
        names += apps.filter { app in !blockers.contains { $0.pid == app.processIdentifier } }
            .map { "Codex (PID \($0.processIdentifier))" }
        guard names.isEmpty else { throw LoginSwitchError.clientsRunning(names) }
    }

    private static func processes() throws -> [CodexClientProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "uid=,pid=,ppid=,comm="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw LoginSwitchError.processCheckFailed }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let listing = String(data: data, encoding: .utf8) else {
            throw LoginSwitchError.processCheckFailed
        }
        return listing.split(separator: "\n").compactMap { line in
            let fields = line.split(maxSplits: 3, whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 4, UInt32(fields[0]) == getuid(), let pid = Int32(fields[1]), let parent = Int32(fields[2]) else { return nil }
            let executable = String(fields[3])
            guard isCodexExecutable(executable) else { return nil }
            return CodexClientProcess(pid: pid, parent: parent, executable: executable, home: credentialHome(pid: pid))
        }
    }

    /// Read just enough of our own client's process environment to identify its scope.
    /// Never retain or display arguments, environment values, or token overrides.
    static func credentialHome(pid: Int32) -> URL? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4, size <= 4_194_304 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &bytes, &size, nil, 0) == 0 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0, argc < 100_000 else { return nil }
        var offset = 4
        func next() -> String? {
            guard offset < size, let end = bytes[offset..<size].firstIndex(of: 0) else { return nil }
            let value = String(bytes: bytes[offset..<end], encoding: .utf8)
            offset = end + 1
            return value
        }
        guard next() != nil else { return nil } // executable path
        while offset < size && bytes[offset] == 0 { offset += 1 }
        for _ in 0..<argc { guard next() != nil else { return nil } }
        var codexHome: String?
        var userHome: String?
        while let entry = next(), !entry.isEmpty {
            if entry.hasPrefix("CODEX_HOME=") { codexHome = String(entry.dropFirst(11)) }
            if entry.hasPrefix("HOME=") { userHome = String(entry.dropFirst(5)) }
        }
        let path = codexHome ?? userHome.map { $0 + "/.codex" }
        guard let path, path.hasPrefix("/"), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}

@MainActor
struct CodexDesktopLifecycle {
    func close() async throws -> Bool {
        let applications = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.openai.codex" }
        guard !applications.isEmpty else { return false }
        try Task.checkCancellation()
        for application in applications where !application.isTerminated {
            guard application.terminate() || application.isTerminated else { throw LoginSwitchError.quitFailed }
        }
        try await Self.waitForExit {
            applications.contains { !$0.isTerminated }
                || NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.openai.codex" }
        }
        return true
    }

    static func waitForExit(timeout: Duration = .seconds(30), isRunning: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while isRunning() {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw LoginSwitchError.quitTimedOut }
            try await Task.sleep(for: .milliseconds(100))
        }
        try Task.checkCancellation()
    }

    func open() async throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            throw LoginSwitchError.reopenFailed
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration) }
        catch { throw LoginSwitchError.reopenFailed }
    }
}
