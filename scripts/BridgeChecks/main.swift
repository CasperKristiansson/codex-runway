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
struct BridgeChecks {
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String = "Hub check failed", line: UInt = #line) throws { let result = try value(); precondition(result, message, line: line) }
    @MainActor private final class Flags { var failed = false }
    @MainActor private final class DisconnectGate {
        var holdNextReply = false
        var holding = false
        var waiter: CheckedContinuation<Void, Never>?
        var release: CheckedContinuation<Void, Never>?
        func pause() async {
            guard holdNextReply else { return }
            holdNextReply = false
            holding = true
            waiter?.resume(); waiter = nil
            await withCheckedContinuation { release = $0 }
        }
        func waitForReceipt() async {
            if holding { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }
    static func credentials(_ email: String, account: String) throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: ["email": email, "https://api.openai.com/auth": ["chatgpt_account_id": account]])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "OPENAI_API_KEY": NSNull(), "tokens": ["account_id": account, "id_token": "synthetic.\(payload).signature", "access_token": "NEVER_EXPORT_ACCESS", "refresh_token": "NEVER_EXPORT_REFRESH"]])
    }
    @MainActor
    static func main() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("hub-checks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "runway-hub-checks.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let time = Date.now, reset = time.addingTimeInterval(72 * 3600)
        var first = CodexAccount(name: "Primary", email: "first@example.com", planName: "Pro 20×", externalAccountID: "one")
        var second = CodexAccount(name: "Reserve", email: "second@example.com", planName: "Pro 5×", externalAccountID: "two")
        for index in 0..<100 {
            var sample = UsageSnapshot(capturedAt: time.addingTimeInterval(-Double(99 - index) * 3600), usedPercent: Double(index) * 0.5, resetAt: reset)
            sample.capacityUnits = 4; sample.windowDurationMins = 10080; first.snapshots.append(sample)
            sample.capacityUnits = 1; second.snapshots.append(sample)
        }
        first.profile = AccountProfile(summary: ProfileSummary(lifetimeTokens: 500_000, peakDailyTokens: 50_000, longestRunningTurnSec: 1200, currentStreakDays: 3, longestStreakDays: 5), dailyUsageBuckets: (0..<30).map { ProfileDay(startDate: ProfileCalendar.key(time.addingTimeInterval(-Double($0) * 86400)), tokens: Int64(($0 % 5 + 1) * 10_000)) }, fetchedAt: time, hasDailyData: true)
        second.profile = first.profile
        defaults.set(try JSONEncoder().encode([first, second]), forKey: "codex-runway.accounts.v1")
        let archiveStore = AnalyticsArchiveStore(directory: root.appendingPathComponent("analytics"))
        var archive = AnalyticsArchive(accountID: "one")
        let today = ProfileCalendar.key(time)
        archive.messages = [AnalyticsMessageDay(date: today, totals: AnalyticsMessageTotals(turns: 80, threads: 5, credits: nil, textTotalTokens: nil, cachedTextInputTokens: nil, uncachedTextInputTokens: nil, textOutputTokens: nil), models: [AnalyticsMessageModel(model: "Sol", turns: 70, credits: nil)], clients: [AnalyticsMessageClient(clientId: "desktop_app", turns: 80, credits: nil)])]
        archive.usage = [AnalyticsUsageDay(date: today, attribution: [AnalyticsAttribution(threadSource: "task", turnTrigger: "user", model: "Sol", surface: "desktop_app", value: 12)], models: [AnalyticsUsageModel(model: "Sol", speed: nil, credits: 12)], productSurfaceUsageValues: ["desktop_app": 12])]
        archive.plugins = [AnalyticsToolDay(date: today, pluginUsageOverviews: [AnalyticsToolOverview(displayName: "Browser", invocationCounts: 8, pluginId: "browser", pluginName: nil, skillName: nil, skillIds: nil)], skillUsageOverviews: nil)]
        archive.skills = archive.plugins
        archive.planPeriods = [AnalyticsPlanPeriod(id: "period", windowMinutes: 10080, planType: "pro", startsAt: today, endsAt: today, accountingComplete: false, usedBasisPoints: 1200, breakdowns: [AnalyticsPlanBreakdown(dimension: "thread_source", rows: [AnalyticsPlanBreakdownRow(key: "task", basisPoints: 1200)])])]
        archive.chats = [AnalyticsChat(threadID: "test-chat", title: "Synthetic runway planning", createdAt: time, updatedAt: time, weeklyLimitPercent: 5, fiveHourLimitPercent: nil, balanceUsageCredits: "12", dataStatus: "saved", groups: [.string("NEVER_EXPORT_RAW")])]
        archive.creditEvents = [.string("NEVER_EXPORT_RAW")]
        archive.usageFetchedAt = time; archive.messagesFetchedAt = time
        try archiveStore.save(archive, accountID: first.id)
        archive.accountID = "two"; try archiveStore.save(archive, accountID: second.id)
        let vault = MemoryLoginStore(), recovery = MemoryRecoveryStore(), fixture = Fixture(), lifecycle = LifecycleFixture()
        let config = CodexLoginConfiguration(storage: "file")
        let auth = root.appendingPathComponent("auth.json")
        func write(_ data: Data) throws { try data.write(to: auth); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: auth.path) }
        let outgoing = try credentials(first.email, account: "one"), incoming = try credentials(second.email, account: "two")
        try write(incoming)
        let switcher = CodexLoginSwitcher(home: root, vault: vault, recovery: recovery, assertClosed: { try fixture.assertClosed() })
        let secondLogin = try switcher.saveCurrent(configuration: config)
        try write(outgoing); _ = try switcher.saveCurrent(configuration: config)
        var quotaCalls = 0, savedCalls = 0, savedProfileCalls = 0, savedAnalyticsCalls = 0
        let flags = Flags()
        var quotaGate: CheckedContinuation<Void, Never>?
        var verifyGate: CheckedContinuation<Void, Never>?
        func response(_ email: String) -> AccountReadResponse { AccountReadResponse(account: ChatGPTAccount(type: "chatgpt", email: email, planType: email == first.email ? "pro" : "prolite")) }
        func usage(_ email: String, id: String) -> ActiveCodexAccount {
            ActiveCodexAccount(identity: response(email), rateLimits: RateLimitsReadResponse(accountId: id, rateLimits: RateLimitSnapshot(primary: LimitWindow(usedPercent: 50, resetsAt: reset.timeIntervalSince1970, windowDurationMins: 10080), planType: "pro"), rateLimitResetCredits: nil))
        }
        let store = RunwayStore(defaults: defaults, forecastJournal: ForecastJournal(directory: root.appendingPathComponent("forecasts")), analyticsArchiveStore: archiveStore, analyticsEnabled: false, loginSwitcher: switcher,
            readLoginConfiguration: { config }, verifyLogin: {
                await withCheckedContinuation { verifyGate = $0 }
                return response(second.email)
            }, readSavedUsage: { _, _ in savedCalls += 1; return usage(second.email, id: "two") }, readSavedProfile: { id, _ in
                precondition(id == secondLogin.id); savedProfileCalls += 1
                return ActiveAccountProfile(identity: response(second.email), usage: ProfileUsageResponse(summary: second.profile!.summary, dailyUsageBuckets: second.profile!.dailyUsageBuckets))
            }, readSavedAnalytics: { id, _, _, _, _ in
                precondition(id == secondLogin.id); savedAnalyticsCalls += 1
                var update = AnalyticsUpdate(); update.messages = []; return update
            }, readAnalyticsThreads: { _ in [] }, synchronizeSavedLogin: {}, closeDesktop: {
                lifecycle.closes += 1; lifecycle.isOpen = false; fixture.open = false; return true
            }, openDesktop: { lifecycle.opens += 1; lifecycle.isOpen = true }, desktopIsOpen: { lifecycle.isOpen }, now: { time }, readProfile: {
                ActiveAccountProfile(identity: response(first.email), usage: ProfileUsageResponse(summary: first.profile!.summary, dailyUsageBuckets: first.profile!.dailyUsageBuckets))
            }, readAccount: {
                quotaCalls += 1
                await withCheckedContinuation { quotaGate = $0 }
                if flags.failed { throw CodexAppServerError.server("NEVER_EXPORT_ACCESS") }
                return usage(first.email, id: "one")
            })
        store.reloadSavedLogins()
        let backups = RunwayBackupManager(defaults: defaults)
        let hub = RunwayHubController(store: store, backups: backups, defaults: defaults, openNative: {})
        func wire(_ kind: String, _ args: [String: Any] = [:]) throws -> Data { try JSONSerialization.data(withJSONObject: ["version": 1, "kind": kind].merging(args) { _, new in new }) }
        func reply(_ input: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: hub.reply(input)) as! [String: Any] }
        let before = store.accounts
        let snapshot = try reply(wire("snapshot", ["section": "history"]))
        let report = CapacityForecast.report(accounts: store.accounts, now: time)
        let overview = snapshot["overview"] as! [String: Any]
        try check(abs((overview["remaining"] as! Double) - report.remaining) < 0.0001)
        try check((overview["ratePerDay"] as! Double) - report.ratePerHour! * 24 < 0.00001)
        let history = snapshot["history"] as! [String: Any]
        try check((history["stats"] as! [String: String])["Lifetime tokens"] == ProfileFormat.tokens(AccountProfile.combined(store.accounts.compactMap(\.profile), now: time)?.summary.lifetimeTokens))
        for _ in 0..<10 { _ = try reply(wire("snapshot", ["section": "analytics"])) }
        try check(quotaCalls == 0 && savedCalls == 0 && store.accounts == before, "Polling must never refresh or write account data")
        var fixtureSnapshot = try hub.snapshot(try HubRequest.decode(wire("snapshot", ["section": "analytics"])), now: time)
        fixtureSnapshot["fixtureAnalyticsByAccount"] = Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.id.uuidString, HubSnapshot.analytics(accounts: [$0], store: store, days: 365, now: time)) })
        fixtureSnapshot["fixtureHistoryByAccount"] = try Dictionary(uniqueKeysWithValues: store.accounts.map { ($0.id.uuidString, try HubSnapshot.history(accounts: [$0], now: time)) })
        fixtureSnapshot["history"] = try HubSnapshot.history(accounts: store.accounts, now: time)
        let export = try JSONSerialization.data(withJSONObject: fixtureSnapshot, options: [.sortedKeys])
        let text = String(decoding: export, as: UTF8.self)
        try check(!text.contains("NEVER_EXPORT") && !text.contains("access_token") && !text.contains("refresh_token"))
        if CommandLine.arguments.count > 1 { try export.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
        for invalid in ["{\"version\":2,\"kind\":\"snapshot\"}", "{\"version\":1,\"kind\":\"snapshot\",\"token\":\"x\"}", "{\"version\":1,\"kind\":\"snapshot\",\"days\":8}"] {
            try check(try reply(Data(invalid.utf8))["error"] != nil)
        }
        try check(try reply(wire("snapshot", ["accountID": UUID().uuidString]))["error"] != nil)
        let refresh = try wire("command", ["action": "refresh", "requestID": UUID().uuidString])
        let receipt = try reply(refresh)
        for _ in 0..<1000 { if quotaGate != nil { break }; await Task.yield() }
        try check(quotaCalls == 1 && store.isRefreshing)
        try check(try reply(refresh)["operationID"] as? String == receipt["operationID"] as? String)
        try check(try reply(wire("command", ["action": "save", "requestID": UUID().uuidString]))["error"] != nil)
        await store.refreshUsage(accountID: second.id)
        try check(savedCalls == 0 && store.accounts == before, "Native/embedded refresh serialization")
        quotaGate?.resume(); quotaGate = nil
        for _ in 0..<1000 { if hub.operations.last?.state != "running" { break }; await Task.yield() }
        try check(hub.operations.last?.state == "completed")
        let successful = store.accounts
        flags.failed = true
        _ = try reply(wire("command", ["action": "refresh", "requestID": UUID().uuidString]))
        for _ in 0..<1000 { if quotaGate != nil { break }; await Task.yield() }
        quotaGate?.resume(); quotaGate = nil
        for _ in 0..<1000 { if hub.operations.last?.state != "running" { break }; await Task.yield() }
        try check(store.accounts == successful && hub.operations.last?.state == "failed")
        try check(!String(decoding: hub.reply(try wire("snapshot")), as: UTF8.self).contains("NEVER_EXPORT"))
        // Native edits reconcile on the next cached read, including preferences.
        store.setAccountEnabled(id: second.id, enabled: false)
        store.displayPreferences.showsPercent = true
        let reconciled = try reply(wire("snapshot"))
        try check((reconciled["preferences"] as! [String: Any])["percent"] as? Bool == true)
        let rows = reconciled["accounts"] as! [[String: Any]]
        try check(rows.first { $0["id"] as? String == second.id.uuidString }?["enabled"] as? Bool == false)
        // Both manual buttons route the selected account even with no active
        // marker. All excludes disabled rows; explicit selections include them.
        try check(store.activeAccountID == nil)
        for action in ["refreshProfile", "refreshAnalytics"] {
            try check(try reply(wire("command", ["action": action, "accountID": UUID().uuidString, "requestID": UUID().uuidString]))["error"] != nil)
        }
        _ = try reply(wire("command", ["action": "refreshProfile", "requestID": UUID().uuidString]))
        for _ in 0..<1000 { if hub.operations.last?.state != "running" { break }; await Task.yield() }
        try check(savedProfileCalls == 0 && hub.operations.last?.state == "completed", "All must skip disabled accounts")
        _ = try reply(wire("command", ["action": "refreshProfile", "accountID": second.id.uuidString, "requestID": UUID().uuidString]))
        for _ in 0..<1000 { if hub.operations.last?.state != "running" { break }; await Task.yield() }
        try check(savedProfileCalls == 1 && hub.operations.last?.state == "completed")
        _ = try reply(wire("command", ["action": "refreshAnalytics", "accountID": second.id.uuidString, "requestID": UUID().uuidString]))
        for _ in 0..<1000 { if hub.operations.last?.state != "running" { break }; await Task.yield() }
        try check(savedAnalyticsCalls == 1 && hub.operations.last?.state == "completed")
        let stale = HubSnapshot.base(store: store, now: time.addingTimeInterval(8 * 86400))
        let staleRows = stale["accounts"] as! [[String: Any]]
        try check(staleRows.first?["assumedReset"] as? Bool == true && staleRows.first?["resetAt"] is NSNull)
        try check(staleRows.first?["observedUsedPercent"] as? Double == store.accounts.first?.latestSnapshot?.usedPercent)
        // Host-disconnect simulation: submit and retain only the native hub. The
        // browser/stdio client isn't an owner of the transaction or its task.
        fixture.open = true
        let switchWire = try wire("command", ["action": "switch", "loginID": secondLogin.id, "requestID": UUID().uuidString])
        let switchReceipt = try reply(switchWire)
        for _ in 0..<1000 { if verifyGate != nil { break }; await Task.yield() }
        try check(lifecycle.closes == 1 && verifyGate != nil && !store.loginCanCancel)
        try check(try reply(switchWire)["operationID"] as? String == switchReceipt["operationID"] as? String)
        try check(try reply(wire("command", ["action": "switch", "loginID": secondLogin.id, "requestID": UUID().uuidString]))["operationID"] as? String == switchReceipt["operationID"] as? String)
        try check(try reply(wire("command", ["action": "cancel", "requestID": UUID().uuidString]))["error"] != nil)
        try check(try Data(contentsOf: auth) == incoming)
        verifyGate?.resume(); verifyGate = nil
        for _ in 0..<1000 { if hub.operations.last?.state != "running" { break }; await Task.yield() }
        try check(lifecycle.opens == 1 && hub.operations.last?.state == "completed" && recovery.record == nil)
        let reopened = RunwayHubController(store: store, backups: backups, defaults: defaults, openNative: {})
        try check(reopened.operations.last?.id == hub.operations.last?.id)
        try check(try reply(switchWire)["operationID"] as? String == switchReceipt["operationID"] as? String)
        // Transport tests: private modes, exclusive lease, real socket roundtrip.
        let socketPath = root.appendingPathComponent("bridge/hub.sock").path
        let disconnectGate = DisconnectGate()
        let server = try RunwayHubSocket(path: socketPath) { bytes in
            let receipt = await hub.reply(bytes)
            await disconnectGate.pause()
            return receipt
        }
        server.start(); defer { server.stop() }
        let permissions = try FileManager.default.attributesOfItem(atPath: socketPath)[.posixPermissions] as! Int
        try check(permissions == 0o600)
        do { _ = try RunwayHubSocket(path: socketPath) { _ in Data() }; preconditionFailure("Exclusive bridge lease") } catch {}
        FileHandle.standardError.write(Data("Checking native socket roundtrip…\n".utf8))
        let request = try wire("snapshot") + Data([10])
        let output = try await Task.detached { () throws -> Data in
            let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(fd) }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketPath.utf8) + [0]; withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
            let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            try check(connected == 0)
            _ = request.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while !result.contains(10) { let count = recv(fd, &buffer, buffer.count, 0); try check(count > 0); result.append(contentsOf: buffer.prefix(count)) }
            return result
        }.value
        try check((try JSONSerialization.jsonObject(with: output) as! [String: Any])["available"] as? Bool == true)
        FileHandle.standardError.write(Data("Checking abrupt client disconnect…\n".utf8))
        let disconnectedRequest = try wire("command", ["action": "display", "percent": false, "requestID": UUID().uuidString]) + Data([10])
        disconnectGate.holdNextReply = true
        await Task.detached {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(fd) }
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(socketPath.utf8) + [0]) }
            _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            _ = disconnectedRequest.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
            // First prove native admission, then disconnect before the held
            // receipt is sent. A frame dropped before admission is not a task.
            await disconnectGate.waitForReceipt()
        }.value
        disconnectGate.release?.resume(); disconnectGate.release = nil
        FileHandle.standardError.write(Data("Accepted request disconnected before reply…\n".utf8))
        for _ in 0..<1000 { if !store.displayPreferences.showsPercent { break }; await Task.yield() }
        try check(!store.displayPreferences.showsPercent, "A transport disconnect must not cancel an accepted native task")
        print("Hub checks passed: Swift parity, read-only polling, bounded/redacted contract, native reconciliation, stale/reset semantics, serialization, disconnect ownership, durable duplicate switches and private socket lease/roundtrip")
    }
}
