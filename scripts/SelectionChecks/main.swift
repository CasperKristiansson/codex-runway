import Foundation

@MainActor
private final class MemoryLogins: SavedLoginStore {
    var values: [String: SavedCodexLogin] = [:]
    func profiles() throws -> [SavedLoginProfile] { values.values.map(\.profile) }
    func save(_ login: SavedCodexLogin) throws { values[login.profile.id] = login }
    func load(id: String) throws -> SavedCodexLogin {
        guard let login = values[id] else { throw LoginSwitchError.missingSavedLogin }
        return login
    }
    func remove(id: String) throws { values[id] = nil }
}

@MainActor
private final class MemoryRecovery: LoginRecoveryStore {
    var record: LoginRecoveryRecord?
    func load() throws -> LoginRecoveryRecord? { record }
    func save(_ record: LoginRecoveryRecord) throws { self.record = record }
    func clear() throws { record = nil }
}

private final class AnalyticsProtocol: URLProtocol, @unchecked Sendable {
    @MainActor static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            Self.requests.append(request)
            let path = request.url!.path
            let body: String
            if path.hasSuffix("daily-workspace-usage-counts") {
                body = #"{"data":[{"date":"2026-10-04","totals":{"turns":7},"clients":[]}]}"#
            } else if path.hasSuffix("plan_limit_history") { body = #"{"periods":[],"coverage_complete":true,"approximate":false}"# }
            else if path.hasSuffix("query_v2") { body = #"{"threads":[]}"# }
            else { body = #"{"data":[]}"# }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

@main
struct SelectionChecks {
    static func check(_ value: @autoclosure () throws -> Bool) throws { let result = try value(); precondition(result) }

    static func credentials(_ email: String, id: String, rotation: Int = 0) throws -> Data {
        let claims = try JSONSerialization.data(withJSONObject: ["email": email,
            "https://api.openai.com/auth": ["chatgpt_account_id": id]])
        let payload = claims.base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": [
            "account_id": id, "id_token": "synthetic.\(payload).signature",
            "access_token": "synthetic-\(id)-\(rotation)", "refresh_token": "synthetic-refresh-\(rotation)"]])
    }

    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("runway-selection-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let suite = "runway-selection.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = ProfileCalendar.date("2026-10-04")!
        let rows = ["Current", "Missing", "Failed", "Reserve", "Disabled"].map {
            CodexAccount(name: $0, email: "\($0.lowercased())@example.com", planName: "Pro 20×", externalAccountID: $0.lowercased())
        }
        defaults.set(try JSONEncoder().encode(rows), forKey: "codex-runway.accounts.v1")
        let vault = MemoryLogins(), recovery = MemoryRecovery()
        let config = CodexLoginConfiguration(storage: "file")
        let auth = CodexAuthFile(home: root)
        let switcher = CodexLoginSwitcher(home: root, vault: vault, recovery: recovery,
            assertClosed: { preconditionFailure("Refresh must keep Codex open") })
        var profiles: [UUID: SavedLoginProfile] = [:]
        for row in rows where row.name != "Missing" {
            let data = try credentials(row.email, id: row.externalAccountID!)
            try auth.replace(with: data, expecting: try auth.read(), assertClosed: {})
            profiles[row.id] = try switcher.saveCurrent(configuration: config)
        }
        let currentCredentials = try credentials(rows[0].email, id: "current")
        try auth.replace(with: currentCredentials, expecting: try auth.read(), assertClosed: {})
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [AnalyticsProtocol.self]
        let client = AnalyticsClient(authFile: root.appendingPathComponent("auth.json"), session: URLSession(configuration: sessionConfig))
        let archives = AnalyticsArchiveStore(directory: root.appendingPathComponent("analytics"))
        var profileCalls: [String] = [], analyticsCalls: [String] = [], isolatedHomes: [URL] = []
        var failReserve = false, wrongProfile = false, threadCalls = 0, activeQuotaCalls = 0
        var store: RunwayStore!
        func profile(_ email: String) -> ActiveAccountProfile {
            ActiveAccountProfile(identity: AccountReadResponse(account: ChatGPTAccount(type: "chatgpt", email: email, planType: "pro")),
                usage: ProfileUsageResponse(summary: ProfileSummary(lifetimeTokens: 200),
                    dailyUsageBuckets: [ProfileDay(startDate: "2026-10-04", tokens: 200)]))
        }
        func exclusion() async {
            precondition(store.loginActionsDisabled)
            let refreshed = await store.refreshActiveAccount()
            precondition(!refreshed && activeQuotaCalls == 1)
            await store.refreshProfile()
            await store.refreshAnalytics()
            await store.refreshUsage(accountID: rows[3].id)
            store.forgetLogin(id: profiles[rows[3].id]!.id)
            precondition(vault.values[profiles[rows[3].id]!.id] != nil)
        }
        store = RunwayStore(defaults: defaults, forecastJournal: ForecastJournal(directory: root.appendingPathComponent("forecasts")),
            analyticsArchiveStore: archives, analyticsClient: client, analyticsEnabled: false, loginSwitcher: switcher,
            readLoginConfiguration: { config }, readSavedProfile: { id, configuration in
                try await switcher.readSavedProfile(id: id, configuration: configuration) { home, _ in
                    isolatedHomes.append(home)
                    await exclusion()
                    let cache = try CodexLoginCache(CodexAuthFile(home: home).read()!)
                    profileCalls.append(cache.accountID)
                    if cache.accountID == "failed" || failReserve { throw CodexAppServerError.authenticationExpired }
                    let rotated = try credentials(cache.email, id: cache.accountID, rotation: 1)
                    try CodexAuthFile(home: home).replace(with: rotated, expecting: try CodexAuthFile(home: home).read(), assertClosed: {})
                    return profile(wrongProfile ? rows[0].email : cache.email)
                }
            }, readSavedAnalytics: { id, configuration, initial, threads, now in
                try await switcher.withSavedLogin(id: id, configuration: configuration) { home, _, login in
                    isolatedHomes.append(home)
                    await exclusion()
                    analyticsCalls.append(login.accountID)
                    if login.accountID == "failed" || failReserve { throw CodexAppServerError.authenticationExpired }
                    return try await client.fetch(accountID: login.accountID, initial: initial, threads: threads, now: now,
                                                  authFile: home.appendingPathComponent("auth.json"))
                }
            }, readAnalyticsThreads: { _ in threadCalls += 1; return [] }, synchronizeSavedLogin: {}, now: { now }, readProfile: {
                profileCalls.append("current")
                return profile(rows[0].email)
            }, readAccount: {
                activeQuotaCalls += 1
                return ActiveCodexAccount(identity: profile(rows[0].email).identity,
                    rateLimits: RateLimitsReadResponse(accountId: "current", rateLimits: RateLimitSnapshot(
                        primary: LimitWindow(usedPercent: 12, resetsAt: now.addingTimeInterval(3600).timeIntervalSince1970), planType: "pro"), rateLimitResetCredits: nil))
            })
        store.reloadSavedLogins()
        await store.refreshActiveAccount()
        store.setAccountEnabled(id: rows[4].id, enabled: false)
        profileCalls = []
        let activeID = store.activeAccountID, quotas = store.accounts.map(\.snapshots)
        await store.refreshProfile()
        precondition(profileCalls == ["current", "failed", "reserve"], "All selects enabled accounts and continues after failures")
        precondition(store.profileRefreshError!.contains("Missing") && store.profileRefreshError!.contains("Failed"))
        precondition(store.accounts[0].profile != nil && store.accounts[3].profile != nil && store.accounts[4].profile == nil)
        precondition(store.accounts.map(\.snapshots) == quotas && store.activeAccountID == activeID)
        precondition(isolatedHomes.allSatisfy { !fm.fileExists(atPath: $0.path) })
        try check(try auth.read() == currentCredentials)
        let savedProfile = store.accounts[3].profile
        profileCalls = []; wrongProfile = true
        await store.refreshProfile(accountID: rows[3].id)
        precondition(profileCalls == ["reserve"] && store.accounts[3].profile == savedProfile && store.profileRefreshError != nil)
        wrongProfile = false
        profileCalls = []
        await store.refreshProfile(accountID: rows[4].id)
        precondition(profileCalls == ["disabled"] && store.profileRefreshError == nil, "An explicit selection can refresh a disabled account")
        await store.refreshAnalytics()
        precondition(analyticsCalls == ["failed", "reserve"])
        precondition(store.analyticsRefreshError!.contains("Missing") && store.analyticsRefreshError!.contains("Failed"))
        precondition(store.analyticsByAccount[rows[0].id]?.messages.first?.totals?.turns == 7)
        precondition(store.analyticsByAccount[rows[3].id]?.messages.first?.totals?.turns == 7)
        precondition(store.analyticsByAccount[rows[4].id] == nil && threadCalls == 3)
        let requestIDs = Set(AnalyticsProtocol.requests.compactMap { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") })
        precondition(requestIDs == ["current", "reserve"], "Each account must use its own HTTP credentials")
        for request in AnalyticsProtocol.requests {
            let id = request.value(forHTTPHeaderField: "ChatGPT-Account-Id")!
            precondition(request.value(forHTTPHeaderField: "Authorization")!.hasPrefix("Bearer synthetic-\(id)-"))
        }
        analyticsCalls = []; AnalyticsProtocol.requests = []; failReserve = true
        let archiveEncoder = JSONEncoder(); archiveEncoder.outputFormatting = [.sortedKeys]
        let savedArchive = try archiveEncoder.encode(store.analyticsByAccount[rows[3].id])
        await store.refreshAnalytics(accountID: rows[3].id)
        try check(analyticsCalls == ["reserve"] && archiveEncoder.encode(store.analyticsByAccount[rows[3].id]) == savedArchive)
        precondition(AnalyticsProtocol.requests.isEmpty && store.analyticsRefreshError != nil)
        failReserve = false; analyticsCalls = []
        await store.refreshAnalytics(accountID: rows[4].id)
        precondition(analyticsCalls == ["disabled"] && store.analyticsRefreshError == nil)
        try check(try archives.load(accountID: rows[4].id)?.messages.first?.totals?.turns == 7)
        try check(try auth.read() == currentCredentials)
        precondition(store.activeAccountID == activeID && store.accounts.map(\.snapshots) == quotas)
        precondition(isolatedHomes.allSatisfy { !fm.fileExists(atPath: $0.path) })
        profileCalls = []; analyticsCalls = []
        for row in rows { store.setAccountEnabled(id: row.id, enabled: false) }
        await store.refreshProfile(); await store.refreshAnalytics()
        precondition(profileCalls.isEmpty && analyticsCalls.isEmpty && store.profileRefreshError != nil && store.analyticsRefreshError != nil)
        print("Selection, partial failure, archive preservation, isolated credentials and refresh exclusion checks passed")
    }
}
