import Foundation

@main
struct CapacityChecks {
    static func close(_ actual: Double, _ expected: Double) {
        precondition(abs(actual - expected) < 0.00001, "Expected \(expected), got \(actual)")
    }

    static func main() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let hoverPoints = [CapacityPoint(date: now, units: 4, segment: 0),
                           CapacityPoint(date: now.addingTimeInterval(100), units: 2, segment: 0),
                           CapacityPoint(date: now.addingTimeInterval(100), units: 6, segment: 0)]
        close(CapacityForecast.value(at: now.addingTimeInterval(50), in: hoverPoints)!, 3)
        close(CapacityForecast.value(at: now.addingTimeInterval(100), in: hoverPoints)!, 6)
        precondition(CapacityForecast.value(at: now.addingTimeInterval(-1), in: hoverPoints) == nil)
        precondition(CapacityForecast.value(at: now.addingTimeInterval(101), in: hoverPoints) == nil)
        precondition(CapacityForecast.value(at: now, in: []) == nil)
        let gapPoints = [CapacityPoint(date: now, units: 4, segment: 0),
                         CapacityPoint(date: now.addingTimeInterval(100), units: 3, segment: 1)]
        precondition(CapacityForecast.value(at: now.addingTimeInterval(50), in: gapPoints) == nil,
            "Hover must not interpolate across an unobserved gap")
        func account(_ name: String, plan: String = "Pro 20×", used: Double, resetHours: Double) -> CodexAccount {
            CodexAccount(name: name, planName: plan, snapshots: [UsageSnapshot(capturedAt: now,
                usedPercent: used, resetAt: now.addingTimeInterval(resetHours * 3_600))])
        }
        let accounts = [account("A", used: 50, resetHours: 4), account("B", used: 50, resetHours: 8),
                        account("C", plan: "Pro 5×", used: 0, resetHours: 6)]
        let report = CapacityForecast.report(accounts: accounts, now: now)
        close(report.total, 9)
        close(report.remaining, 5)
        var inactive = accounts[0]
        inactive.isEnabled = false
        inactive.planName = "Unsupported"
        let activeOnly = CapacityForecast.report(accounts: [inactive, accounts[1], accounts[2]], now: now)
        close(activeOnly.total, 5)
        close(activeOnly.remaining, 3)
        precondition(activeOnly.resets.count == 2)
        let noneActive = CapacityForecast.report(accounts: [inactive], now: now)
        precondition(noneActive.total == 0 && noneActive.history.isEmpty && noneActive.projection == nil)
        precondition(report.projection == nil && report.issue!.contains("Learning"))
        precondition(report.resets.count == 3 && report.resets.allSatisfy { !$0.hasEstimate })

        let snapshots = accounts.map { $0.latestSnapshot! }
        let fits = CapacityForecast.simulate(accounts: accounts, snapshots: snapshots, ratePerHour: 0.5, now: now)
        precondition(fits.exhaustedAt == nil)
        // First account spends its two units before resetting: pool 3 -> 7.
        close(fits.resets[0].before, 3)
        close(fits.resets[0].after, 7)
        precondition(fits.points.allSatisfy { (0...9).contains($0.units) })
        let fails = CapacityForecast.simulate(accounts: accounts, snapshots: snapshots, ratePerHour: 2, now: now)
        close(fails.exhaustedAt!.timeIntervalSince(now), 2.5 * 3_600)
        close(fails.minimum, 0)
        let single = [account("A", used: 75, resetHours: 1)]
        let noBurn = CapacityForecast.simulate(accounts: single, snapshots: single.map { $0.latestSnapshot! }, ratePerHour: 0, now: now)
        close(noBurn.resets[0].before, 1)
        close(noBurn.resets[0].after, 4) // Refill adds 3, not 4.
        let exact = CapacityForecast.simulate(accounts: single, snapshots: single.map { $0.latestSnapshot! }, ratePerHour: 1, now: now)
        precondition(exact.exhaustedAt == nil, "Reaching zero exactly at reset must not create a gap")
        let together = [account("A", used: 50, resetHours: 1), account("B", used: 50, resetHours: 1)]
        let simultaneous = CapacityForecast.simulate(accounts: together, snapshots: together.map { $0.latestSnapshot! }, ratePerHour: 1, now: now)
        close(simultaneous.points.last!.units, 8)
        precondition(simultaneous.resets.count == 2)

        var tracked = account("Tracked", used: 40, resetHours: 10)
        tracked.snapshots = (0...8).map { index in
            UsageSnapshot(capturedAt: now.addingTimeInterval(Double(index - 8) * 900),
                usedPercent: Double(index * 5), resetAt: now.addingTimeInterval(10 * 3_600))
        }
        let paced = CapacityForecast.report(accounts: [tracked], now: now)
        close(paced.ratePerHour!, 0.8)
        precondition(paced.projection!.exhaustedAt != nil)
        close(paced.reductionPercent!, 70)
        let duplicates = CapacityForecast.report(accounts: [tracked, tracked], now: now)
        close(duplicates.ratePerHour!, 1.6) // Concurrent consumption is still added.

