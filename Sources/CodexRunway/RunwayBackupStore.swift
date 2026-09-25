import CryptoKit
import Foundation

/// Creates portable, unencrypted ZIP snapshots of Runway's own durable data.
/// The selected folder remains a backup destination, never live app storage.
struct RunwayBackupStore: Sendable {
    struct Result: Sendable {
        let daily: URL
        let monthly: URL
        let createdDaily: Bool
        let createdMonthly: Bool
    }

    private struct Manifest: Codable {
        struct File: Codable {
            let path: String
            let bytes: Int
            let sha256: String
        }

        let formatVersion: Int
        let createdAt: Date
        let files: [File]
    }

    enum BackupError: LocalizedError {
        case destinationUnavailable
        case destinationInsideLiveData
        case invalidArchive
        case zipFailed

        var errorDescription: String? {
            switch self {
            case .destinationUnavailable: "The backup folder is unavailable. Choose an available folder and try again."
            case .destinationInsideLiveData: "Choose a folder outside Codex Runway's live data folder."
            case .invalidArchive: "The new backup could not be verified. Existing backups were kept."
            case .zipFailed: "The backup ZIP could not be created or opened. Existing backups were kept."
            }
        }
    }

    static let folderName = "Codex Runway Backups"
    let sourceDirectory: URL
    let destination: URL
    private var manager: FileManager { .default }

    init(sourceDirectory: URL = URL.applicationSupportDirectory
        .appendingPathComponent("Codex Runway", isDirectory: true), destination: URL) {
        self.sourceDirectory = sourceDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.destination = destination.standardizedFileURL.resolvingSymlinksInPath()
    }

    var backupDirectory: URL { destination.appendingPathComponent(Self.folderName, isDirectory: true) }

