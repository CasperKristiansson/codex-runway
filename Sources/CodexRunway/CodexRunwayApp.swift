import SwiftUI

@main
struct CodexRunwayApp: App {
    @StateObject private var store = RunwayStore()

    var body: some Scene {
        MenuBarExtra("Codex Runway", systemImage: "gauge.with.dots.needle.67percent") {
            MenuBarView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

private struct MenuBarView: View {
    @EnvironmentObject private var store: RunwayStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            ForEach(store.accounts) { account in
                AccountCard(account: account, isSelected: account.id == store.selectedAccountID)
                    .contentShape(.rect)
                    .onTapGesture { store.selectedAccountID = account.id }
            }

            Divider()

            if let selected = store.selectedAccount {
                ForecastCard(account: selected)
            }

            if let error = store.refreshError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Local snapshots only")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Settings") { openSettings() }
                Button(store.isRefreshing ? "Refreshing…" : "Refresh current") {
                    Task { await store.refreshActiveAccount() }
                }
                .disabled(store.isRefreshing)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(16)
        .frame(width: 390)
    }

    private var header: some View {
        HStack(alignment: .top) {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Runway").font(.headline)
                if let reset = store.nextEnabledReset {
                    Text("Next enabled reset \(reset, style: .relative)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Refresh an account to start planning")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

private struct AccountCard: View {
    @EnvironmentObject private var store: RunwayStore
    let account: CodexAccount
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(account.name) · \(account.planName)")
                        .font(.headline)
                    Text("\(account.displayEmail) · \(account.isEnabledForPlanning ? "Included in planning" : "Not in planning")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let snapshot = account.latestSnapshot {
                    Text("\(Forecasting.formatPercent(snapshot.usedPercent)) used")
                        .font(.subheadline.weight(.medium))
                } else {
                    Text("Not refreshed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = account.latestSnapshot {
                ProgressView(value: snapshot.usedPercent, total: 100)
                    .tint(.secondary)
                HStack {
                    Text("Resets \(snapshot.resetAt, style: .date) · \(snapshot.resetAt, style: .time)")
                    Spacer()
                    if snapshot.bankedResetCount > 0 {
                        Text("\(snapshot.bankedResetCount) banked")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("Updated \(snapshot.capturedAt, style: .relative)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1))
    }
}

private struct ForecastCard: View {
    @EnvironmentObject private var store: RunwayStore
    let account: CodexAccount

    var body: some View {
        let state = store.forecast(for: account)
        VStack(alignment: .leading, spacing: 5) {
            Text("Will \(account.name) last until its next reset?")
                .font(.headline)
            Text(state.headline)
                .font(.title3.weight(.semibold))
            forecastDetail(state)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func forecastDetail(_ state: ForecastState) -> some View {
        switch state {
        case .learning(let count):
            Text("Need at least three saved snapshots in this reset window. Currently \(count).")
        case .likelyLasts(_, let rate), .likelyShort(_, let rate):
            Text("Based on a median burn of \(String(format: "%.2f", rate)) percentage points/hour in this reset window.")
        case .needsRefresh:
            Text("Refresh while this account is active in Codex.")
        case .resetDue:
            Text("Refresh to capture the new reset window.")
        }
    }
}
