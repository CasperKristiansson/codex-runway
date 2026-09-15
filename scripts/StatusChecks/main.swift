import Foundation

@MainActor
private final class RefreshFixture {
    var calls = 0
    var inFlight = 0
    var maximumInFlight = 0
    var email = "first@example.com"
    var shouldFail = false
    var profileCalls = 0
    var profileShouldFail = false
    var profileEmail: String?
    var time = Date.now
}

@main
struct StatusChecks {
    @MainActor
    static func main() async throws {
        let now = Date(timeIntervalSince1970: 0)
        precondition(StatusDates.elapsed(since: now.addingTimeInterval(-4_200), now: now) == "1h 10min")
        precondition(StatusDates.elapsed(since: now.addingTimeInterval(-442_800), now: now) == "5d 3h")
        precondition(StatusDates.elapsed(since: now, now: now) == "Just now")
        let utc = TimeZone(secondsFromGMT: 0)!
        precondition(StatusDates.reset(now.addingTimeInterval(3.6 * 86_400), now: now, timeZone: utc) == "4 January 14:24 (4d)")
        precondition(StatusDates.reset(now.addingTimeInterval(3_600), now: now, timeZone: utc) == "1 January 01:00 (<1d)")
        precondition(StatusDates.reset(now, now: now, timeZone: utc) == "1 January 00:00 (reset due)")

        let suite = "codex-runway.checks.\(UUID().uuidString)"
        let responseData = Data(#"{"rateLimits":{"primary":{"usedPercent":20,"resetsAt":1800000000,"windowDurationMins":10080},"secondary":{"usedPercent":5,"resetsAt":null}}}"#.utf8)
        let decodedResponse = try JSONDecoder().decode(RateLimitsReadResponse.self, from: responseData)
        precondition(decodedResponse.rateLimits.primary.windowDurationMins == 10080)
        precondition(decodedResponse.rateLimits.secondary?.usedPercent == 5)
        precondition(decodedResponse.rateLimits.secondary?.resetsAt == nil)
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = CodexAccount(name: "Renamed account", email: "first@example.com", planName: "Pro")
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode([legacy])) as! [[String: Any]]
        legacyJSON[0]["isEnabledForPlanning"] = false
        legacyJSON[0].removeValue(forKey: "isEnabled")
        defaults.set(try JSONSerialization.data(withJSONObject: legacyJSON), forKey: "codex-runway.accounts.v1")

        let fixture = RefreshFixture()
        let store = RunwayStore(defaults: defaults, now: { fixture.time }, readProfile: {
            fixture.profileCalls += 1
            if fixture.profileShouldFail { throw CodexAppServerError.invalidResponse }
            return ActiveAccountProfile(
                identity: AccountReadResponse(account: ChatGPTAccount(type: "chatgpt", email: fixture.profileEmail ?? fixture.email, planType: "pro")),
                usage: ProfileUsageResponse(summary: ProfileSummary(lifetimeTokens: 100), dailyUsageBuckets: [ProfileDay(startDate: ProfileCalendar.key(fixture.time), tokens: 100)]))
        }) {
            fixture.calls += 1
            fixture.inFlight += 1
            fixture.maximumInFlight = max(fixture.maximumInFlight, fixture.inFlight)
            defer { fixture.inFlight -= 1 }
            try await Task.sleep(for: .milliseconds(20))
            if fixture.shouldFail { throw CodexAppServerError.invalidResponse }
            return ActiveCodexAccount(
                identity: AccountReadResponse(account: ChatGPTAccount(type: "chatgpt", email: fixture.email, planType: "pro")),
                rateLimits: RateLimitsReadResponse(accountId: fixture.email, rateLimits: RateLimitSnapshot(
                    primary: LimitWindow(usedPercent: 42, resetsAt: Date.now.addingTimeInterval(3600).timeIntervalSince1970),
                    planType: "pro"
                ), rateLimitResetCredits: ResetCredits(availableCount: 2))
            )
        }
        precondition(store.accounts.first?.name == "Renamed account", "Legacy data must remain readable")
        precondition(store.accounts.first!.isEnabled, "Existing accounts default to active")
        let staleSettings = store.accounts[0]

        // The same scheduler runs without any menu or view being created.
        store.startAutomaticRefresh(interval: 0.08)
        store.startAutomaticRefresh(interval: 0.08)
        try await Task.sleep(for: .milliseconds(350))
        store.stopAutomaticRefresh()
        try await Task.sleep(for: .milliseconds(50))
        precondition(fixture.calls >= 3, "Launch and repeating refresh must run without a menu")
        precondition(fixture.maximumInFlight == 1, "Refreshes must never overlap")
        precondition(store.accounts.count == 1 && store.accounts[0].latestSnapshot?.usedPercent == 42)
        precondition(fixture.profileCalls == 1, "15-minute checks must skip profiles younger than six hours")
        fixture.time = fixture.time.addingTimeInterval(6 * 3_600)
        await store.refreshActiveAccount()
        precondition(fixture.profileCalls == 2, "Due profiles refresh on the next check, without waiting for a new six-hour timer")
        await store.refreshProfile()
        precondition(fixture.profileCalls == 3, "Manual refresh bypasses freshness")
        let profileSaved = store.accounts[0].profile
        fixture.profileShouldFail = true
        fixture.time = fixture.time.addingTimeInterval(6 * 3_600)
        await store.refreshActiveAccount()
        precondition(store.accounts[0].profile == profileSaved && store.refreshError == nil && store.profileRefreshError != nil)
        let failedCalls = fixture.profileCalls
        await store.refreshActiveAccount()
        precondition(fixture.profileCalls == failedCalls + 1, "Failed requests remain due for retry")
        fixture.profileShouldFail = false
        fixture.profileEmail = "wrong@example.com"
        await store.refreshProfile()
        precondition(store.accounts[0].profile == profileSaved, "Never save another identity's profile")
        fixture.profileEmail = nil
        await store.refreshProfile()
        let stoppedCalls = fixture.calls
        try await Task.sleep(for: .milliseconds(150))
        precondition(fixture.calls == stoppedCalls, "Stopping must invalidate the timer")

        store.update(staleSettings)
        precondition(store.accounts[0].latestSnapshot != nil, "Settings must preserve background snapshots")
        fixture.email = "second@example.com"
        await store.refreshActiveAccount()
        precondition(store.accounts.count == 2, "Switching identities must retain both accounts")
        precondition(store.activeAccountID == store.accounts[1].id)
        let saved = store.accounts
        fixture.shouldFail = true
        await store.refreshActiveAccount()
        precondition(store.refreshError != nil && !store.isRefreshing && store.activeAccountID == nil)
        precondition(store.accounts == saved, "Failed refresh must preserve saved status")
        fixture.shouldFail = false
        await store.refreshActiveAccount()
        precondition(store.refreshError == nil && store.activeAccountID == store.accounts[1].id)
        fixture.shouldFail = true
        let quietRefreshSucceeded = await store.refreshActiveAccount(presentFailure: false)
        precondition(!quietRefreshSucceeded && store.refreshError == nil,
            "A transient launch refresh failure must stay quiet when saved account data is available")
        fixture.shouldFail = false
        await store.refreshActiveAccount()
        let reloaded = RunwayStore(defaults: defaults)
        precondition(reloaded.accounts == store.accounts, "All account snapshots must persist")
        let beforeMove = store.accounts
        let activeBeforeMove = store.activeAccountID
        precondition(store.moveAccount(id: beforeMove[0].id, to: beforeMove[1].id))
        precondition(store.accounts == Array(beforeMove.reversed()))
        precondition(store.activeAccountID == activeBeforeMove, "Reordering must not switch the active account")
        precondition(RunwayStore(defaults: defaults).accounts == store.accounts, "Reordered accounts must persist")
        await store.refreshActiveAccount()
        precondition(store.accounts.map(\.id) == beforeMove.reversed().map(\.id), "Refresh must retain the chosen order")
        precondition(store.moveAccount(id: beforeMove[0].id, to: beforeMove[1].id))
        precondition(store.accounts.map(\.id) == beforeMove.map(\.id), "Moving upward must restore the order")
        precondition(!store.moveAccount(id: UUID(), to: beforeMove[0].id))
        precondition(!store.moveAccount(id: beforeMove[0].id, to: beforeMove[0].id))
        precondition(!store.moveAccount(id: store.accounts.first!.id, by: -1))
        precondition(!store.moveAccount(id: store.accounts.last!.id, by: 1))
        precondition(!store.moveAccount(id: UUID(), by: 1))
        let settingsOrder = store.accounts.map(\.id)
        precondition(store.moveAccount(id: settingsOrder[0], by: 1))
        precondition(store.accounts.map(\.id) == Array(settingsOrder.reversed()))
        precondition(RunwayStore(defaults: defaults).accounts == store.accounts)
        precondition(store.moveAccount(id: settingsOrder[0], by: -1))
        precondition(store.accounts.map(\.id) == settingsOrder)
        let inactiveID = store.activeAccountID!
        let preservedHistory = store.accounts.first { $0.id == inactiveID }!.snapshots
        store.setAccountEnabled(id: inactiveID, enabled: false)
        precondition(store.accounts.count == 2 && store.dashboardAccounts.count == 1)
        precondition(store.accounts.first { $0.id == inactiveID }!.snapshots == preservedHistory)
        precondition(!RunwayStore(defaults: defaults).accounts.first { $0.id == inactiveID }!.isEnabled)
        await store.refreshActiveAccount()
        precondition(!store.accounts.first { $0.id == inactiveID }!.isEnabled, "Refresh must not reactivate an account")
        store.setAccountEnabled(id: inactiveID, enabled: true)
        precondition(store.dashboardAccounts.map(\.id) == settingsOrder, "Reactivation preserves order")
        for account in store.accounts { store.setAccountEnabled(id: account.id, enabled: false) }
        precondition(store.dashboardAccounts.isEmpty && store.accounts.count == 2)
        print("Status and automatic refresh checks passed")
    }
}
