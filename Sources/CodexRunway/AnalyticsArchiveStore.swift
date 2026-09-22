import Foundation

struct AnalyticsArchiveStore {
    let directory: URL

    init(directory: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Codex Runway/Analytics", isDirectory: true)) {
        self.directory = directory
    }

    func load(accountID: UUID) throws -> AnalyticsArchive? {
        let file = directory.appendingPathComponent("\(accountID.uuidString).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AnalyticsArchive.self, from: Data(contentsOf: file))
    }

    func save(_ archive: AnalyticsArchive, accountID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(archive)
        try data.write(to: directory.appendingPathComponent("\(accountID.uuidString).json"), options: .atomic)
    }

    func remove(accountID: UUID) throws {
        let file = directory.appendingPathComponent("\(accountID.uuidString).json")
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }
}

extension AnalyticsArchive {
    mutating func apply(_ update: AnalyticsUpdate, now: Date, wasBackfill: Bool) {
        if let rows = update.messages {
            messages = Self.merged(messages, rows, date: \.date)
            messagesFetchedAt = now
        }
        if let rows = update.usage {
            usage = Self.merged(usage, rows, date: \.date)
            usageFetchedAt = now
        }
        if let rows = update.plugins {
            plugins = Self.merged(plugins, rows, date: \.date)
            pluginsFetchedAt = now
        }
        if let rows = update.skills {
            skills = Self.merged(skills, rows, date: \.date)
            skillsFetchedAt = now
        }
        if let rows = update.reviews { reviews = Self.merged(reviews, rows, date: \.date) }
        if let plan = update.plan {
            var values = Dictionary(planPeriods.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
            for period in plan.periods { values[period.id] = period }
            planPeriods = values.values.sorted { $0.startsAt > $1.startsAt }
            planFetchedAt = now
        }
        if let events = update.creditEvents {
            var seen = Set(creditEvents.compactMap { try? JSONEncoder().encode($0) })
            for event in events {
                guard let encoded = try? JSONEncoder().encode(event), seen.insert(encoded).inserted else { continue }
                creditEvents.append(event)
            }
        }
        if let chats = update.chats {
            var values = Dictionary(self.chats.map { ($0.threadID, $0) }, uniquingKeysWith: { _, latest in latest })
            for chat in chats { values[chat.threadID] = chat }
            self.chats = values.values.sorted { $0.createdAt > $1.createdAt }
            chatsFetchedAt = now
        }
        dataFreshnessTimestamp = update.dataFreshnessTimestamp ?? dataFreshnessTimestamp
        if wasBackfill { lastBackfillAt = now }
        prune(now: now)
    }
}
