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
}

struct CapacitySimulation {
    var points: [CapacityPoint] = []
    var resets: [CapacityReset] = []
    var minimum: Double = .infinity
    var exhaustedAt: Date?
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
    var reductionPercent: Double?
    var horizon: Date
    var issue: String?
    var hasStaleReadings = false
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

    // Keep the complete 30-day history, not a fixed number of refreshes.
    static func retainedSnapshots(_ snapshots: [UsageSnapshot], now: Date) -> [UsageSnapshot] {
        snapshots.filter { $0.capturedAt >= now.addingTimeInterval(-30 * day) }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    static func remaining(_ snapshot: UsageSnapshot, weight: Double) -> Double {
        weight * (1 - min(100, max(0, snapshot.usedPercent)) / 100)
    }

    static func report(accounts: [CodexAccount], now: Date = .now) -> CapacityReport {
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
        let events = ordered.enumerated().flatMap { index, snapshots in
            snapshots.map { (index: index, snapshot: $0) }
        }.sorted { $0.snapshot.capturedAt < $1.snapshot.capturedAt }
        var known: [Int: UsageSnapshot] = [:]
        var segment = 0
        for event in events {
            let previous = known[event.index]
            let date = event.snapshot.capturedAt
            let reset = previous.map { abs($0.resetAt.timeIntervalSince(event.snapshot.resetAt)) > 60 } ?? false
            let before = known.reduce(0.0) { sum, pair in
                sum + remaining(pair.value, weight: pair.value.capacityUnits ?? accounts[pair.key].capacityUnits!)
            }
            let wasComplete = known.count == accounts.count
            known[event.index] = event.snapshot
            guard known.count == accounts.count else { continue }
            let after = known.reduce(0.0) { sum, pair in
                sum + remaining(pair.value, weight: pair.value.capacityUnits ?? accounts[pair.key].capacityUnits!)
            }
            // An overdue saved window cannot supply a current combined balance.
            guard known.values.allSatisfy({ $0.resetAt > date }) else { segment += 1; continue }
            if let last = result.history.last, date.timeIntervalSince(last.date) > 3_600 { segment += 1 }
            if reset && wasComplete {
                result.history.append(CapacityPoint(date: date, units: before, segment: segment))
                result.resets.append(CapacityReset(date: date, accountName: accounts[event.index].name,
                    before: before, after: after, projected: false))
            }
            result.history.append(CapacityPoint(date: date, units: after, segment: segment))
        }

        guard ordered.allSatisfy({ !$0.isEmpty }) else {
            result.issue = "Refresh each account to establish a combined balance."
            return result
        }
        let latest = ordered.map { $0.last! }
        result.remaining = zip(accounts, latest).reduce(0) { $0 + remaining($1.1, weight: $1.0.capacityUnits!) }
        result.hasBalance = true
        result.horizon = max(now, latest.map(\.resetAt).max()!)
        result.resets += accounts.indices.compactMap { index in
            guard latest[index].resetAt > now else { return nil }
            return CapacityReset(date: latest[index].resetAt, accountName: accounts[index].name,
                before: 0, after: 0, projected: true, hasEstimate: false)
        }
        if zip(accounts, latest).contains(where: { ($0.1.capacityUnits ?? $0.0.capacityUnits!) != $0.0.capacityUnits! }) {
            result.issue = "An account’s plan changed. Refresh it to establish its new capacity."
            return result
        }
        if latest.contains(where: { $0.resetAt <= now }) {
            result.issue = "A saved reset has passed. Sign in to that account and refresh to update the forecast."
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
        if projection.exhaustedAt != nil {
            var low = 0.0, high = rate
            for _ in 0..<40 {
                let middle = (low + high) / 2
                if simulate(accounts: accounts, snapshots: latest, ratePerHour: middle, now: now).exhaustedAt == nil {
                    low = middle
                } else { high = middle }
            }
            result.reductionPercent = min(100, max(0, (1 - low / rate) * 100))
        }
        return result
    }

    static func simulate(accounts: [CodexAccount], snapshots: [UsageSnapshot], ratePerHour: Double, now: Date) -> CapacitySimulation {
        var balances = zip(accounts, snapshots).map { remaining($0.1, weight: $0.0.capacityUnits!) }
        var pending = Array(accounts.indices).sorted { snapshots[$0].resetAt < snapshots[$1].resetAt }
        var result = CapacitySimulation()
        var date = now
        result.minimum = balances.reduce(0, +)
        result.points.append(CapacityPoint(date: now, units: result.minimum, segment: 0))
        while let next = pending.first {
            let resetAt = snapshots[next].resetAt
            let hours = max(0, resetAt.timeIntervalSince(date) / 3_600)
            let total = balances.reduce(0, +)
            var demand = ratePerHour * hours
            if demand > total + 0.000000001 && ratePerHour > 0 {
                let exhaustion = date.addingTimeInterval(total / ratePerHour * 3_600)
                if result.exhaustedAt == nil { result.exhaustedAt = exhaustion }
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
