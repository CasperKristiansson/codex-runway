import Foundation
import SwiftUI
import AppKit

@MainActor
final class RunwayStore: ObservableObject {
    @Published private(set) var accounts: [CodexAccount] = []
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var analyticsByAccount: [UUID: AnalyticsArchive] = [:]
    @Published private(set) var isRefreshingAnalytics = false
    @Published var analyticsRefreshError: String?
    @Published var isRefreshing = false
    @Published var refreshError: String?
    @Published var profileRefreshError: String?
    @Published private(set) var isRefreshingProfile = false

    private let defaultsKey = "codex-runway.accounts.v1"
    var dashboardAccounts: [CodexAccount] { accounts.filter(\.isEnabled) }
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let defaults: UserDefaults
    private let forecastJournal: ForecastJournal
    private let analyticsArchiveStore: AnalyticsArchiveStore
    private let analyticsClient: AnalyticsClient
    private let analyticsEnabled: Bool
    private(set) var forecastRecordingError: String?
    private let readAccount: @MainActor () async throws -> ActiveCodexAccount
    private let readProfile: @MainActor () async throws -> ActiveAccountProfile
    private let now: () -> Date

    init(defaults: UserDefaults = .standard,
         forecastJournal: ForecastJournal = ForecastJournal(),
         analyticsArchiveStore: AnalyticsArchiveStore = AnalyticsArchiveStore(),
         analyticsClient: AnalyticsClient = AnalyticsClient(),
         analyticsEnabled: Bool = true,
         now: @escaping () -> Date = { .now },
         readProfile: @escaping @MainActor () async throws -> ActiveAccountProfile = {
             try await CodexAppServerClient().readActiveProfile()
         }, readAccount: @escaping @MainActor () async throws -> ActiveCodexAccount = {
        try await CodexAppServerClient().readActiveAccount()
    }) {
        self.defaults = defaults
        self.forecastJournal = forecastJournal
        self.analyticsArchiveStore = analyticsArchiveStore
        self.analyticsClient = analyticsClient
        self.analyticsEnabled = analyticsEnabled
        self.readAccount = readAccount
        self.readProfile = readProfile
        self.now = now
        load()
        for account in accounts {
            if let archive = try? analyticsArchiveStore.load(accountID: account.id),
               archive.accountID == account.externalAccountID {
                analyticsByAccount[account.id] = archive
            }
        }
    }

