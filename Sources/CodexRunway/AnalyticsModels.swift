import Foundation

struct AnalyticsEnvelope<Row: Decodable>: Decodable {
    let data: [Row]
    let dataFreshnessTs: String?
}

struct AnalyticsMessageDay: Codable {
    let date: String
    let totals: AnalyticsMessageTotals?
    let models: [AnalyticsMessageModel]?
    let clients: [AnalyticsMessageClient]
}

struct AnalyticsMessageTotals: Codable {
    let turns: Int?
    let threads: Int?
    let credits: Double?
    let textTotalTokens: Int64?
    let cachedTextInputTokens: Int64?
    let uncachedTextInputTokens: Int64?
    let textOutputTokens: Int64?
}

struct AnalyticsMessageModel: Codable {
    let model: String
    let turns: Int?
    let credits: Double?
}

struct AnalyticsMessageClient: Codable {
    let clientId: String
    let turns: Int?
    let credits: Double?
}

struct AnalyticsUsageDay: Codable {
    let date: String
    let attribution: [AnalyticsAttribution]
    let models: [AnalyticsUsageModel]
    let productSurfaceUsageValues: [String: Double]
}

struct AnalyticsAttribution: Codable {
    let threadSource: String
    let turnTrigger: String
    let model: String
    let surface: String
    let value: Double
}

struct AnalyticsUsageModel: Codable {
    let model: String
    let speed: String?
    let credits: Double
}

struct AnalyticsToolDay: Codable {
    let date: String
    let pluginUsageOverviews: [AnalyticsToolOverview]?
    let skillUsageOverviews: [AnalyticsToolOverview]?

    var overviews: [AnalyticsToolOverview] { pluginUsageOverviews ?? skillUsageOverviews ?? [] }
}

struct AnalyticsToolOverview: Codable {
    let displayName: String
    let invocationCounts: Int
    let pluginId: String?
    let pluginName: String?
    let skillName: String?
    let skillIds: [String]?

    var key: String { pluginId ?? skillName ?? displayName }
}

struct AnalyticsPlanHistory: Decodable {
    let dataAsOf: String?
    let coverageStart: String?
    let coverageComplete: Bool
    let approximate: Bool
    let periods: [AnalyticsPlanPeriod]
}

struct AnalyticsPlanPeriod: Codable {
    let id: String
    let windowMinutes: Int
    let planType: String
    let startsAt: String
    let endsAt: String
    let accountingComplete: Bool
    let usedBasisPoints: Double?
    let breakdowns: [AnalyticsPlanBreakdown]?
}

struct AnalyticsPlanBreakdown: Codable {
    let dimension: String
    let rows: [AnalyticsPlanBreakdownRow]
}

struct AnalyticsPlanBreakdownRow: Codable {
    let key: String
    let basisPoints: Double
}

// Credit events and review metrics can evolve independently of this app.
// Preserve their server payloads so future views can use data already collected.
enum AnalyticsJSON: Codable, Equatable {
    case object([String: AnalyticsJSON])
    case array([AnalyticsJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([String: AnalyticsJSON].self) { self = .object(value) }
        else { self = .array(try box.decode([AnalyticsJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .object(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .null: try box.encodeNil()
        }
    }

    var object: [String: AnalyticsJSON]? {
        if case .object(let value) = self { value } else { nil }
    }
    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }
    var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }
}

struct AnalyticsRawDay: Codable {
    let date: String
    let payload: AnalyticsJSON
}

struct AnalyticsThreadSummary: Decodable {
    let id: String
    let name: String?
    let preview: String?
    let createdAt: Double?
    let updatedAt: Double?
    let parentThreadId: String?

    var bestTimestamp: Double? { createdAt ?? updatedAt }
    var activityTimestamp: Double? { updatedAt ?? createdAt }
}

struct AnalyticsChatUsage: Decodable {
    let threadId: String
    let weeklyLimitPercent: Double?
    let fiveHourLimitPercent: Double?
    let balanceUsageCredits: String?
    let dataStatus: String
    let groups: [AnalyticsJSON]
}

struct AnalyticsChat: Codable {
    let threadID: String
    let title: String
    let createdAt: Date
    let updatedAt: Date?
    let weeklyLimitPercent: Double?
    let fiveHourLimitPercent: Double?
    let balanceUsageCredits: String?
    let dataStatus: String
    let groups: [AnalyticsJSON]
}

struct AnalyticsArchive: Codable {
    var accountID: String
    var messages: [AnalyticsMessageDay] = []
    var usage: [AnalyticsUsageDay] = []
    var plugins: [AnalyticsToolDay] = []
    var skills: [AnalyticsToolDay] = []
    var reviews: [AnalyticsRawDay] = []
    var planPeriods: [AnalyticsPlanPeriod] = []
    var creditEvents: [AnalyticsJSON] = []
    var chats: [AnalyticsChat] = []
    var usageFetchedAt: Date?
    var messagesFetchedAt: Date?
    var pluginsFetchedAt: Date?
    var skillsFetchedAt: Date?
    var planFetchedAt: Date?
    var chatsFetchedAt: Date?
    var lastBackfillAt: Date?
    var dataFreshnessTimestamp: String?

    mutating func prune(now: Date) {
        let cutoff = ProfileCalendar.key(HistoryRetention.cutoff(now: now))
        messages.removeAll { $0.date < cutoff }
        usage.removeAll { $0.date < cutoff }
        plugins.removeAll { $0.date < cutoff }
        skills.removeAll { $0.date < cutoff }
        reviews.removeAll { $0.date < cutoff }
        planPeriods.removeAll { String($0.endsAt.prefix(10)) < cutoff }
        chats.removeAll { ($0.updatedAt ?? $0.createdAt) < HistoryRetention.cutoff(now: now) }
        creditEvents.removeAll { event in
            guard let object = event.object,
                  let date = (object["created_at"] ?? object["timestamp"] ?? object["date"])?.string
            else { return false }
            return String(date.prefix(10)) < cutoff
        }
    }

    static func merged<Row>(_ old: [Row], _ new: [Row], date: (Row) -> String) -> [Row] {
        var rows = Dictionary(old.map { (date($0), $0) }, uniquingKeysWith: { _, latest in latest })
        for row in new { rows[date(row)] = row }
        return rows.keys.sorted().compactMap { rows[$0] }
    }
}

enum AnalyticsUsageBreakdown {
    static func totals(_ days: [String: [String: Double]]) -> [String: Double] {
        var totals: [String: Double] = [:]
        for values in days.values {
            for (name, value) in values { totals[name, default: 0] += value }
        }
        return totals
    }

    static func share(of value: Double, in values: [String: Double]) -> Double {
        let total = values.values.reduce(0, +)
        return total > 0 ? value / total * 100 : 0
    }
}
