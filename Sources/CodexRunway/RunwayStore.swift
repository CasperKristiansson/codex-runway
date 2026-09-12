import Foundation
import SwiftUI

@MainActor
final class RunwayStore: ObservableObject {
    @Published private(set) var accounts: [CodexAccount] = []
    @Published var selectedAccountID: UUID?
    @Published var isRefreshing = false
    @Published var refreshError: String?

    private let defaultsKey = "codex-runway.accounts.v1"
    private let selectionKey = "codex-runway.selected-account.v1"

    init() {
        load()
    }

    var selectedAccount: CodexAccount? {
        accounts.first { $0.id == selectedAccountID } ?? accounts.first
    }

    var nextEnabledReset: Date? {
        accounts
            .filter(\.isEnabledForPlanning)
            .compactMap(\.latestSnapshot)
            .map(\.resetAt)
            .filter { $0 > .now }
            .min()
    }

    func forecast(for account: CodexAccount) -> ForecastState {
        Forecasting.forecast(for: account)
    }

    func addAccount() {
        let account = CodexAccount(name: "Account \(accounts.count + 1)", planName: "Custom")
        accounts.append(account)
        selectedAccountID = account.id
        save()
    }

    func removeAccounts(at offsets: IndexSet) {
        let removed = offsets.compactMap { accounts.indices.contains($0) ? accounts[$0].id : nil }
        accounts.remove(atOffsets: offsets)
        if removed.contains(selectedAccountID ?? UUID()) { selectedAccountID = accounts.first?.id }
        save()
    }

    func update(_ account: CodexAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        save()
    }

    /// Refreshes whichever account is currently signed in to Codex. Accounts are
    /// discovered by stable account ID and email, never by their plan tier.
    func refreshActiveAccount() async {
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }

        do {
            let response = try await CodexAppServerClient().readActiveAccount()
            let index = resolveOrCreateAccount(for: response)
            let snapshot = UsageSnapshot(
                usedPercent: response.rateLimits.rateLimits.primary.usedPercent,
                resetAt: Date(timeIntervalSince1970: response.rateLimits.rateLimits.primary.resetsAt),
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
            accounts[index].snapshots.append(snapshot)
            accounts[index].snapshots = Array(accounts[index].snapshots.sorted { $0.capturedAt < $1.capturedAt }.suffix(180))
            selectedAccountID = accounts[index].id
            save()
        } catch {
            refreshError = error.localizedDescription
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
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode([CodexAccount].self, from: data)
        {
            accounts = decoded
        } else {
            // New installs start empty. Refreshing any signed-in account adds a
            // row; the app has no opinion about how many accounts exist or tiers.
            accounts = []
        }

        if let storedID = UserDefaults.standard.string(forKey: selectionKey), let id = UUID(uuidString: storedID), accounts.contains(where: { $0.id == id }) {
            selectedAccountID = id
        } else {
            selectedAccountID = accounts.first?.id
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: defaultsKey) }
        UserDefaults.standard.set(selectedAccountID?.uuidString, forKey: selectionKey)
    }
}
