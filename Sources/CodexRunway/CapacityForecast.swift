import Foundation

struct CapacityPoint: Identifiable {
    let id = UUID()
    let date: Date
    let units: Double
    let segment: Int
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

    static func report(accounts: [CodexAccount], now: Date = .now) -> CapacityReport {
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

        // Average calendar-time consumption over the retained thirty days.
        // Same-window gaps include nights and idle time; reset/plan-change
        // intervals are excluded because their consumption is unobserved.
        let cutoff = now.addingTimeInterval(-30 * day)
        var totalConsumed = 0.0
        var sharedStart = now
        for (index, snapshots) in ordered.enumerated() {
            var consumed = 0.0
            var coveredSeconds = 0.0
            for (older, newer) in zip(snapshots, snapshots.dropFirst()) {
                let seconds = newer.capturedAt.timeIntervalSince(older.capturedAt)
                let intervalStart = max(cutoff, older.capturedAt)
                let overlap = newer.capturedAt.timeIntervalSince(intervalStart)
                let weight = newer.capacityUnits ?? accounts[index].capacityUnits!
                guard seconds > 0, overlap > 0,
                      older.resetAt > newer.capturedAt,
                      abs(older.resetAt.timeIntervalSince(newer.resetAt)) < 60,
                      (older.capacityUnits ?? accounts[index].capacityUnits!) == weight,
                      newer.usedPercent >= older.usedPercent else { continue }
                // Interpolate only the part inside the thirty-day lookback.
                consumed += max(0, remaining(older, weight: weight) - remaining(newer, weight: weight)) * overlap / seconds
                coveredSeconds += overlap
                sharedStart = min(sharedStart, intervalStart)
            }
            let hours = coveredSeconds / 3_600
            guard hours >= 2 else {
                result.issue = "Learning the usage average · needs at least 2h of history for each account."
                return result
            }
            totalConsumed += consumed
        }
        // Divide once by a shared calendar window. Adding separately annualized
        // account rates would treat sequential account use as concurrent use.
        // Gaps count as elapsed time; unseen consumption is not fabricated.
        let sharedHours = now.timeIntervalSince(sharedStart) / 3_600
        let rate = totalConsumed / sharedHours
        result.averageHistoryHours = sharedHours
        result.ratePerHour = rate
        let projection = simulate(accounts: accounts, snapshots: latest, ratePerHour: rate, now: now)
        result.projection = projection
        result.resets.removeAll { !$0.hasEstimate }
        result.resets += projection.resets
        return result
    }

    static func simulate(accounts: [CodexAccount], snapshots: [UsageSnapshot], ratePerHour: Double, now: Date) -> CapacitySimulation {
        var balances = zip(accounts, snapshots).map { $0.0.capacityUnits! * $0.1.remainingPercent(at: now) / 100 }
        var pending = accounts.indices.filter { snapshots[$0].nextReset(at: now) != nil }.sorted { snapshots[$0].resetAt < snapshots[$1].resetAt }
        var result = CapacitySimulation()
        var date = now
        result.minimum = balances.reduce(0, +)
        result.points.append(CapacityPoint(date: now, units: result.minimum, segment: 0))
        if pending.isEmpty {
            // All next reset dates are unknown. Show a bounded two-day burn
            // estimate without inventing another refill or a repeating cycle.
            let horizon = now.addingTimeInterval(2 * day)
            let total = result.minimum
            if ratePerHour > 0 && ratePerHour * 48 > total {
                let exhaustion = now.addingTimeInterval(total / ratePerHour * 3_600)
                result.exhaustedAt = exhaustion
                result.shortfallUnits = ratePerHour * 48 - total
                result.shortfallAt = horizon
                result.points.append(CapacityPoint(date: exhaustion, units: 0, segment: 0))
            }
            result.minimum = max(0, total - ratePerHour * 48)
            result.points.append(CapacityPoint(date: horizon, units: result.minimum, segment: 0))
        }
        while let next = pending.first {
            let resetAt = snapshots[next].resetAt
            let hours = max(0, resetAt.timeIntervalSince(date) / 3_600)
            let total = balances.reduce(0, +)
            var demand = ratePerHour * hours
            if demand > total + 0.000000001 && ratePerHour > 0 {
                let exhaustion = date.addingTimeInterval(total / ratePerHour * 3_600)
                if result.exhaustedAt == nil {
                    result.exhaustedAt = exhaustion
                    result.shortfallUnits = demand - total
                    result.shortfallAt = resetAt
                }
                result.points.append(CapacityPoint(date: exhaustion, units: 0, segment: 0))
            }
            // Spend the soonest-resetting allowance first, preserving accounts
            // that have already refilled for the later intervals.
            let spendOrder = pending + accounts.indices.filter { !pending.contains($0) }
            for index in spendOrder {
                let spend = min(balances[index], demand)
                balances[index] -= spend
                demand -= spend
            }
            let before = balances.reduce(0, +)
            result.minimum = min(result.minimum, before)
            result.points.append(CapacityPoint(date: resetAt, units: before, segment: 0))
            let simultaneous = pending.filter { snapshots[$0].resetAt == resetAt }
            for index in simultaneous {
                let prior = balances.reduce(0, +)
                balances[index] = accounts[index].capacityUnits!
                result.resets.append(CapacityReset(date: resetAt, accountName: accounts[index].name,
                    before: prior, after: balances.reduce(0, +), projected: true))
            }
            pending.removeAll { simultaneous.contains($0) }
            result.points.append(CapacityPoint(date: resetAt, units: balances.reduce(0, +), segment: 0))
            date = resetAt
        }
        return result
    }
}
