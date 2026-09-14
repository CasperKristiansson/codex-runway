import Foundation

enum HistoryRetention {
    static func cutoff(now: Date) -> Date { now.addingTimeInterval(-365 * 86_400) }
}

struct ProfileSummary: Codable, Equatable {
    var lifetimeTokens: Int64?
    var peakDailyTokens: Int64?
    var longestRunningTurnSec: Int64?
    var currentStreakDays: Int64?
    var longestStreakDays: Int64?
}

struct ProfileDay: Codable, Equatable {
    let startDate: String
    let tokens: Int64
}

struct ProfileUsageResponse: Decodable {
    let summary: ProfileSummary
    let dailyUsageBuckets: [ProfileDay]?
}

struct AccountProfile: Codable, Equatable {
    var summary: ProfileSummary
    var dailyUsageBuckets: [ProfileDay]
    var fetchedAt: Date
    var hasDailyData: Bool

    static func needsRefresh(_ profile: AccountProfile?, now: Date) -> Bool {
        guard let profile else { return true }
        let age = now.timeIntervalSince(profile.fetchedAt)
        return age >= 6 * 3_600 || age < 0
    }

    static func merging(_ response: ProfileUsageResponse, into previous: AccountProfile?, now: Date) -> AccountProfile {
        var days = Dictionary((previous?.dailyUsageBuckets ?? []).map { ($0.startDate, $0.tokens) }, uniquingKeysWith: { _, new in new })
        // The service can revise delayed buckets. Replace dates, never add a
        // second copy; keep older dates omitted by a later, shorter response.
        for day in response.dailyUsageBuckets ?? [] where day.tokens >= 0 && ProfileCalendar.date(day.startDate) != nil {
            days[day.startDate] = day.tokens
        }
        let cutoff = ProfileCalendar.key(HistoryRetention.cutoff(now: now))
        let today = ProfileCalendar.key(now)
        return AccountProfile(summary: response.summary,
            dailyUsageBuckets: days.filter { $0.key >= cutoff && $0.key <= today }
                .map { ProfileDay(startDate: $0.key, tokens: $0.value) }.sorted { $0.startDate < $1.startDate },
            fetchedAt: now, hasDailyData: response.dailyUsageBuckets != nil || previous?.hasDailyData == true)
    }

    static func combined(_ profiles: [AccountProfile], now: Date) -> AccountProfile? {
        guard !profiles.isEmpty else { return nil }
        var days: [String: Int64] = [:]
        let cutoff = ProfileCalendar.key(HistoryRetention.cutoff(now: now))
        for profile in profiles {
            for day in profile.dailyUsageBuckets where day.startDate >= cutoff && day.startDate <= ProfileCalendar.key(now) {
                days[day.startDate, default: 0] += day.tokens
            }
        }
        let buckets = days.map { ProfileDay(startDate: $0.key, tokens: $0.value) }.sorted { $0.startDate < $1.startDate }
        let activeDates = buckets.filter { $0.tokens > 0 }.compactMap { ProfileCalendar.date($0.startDate) }
        var longest: Int64 = 0, run: Int64 = 0
        var previous: Date?
        for date in activeDates {
            run = previous.map { date.timeIntervalSince($0) == 86_400 } == true ? run + 1 : 1
            longest = max(longest, run)
            previous = date
        }
        let today = ProfileCalendar.date(ProfileCalendar.key(now))!
        let last = activeDates.last
        let current = last.map { today.timeIntervalSince($0) <= 86_400 ? run : 0 } ?? 0
        let completeDaily = profiles.allSatisfy(\.hasDailyData)
        let summary = ProfileSummary(
            lifetimeTokens: profiles.allSatisfy { $0.summary.lifetimeTokens != nil } ? profiles.reduce(0) { $0 + ($1.summary.lifetimeTokens ?? 0) } : nil,
            peakDailyTokens: completeDaily ? buckets.map(\.tokens).max() ?? 0 : nil,
            longestRunningTurnSec: profiles.allSatisfy { $0.summary.longestRunningTurnSec != nil } ? profiles.compactMap { $0.summary.longestRunningTurnSec }.max() : nil,
            currentStreakDays: completeDaily ? current : nil,
            longestStreakDays: completeDaily ? longest : nil)
        return AccountProfile(summary: summary, dailyUsageBuckets: buckets,
            fetchedAt: profiles.map(\.fetchedAt).min()!, hasDailyData: completeDaily)
    }
}

enum ProfileCalendar {
    static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.locale = Locale(identifier: "en_GB")
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }

    static func date(_ key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, key.count == 10,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              self.key(date) == key else { return nil }
        return date
    }

    static func key(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }
}

enum ProfileFormat {
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    static func tokens(_ value: Int64?) -> String {
        guard let value else { return "—" }
        for (scale, suffix) in [(1_000_000_000.0, "B"), (1_000_000.0, "M"), (1_000.0, "K")] {
            if Double(value) >= scale {
                let number = String(format: "%.1f", Double(value) / scale)
                return (number.hasSuffix(".0") ? String(number.dropLast(2)) : number) + suffix
            }
        }
        return String(value)
    }

    static func duration(_ seconds: Int64?) -> String {
        guard let seconds else { return "—" }
        let minutes = Int64((Double(seconds) / 60).rounded())
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    static func days(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return "\(value) \(value == 1 ? "day" : "days")"
    }
}