    func validateDestination() throws {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BackupError.destinationUnavailable
        }
        let source = sourceDirectory.path + "/"
        if destination.path == sourceDirectory.path || destination.path.hasPrefix(source) {
            throw BackupError.destinationInsideLiveData
        }
    }

    func needsBackup(at date: Date, calendar: Calendar = .current) -> Bool {
        let names = (try? manager.contentsOfDirectory(atPath: backupDirectory.path)) ?? []
        let day = Self.dayKey(date, calendar: calendar)
        let month = String(day.prefix(7))
        return !names.contains(where: { $0.hasPrefix("daily-\(day)-") && $0.hasSuffix(".zip") })
            || !names.contains("monthly-\(month).zip")
    }

    @discardableResult
    func create(preferences: Data, at date: Date, keepDailyDays: Int = 30,
                force: Bool = false, calendar: Calendar = .current) throws -> Result? {
        try validateDestination()
        try manager.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let day = Self.dayKey(date, calendar: calendar)
        let month = String(day.prefix(7))
        let names = try manager.contentsOfDirectory(atPath: backupDirectory.path)
        let existingDaily = names.filter { $0.hasPrefix("daily-\(day)-") && $0.hasSuffix(".zip") }.sorted().last
        let monthly = backupDirectory.appendingPathComponent("monthly-\(month).zip")
        let createDaily = force || existingDaily == nil
        let createMonthly = !manager.fileExists(atPath: monthly.path)
        guard createDaily || createMonthly else { return nil }

        let daily: URL
        if createDaily {
            let time = Self.timeKey(date, calendar: calendar)
            daily = backupDirectory.appendingPathComponent("daily-\(day)-\(time)-\(UUID().uuidString).zip")
            try writeSnapshot(preferences: preferences, at: date, to: daily)
        } else {
            daily = backupDirectory.appendingPathComponent(existingDaily!)
            try verify(daily)
        }

        if createMonthly {
            let pending = backupDirectory.appendingPathComponent(".\(UUID().uuidString).pending")
            defer { try? manager.removeItem(at: pending) }
            try manager.copyItem(at: daily, to: pending)
            try verify(pending)
            try manager.moveItem(at: pending, to: monthly)
        }

        try pruneDaily(before: date, keeping: max(1, keepDailyDays), calendar: calendar)
        return Result(daily: daily, monthly: monthly,
                      createdDaily: createDaily, createdMonthly: createMonthly)
    }

    func verify(_ archive: URL) throws {
        let extracted = manager.temporaryDirectory.appendingPathComponent("codex-runway-verify-\(UUID().uuidString)")
        try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: extracted) }
        try runDitto(["-x", "-k", archive.path, extracted.path])
        let manifestURL = extracted.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.formatVersion == 1,
              manifest.files.contains(where: { $0.path == "preferences.plist" }) else {
            throw BackupError.invalidArchive
        }
        for file in manifest.files {
            guard Self.isAllowedPath(file.path),
                  let contents = try? Data(contentsOf: extracted.appendingPathComponent(file.path)),
                  contents.count == file.bytes,
                  Self.sha256(contents) == file.sha256 else {
                throw BackupError.invalidArchive
            }
        }
        guard let preferences = try? Data(contentsOf: extracted.appendingPathComponent("preferences.plist")),
              (try? PropertyListSerialization.propertyList(from: preferences, format: nil)) != nil else {
            throw BackupError.invalidArchive
        }
    }

    private func writeSnapshot(preferences: Data, at date: Date, to target: URL) throws {
        let staging = manager.temporaryDirectory.appendingPathComponent("codex-runway-backup-\(UUID().uuidString)")
        let pending = backupDirectory.appendingPathComponent(".\(UUID().uuidString).pending")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            try? manager.removeItem(at: staging)
            try? manager.removeItem(at: pending)
        }

        var files: [Manifest.File] = []
        let preferencesPath = staging.appendingPathComponent("preferences.plist")
        try preferences.write(to: preferencesPath)
        files.append(Self.manifestFile(path: "preferences.plist", contents: preferences))

        for folder in ["Analytics", "Forecasts"] {
            let source = sourceDirectory.appendingPathComponent(folder, isDirectory: true)
            let output = staging.appendingPathComponent(folder, isDirectory: true)
            try manager.createDirectory(at: output, withIntermediateDirectories: true)
            guard manager.fileExists(atPath: source.path) else { continue }
            let urls = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                guard Self.isAllowedSourceFile(folder: folder, name: name),
                      try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
                      try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                let contents = try Data(contentsOf: url)
                try contents.write(to: output.appendingPathComponent(name))
                files.append(Self.manifestFile(path: "\(folder)/\(name)", contents: contents))
            }
        }

        let manifest = Manifest(formatVersion: 1, createdAt: date, files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        try runDitto(["-c", "-k", "--norsrc", staging.path, pending.path])
        try verify(pending)
        try manager.moveItem(at: pending, to: target)
    }

    private func pruneDaily(before date: Date, keeping days: Int, calendar: Calendar) throws {
        let today = calendar.startOfDay(for: date)
        guard let oldest = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return }
        let cutoff = Self.dayKey(oldest, calendar: calendar)
        for url in try manager.contentsOfDirectory(at: backupDirectory, includingPropertiesForKeys: [.isRegularFileKey]) {
            let name = url.lastPathComponent
            let day = String(name.dropFirst(6).prefix(10))
            guard name.hasPrefix("daily-"), name.hasSuffix(".zip"), name.count > 21,
                  name[name.index(name.startIndex, offsetBy: 16)] == "-",
                  Self.validDayKey(day), day < cutoff,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            try manager.removeItem(at: url)
        }
    }

    private func runDitto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw BackupError.zipFailed }
    }

    private static func manifestFile(path: String, contents: Data) -> Manifest.File {
        Manifest.File(path: path, bytes: contents.count, sha256: sha256(contents))
    }

    private static func sha256(_ contents: Data) -> String {
        SHA256.hash(data: contents).map { String(format: "%02x", $0) }.joined()
    }

    private static func isAllowedSourceFile(folder: String, name: String) -> Bool {
        guard name.hasSuffix(".json") else { return false }
        let stem = String(name.dropLast(5))
        if folder == "Analytics" { return UUID(uuidString: stem) != nil }
        return folder == "Forecasts" && stem.hasPrefix("forecast-") && Int(stem.dropFirst(9)) != nil
    }

    private static func isAllowedPath(_ path: String) -> Bool {
        if path == "preferences.plist" { return true }
        let parts = path.split(separator: "/")
        return parts.count == 2 && isAllowedSourceFile(folder: String(parts[0]), name: String(parts[1]))
    }

    private static func validDayKey(_ value: String) -> Bool {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter.date(from: value) != nil && value.count == 10
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    private static func timeKey(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d%02d%02d", parts.hour!, parts.minute!, parts.second!)
    }
}