        // Switching accounts must not extrapolate each short session to a full day.
        var morning = tracked
        morning.snapshots = [
            UsageSnapshot(capturedAt: now.addingTimeInterval(-86_400), usedPercent: 0, resetAt: now.addingTimeInterval(86_400)),
            UsageSnapshot(capturedAt: now.addingTimeInterval(-79_200), usedPercent: 10, resetAt: now.addingTimeInterval(86_400))
        ]
        var evening = tracked
        evening.snapshots = [
            UsageSnapshot(capturedAt: now.addingTimeInterval(-7_200), usedPercent: 0, resetAt: now.addingTimeInterval(86_400)),
            UsageSnapshot(capturedAt: now, usedPercent: 20, resetAt: now.addingTimeInterval(86_400))
        ]
        let switched = CapacityForecast.report(accounts: [morning, evening], now: now)
        close(switched.ratePerHour! * 24, 1.2) // 0.4 + 0.8 units over one day, not 14.4/day.
        close(switched.averageHistoryHours!, 24)
        let later = CapacityForecast.report(accounts: [morning, evening], now: now.addingTimeInterval(3_600))
        close(later.ratePerHour!, 1.2 / 25) // Idle calendar time stays in the shared denominator.

        var threeDays = account("Daily", used: 60, resetHours: 24)
        threeDays.snapshots = [0.0, 0, 30, 60].enumerated().map { index, used in
            UsageSnapshot(capturedAt: now.addingTimeInterval(Double(index - 3) * 86_400),
                usedPercent: used, resetAt: now.addingTimeInterval(86_400))
        }
        let daily = CapacityForecast.report(accounts: [threeDays], now: now)
        close(daily.ratePerHour! * 24, 0.8)
        close(daily.averageHistoryHours!, 72)
        close(daily.projection!.resets[0].before, 0.8)
        var bounded = threeDays
        bounded.snapshots = [
            UsageSnapshot(capturedAt: now.addingTimeInterval(-4 * 86_400), usedPercent: 0, resetAt: now.addingTimeInterval(86_400)),
            UsageSnapshot(capturedAt: now.addingTimeInterval(-3 * 86_400), usedPercent: 50, resetAt: now.addingTimeInterval(86_400)),
            UsageSnapshot(capturedAt: now, usedPercent: 80, resetAt: now.addingTimeInterval(86_400))
        ]
        close(CapacityForecast.report(accounts: [bounded], now: now).ratePerHour! * 24, 0.8)
        bounded.snapshots.remove(at: 1)
        let prorated = CapacityForecast.report(accounts: [bounded], now: now)
        close(prorated.averageHistoryHours!, 96)
        close(prorated.ratePerHour! * 24, 0.8)
        var monthly = threeDays
        monthly.snapshots = [
            UsageSnapshot(capturedAt: now.addingTimeInterval(-31 * 86_400), usedPercent: 0, resetAt: now.addingTimeInterval(86_400)),
            UsageSnapshot(capturedAt: now.addingTimeInterval(-30 * 86_400), usedPercent: 40, resetAt: now.addingTimeInterval(86_400)),
            UsageSnapshot(capturedAt: now.addingTimeInterval(-10 * 86_400), usedPercent: 60, resetAt: now.addingTimeInterval(86_400)),
            UsageSnapshot(capturedAt: now, usedPercent: 70, resetAt: now.addingTimeInterval(86_400))
        ]
        let monthlyReport = CapacityForecast.report(accounts: [monthly], now: now)
        close(monthlyReport.averageHistoryHours!, 720)
        close(monthlyReport.ratePerHour! * 24, 0.04) // 1.2 units over 30 days; older usage excluded.
        var idle = threeDays
        idle.snapshots = threeDays.snapshots.map {
            UsageSnapshot(capturedAt: $0.capturedAt, usedPercent: 40, resetAt: $0.resetAt)
        }
        let idleReport = CapacityForecast.report(accounts: [idle], now: now)
        close(idleReport.ratePerHour!, 0)
        close(idleReport.projection!.resets[0].before, 2.4)

