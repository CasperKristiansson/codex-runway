import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let now = Date(timeIntervalSince1970: 1_700_000_000)
let blank = CodexAccount(name: "Primary", planName: "Pro 20×")
require(Forecasting.forecast(for: blank, now: now) == .needsRefresh, "empty accounts must request a refresh")

let reset = now.addingTimeInterval(4 * 3_600)
let sustainable = CodexAccount(
    name: "Primary",
    planName: "Pro 20×",
    snapshots: [
        UsageSnapshot(capturedAt: now.addingTimeInterval(-2 * 3_600), usedPercent: 10, resetAt: reset),
        UsageSnapshot(capturedAt: now.addingTimeInterval(-1 * 3_600), usedPercent: 15, resetAt: reset),
        UsageSnapshot(capturedAt: now, usedPercent: 20, resetAt: reset)
    ]
)

guard case .likelyLasts(let sustainableMargin, let sustainableRate) = Forecasting.forecast(for: sustainable, now: now) else {
    fputs("FAIL: sustainable account should last through reset\n", stderr)
    exit(1)
}
require(abs(sustainableRate - 5) < 0.001, "median rate should be 5 percentage points/hour")
require(abs(sustainableMargin - 60) < 0.001, "sustainable buffer should be 60 percentage points")

let shortfall = CodexAccount(
    name: "Reserve",
    planName: "Pro 5×",
    snapshots: [
        UsageSnapshot(capturedAt: now.addingTimeInterval(-2 * 3_600), usedPercent: 70, resetAt: now.addingTimeInterval(10 * 3_600)),
        UsageSnapshot(capturedAt: now.addingTimeInterval(-1 * 3_600), usedPercent: 75, resetAt: now.addingTimeInterval(10 * 3_600)),
        UsageSnapshot(capturedAt: now, usedPercent: 80, resetAt: now.addingTimeInterval(10 * 3_600))
    ]
)
guard case .likelyShort(let shortfallHours, _) = Forecasting.forecast(for: shortfall, now: now) else {
    fputs("FAIL: depleted account should predict a shortfall\n", stderr)
    exit(1)
}
require(abs(shortfallHours - 6) < 0.001, "shortfall should be six hours")

print("Forecasting checks passed")
