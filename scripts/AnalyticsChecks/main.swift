import Foundation

@main
struct AnalyticsChecks {
    @MainActor
    static func main() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let messages = try decoder.decode(AnalyticsEnvelope<AnalyticsMessageDay>.self, from: Data(#"""
        {
          "data": [
            {"date":"2025-09-20","totals":{"turns":2},"clients":[]},
            {"date":"2026-09-21","totals":{"turns":5},"clients":[{"client_id":"desktop_app","turns":5}]}
          ]
        }
        """#.utf8))
        precondition(messages.data[1].models == nil, "Some server days omit the model breakdown")
        let plan = try decoder.decode(AnalyticsPlanHistory.self, from: Data(#"""
        {
          "data_as_of":"2026-09-22T00:00:00Z","coverage_start":null,
          "coverage_complete":false,"approximate":true,
          "periods":[{"id":"period-1","window_minutes":10080,"plan_type":"pro",
            "starts_at":"2026-09-21T00:00:00Z","ends_at":"2026-09-28T00:00:00Z",
            "accounting_complete":false,"used_basis_points":180.25,
            "breakdowns":[{"dimension":"thread_source","rows":[{"key":"task","basis_points":170.5}]}]}]
        }
        """#.utf8))
        precondition(plan.periods[0].usedBasisPoints == 180.25, "Plan percentages may be fractional")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("runway-analytics-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AnalyticsArchiveStore(directory: directory)
        let accountID = UUID()
        var archive = AnalyticsArchive(accountID: "backend-account")
        var update = AnalyticsUpdate()
        update.messages = messages.data
        update.plan = plan
        let now = ProfileCalendar.date("2026-09-22")!
        archive.apply(update, now: now, wasBackfill: true)
        precondition(archive.messages.map(\.date) == ["2026-09-21"], "History older than one year must expire")
        precondition(archive.lastBackfillAt == now)
        try store.save(archive, accountID: accountID)
        var reloaded = try store.load(accountID: accountID)!
        precondition(reloaded.accountID == "backend-account" && reloaded.planPeriods.count == 1)
        update.messages = try decoder.decode(AnalyticsEnvelope<AnalyticsMessageDay>.self, from: Data(#"""
        {
          "data":[{"date":"2026-09-21","totals":{"turns":7},"models":[],"clients":[]}]
        }
        """#.utf8)).data
        reloaded.apply(update, now: now, wasBackfill: false)
        precondition(reloaded.messages.count == 1 && reloaded.messages[0].totals?.turns == 7,
                     "A revised day must replace its previous value")
        precondition(reloaded.planPeriods.count == 1, "Period IDs must upsert")
        reloaded.chats = [AnalyticsChat(threadID: "old-but-active", title: "Active task",
            createdAt: now.addingTimeInterval(-400 * 86_400), updatedAt: now.addingTimeInterval(-86_400),
            weeklyLimitPercent: 1, fiveHourLimitPercent: nil, balanceUsageCredits: nil,
            dataStatus: "partial", groups: [])]
        reloaded.prune(now: now)
        precondition(reloaded.chats.count == 1, "Recently active older chats must remain saved")
        try store.save(reloaded, accountID: accountID)
        let verified = try store.load(accountID: accountID)!
        precondition(verified.messages[0].totals?.turns == 7)
        print("Analytics archive and response checks passed")
    }
}
