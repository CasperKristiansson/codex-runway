import Foundation

@main
struct CapacityChecks {
    static func close(_ actual: Double, _ expected: Double) {
        precondition(abs(actual - expected) < 0.00001, "Expected \(expected), got \(actual)")
    }

    static func main() throws {
        precondition(CapacityDisplayLayout.rowsHeight == 7 * CapacityDisplayLayout.rowHeight)
        precondition(CapacityDisplayLayout.height == CapacityDisplayLayout.headerHeight + 8 +
            CapacityDisplayLayout.rowsHeight)
        precondition(CapacityDisplayLayout.height > 118, "Graph and every table range must share seven-row height")
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
        close(CapacityForecast.value(at: now.addingTimeInterval(50), in: gapPoints)!, 3.5)
        close(CapacityForecast.percentage(forUnits: 4), 100)
        close(CapacityForecast.percentage(forUnits: 1), 25)
        close(CapacityForecast.percentage(forUnits: 9), 225)
        let intervalPoints = [CapacityPoint(date: now.addingTimeInterval(-3_600), units: 4, segment: 0),
                              CapacityPoint(date: now.addingTimeInterval(-1_800), units: 3, segment: 0),
                              CapacityPoint(date: now.addingTimeInterval(-1_200), units: 2.5, segment: 0),
                              CapacityPoint(date: now.addingTimeInterval(-1_200), units: 6.5, segment: 0),
                              CapacityPoint(date: now, units: 6, segment: 0)]
        let intervalReset = CapacityReset(date: now.addingTimeInterval(-1_200), accountName: "A",
            before: 2.5, after: 6.5, projected: false)
        let intervals = CapacityForecast.intervals(points: intervalPoints, resets: [intervalReset],
            start: now.addingTimeInterval(-3_600), end: now, duration: 1_800)
        precondition(intervals.count == 2)
        close(intervals[0].startUnits, 4)
        close(intervals[0].endUnits, 3)
        close(intervals[0].consumedUnits, 1)
        precondition(intervals[0].resets.isEmpty)
        precondition(intervals[1].resets.count == 1)
        close(intervals[1].consumedUnits, 1)
        precondition(CapacityForecast.intervals(points: intervalPoints, resets: [], start: now, end: now, duration: 1_800).isEmpty)
        let sevenDayPoints = [CapacityPoint(date: now.addingTimeInterval(-7 * 86_400), units: 4, segment: 0),
                              CapacityPoint(date: now, units: 2, segment: 0)]
        precondition(CapacityForecast.intervals(points: sevenDayPoints, resets: [],
            start: now.addingTimeInterval(-7 * 86_400), end: now, duration: 86_400).count == 7)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let unaligned = utc.date(from: DateComponents(year: 2027, month: 1, day: 15,
            hour: 23, minute: 43, second: 27))!
        let tenMinuteEnd = CapacityForecast.alignedIntervalEnd(now: unaligned, duration: 10 * 60, calendar: utc)
        let hourEnd = CapacityForecast.alignedIntervalEnd(now: unaligned, duration: 3_600, calendar: utc)
        let fourHourEnd = CapacityForecast.alignedIntervalEnd(now: unaligned, duration: 4 * 3_600, calendar: utc)
        precondition(utc.component(.minute, from: tenMinuteEnd) == 40)
        precondition(utc.component(.hour, from: hourEnd) == 23 && utc.component(.minute, from: hourEnd) == 0)
        precondition(utc.component(.hour, from: fourHourEnd) == 20 && utc.component(.minute, from: fourHourEnd) == 0)
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
        close(fails.shortfallUnits!, 3)
        close(fails.shortfallAt!.timeIntervalSince(fails.exhaustedAt!), 1.5 * 3_600)
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
        close(paced.projection!.shortfallUnits!, 5.6)
        close(paced.projection!.shortfallAt!.timeIntervalSince(paced.projection!.exhaustedAt!), 7 * 3_600)
        let duplicates = CapacityForecast.report(accounts: [tracked, tracked], now: now)
        close(duplicates.ratePerHour!, 1.6) // Concurrent consumption is still added.

        // Adding a newly discovered account must not hide the established
        // account's earlier history. Its balance joins only at the first real
        // observation, without being fabricated into earlier points.
        var newcomer = account("New", used: 25, resetHours: 12)
        let joinedAt = now.addingTimeInterval(-450)
        newcomer.snapshots = [UsageSnapshot(capturedAt: joinedAt, usedPercent: 25,
            resetAt: now.addingTimeInterval(12 * 3_600))]
        let joined = CapacityForecast.report(accounts: [tracked, newcomer], now: now)
        precondition(joined.history.first!.date == tracked.snapshots.first!.capturedAt)
        let joiningPoints = joined.history.filter { $0.date == joinedAt }
        precondition(joiningPoints.count == 2)
        close(joiningPoints.last!.units - joiningPoints.first!.units, 3)
        precondition(joined.issue!.contains("Learning"))

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
        close(allUnknown.shortfallUnits!, 0.8)
        precondition(allUnknown.shortfallAt == now.addingTimeInterval(2 * 86_400))
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
        // Day/night timing changes hourly demand without inventing extra daily usage.
        let midnight = utc.date(from: DateComponents(year: 2026, month: 9, day: 20))!
        let observed = (0..<72).map { hour in
            CapacityConsumption(accountIndex: 0, start: midnight.addingTimeInterval(Double(hour) * 3_600),
                end: midnight.addingTimeInterval(Double(hour + 1) * 3_600),
                units: hour % 24 < 6 ? 0.01 : 0.1)
        }
        let learned = CapacityDemand.learnHourlyFactors(observed, calendar: utc)!
        precondition(learned[2] < learned[14])
        close(learned.reduce(0, +), 24)
        // Duplicating concurrent observations doubles consumption and its prior,
        // but cannot double exposure or change the learned daily shape.
        let concurrent = CapacityDemand.learnHourlyFactors(observed + observed, calendar: utc)!
        for hour in 0..<24 { close(learned[hour], concurrent[hour]) }
        precondition(CapacityDemand.learnHourlyFactors(Array(observed.prefix(24)), calendar: utc) == nil)
        precondition(CapacityDemand.learnHourlyFactors([
            CapacityConsumption(accountIndex: 0, start: midnight, end: midnight.addingTimeInterval(72 * 3_600), units: 10)
        ], calendar: utc) == nil, "Long gaps cannot teach hourly timing")
        let learnedDemand = CapacityDemand(ratePerHour: 0.2, hourlyFactors: learned, calendar: utc)
        close(learnedDemand.units(from: midnight.addingTimeInterval(1234),
            to: midnight.addingTimeInterval(1234 + 86_400)), 4.8)
        let factors = (0..<24).map { $0 < 12 ? 0.0 : 2.0 }
        let shapedSnapshot = UsageSnapshot(capturedAt: midnight, usedPercent: 75,
            resetAt: midnight.addingTimeInterval(15 * 3_600))
        let shapedAccount = CodexAccount(name: "Daytime", planName: "Pro 20×", snapshots: [shapedSnapshot])
        let shaped = CapacityForecast.simulate(accounts: [shapedAccount], snapshots: [shapedSnapshot],
            ratePerHour: 1, now: midnight, hourlyFactors: factors, calendar: utc)
        close(shaped.exhaustedAt!.timeIntervalSince(midnight), 12.5 * 3_600)
        close(shaped.shortfallUnits!, 5)
        close(shaped.resets[0].before, 0)
        close(shaped.resets[0].after, 4)
        close(CapacityForecast.value(at: midnight.addingTimeInterval(6 * 3_600), in: shaped.points)!, 1)
        let exactlyAtReset = UsageSnapshot(capturedAt: midnight, usedPercent: 75,
            resetAt: midnight.addingTimeInterval(12.5 * 3_600))
        let shapedExact = CapacityForecast.simulate(accounts: [shapedAccount], snapshots: [exactlyAtReset],
            ratePerHour: 1, now: midnight, hourlyFactors: factors, calendar: utc)
        precondition(shapedExact.exhaustedAt == nil)
        let unknownReset = UsageSnapshot(capturedAt: midnight.addingTimeInterval(-3_600), usedPercent: 100, resetAt: midnight)
        let shapedUnknown = CapacityForecast.simulate(accounts: [shapedAccount], snapshots: [unknownReset],
            ratePerHour: 1, now: midnight, hourlyFactors: factors, calendar: utc)
        close(shapedUnknown.exhaustedAt!.timeIntervalSince(midnight), 14 * 3_600)
        close(shapedUnknown.shortfallUnits!, 44)
        precondition(shapedUnknown.resets.isEmpty)

        var stockholm = utc
        stockholm.timeZone = TimeZone(identifier: "Europe/Stockholm")!
        for (month, date, expectedHours) in [(3, 29, 23.0), (10, 25, 25.0)] {
            let start = stockholm.date(from: DateComponents(year: 2026, month: month, day: date))!
            let end = stockholm.date(byAdding: .day, value: 1, to: start)!
            let clock = CapacityDemand(ratePerHour: 1, calendar: stockholm)
            close(clock.units(from: start, to: end), expectedHours)
            let parts = clock.segments(from: start, to: end)
            precondition(parts.count == Int(expectedHours))
            precondition(zip(parts, parts.dropFirst()).allSatisfy { $0.end == $1.start })
            if month == 10 {
                precondition(parts.filter { stockholm.component(.hour, from: $0.start) == 2 }.count == 2)
            }
        }
        let journalDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("runway-forecast-check-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: journalDirectory) }
        let journal = ForecastJournal(directory: journalDirectory)
        let recorded = try journal.record(accounts: [tracked], now: now, calendar: utc)
        precondition(recorded)
        let recordFile = try FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil).first!
        let originalRecord = try Data(contentsOf: recordFile)
        let decoded = try JSONDecoder().decode(ForecastJournal.Record.self, from: originalRecord)
        precondition(decoded.schemaVersion == 1 && decoded.origin == now)
        precondition(decoded.accounts[0].snapshot == tracked.latestSnapshot!)
        precondition(Set(decoded.candidates.map(\.model)) == ["calendar-v1", "clock-v1", "clock-recent-v1"])
        precondition(decoded.candidates.allSatisfy { $0.predictions.map(\.horizonHours) == [3, 6, 12, 24, 48] })
        precondition(!String(data: originalRecord, encoding: .utf8)!.contains(tracked.name))
        let repeated = try journal.record(accounts: [tracked], now: now.addingTimeInterval(1), calendar: utc)
        precondition(!repeated)
        let unchangedRecord = try Data(contentsOf: recordFile)
        precondition(unchangedRecord == originalRecord, "Forecast origins must remain immutable")
        let expired = journalDirectory.appendingPathComponent("forecast-0.json")
        let unrelated = journalDirectory.appendingPathComponent("notes.json")
        try Data().write(to: expired)
        try Data().write(to: unrelated)
        let nextOrigin = try journal.record(accounts: [tracked], now: now.addingTimeInterval(6 * 3_600), calendar: utc)
        precondition(nextOrigin && !FileManager.default.fileExists(atPath: expired.path))
        precondition(FileManager.default.fileExists(atPath: unrelated.path))
        let noForecast = try journal.record(accounts: [missing], now: now.addingTimeInterval(12 * 3_600), calendar: utc)
        precondition(!noForecast)
        print("Capacity checks passed: weighting, resets, depletion, pace, hourly learning, DST, freshness, and one-year retention")
    }
}