    func startAutomaticRefresh(interval: TimeInterval = 15 * 60) {
        guard refreshTimer == nil else { return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshActiveAccount() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshActiveAccount() }
        }
        Task { [weak self] in
            guard let self else { return }
            let hasSavedAccounts = !self.accounts.isEmpty
            let succeeded = await self.refreshActiveAccount(presentFailure: !hasSavedAccounts)
            if !succeeded {
                try? await Task.sleep(for: .seconds(10))
                _ = await self.refreshActiveAccount(presentFailure: !hasSavedAccounts)
            }
        }
    }

    func stopAutomaticRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func addAccount() {
        let account = CodexAccount(name: "Account \(accounts.count + 1)", planName: "Custom")
        accounts.append(account)
        save()
    }

    func setAccountEnabled(id: UUID, enabled: Bool) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[index].isEnabled = enabled
        save()
    }

    func removeAccount(id: UUID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        removeAccounts(at: IndexSet(integer: index))
    }

    func removeAccounts(at offsets: IndexSet) {
        let removed = offsets.compactMap { accounts.indices.contains($0) ? accounts[$0].id : nil }
        accounts.remove(atOffsets: offsets)
        if let activeAccountID, removed.contains(activeAccountID) { self.activeAccountID = nil }
        for id in removed {
            analyticsByAccount.removeValue(forKey: id)
            do { try analyticsArchiveStore.remove(accountID: id) }
            catch { NSLog("Codex Runway analytics removal failed: %@", error.localizedDescription) }
        }
        save()
    }

    func update(_ account: CodexAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        // Settings may hold an older copy while a background refresh completes.
        accounts[index].name = account.name
        accounts[index].email = account.email
        accounts[index].planName = account.planName
        save()
    }

    @discardableResult
    func moveAccount(id: UUID, by offset: Int) -> Bool {
        guard offset == -1 || offset == 1,
              let index = accounts.firstIndex(where: { $0.id == id }),
              accounts.indices.contains(index + offset) else { return false }
        return moveAccount(id: id, to: accounts[index + offset].id)
    }

    @discardableResult
    func moveAccount(id: UUID, to targetID: UUID) -> Bool {
        guard id != targetID,
              let source = accounts.firstIndex(where: { $0.id == id }),
              let destination = accounts.firstIndex(where: { $0.id == targetID }) else { return false }
        let account = accounts.remove(at: source)
        accounts.insert(account, at: destination)
        save()
        return true
    }

    /// Refreshes whichever account is currently signed in to Codex. Accounts are
    /// discovered by stable account ID and email, never by their plan tier.
    @discardableResult
    func refreshActiveAccount(forceProfile: Bool = false, presentFailure: Bool = true) async -> Bool {
        guard !isRefreshing else { return false }
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }

        do {
            let response = try await readAccount()
            guard let primaryReset = response.rateLimits.rateLimits.primary.resetsAt else {
                throw CodexAppServerError.invalidResponse
            }
            let index = resolveOrCreateAccount(for: response)
            var snapshot = UsageSnapshot(
                capturedAt: now(),
                usedPercent: response.rateLimits.rateLimits.primary.usedPercent,
                resetAt: Date(timeIntervalSince1970: primaryReset),
                bankedResetCount: response.rateLimits.rateLimitResetCredits?.availableCount ?? 0
            )
            let planName = Self.displayPlanName(
                response.identity.account?.planType ?? response.rateLimits.rateLimits.planType
            )
            if let backendID = response.rateLimits.accountId, !backendID.isEmpty {
                for otherIndex in accounts.indices where otherIndex != index && accounts[otherIndex].externalAccountID == backendID {
                    accounts[otherIndex].externalAccountID = nil
                }
                accounts[index].externalAccountID = backendID
            }
            if let email = response.identity.account?.email, !email.isEmpty {
                accounts[index].email = email
            }
            accounts[index].planName = planName
            snapshot.capacityUnits = accounts[index].capacityUnits
            snapshot.windowDurationMins = response.rateLimits.rateLimits.primary.windowDurationMins
            snapshot.secondaryUsedPercent = response.rateLimits.rateLimits.secondary?.usedPercent
            snapshot.secondaryResetAt = response.rateLimits.rateLimits.secondary?.resetsAt.map { Date(timeIntervalSince1970: $0) }
            accounts[index].snapshots.append(snapshot)
            for accountIndex in accounts.indices {
                accounts[accountIndex].snapshots = CapacityForecast.retainedSnapshots(accounts[accountIndex].snapshots, now: snapshot.capturedAt)
                let cutoff = ProfileCalendar.key(HistoryRetention.cutoff(now: now()))
                accounts[accountIndex].profile?.dailyUsageBuckets.removeAll { $0.startDate < cutoff }
            }
            activeAccountID = accounts[index].id
            save()
            do {
                try forecastJournal.record(accounts: accounts, now: snapshot.capturedAt)
                forecastRecordingError = nil
            } catch {
                // A diagnostic write failure must not discard a successful quota
                // refresh or change the displayed forecast.
                forecastRecordingError = error.localizedDescription
                NSLog("Codex Runway forecast recording failed: %@", error.localizedDescription)
            }
            await refreshProfileIfNeeded(accountID: accounts[index].id, force: forceProfile)
            if analyticsEnabled, let externalAccountID = accounts[index].externalAccountID {
                let accountID = accounts[index].id
                Task { await self.refreshAnalytics(accountID: accountID, externalAccountID: externalAccountID) }
            }
            return true
        } catch {
            activeAccountID = nil
            if presentFailure { refreshError = error.localizedDescription }
            return false
        }
    }

    func refreshAnalyticsForSignedInAccount() async {
        guard let activeAccountID,
              let account = accounts.first(where: { $0.id == activeAccountID }),
              let externalAccountID = account.externalAccountID else { return }
        await refreshAnalytics(accountID: activeAccountID, externalAccountID: externalAccountID, forceChats: true)
    }

    private func refreshAnalytics(accountID: UUID, externalAccountID: String, forceChats: Bool = false) async {
        guard !isRefreshingAnalytics else { return }
        isRefreshingAnalytics = true
        analyticsRefreshError = nil
        defer { isRefreshingAnalytics = false }
        let now = self.now()
        var archive = analyticsByAccount[accountID] ?? AnalyticsArchive(accountID: externalAccountID)
        guard archive.accountID == externalAccountID else {
            analyticsRefreshError = "Saved Analytics belong to a different account."
            return
        }
        let backfill = archive.lastBackfillAt.map { now.timeIntervalSince($0) >= 7 * 86_400 } ?? true
        do {
            let fetchChats = forceChats || (archive.chatsFetchedAt.map { now.timeIntervalSince($0) >= 15 * 60 } ?? true)
            var threadError: String?
            var threads: [AnalyticsThreadSummary] = []
            if fetchChats {
                do {
                    threads = try await CodexAppServerClient().readAnalyticsThreads(
                        since: (backfill || archive.chatsFetchedAt == nil)
                            ? HistoryRetention.cutoff(now: now) : now.addingTimeInterval(-30 * 86_400))
                } catch { threadError = "Top chats: \(error.localizedDescription)" }
            }
            var update = try await analyticsClient.fetch(accountID: externalAccountID, initial: backfill,
                                                         threads: threads, now: now)
            if let threadError { update.errors.append(threadError) }
            guard accounts.contains(where: { $0.id == accountID && $0.externalAccountID == externalAccountID }) else { return }
            archive.apply(update, now: now, wasBackfill: backfill)
            try analyticsArchiveStore.save(archive, accountID: accountID)
            analyticsByAccount[accountID] = archive
            if !update.errors.isEmpty { analyticsRefreshError = update.errors.joined(separator: " · ") }
        } catch {
            analyticsRefreshError = error.localizedDescription
        }
    }

    func refreshProfile() async {
        // Re-resolve the signed-in identity before a manual request; a selected
        // saved profile is never used as an authentication target.
        await refreshActiveAccount(forceProfile: true)
    }

    private func refreshProfileIfNeeded(accountID: UUID, force: Bool) async {
        guard let account = accounts.first(where: { $0.id == accountID }),
              force || AccountProfile.needsRefresh(account.profile, now: now()) else { return }
        isRefreshingProfile = true
        profileRefreshError = nil
        defer { isRefreshingProfile = false }
        do {
            let response = try await readProfile()
            guard normalizedEmail(response.identity.account?.email) == normalizedEmail(account.email),
                  let index = accounts.firstIndex(where: { $0.id == accountID }) else {
                throw CodexAppServerError.server("Account changed during profile refresh. Try again.")
            }
            accounts[index].profile = AccountProfile.merging(response.usage, into: accounts[index].profile, now: now())
            save()
        } catch {
            // A failed profile request must not erase quota data, its current
            // identity, or the last successful profile/freshness timestamp.
            profileRefreshError = error.localizedDescription
        }
    }

    private func resolveOrCreateAccount(for response: ActiveCodexAccount) -> Int {
        let email = normalizedEmail(response.identity.account?.email)
        let backendID = response.rateLimits.accountId?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Email is the user-recognisable identity. If legacy data contains a
        // stale ID on a different row, prefer the email row and repair that ID
        // during the refresh rather than overwriting either account's data.
        if let email,
           let emailIndex = accounts.firstIndex(where: { normalizedEmail($0.email) == email }) {
            return emailIndex
        }

        if let backendID, !backendID.isEmpty,
           let idIndex = accounts.firstIndex(where: { $0.externalAccountID == backendID }) {
            return idIndex
        }

        let discovered = CodexAccount(
            name: suggestedName(for: email),
            email: email ?? "",
            planName: Self.displayPlanName(
                response.identity.account?.planType ?? response.rateLimits.rateLimits.planType
            ),
            externalAccountID: (backendID?.isEmpty == false) ? backendID : nil
        )
        accounts.append(discovered)
        return accounts.index(before: accounts.endIndex)
    }

    private func normalizedEmail(_ value: String?) -> String? {
        guard let value else { return nil }
        let email = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return email.isEmpty ? nil : email
    }

    private func suggestedName(for email: String?) -> String {
        guard let email, let localPart = email.split(separator: "@", maxSplits: 1).first, !localPart.isEmpty else {
            return "Account \(accounts.count + 1)"
        }
        let base = String(localPart)
        let usedNames = Set(accounts.map { $0.name.lowercased() })
        guard usedNames.contains(base.lowercased()) else { return base }
        var suffix = 2
        while usedNames.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private static func displayPlanName(_ backendPlanType: String?) -> String {
        switch backendPlanType?.lowercased() {
        case "pro":
            return "Pro 20×"
        case "prolite":
            return "Pro 5×"
        case let planType? where !planType.isEmpty:
            return "ChatGPT \(planType)"
        default:
            return "Unknown plan"
        }
    }

    private func load() {
        if
            let data = defaults.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([CodexAccount].self, from: data)
        {
            accounts = decoded
        } else {
            // New installs start empty. Refreshing any signed-in account adds a
            // row; the app has no opinion about how many accounts exist or tiers.
            accounts = []
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) { defaults.set(data, forKey: defaultsKey) }
    }
}
