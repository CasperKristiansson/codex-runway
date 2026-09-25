import AppKit
import Foundation

@MainActor
final class RunwayBackupManager: ObservableObject {
    @Published private(set) var destinationPath: String?
    @Published private(set) var isEnabled: Bool
    @Published private(set) var keepDailyDays: Int
    @Published private(set) var lastCompletedAt: Date?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isWorking = false

    private enum Key {
        static let destination = "codex-runway.backup.destination.v1"
        static let enabled = "codex-runway.backup.enabled.v1"
        static let keepDailyDays = "codex-runway.backup.keep-daily-days.v1"
        static let lastCompleted = "codex-runway.backup.last-completed.v1"
    }

    private let defaults: UserDefaults
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        destinationPath = defaults.string(forKey: Key.destination)
        isEnabled = defaults.bool(forKey: Key.enabled)
        keepDailyDays = max(1, defaults.object(forKey: Key.keepDailyDays) == nil
                            ? 30 : defaults.integer(forKey: Key.keepDailyDays))
        lastCompletedAt = defaults.object(forKey: Key.lastCompleted) as? Date
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.backUpIfDue() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.backUpIfDue() }
        }
        Task { await backUpIfDue() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func chooseDestination(_ url: URL) {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        do {
            try RunwayBackupStore(destination: URL(fileURLWithPath: path, isDirectory: true)).validateDestination()
            destinationPath = path
            defaults.set(path, forKey: Key.destination)
            isEnabled = true
            defaults.set(true, forKey: Key.enabled)
            lastCompletedAt = nil
            defaults.removeObject(forKey: Key.lastCompleted)
            statusMessage = nil
            Task { await backUpNow() }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard destinationPath != nil else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Key.enabled)
        if enabled { Task { await backUpIfDue() } }
    }

    func setKeepDailyDays(_ days: Int) {
        keepDailyDays = min(365, max(1, days))
        defaults.set(keepDailyDays, forKey: Key.keepDailyDays)
    }

    func backUpNow() async { await run(force: true) }
    private func backUpIfDue() async { await run(force: false) }

    private func run(force: Bool) async {
        guard let destinationPath, !isWorking, force || isEnabled else { return }
        isWorking = true
        defer { isWorking = false }

        do {
            let preferences = try snapshotPreferences()
            let destination = URL(fileURLWithPath: destinationPath, isDirectory: true)
            let days = keepDailyDays
            let date = Date()
            let result = try await Task.detached(priority: .utility) {
                try RunwayBackupStore(destination: destination).create(
                    preferences: preferences, at: date, keepDailyDays: days, force: force
                )
            }.value
            if result != nil {
                lastCompletedAt = date
                defaults.set(date, forKey: Key.lastCompleted)
            }
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func snapshotPreferences() throws -> Data {
        let keys = [
            "codex-runway.accounts.v1",
            "codex-runway.selected-account.v1",
            "codex-runway.graph-range.v1",
            "codex-runway.graph-percent.v1",
            "codex-runway.capacity-view.v1"
        ]
        var preferences: [String: Any] = [:]
        for key in keys {
            if let value = defaults.object(forKey: key) { preferences[key] = value }
        }
        return try PropertyListSerialization.data(fromPropertyList: preferences, format: .xml, options: 0)
    }
}
