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
                        AccountCard(account: account, isActive: account.id == store.activeAccountID)
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
