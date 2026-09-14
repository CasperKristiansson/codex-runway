import Foundation

@main
struct ProfileChecks {
    static func main() throws {
        let now = ProfileCalendar.date("2026-09-14")!
        // Synthetic fixture; never commit a captured account payload.
        let data = Data(#"{"summary":{"lifetimeTokens":11600000000,"peakDailyTokens":1400000000,"longestRunningTurnSec":35580,"currentStreakDays":1,"longestStreakDays":6},"dailyUsageBuckets":[{"startDate":"2026-09-13","tokens":100}]}"#.utf8)
        let response = try JSONDecoder().decode(ProfileUsageResponse.self, from: data)
        precondition(ProfileFormat.tokens(response.summary.lifetimeTokens) == "11.6B")
        precondition(ProfileFormat.tokens(100_000_000) == "100M")
        precondition(ProfileFormat.tokens(1_200_000) == "1.2M")
        precondition(ProfileFormat.tokens(1_000) == "1K")
        precondition(ProfileFormat.tokens(0) == "0")
        precondition(ProfileFormat.duration(response.summary.longestRunningTurnSec) == "9h 53m")
        let first = AccountProfile.merging(response, into: nil, now: now)
        precondition(AccountProfile.needsRefresh(nil, now: now))
        precondition(!AccountProfile.needsRefresh(first, now: now.addingTimeInterval(21_599)))
        precondition(AccountProfile.needsRefresh(first, now: now.addingTimeInterval(21_600)))
        let corrected = ProfileUsageResponse(summary: response.summary, dailyUsageBuckets: [
            ProfileDay(startDate: "2026-09-13", tokens: 150), ProfileDay(startDate: "2026-09-14", tokens: 20),
            ProfileDay(startDate: "2025-09-13", tokens: 1), ProfileDay(startDate: "2025-09-14", tokens: 3),
            ProfileDay(startDate: "invalid", tokens: 3), ProfileDay(startDate: "2026-09-15", tokens: 5)])
        let merged = AccountProfile.merging(corrected, into: first, now: now)
        precondition(merged.dailyUsageBuckets.count == 3)
        precondition(merged.dailyUsageBuckets.first?.startDate == "2025-09-14")
        precondition(merged.dailyUsageBuckets.first { $0.startDate == "2026-09-13" }?.tokens == 150)
        let shorter = AccountProfile.merging(response, into: merged, now: now)
        precondition(shorter.dailyUsageBuckets.count == 3, "Shorter responses preserve retained days")
        let total = AccountProfile.combined([first, merged], now: now)!
        precondition(total.summary.lifetimeTokens == 23_200_000_000)
        precondition(total.summary.peakDailyTokens == 250, "Combined peak is peak of daily sums")
        precondition(total.summary.longestStreakDays == 2 && total.summary.currentStreakDays == 2)
        precondition(total.summary.longestRunningTurnSec == 35_580)
        precondition(AccountProfile.combined([first], now: now.addingTimeInterval(2 * 86_400))?.summary.currentStreakDays == 0)
        let null = try JSONDecoder().decode(ProfileUsageResponse.self, from: Data(#"{"summary":{},"dailyUsageBuckets":null}"#.utf8))
        let missing = AccountProfile.merging(null, into: nil, now: now)
        precondition(!missing.hasDailyData && missing.summary.lifetimeTokens == nil)
        precondition(AccountProfile.combined([missing, first], now: now)?.summary.lifetimeTokens == nil)
        precondition(ProfileCalendar.date("2026-02-30") == nil)
        let encoded = try JSONEncoder().encode(merged)
        let restored = try JSONDecoder().decode(AccountProfile.self, from: encoded)
        precondition(restored == merged)
        print("Profile checks passed: schema, formatting, six-hour freshness, merging, one-year retention, aggregation, and persistence")
    }
}
