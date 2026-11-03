import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var store: RunwayStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Overview").font(.system(size: 27))
                        Text("Saved allowances and predicted capacity · Auto-refresh every 15 min")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(store.isRefreshing ? "Refreshing…" : "Refresh usage") {
                        Task { await store.refreshActiveAccount() }
                    }.disabled(store.loginActionsDisabled || store.loginRecoveryPending)
                }
                if let error = store.refreshError { Text(error).font(.caption).foregroundStyle(.red) }
                if store.activeAccountID == nil {
                    Text("Current sign-in is unknown until Runway refreshes or verifies it.").font(.caption).foregroundStyle(.secondary)
                }
                CapacityGraphView(expanded: true)
                if store.dashboardAccounts.isEmpty {
                    Text(store.accounts.isEmpty ? "Refresh to discover your signed-in account." : "Activate accounts in Settings to show them here.")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .top)], spacing: 12) {
                    ForEach(store.dashboardAccounts) { account in
                        AccountCard(account: account, isActive: account.id == store.activeAccountID, showsBenefits: true)
                    }
                }
                if let message = store.loginStatusMessage {
                    Text(message).font(.caption).foregroundStyle(store.loginStatusIsError ? Color.red : .secondary)
                }
                Text("Saved readings stay visible during refresh. Passed resets are assumptions; forecasts estimate the tracked allowance and cannot guarantee access.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28)
        }.background(.white)
    }
}

struct AccountBenefitsView: View {
    let account: CodexAccount
    var fullDetails = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            let details = account.bankedResetDetails
            let count = details?.remainingCount(at: now) ?? account.latestSnapshot?.bankedResetCount
            let expiry = details?.earliestExpiry(at: now)
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Credits", value: account.creditBalance?.displayBalance ?? "Unavailable")
                LabeledContent("Banked resets", value: count.map(String.init) ?? "Unavailable")
                if let expiry {
                    Text("\(fullDetails ? "Earliest expiry" : "Banked reset expires"): \(expiry.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(expiry.timeIntervalSince(now) <= 7 * 86_400 ? Color.orange : .secondary)
                } else if count != 0 {
                    Text("Banked reset expiry: Unavailable").foregroundStyle(.secondary)
                }
                if fullDetails {
                    if let balance = account.creditBalance {
                        Text("Credits updated: \(balance.fetchedAt.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                    }
                    if let details {
                        Text("Reset details updated: \(details.fetchedAt.formatted(date: .abbreviated, time: .shortened))").foregroundStyle(.secondary)
                        ForEach(Array(details.resets.enumerated()), id: \.offset) { index, reset in
                            VStack(alignment: .leading, spacing: 3) {
                                let status = reset.status == "available" && reset.expiresAt.map({ $0 <= now }) == true ? "Expired" : reset.status.capitalized
                                Text("Reset \(index + 1) · \(status)\(reset.supportedByPlan == false ? " · Not supported by this plan" : "")")
                                    .fontWeight(.medium)
                                Text("Granted: \(reset.grantedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unavailable")")
                                Text("Expires: \(reset.expiresAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Unavailable")")
                            }.padding(.top, 4)
                        }
                    }
                    Text("Allowance refills happen automatically. Banked resets must be redeemed before expiry.").foregroundStyle(.secondary)
                } else {
                    if let balance = account.creditBalance {
                        Text("Credits updated: \(StatusDates.elapsed(since: balance.fetchedAt, now: now))").foregroundStyle(.secondary)
                    }
                    if let details {
                        Text("Reset details updated: \(StatusDates.elapsed(since: details.fetchedAt, now: now))").foregroundStyle(.secondary)
                    }
                }
                if account.benefitsRefreshFailed == true {
                    Text("Credit or reset details could not refresh. Showing last saved values.").foregroundStyle(.orange)
                }
            }.font(.caption)
        }
    }
}
