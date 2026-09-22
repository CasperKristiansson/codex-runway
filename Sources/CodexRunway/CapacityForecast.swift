import Foundation

struct CapacityPoint: Identifiable {
    let id = UUID()
    let date: Date
    let units: Double
    let segment: Int
}

struct CapacityInterval: Identifiable {
    var id: Date { start }
    let start: Date
    let end: Date
    let startUnits: Double
    let endUnits: Double
    let resets: [CapacityReset]

    var consumedUnits: Double {
        let replenished = resets.reduce(0) { $0 + max(0, $1.after - $1.before) }
        return max(0, startUnits + replenished - endUnits)
    }
}

struct CapacityReset: Identifiable {
    let id = UUID()
    let date: Date
    let accountName: String
    let before: Double
    let after: Double
    let projected: Bool
    var hasEstimate = true
    var assumed = false
}

struct CapacitySimulation {
    var points: [CapacityPoint] = []
    var resets: [CapacityReset] = []
    var minimum: Double = .infinity
    var exhaustedAt: Date?
    var shortfallUnits: Double?
    var shortfallAt: Date?
}

struct CapacityReport {
    var total: Double = 0
    var remaining: Double = 0
    var hasBalance = false
    var history: [CapacityPoint] = []
    var resets: [CapacityReset] = []
    var projection: CapacitySimulation?
    var ratePerHour: Double?
    var averageHistoryHours: Double?
    var demand: CapacityDemand?
    var usesTimeOfDay = false
    var shadowDemands: [String: CapacityDemand] = [:]
    var horizon: Date
    var issue: String?
    var hasStaleReadings = false
    var hasAssumedResets = false
    var notes: [String] = []
}

enum CapacityForecast {
    static let day: TimeInterval = 86_400

    // Match the chart's connected lines without extrapolating beyond available data.
    // At a reset's duplicate timestamp, use the balance after the jump.
    static func value(at date: Date, in points: [CapacityPoint]) -> Double? {
        guard let first = points.first, let last = points.last,
              date >= first.date, date <= last.date,
              let lower = points.last(where: { $0.date <= date }) else { return nil }
        guard lower.date != date,
              let upper = points.first(where: { $0.date > date }) else { return lower.units }
        let fraction = date.timeIntervalSince(lower.date) / upper.date.timeIntervalSince(lower.date)
        return lower.units + (upper.units - lower.units) * fraction
    }

