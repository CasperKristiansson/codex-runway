import AppKit
import Foundation
import Combine

struct HubRequest: Decodable {
    let version: Int
    let kind: String
    var section: String?
    var accountID: UUID?
    var days: Int?
    var requestID: UUID?
    var action: String?
    var loginID: String?
    var enabled: Bool?
    var offset: Int?
    var range: String?
    var mode: String?
    var percent: Bool?
    var keepDailyDays: Int?

    static func decode(_ data: Data) throws -> HubRequest {
        let keys: Set<String> = ["version", "kind", "section", "accountID", "days", "requestID", "action", "loginID", "enabled", "offset", "range", "mode", "percent", "keepDailyDays"]
        guard data.count <= 16_384, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: keys) else { throw HubError.invalid }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, ["snapshot", "command"].contains(value.kind),
              value.loginID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              value.days.map({ [7, 30, 365].contains($0) }) ?? true,
              value.section.map({ ["overview", "settings", "history", "analytics"].contains($0) }) ?? true else { throw HubError.invalid }
        return value
    }
}

enum HubError: Error { case invalid, busy, missing, recovery, persistence, tooLarge }

struct HubOperation: Codable {
    let id: UUID
    let requestID: UUID
    let signature: String
    let action: String
    let target: String?
    let startedAt: Date
    var finishedAt: Date?
    var state: String
    var message: String
}

/// Admission and receipts belong to the native process, never the MCP lifetime.
@MainActor
final class RunwayHubController {
    let store: RunwayStore
    let backups: RunwayBackupManager
    private let defaults: UserDefaults
    private let openNative: () -> Void
    private var task: Task<Void, Never>?
    private(set) var operations: [HubOperation]
    private var observers: Set<AnyCancellable> = []
    private var overviewCache: (at: Date, value: [String: Any])?
    private let operationKey = "codex-runway.hub-operations.v1"

    init(store: RunwayStore, backups: RunwayBackupManager, defaults: UserDefaults = .standard, openNative: @escaping () -> Void) {
        self.store = store; self.backups = backups; self.defaults = defaults; self.openNative = openNative
        operations = defaults.data(forKey: operationKey).flatMap { try? JSONDecoder().decode([HubOperation].self, from: $0) } ?? []
        for index in operations.indices where operations[index].state == "running" {
            operations[index].state = "interrupted"
            operations[index].finishedAt = .now
            operations[index].message = "Runway stopped during this operation. Check native recovery before retrying."
        }
        try? persist()
        store.objectWillChange.sink { [weak self] _ in self?.overviewCache = nil }.store(in: &observers)
        store.displayPreferences.objectWillChange.sink { [weak self] _ in self?.overviewCache = nil }.store(in: &observers)
    }

    func reply(_ data: Data) -> Data {
        do {
            let request = try HubRequest.decode(data)
            let value = request.kind == "snapshot" ? try snapshot(request) : try command(request, data: data)
            let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            guard bytes.count <= 4_194_304 else { throw HubError.tooLarge }
            return bytes
        } catch {
            let message: String
            switch error {
            case HubError.busy: message = "A native operation is running. Wait for completion."
            case HubError.missing: message = "The selected account or saved login is no longer available. Reload the hub."
            case HubError.recovery: message = "An interrupted switch needs native recovery first."
            case HubError.tooLarge: message = "This snapshot exceeds the bridge limit. Select one account or open native Runway."
            case HubError.persistence: message = "Could not save the operation receipt. No action started."
            default: message = "Invalid or unsupported Runway request."
            }
            return (try? JSONSerialization.data(withJSONObject: ["version": 1, "error": message])) ?? Data()
        }
    }

