import Foundation

// A separate local archive of immutable forecast origins, not another source of
// account balances. Nothing here is sent to a server or used to switch accounts.
struct ForecastJournal {
    struct AccountState: Codable {
        let id: UUID
        let capacityUnits: Double
        let snapshot: UsageSnapshot
    }

    struct Prediction: Codable {
        let horizonHours: Int
        let units: Double
    }

    struct ResetBalance: Codable {
        let date: Date
        let before: Double
        let after: Double
    }

    struct Candidate: Codable {
        let model: String
        let ratePerHour: Double
        let hourlyFactors: [Double]
        let predictions: [Prediction]
        let exhaustedAt: Date?
        let shortfallUnits: Double?
        let shortfallAt: Date?
        let resetBalances: [ResetBalance]
    }

    struct Record: Codable {
        let schemaVersion: Int
        let origin: Date
        let timeZone: String
        let usesTimeOfDay: Bool
        let accounts: [AccountState]
        let candidates: [Candidate]
    }

    let directory: URL
    static let interval: TimeInterval = 3 * 3_600

    init(directory: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Codex Runway/Forecasts", isDirectory: true)) {
        self.directory = directory
    }

    // At most one successful origin per three-hour UTC bucket, including across
    // relaunches. Called only after a real quota refresh, never by view rendering.
    @discardableResult
    func record(accounts: [CodexAccount], now: Date, calendar: Calendar = .current) throws -> Bool {
        let bucket = Int(floor(now.timeIntervalSince1970 / Self.interval))
        let file = directory.appendingPathComponent("forecast-\(bucket).json")
        let manager = FileManager.default
        guard !manager.fileExists(atPath: file.path) else { return false }
        let active = accounts.filter(\.isEnabled)
        let report = CapacityForecast.report(accounts: active, now: now, calendar: calendar)
        guard report.issue == nil, let demand = report.demand else { return false }
        let states = active.map { account in
            AccountState(id: account.id, capacityUnits: account.capacityUnits!,
                snapshot: account.snapshots.filter { $0.capturedAt <= now }.max(by: { $0.capturedAt < $1.capturedAt })!)
        }
        var models = report.shadowDemands
        models["clock-v1"] = demand
        let candidates = models.keys.sorted().map { name in
            let model = models[name]!
            let simulation = CapacityForecast.simulate(accounts: active, snapshots: states.map(\.snapshot),
                ratePerHour: model.ratePerHour, now: now, hourlyFactors: model.hourlyFactors, calendar: calendar)
            return Candidate(model: name, ratePerHour: model.ratePerHour, hourlyFactors: model.hourlyFactors,
                predictions: [3, 6, 12, 24, 48].map {
                    Prediction(horizonHours: $0, units: model.units(from: now, to: now.addingTimeInterval(Double($0) * 3_600)))
                }, exhaustedAt: simulation.exhaustedAt, shortfallUnits: simulation.shortfallUnits,
                shortfallAt: simulation.shortfallAt,
                resetBalances: simulation.resets.map { ResetBalance(date: $0.date, before: $0.before, after: $0.after) })
        }
        let record = Record(schemaVersion: 1, origin: now, timeZone: calendar.timeZone.identifier,
            usesTimeOfDay: report.usesTimeOfDay, accounts: states, candidates: candidates)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Publish a complete file without replacing an existing origin. A crash
        // during encoding/writing cannot leave a partial forecast at its final
        // name, and a second app instance cannot overwrite the first one's data.
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).pending")
        defer { try? manager.removeItem(at: temporary) }
        try encoder.encode(record).write(to: temporary, options: .atomic)
        do {
            try manager.linkItem(at: temporary, to: file)
        } catch CocoaError.fileWriteFileExists {
            return false
        }
        // Only remove this archive's own expired files. Quota/profile history is
        // retained independently; forecast records cannot modify that history.
        let cutoff = HistoryRetention.cutoff(now: now).timeIntervalSince1970
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "json", name.hasPrefix("forecast-"),
                  let oldBucket = Int(name.dropFirst("forecast-".count)),
                  Double(oldBucket + 1) * Self.interval < cutoff else { continue }
            try manager.removeItem(at: url)
        }
        return true
    }
}