    // Retention is independent of the thirty-day forecast pace window.
    static func retainedSnapshots(_ snapshots: [UsageSnapshot], now: Date) -> [UsageSnapshot] {
        snapshots.filter { $0.capturedAt >= HistoryRetention.cutoff(now: now) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    static func remaining(_ snapshot: UsageSnapshot, weight: Double) -> Double {
        weight * (1 - min(100, max(0, snapshot.usedPercent)) / 100)
    }

    // One Pro 20× allowance is four internal units and defines 100%.
    static func percentage(forUnits units: Double) -> Double { units * 25 }

    static func alignedIntervalEnd(now: Date, duration: TimeInterval, calendar: Calendar = .current) -> Date {
        if duration < 3_600 {
            let step = max(1, Int(duration / 60))
            var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
            components.minute = ((components.minute ?? 0) / step) * step
            return calendar.date(from: components) ?? now
        }
        if duration < day {
            let step = max(1, Int(duration / 3_600))
            var components = calendar.dateComponents([.year, .month, .day, .hour], from: now)
            components.hour = ((components.hour ?? 0) / step) * step
            return calendar.date(from: components) ?? now
        }
        return calendar.startOfDay(for: now)
    }

    static func intervals(points: [CapacityPoint], resets: [CapacityReset], start: Date, end: Date,
                          duration: TimeInterval) -> [CapacityInterval] {
        guard duration > 0, start < end else { return [] }
        var result: [CapacityInterval] = []
        var intervalStart = start
        while intervalStart < end {
            let intervalEnd = min(intervalStart.addingTimeInterval(duration), end)
            if let startUnits = value(at: intervalStart, in: points),
               let endUnits = value(at: intervalEnd, in: points) {
                let intervalResets = resets.filter {
                    !$0.projected && $0.date > intervalStart && $0.date <= intervalEnd
                }
                result.append(CapacityInterval(start: intervalStart, end: intervalEnd,
                    startUnits: startUnits, endUnits: endUnits, resets: intervalResets))
            }
            intervalStart = intervalEnd
        }
        return result
    }

    static func report(accounts: [CodexAccount], now: Date = .now, calendar: Calendar = .current) -> CapacityReport {
        let accounts = accounts.filter(\.isEnabled)
        var result = CapacityReport(horizon: now.addingTimeInterval(day))
        guard !accounts.isEmpty else {
            result.issue = "Refresh your accounts to start the combined history."
            return result
        }
        guard accounts.allSatisfy({ $0.capacityUnits != nil }) else {
            result.issue = "Combined capacity requires Pro 5× or Pro 20× accounts; an account has an unsupported plan."
            return result
        }
        result.total = accounts.reduce(0) { $0 + $1.capacityUnits! }
        let ordered = accounts.map { account in
            retainedSnapshots(account.snapshots, now: now).filter { $0.capturedAt <= now }
        }
        // Insert derived reset events between actual readings. They are not
        // persisted and are excluded from the observed-consumption average.
        typealias HistoryEvent = (index: Int, snapshot: UsageSnapshot, date: Date, reset: Bool, assumed: Bool)
        var events: [HistoryEvent] = []
        for (index, snapshots) in ordered.enumerated() {
            for (offset, snapshot) in snapshots.enumerated() {
                events.append((index: index, snapshot: snapshot, date: snapshot.capturedAt, reset: false, assumed: false))
                let nextDate = offset + 1 < snapshots.count ? snapshots[offset + 1].capturedAt : now
                if snapshot.resetAt > snapshot.capturedAt && snapshot.resetAt <= min(nextDate, now) {
                    let next = offset + 1 < snapshots.count ? snapshots[offset + 1] : nil
                    let wasConfirmedLater = next.map { abs($0.resetAt.timeIntervalSince(snapshot.resetAt)) > 60 } ?? false
                    events.append((index: index, snapshot: snapshot, date: snapshot.resetAt, reset: true, assumed: !wasConfirmedLater))
                }
            }
        }
        events.sort { $0.date == $1.date ? ($0.assumed && !$1.assumed) : $0.date < $1.date }
        var known: [Int: UsageSnapshot] = [:]
        var assumedAccounts: Set<Int> = []
        var segment = 0
        for event in events {
            let previous = known[event.index]
            let date = event.date
            let reset = event.reset || (!assumedAccounts.contains(event.index) && (previous.map { abs($0.resetAt.timeIntervalSince(event.snapshot.resetAt)) > 60 } ?? false))
            let before = known.reduce(0.0) { sum, pair in
                let weight = pair.value.capacityUnits ?? accounts[pair.key].capacityUnits!
                return sum + (assumedAccounts.contains(pair.key) ? weight : remaining(pair.value, weight: weight))
            }
            let hadKnownAccounts = !known.isEmpty
            let wasKnown = previous != nil
            known[event.index] = event.snapshot
            if event.reset { assumedAccounts.insert(event.index) }
            else { assumedAccounts.remove(event.index) }
            let after = known.reduce(0.0) { sum, pair in
                let weight = pair.value.capacityUnits ?? accounts[pair.key].capacityUnits!
                return sum + (assumedAccounts.contains(pair.key) ? weight : remaining(pair.value, weight: weight))
            }
            if let last = result.history.last, date.timeIntervalSince(last.date) > 3_600 { segment += 1 }
            // A newly discovered account joins the observed pool at its first
            // real reading. Keep earlier history from already known accounts,
            // and show the added balance as a truthful step at discovery time.
            if !wasKnown && hadKnownAccounts {
                result.history.append(CapacityPoint(date: date, units: before, segment: segment))
            }
            if reset && wasKnown {
                result.history.append(CapacityPoint(date: date, units: before, segment: segment))
                result.resets.append(CapacityReset(date: date, accountName: accounts[event.index].name,
                    before: before, after: after, projected: false, assumed: event.assumed))
            }
            result.history.append(CapacityPoint(date: date, units: after, segment: segment))
        }

        guard ordered.allSatisfy({ !$0.isEmpty }) else {
            result.issue = "Refresh each account to establish a combined balance."
            return result
        }
        let latest = ordered.map { $0.last! }
        result.remaining = zip(accounts, latest).reduce(0) { $0 + $1.0.capacityUnits! * $1.1.remainingPercent(at: now) / 100 }
        result.hasBalance = true
        result.hasAssumedResets = latest.contains { $0.assumesReset(at: now) }
        result.horizon = latest.compactMap { $0.nextReset(at: now) }.max() ?? now.addingTimeInterval(2 * day)
        if let last = result.history.last, now.timeIntervalSince(last.date) > 3_600 { segment += 1 }
        result.history.append(CapacityPoint(date: now, units: result.remaining, segment: segment))
        result.resets += accounts.indices.compactMap { index in
            guard latest[index].resetAt > now else { return nil }
            return CapacityReset(date: latest[index].resetAt, accountName: accounts[index].name,
                before: 0, after: 0, projected: true, hasEstimate: false)
        }
        if zip(accounts, latest).contains(where: { ($0.1.capacityUnits ?? $0.0.capacityUnits!) != $0.0.capacityUnits! }) {
            result.issue = "An account’s plan changed. Refresh it to establish its new capacity."
            return result
        }
        let durations = Set(latest.compactMap(\.windowDurationMins))
        if durations.count > 1 {
            result.issue = "Accounts report different allowance windows; their balances cannot be pooled reliably."
            return result
        }
        if latest.contains(where: { now.timeIntervalSince($0.capturedAt) > day }) {
            result.hasStaleReadings = true
        }
        if latest.contains(where: { now.timeIntervalSince($0.capturedAt) > 30 * 60 }) {
            result.notes.append("Uses saved balances for inactive accounts.")
        }
        if latest.contains(where: { ($0.secondaryUsedPercent ?? 0) >= 100 && ($0.secondaryResetAt == nil || $0.secondaryResetAt! > now) }) {
            result.issue = "Another usage limit is exhausted on an account. The combined allowance cannot predict access yet."
            return result
        }

        let observations = CapacityDemand.observations(accounts: accounts, snapshots: ordered)
        let cutoff = now.addingTimeInterval(-30 * day)
        var totalConsumed = 0.0
        var sharedStart = now
        for index in accounts.indices {
            var coveredSeconds = 0.0
            for observation in observations where observation.accountIndex == index {
                let intervalStart = max(cutoff, observation.start)
                let overlap = observation.end.timeIntervalSince(intervalStart)
                guard overlap > 0 else { continue }
                totalConsumed += observation.units(from: intervalStart, to: observation.end)
                coveredSeconds += overlap
                sharedStart = min(sharedStart, intervalStart)
            }
            guard coveredSeconds >= 2 * 3_600 else {
                result.issue = "Learning the usage average · needs at least 2h of history for each account."
                return result
            }
        }
        // Keep the tested shared-calendar level. The learned curve changes when
        // demand arrives, conserving the total over an ordinary 24-hour day.
        let sharedHours = now.timeIntervalSince(sharedStart) / 3_600
        let rate = totalConsumed / sharedHours
        result.averageHistoryHours = sharedHours
        result.ratePerHour = rate
        let factors = CapacityDemand.learnHourlyFactors(observations, calendar: calendar)
        let demand = CapacityDemand(ratePerHour: rate, hourlyFactors: factors, calendar: calendar)
        result.demand = demand
        result.usesTimeOfDay = factors != nil
        result.shadowDemands["calendar-v1"] = CapacityDemand(ratePerHour: rate, calendar: calendar)
        // Recent pace stays in shadow until prospective quota evidence supports
        // changing the daily total. Do not infer quota cost from token counts.
        let recentStart = max(sharedStart, now.addingTimeInterval(-72 * 3_600))
        let recentRate = observations.reduce(0) { $0 + $1.units(from: recentStart, to: now) }
            / (now.timeIntervalSince(recentStart) / 3_600)
        result.shadowDemands["clock-recent-v1"] = CapacityDemand(ratePerHour: (rate + recentRate) / 2,
            hourlyFactors: factors, calendar: calendar)
        let projection = simulate(accounts: accounts, snapshots: latest, ratePerHour: rate, now: now,
            hourlyFactors: factors, calendar: calendar)
        result.projection = projection
        result.resets.removeAll { !$0.hasEstimate }
        result.resets += projection.resets
        return result
    }

    static func simulate(accounts: [CodexAccount], snapshots: [UsageSnapshot], ratePerHour: Double, now: Date,
                         hourlyFactors: [Double]? = nil, calendar: Calendar = .current) -> CapacitySimulation {
        var balances = zip(accounts, snapshots).map { $0.0.capacityUnits! * $0.1.remainingPercent(at: now) / 100 }
        var pending = accounts.indices.filter { snapshots[$0].nextReset(at: now) != nil }
            .sorted { snapshots[$0].resetAt < snapshots[$1].resetAt }
        let horizon = pending.last.map { snapshots[$0].resetAt } ?? now.addingTimeInterval(2 * day)
        let demand = CapacityDemand(ratePerHour: ratePerHour, hourlyFactors: hourlyFactors, calendar: calendar)
        var result = CapacitySimulation()
        var date = now
        result.minimum = balances.reduce(0, +)
        result.points.append(CapacityPoint(date: now, units: result.minimum, segment: 0))
        while date < horizon {
            let boundary = pending.first.map { snapshots[$0].resetAt } ?? horizon
            let parts = demand.segments(from: date, to: boundary)
            let intervalDemand = parts.reduce(0) { $0 + $1.units }
            let initialBalance = balances.reduce(0, +)
            // Keep nearest-reset-first allocation across all hourly steps.
            let spendOrder = pending + accounts.indices.filter { !pending.contains($0) }
            for part in parts {
                let available = balances.reduce(0, +)
                if part.units > available + 0.000000001 && part.rate > 0 && result.exhaustedAt == nil {
                    let exhaustion = part.start.addingTimeInterval(available / part.rate * 3_600)
                    result.exhaustedAt = exhaustion
                    // The deficit is for the entire interval up to the reset,
                    // not just the hour in which the account pool runs out.
                    result.shortfallUnits = max(0, intervalDemand - initialBalance)
                    result.shortfallAt = boundary
                    result.points.append(CapacityPoint(date: exhaustion, units: 0, segment: 0))
                }
                var remainingDemand = part.units
                for index in spendOrder {
                    let spend = min(balances[index], remainingDemand)
                    balances[index] -= spend
                    remainingDemand -= spend
                }
                let total = balances.reduce(0, +)
                result.minimum = min(result.minimum, total)
                result.points.append(CapacityPoint(date: part.end, units: total, segment: 0))
            }
            let simultaneous = pending.filter { snapshots[$0].resetAt == boundary }
            for index in simultaneous {
                let before = balances.reduce(0, +)
                balances[index] = accounts[index].capacityUnits!
                result.resets.append(CapacityReset(date: boundary, accountName: accounts[index].name,
                    before: before, after: balances.reduce(0, +), projected: true))
            }
            pending.removeAll { simultaneous.contains($0) }
            if !simultaneous.isEmpty {
                result.points.append(CapacityPoint(date: boundary, units: balances.reduce(0, +), segment: 0))
            }
            date = boundary
        }
        return result
    }
}