        var resetHistory = tracked
        resetHistory.snapshots[0] = UsageSnapshot(capturedAt: now.addingTimeInterval(-7_200), usedPercent: 95,
            resetAt: now.addingTimeInterval(-6_500))
        precondition(CapacityForecast.report(accounts: [resetHistory], now: now).ratePerHour == nil,
            "A cross-reset pair must not count as a pace observation")
        let observedReset = CapacityForecast.report(accounts: [resetHistory], now: now).resets.first { !$0.projected }!
        precondition(!observedReset.assumed, "A later reading with a new reset window confirms the historical reset")
        close(observedReset.after, 4)
        close(observedReset.date.timeIntervalSince(now), -6_500)
        var stale = tracked
        stale.snapshots = [UsageSnapshot(capturedAt: now.addingTimeInterval(-90_000), usedPercent: 40,
            resetAt: now.addingTimeInterval(3_600))]
        let staleReport = CapacityForecast.report(accounts: [stale], now: now)
        precondition(staleReport.issue!.contains("Learning"))
        precondition(staleReport.hasStaleReadings && staleReport.projection == nil)
        stale.snapshots.insert(UsageSnapshot(capturedAt: now.addingTimeInterval(-100_800), usedPercent: 30,
            resetAt: now.addingTimeInterval(3_600)), at: 0)
        let staleEstimate = CapacityForecast.report(accounts: [stale], now: now)
        precondition(staleEstimate.hasStaleReadings && staleEstimate.issue == nil)
        precondition(staleEstimate.projection != nil && staleEstimate.resets.contains { $0.projected && $0.hasEstimate })
        var overdue = tracked
        overdue.snapshots = [UsageSnapshot(capturedAt: now.addingTimeInterval(-3_600), usedPercent: 90,
            resetAt: now.addingTimeInterval(-60))]
        let assumed = CapacityForecast.report(accounts: [overdue], now: now)
        close(assumed.remaining, 4)
        precondition(assumed.hasAssumedResets && assumed.issue!.contains("Learning"))
        precondition(overdue.latestSnapshot!.nextReset(at: now) == nil)
        precondition(overdue.latestSnapshot!.usedPercent == 90, "Assumptions must not overwrite real readings")
        precondition(assumed.resets.filter(\.assumed).count == 1)
        precondition(!assumed.resets.contains(where: \.projected))
        let boundary = overdue.latestSnapshot!.resetAt
        close(overdue.latestSnapshot!.remainingPercent(at: boundary.addingTimeInterval(-1)), 10)
        close(overdue.latestSnapshot!.remainingPercent(at: boundary), 100)
        let mixed = CapacityForecast.report(accounts: [overdue, tracked], now: now)
        close(mixed.remaining, 6.4)
        precondition(mixed.resets.filter(\.projected).count == 1)
        let mixedSimulation = CapacityForecast.simulate(accounts: [overdue, tracked], snapshots: [overdue.latestSnapshot!, tracked.latestSnapshot!], ratePerHour: 0.1, now: now)
        close(mixedSimulation.points.first!.units, 6.4)
        precondition(mixedSimulation.resets.count == 1 && mixedSimulation.points.allSatisfy { $0.date >= now })
        let allUnknown = CapacityForecast.simulate(accounts: [overdue], snapshots: [overdue.latestSnapshot!], ratePerHour: 0.1, now: now)
        precondition(allUnknown.resets.isEmpty && allUnknown.exhaustedAt != nil)
        close(allUnknown.exhaustedAt!.timeIntervalSince(now), 40 * 3_600)
        precondition(allUnknown.points.last!.date == now.addingTimeInterval(2 * 86_400))
        let muchLater = CapacityForecast.report(accounts: [overdue], now: now.addingTimeInterval(20 * 86_400))
        close(muchLater.remaining, 4)
        precondition(muchLater.resets.filter(\.assumed).count == 1, "Never invent repeated resets")
        overdue.snapshots.append(UsageSnapshot(capturedAt: now, usedPercent: 12, resetAt: now.addingTimeInterval(7 * 86_400)))
        let confirmed = CapacityForecast.report(accounts: [overdue], now: now)
        precondition(!confirmed.hasAssumedResets)
        close(confirmed.remaining, 3.52)
        precondition(overdue.latestSnapshot!.nextReset(at: now) != nil)
        var unknown = tracked
        unknown.planName = "Custom"
        precondition(CapacityForecast.report(accounts: [unknown], now: now).projection == nil)
        var changed = tracked
        changed.snapshots[8].capacityUnits = 1
        precondition(CapacityForecast.report(accounts: [changed], now: now).issue!.contains("plan changed"))
        var blocked = tracked
        blocked.snapshots[8].secondaryUsedPercent = 100
        blocked.snapshots[8].secondaryResetAt = now.addingTimeInterval(3_600)
        precondition(CapacityForecast.report(accounts: [blocked], now: now).issue!.contains("Another usage limit"))
        blocked.snapshots[8].secondaryResetAt = nil
        precondition(CapacityForecast.report(accounts: [blocked], now: now).projection == nil)
        var missing = tracked
        missing.snapshots = []
        precondition(!CapacityForecast.report(accounts: [tracked, missing], now: now).hasBalance)

        let many = (0..<36000).map { index in
            UsageSnapshot(capturedAt: now.addingTimeInterval(-Double(index) * 900), usedPercent: 10,
                resetAt: now.addingTimeInterval(3_600))
        }
        let retained = CapacityForecast.retainedSnapshots(many, now: now)
        precondition(retained.count == 35041)
        precondition(retained.first!.capturedAt == now.addingTimeInterval(-365 * 86_400))
        print("Capacity checks passed: weighting, resets, depletion, pace, freshness, and one-year retention")
    }
}
