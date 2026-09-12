import Foundation

struct UsageSnapshot: Codable, Identifiable, Equatable {
    let id: UUID
    let capturedAt: Date
    let usedPercent: Double
    let resetAt: Date
    let bankedResetCount: Int

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
    var isEnabledForPlanning: Bool
    var externalAccountID: String?
    var snapshots: [UsageSnapshot]

    init(
        id: UUID = UUID(),
        name: String,
        email: String = "",
        planName: String,
        isEnabledForPlanning: Bool = true,
        externalAccountID: String? = nil,
        snapshots: [UsageSnapshot] = []
    ) {
        self.id = id
        self.name = name
        self.email = email
        self.planName = planName
        self.isEnabledForPlanning = isEnabledForPlanning
        self.externalAccountID = externalAccountID
        self.snapshots = snapshots
    }

    var latestSnapshot: UsageSnapshot? {
        snapshots.max(by: { $0.capturedAt < $1.capturedAt })
    }

    var displayEmail: String {
        guard !email.isEmpty else { return "Add email in Settings" }
        let parts = email.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return email }
        let local = parts[0]
        let visible = local.prefix(min(3, local.count))
        return "\(visible)…@\(parts[1])"
    }
}

enum ForecastState: Equatable {
    case needsRefresh
    case learning(snapshotCount: Int)
    case resetDue
    case likelyLasts(marginPercent: Double, ratePerHour: Double)
    case likelyShort(shortfallHours: Double, ratePerHour: Double)

    var headline: String {
        switch self {
        case .needsRefresh:
            return "Needs refresh"
        case .learning:
            return "Learning your pace"
        case .resetDue:
            return "Reset due"
        case .likelyLasts(let marginPercent, _):
            return "Likely lasts · \(Forecasting.formatPercent(marginPercent)) buffer"
        case .likelyShort(let hours, _):
            return "Likely runs out \(Forecasting.formatDuration(hours)) early"
        }
    }
}

enum Forecasting {
    static func forecast(for account: CodexAccount, now: Date = .now) -> ForecastState {
        guard let current = account.latestSnapshot else { return .needsRefresh }
        let hoursToReset = current.resetAt.timeIntervalSince(now) / 3_600
        guard hoursToReset > 0 else { return .resetDue }

        let matchingWindow = account.snapshots
            .filter { abs($0.resetAt.timeIntervalSince(current.resetAt)) < 60 }
            .sorted { $0.capturedAt < $1.capturedAt }

        let rates = zip(matchingWindow, matchingWindow.dropFirst()).compactMap { older, newer -> Double? in
            let hours = newer.capturedAt.timeIntervalSince(older.capturedAt) / 3_600
            let delta = newer.usedPercent - older.usedPercent
            guard hours > 0.05, delta >= 0 else { return nil }
            return delta / hours
        }.filter { $0 > 0 }

        guard rates.count >= 2 else { return .learning(snapshotCount: matchingWindow.count) }
        let rate = median(rates)
        let remaining = max(0, 100 - current.usedPercent)
        let projectedUsage = rate * hoursToReset
        let margin = remaining - projectedUsage

        if margin >= 0 {
            return .likelyLasts(marginPercent: margin, ratePerHour: rate)
        }

        return .likelyShort(shortfallHours: abs(margin) / rate, ratePerHour: rate)
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let midpoint = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[midpoint - 1] + sorted[midpoint]) / 2
        }
        return sorted[midpoint]
    }

    static func formatPercent(_ value: Double) -> String {
        String(format: "%.0f%%", max(0, value))
    }

    static func formatDuration(_ hours: Double) -> String {
        let totalMinutes = max(0, Int((hours * 60).rounded()))
        let days = totalMinutes / 1_440
        let remainingMinutes = totalMinutes % 1_440
        let hourPart = remainingMinutes / 60
        if days > 0 { return "\(days)d \(hourPart)h" }
        if hourPart > 0 { return "\(hourPart)h" }
        return "<1h"
    }
}