    func snapshot(_ request: HubRequest, now: Date = .now) throws -> [String: Any] {
        let selected: [CodexAccount]
        if let id = request.accountID {
            guard let account = store.accounts.first(where: { $0.id == id }) else { throw HubError.missing }
            selected = [account]
        } else { selected = store.dashboardAccounts }
        if overviewCache == nil || now.timeIntervalSince(overviewCache!.at) >= 60 || now < overviewCache!.at {
            overviewCache = (now, HubSnapshot.overview(store: store, now: now))
        }
        var result = HubSnapshot.base(store: store, now: now, cachedOverview: overviewCache?.value)
        result["operations"] = operations.suffix(32).map { operation -> [String: Any] in
            ["id": operation.id.uuidString, "requestID": operation.requestID.uuidString, "action": operation.action,
             "state": operation.state, "startedAt": operation.startedAt.timeIntervalSince1970,
             "finishedAt": HubSnapshot.date(operation.finishedAt), "message": operation.message]
        }
        result["bridgeBusy"] = task != nil
        result["backup"] = ["destination": HubSnapshot.optional(backups.destinationPath), "enabled": backups.isEnabled,
                            "keepDailyDays": backups.keepDailyDays, "lastCompletedAt": HubSnapshot.date(backups.lastCompletedAt),
                            "working": backups.isWorking, "error": backups.statusMessage == nil ? NSNull() : "Backup failed. Open native Runway for details."] as [String: Any]
        if request.section == "history" { result["history"] = try HubSnapshot.history(accounts: selected, now: now) }
        if request.section == "analytics" { result["analytics"] = HubSnapshot.analytics(accounts: selected, store: store, days: request.days ?? 30, now: now) }
        return result
    }

    func command(_ request: HubRequest, data: Data) throws -> [String: Any] {
        guard let action = request.action, let requestID = request.requestID else { throw HubError.invalid }
        let object = try JSONSerialization.jsonObject(with: data)
        let signature = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        if let existing = operations.first(where: { $0.requestID == requestID }) {
            guard existing.signature == signature else { throw HubError.invalid }
            return receipt(existing)
        }
        if action == "switch", let existing = operations.last(where: { $0.state == "running" && $0.action == "switch" && $0.target == request.loginID }) {
            return receipt(existing)
        }
        if action == "cancel" {
            guard store.loginCanCancel else { throw HubError.invalid }
            store.cancelLoginOperation()
            return ["version": 1, "accepted": true]
        }
        if action == "openNative" {
            openNative()
            return ["version": 1, "accepted": true]
        }
        guard task == nil else { throw HubError.busy }
        let loginActions = ["add", "save", "switch", "forget", "recover", "reloadLogins"]
        let refreshActions = ["refresh", "refreshSaved", "refreshProfile", "refreshAnalytics"]
        let actions = loginActions + refreshActions + ["enable", "move", "display", "chooseBackupFolder", "backupEnabled", "backupRetention", "backupNow"]
        guard actions.contains(action) else { throw HubError.invalid }
        if loginActions.contains(action) || refreshActions.contains(action) {
            guard !store.loginActionsDisabled else { throw HubError.busy }
            guard !store.loginRecoveryPending || action == "recover" || action == "reloadLogins" else { throw HubError.recovery }
        }
        if ["switch", "forget"].contains(action) {
            guard let id = request.loginID, store.savedLogins.contains(where: { $0.id == id }) else { throw HubError.missing }
        }
        if ["enable", "move", "refreshSaved"].contains(action) {
            guard let id = request.accountID, let account = store.accounts.first(where: { $0.id == id }) else { throw HubError.missing }
            if action == "refreshSaved", !store.canRefreshUsage(for: account) { throw HubError.busy }
        }
        if action == "enable", request.enabled == nil { throw HubError.invalid }
        if action == "move", ![-1, 1].contains(request.offset ?? 0) { throw HubError.invalid }
        if action == "display" {
            guard request.range.map({ CapacityGraphRange(rawValue: $0) != nil }) ?? true,
                  request.mode.map({ CapacityViewMode(rawValue: $0) != nil }) ?? true else { throw HubError.invalid }
        }
        if action == "backupEnabled", request.enabled == nil || backups.destinationPath == nil { throw HubError.invalid }
        if action == "backupRetention", !(1...365).contains(request.keepDailyDays ?? 0) { throw HubError.invalid }
        if action == "backupNow", backups.destinationPath == nil || backups.isWorking { throw HubError.busy }
        if action == "refreshAnalytics", store.activeAccountID == nil { throw HubError.missing }
        if action == "recover", !store.loginRecoveryPending { throw HubError.invalid }
        let operation = HubOperation(id: UUID(), requestID: requestID, signature: signature, action: action,
            target: request.loginID ?? request.accountID?.uuidString, startedAt: .now, state: "running",
            message: action == "switch" ? "Runway will close Codex, verify the login, and reopen it. Reopen this hub to see the result." : "Native operation accepted.")
        operations.append(operation)
        if operations.count > 32 { operations.removeFirst(operations.count - 32) }
        do { try persist() } catch { operations.removeLast(); throw HubError.persistence }
        // An unstructured task held by Runway survives iframe/client disconnect.
        task = Task { @MainActor in
            let outcome = await execute(request)
            if let index = operations.firstIndex(where: { $0.id == operation.id }) {
                let failed = failure(for: request)
                operations[index].state = outcome == "completed" && failed ? "failed" : outcome
                operations[index].message = operations[index].state == "failed" ? "Operation needs attention. See native Runway for details; saved data is retained." : operations[index].state == "cancelled" ? "Native operation cancelled before committing a change." : "Native operation completed."
                operations[index].finishedAt = .now
                try? persist()
            }
            task = nil
        }
        return receipt(operation)
    }

