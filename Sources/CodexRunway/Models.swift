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

    init(
        id: UUID = UUID(),
        name: String,
        email: String = "",
        planName: String,
        externalAccountID: String? = nil,
        snapshots: [UsageSnapshot] = []
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.planName = planName
        self.externalAccountID = externalAccountID
        self.snapshots = snapshots
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
