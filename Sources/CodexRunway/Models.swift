import Foundation

enum StatusDates {
    static func elapsed(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        let hours = minutes / 60
        let days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)min" }
        return minutes > 0 ? "\(minutes)min" : "Just now"
    }

    static func reset(_ date: Date, now: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMMM HH:mm"
        let seconds = date.timeIntervalSince(now)
        let days = max(0, Int((seconds / 86_400).rounded()))
        let countdown = seconds <= 0 ? "reset due" : days == 0 ? "<1d" : "\(days)d"
        return "\(formatter.string(from: date)) (\(countdown))"
    }
}

struct UsageSnapshot: Codable, Identifiable, Equatable {
    let id: UUID
    let capturedAt: Date
    let usedPercent: Double
    let resetAt: Date
    let bankedResetCount: Int
    var capacityUnits: Double? = nil
    var windowDurationMins: Int? = nil
    var secondaryUsedPercent: Double? = nil
    var secondaryResetAt: Date? = nil

    // A derived assumption, never a fabricated server reading. The original
    // timestamp and usage remain available for history and pace calculations.
    func assumesReset(at now: Date) -> Bool { resetAt <= now }
    func remainingPercent(at now: Date) -> Double {
        assumesReset(at: now) ? 100 : min(100, max(0, 100 - usedPercent))
    }
    func nextReset(at now: Date) -> Date? { assumesReset(at: now) ? nil : resetAt }

    init(
        id: UUID = UUID(),
        capturedAt: Date = .now,
        usedPercent: Double,
        resetAt: Date,
        bankedResetCount: Int = 0
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.bankedResetCount = bankedResetCount
    }
}

struct CodexAccount: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var email: String
    var planName: String
    var externalAccountID: String?
    var snapshots: [UsageSnapshot]
    var isEnabled: Bool
    var profile: AccountProfile? = nil

    init(
        id: UUID = UUID(),
        name: String,
        email: String = "",
        planName: String,
        externalAccountID: String? = nil,
        snapshots: [UsageSnapshot] = [],
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.planName = planName
        self.externalAccountID = externalAccountID
        self.snapshots = snapshots
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        email = try values.decode(String.self, forKey: .email)
        planName = try values.decode(String.self, forKey: .planName)
        externalAccountID = try values.decodeIfPresent(String.self, forKey: .externalAccountID)
        snapshots = try values.decode([UsageSnapshot].self, forKey: .snapshots)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        profile = try values.decodeIfPresent(AccountProfile.self, forKey: .profile)
    }

    var latestSnapshot: UsageSnapshot? {
        snapshots.max(by: { $0.capturedAt < $1.capturedAt })
    }

    var displayEmail: String {
        email.isEmpty ? "No email available" : email
    }

    var capacityUnits: Double? {
        let plan = planName.lowercased().replacingOccurrences(of: "×", with: "x")
        if plan.contains("20x") { return 4 }
        if plan.contains("5x") { return 1 }
        return nil
    }
}