    private func receipt(_ operation: HubOperation) -> [String: Any] {
        ["version": 1, "accepted": true, "operationID": operation.id.uuidString, "state": operation.state, "message": operation.message]
    }
    private func persist() throws {
        defaults.set(try JSONEncoder().encode(operations), forKey: operationKey)
        guard defaults.synchronize() else { throw HubError.persistence }
    }
    private func execute(_ request: HubRequest) async -> String {
        let protected = ["refresh", "refreshSaved", "refreshProfile", "refreshAnalytics", "add", "save", "switch", "forget", "recover", "reloadLogins"]
        // Recheck admission after task scheduling; native controls share the
        // same actor and can claim the store between receipt and execution.
        if protected.contains(request.action ?? ""), store.loginActionsDisabled { return "failed" }
        switch request.action {
        case "refresh": if !(await store.refreshActiveAccount()) { return "failed" }
        case "refreshSaved": if let id = request.accountID { await store.refreshUsage(accountID: id) }
        case "refreshProfile": await store.refreshProfile()
        case "refreshAnalytics": await store.refreshAnalyticsForSignedInAccount()
        case "save": await store.saveCurrentLogin()
        case "add": await store.addLogin()
        case "switch": if let id = request.loginID { await store.switchLogin(id: id) }
        case "forget": if let id = request.loginID { store.forgetLogin(id: id) }
        case "recover": await store.recoverLogin()
        case "reloadLogins": store.reloadSavedLogins()
        case "enable": if let id = request.accountID, let value = request.enabled { store.setAccountEnabled(id: id, enabled: value) }
        case "move": if let id = request.accountID, let offset = request.offset { store.moveAccount(id: id, by: offset) }
        case "display":
            if let value = request.range.flatMap(CapacityGraphRange.init(rawValue:)) { store.displayPreferences.range = value }
            if let value = request.mode.flatMap(CapacityViewMode.init(rawValue:)) { store.displayPreferences.mode = value }
            if let value = request.percent { store.displayPreferences.showsPercent = value }
        case "chooseBackupFolder":
            NSApp.activate(ignoringOtherApps: true)
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false; panel.prompt = "Use for Backups"
            let response = await withCheckedContinuation { continuation in panel.begin { continuation.resume(returning: $0) } }
            if response == .OK, let url = panel.url { backups.chooseDestination(url) }
            else { return "cancelled" }
        case "backupEnabled": if let enabled = request.enabled { backups.setEnabled(enabled) }
        case "backupRetention": if let days = request.keepDailyDays { backups.setKeepDailyDays(days) }
        case "backupNow": await backups.backUpNow()
        default: break
        }
        return store.loginStatusMessage?.hasPrefix("Cancelled.") == true && protected.contains(request.action ?? "") ? "cancelled" : "completed"
    }
    private func failure(for request: HubRequest) -> Bool {
        switch request.action {
        case "refresh": store.refreshError != nil
        case "refreshProfile": store.profileRefreshError != nil || store.refreshError != nil
        case "refreshSaved": request.accountID.map { store.savedUsageErrors[$0] != nil } ?? true
        case "refreshAnalytics": store.analyticsRefreshError != nil
        case "add", "save", "switch", "recover", "forget", "reloadLogins": store.loginStatusIsError || store.loginRecoveryPending
        case "backupNow", "chooseBackupFolder": backups.statusMessage != nil
        default: false
        }
    }
}
