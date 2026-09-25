import Foundation

@main
struct BackupChecks {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("runway-backup-checks-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let source = root.appendingPathComponent("live")
        let destination = root.appendingPathComponent("destination")
        let analytics = source.appendingPathComponent("Analytics")
        let forecasts = source.appendingPathComponent("Forecasts")
        for path in [analytics, forecasts, destination] {
            try manager.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let accountID = UUID()
        try Data(#"{"day":"first"}"#.utf8).write(to: analytics.appendingPathComponent("\(accountID).json"))
        try Data(#"{"forecast":1}"#.utf8).write(to: forecasts.appendingPathComponent("forecast-123.json"))
        try Data("should never be copied".utf8).write(to: source.appendingPathComponent("auth.json"))
        let preferences = try PropertyListSerialization.data(
            fromPropertyList: ["codex-runway.accounts.v1": Data("accounts".utf8)], format: .xml, options: 0)
        let store = RunwayBackupStore(sourceDirectory: source, destination: destination)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ value: String) -> Date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: "\(value)T12:00:00Z")!
        }
        let january = date("2026-01-01")
        precondition(store.needsBackup(at: january, calendar: calendar))
        let first = try store.create(preferences: preferences, at: january, calendar: calendar)!
        precondition(first.createdDaily && first.createdMonthly)
        precondition(!store.needsBackup(at: january, calendar: calendar))
        let duplicate = try store.create(preferences: preferences, at: january, calendar: calendar)
        precondition(duplicate == nil)
        try store.verify(first.daily)
        try store.verify(first.monthly)

        let extracted = root.appendingPathComponent("extracted")
        try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", first.daily.path, extracted.path]
        try unzip.run()
        unzip.waitUntilExit()
        precondition(unzip.terminationStatus == 0)
        let savedAnalytics = try Data(contentsOf: extracted.appendingPathComponent("Analytics/\(accountID).json"))
        let savedForecast = try Data(contentsOf: extracted.appendingPathComponent("Forecasts/forecast-123.json"))
        precondition(savedAnalytics == Data(#"{"day":"first"}"#.utf8))
        precondition(savedForecast == Data(#"{"forecast":1}"#.utf8))
        precondition(!manager.fileExists(atPath: extracted.appendingPathComponent("auth.json").path))
        let savedPreferences = try Data(contentsOf: extracted.appendingPathComponent("preferences.plist"))
        precondition(savedPreferences == preferences)

        try Data(#"{"day":"later"}"#.utf8).write(to: analytics.appendingPathComponent("\(accountID).json"))
        let sameMonth = try store.create(preferences: preferences, at: date("2026-01-31"), calendar: calendar)!
        precondition(!sameMonth.createdMonthly, "Only the first backup in a month becomes permanent")
        let february = try store.create(preferences: preferences, at: date("2026-02-01"), calendar: calendar)!
        precondition(february.createdMonthly)
        precondition(!manager.fileExists(atPath: first.daily.path), "Old daily copies must expire")
        precondition(manager.fileExists(atPath: first.monthly.path), "Monthly copies must remain")
        precondition(manager.fileExists(atPath: sameMonth.daily.path))
        _ = try store.create(preferences: preferences, at: date("2026-03-02"), calendar: calendar)
        precondition(!manager.fileExists(atPath: sameMonth.daily.path))
        precondition(manager.fileExists(atPath: first.monthly.path))
        precondition(manager.fileExists(atPath: february.monthly.path))

        let missing = RunwayBackupStore(sourceDirectory: source, destination: root.appendingPathComponent("missing"))
        do {
            _ = try missing.create(preferences: preferences, at: january)
            preconditionFailure("Missing destination must fail")
        } catch RunwayBackupStore.BackupError.destinationUnavailable {}
        let inside = RunwayBackupStore(sourceDirectory: source, destination: analytics)
        do {
            try inside.validateDestination()
            preconditionFailure("Backups cannot be placed within live data")
        } catch RunwayBackupStore.BackupError.destinationInsideLiveData {}
        print("Backup archive, retention, and recovery checks passed")
    }
}
