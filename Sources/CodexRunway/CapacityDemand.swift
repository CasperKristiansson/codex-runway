import Foundation

struct CapacityConsumption {
    let accountIndex: Int
    let start: Date
    let end: Date
    let units: Double

    var seconds: TimeInterval { end.timeIntervalSince(start) }

    func units(from start: Date, to end: Date) -> Double {
        units * max(0, min(self.end, end).timeIntervalSince(max(self.start, start))) / seconds
    }
}

struct CapacityDemand {
    struct Segment {
        let start: Date
        let end: Date
        let rate: Double
        var units: Double { rate * end.timeIntervalSince(start) / 3_600 }
    }

    let ratePerHour: Double
    let hourlyFactors: [Double]
    let calendar: Calendar

    init(ratePerHour: Double, hourlyFactors: [Double]? = nil, calendar: Calendar = .current) {
        self.ratePerHour = ratePerHour.isFinite ? max(0, ratePerHour) : 0
        if let factors = hourlyFactors, factors.count == 24,
           factors.allSatisfy({ $0.isFinite && $0 >= 0 }), factors.reduce(0, +) > 0 {
            let average = factors.reduce(0, +) / 24
            self.hourlyFactors = factors.map { $0 / average }
        } else {
            self.hourlyFactors = Array(repeating: 1, count: 24)
        }
        self.calendar = calendar
    }

    // Calendar hour boundaries handle fractional time zones and repeated/skipped
    // daylight-saving hours. Never step by a wall-clock hour label.
    func segments(from start: Date, to end: Date) -> [Segment] {
        var result: [Segment] = []
        var date = start
        while date < end {
            let boundary = calendar.dateInterval(of: .hour, for: date)?.end ?? date.addingTimeInterval(3_600)
            let next = min(end, boundary > date ? boundary : date.addingTimeInterval(3_600))
            result.append(Segment(start: date, end: next,
                rate: ratePerHour * hourlyFactors[calendar.component(.hour, from: date)]))
            date = next
        }
        return result
    }

    func units(from start: Date, to end: Date) -> Double {
        segments(from: start, to: end).reduce(0) { $0 + $1.units }
    }

    static func observations(accounts: [CodexAccount], snapshots: [[UsageSnapshot]]) -> [CapacityConsumption] {
        accounts.indices.flatMap { index -> [CapacityConsumption] in
            guard let fallbackWeight = accounts[index].capacityUnits else { return [] }
            return zip(snapshots[index], snapshots[index].dropFirst()).compactMap { older, newer in
                let weight = newer.capacityUnits ?? fallbackWeight
                guard newer.capturedAt > older.capturedAt,
                      older.resetAt > newer.capturedAt,
                      abs(older.resetAt.timeIntervalSince(newer.resetAt)) < 60,
                      (older.capacityUnits ?? fallbackWeight) == weight,
                      newer.usedPercent >= older.usedPercent else { return nil }
                return CapacityConsumption(accountIndex: index, start: older.capturedAt, end: newer.capturedAt,
                    units: max(0, CapacityForecast.remaining(older, weight: weight) - CapacityForecast.remaining(newer, weight: weight)))
            }
        }
    }

    // Learn timing from well-localized consumption, using all retained history.
    // Missing hours get the pooled prior, not fabricated zero consumption.
    static func learnHourlyFactors(_ observations: [CapacityConsumption], calendar: Calendar = .current) -> [Double]? {
        let reliable = observations.filter { $0.seconds <= 2 * 3_600 }.sorted { $0.start < $1.start }
        guard let first = reliable.first, let last = reliable.max(by: { $0.end < $1.end }),
              last.end.timeIntervalSince(first.start) >= 48 * 3_600 else { return nil }
        let clock = CapacityDemand(ratePerHour: 1, calendar: calendar)
        var amounts = Array(repeating: 0.0, count: 24)
        for observation in reliable {
            for part in clock.segments(from: observation.start, to: observation.end) {
                amounts[calendar.component(.hour, from: part.start)] += observation.units(from: part.start, to: part.end)
            }
        }
        // Merge exposure across accounts before estimating hourly rates. Multiple
        // accounts observed together contribute consumption, not extra clock time.
        var spans: [(start: Date, end: Date)] = []
        for observation in reliable {
            if let last = spans.last, observation.start <= last.end {
                spans[spans.count - 1].end = max(last.end, observation.end)
            } else {
                spans.append((observation.start, observation.end))
            }
        }
        var exposure = Array(repeating: 0.0, count: 24)
        for span in spans {
            for part in clock.segments(from: span.start, to: span.end) {
                exposure[calendar.component(.hour, from: part.start)] += part.end.timeIntervalSince(part.start) / 3_600
            }
        }
        let hours = exposure.reduce(0, +)
        guard hours >= 24, amounts.reduce(0, +) > 0 else { return nil }
        let pooled = amounts.reduce(0, +) / hours
        let rates = zip(amounts, exposure).map { ($0 + 4 * pooled) / ($1 + 4) }
        let average = rates.reduce(0, +) / 24
        return rates.map { $0 / average }
    }
}
