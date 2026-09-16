import AppKit
import SwiftUI

@main
@MainActor
final class CodexRunwayApp: NSObject, NSApplicationDelegate {
    private let store = RunwayStore()
    private var menuController: StatusPanelController?

    static func main() {
        let app = NSApplication.shared
        let delegate = CodexRunwayApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuController = StatusPanelController(store: store)
        store.startAutomaticRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stopAutomaticRefresh()
    }
}

struct MenuBarView: View {
    @EnvironmentObject private var store: RunwayStore
    let openSettings: () -> Void
    let openAccountHistory: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !store.dashboardAccounts.isEmpty {
                CapacityGraphView()
            }

            if store.accounts.isEmpty {
                Text("Your signed-in Codex account will appear after refresh. Other accounts are added when you sign in to them.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if store.dashboardAccounts.isEmpty {
                Text("All accounts are inactive. Activate an account in Settings to show it here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if store.dashboardAccounts.count > 3 {
                // The first three cards provide the scroll area's actual
                // content height, including wrapped dates and card spacing.
                accountList(Array(store.dashboardAccounts.prefix(3)))
                    .hidden()
                    .overlay {
                        ScrollView {
                            accountList(store.dashboardAccounts)
                        }
                    }
            } else {
                accountList(store.dashboardAccounts)
            }

            Divider()

            if let error = store.refreshError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text("Auto-refresh · 15 min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Current account refreshes every 15 minutes. Other accounts show their last saved status.")
                Spacer()
                Button(action: openSettings) {
                    Label("Settings", systemImage: "gearshape")
                }
                .buttonStyle(FooterButtonStyle(prominent: false))
                Button {
                    Task { await store.refreshActiveAccount() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .opacity(store.isRefreshing ? 0 : 1)
                        .overlay {
                            if store.isRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                }
                .buttonStyle(FooterButtonStyle(prominent: true))
                .disabled(store.isRefreshing)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(12)
        .frame(width: 420)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.white.opacity(0.3))
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.65), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .tint(.indigo)
        .preferredColorScheme(.light)
    }

    private func accountList(_ accounts: [CodexAccount]) -> some View {
        VStack(spacing: 8) {
            ForEach(accounts) { account in
                Button { openAccountHistory(account.id) } label: {
                    AccountCard(account: account, isActive: account.id == store.activeAccountID)
                }
                .buttonStyle(.plain)
                .help("Open \(account.name) history")
                .accessibilityLabel("Open \(account.name) history")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: RunwayBrand.accountMark)
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 22)
            Text("Codex Runway").font(.headline)
            Spacer()
            Text("Account status")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct FooterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .fixedSize()
            .frame(minHeight: 18)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(prominent ? Color.white : Color.primary.opacity(0.8))
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(prominent ? Color.indigo : Color.white.opacity(0.65))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(prominent ? Color.indigo.opacity(0.3) : Color.white.opacity(0.9), lineWidth: 1)
            }
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.5)
            .modifier(ButtonHoverFeedback(tint: prominent ? .white : .indigo))
    }
}

private struct AccountCard: View {
    let account: CodexAccount
    let isActive: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            card(now: context.date)
        }
    }

    private func card(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(account.name) · \(account.planName)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(account.displayEmail) · \(isActive ? "Current" : "Saved")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if let snapshot = account.latestSnapshot {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(snapshot.remainingPercent(at: now), specifier: "%.0f")% left")
                            .font(.subheadline.weight(.medium))
                        if snapshot.bankedResetCount > 0 {
                            Text("\(snapshot.bankedResetCount) banked")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("Not refreshed")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let snapshot = account.latestSnapshot {
                ProgressView(value: snapshot.remainingPercent(at: now), total: 100)
                    .tint(isActive ? Color.indigo.opacity(0.7) : Color.gray.opacity(0.55))
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let updated = "\(snapshot.assumesReset(at: context.date) ? "Reset assumed · Synced" : "Last updated"): \(StatusDates.elapsed(since: snapshot.capturedAt, now: context.date))"
                    let reset = snapshot.nextReset(at: context.date).map { "Next reset: \(StatusDates.reset($0, now: context.date))" } ?? "Next reset: Unknown"
                    ViewThatFits(in: .horizontal) {
                        HStack {
                            Text(updated).fixedSize()
                            Spacer(minLength: 12)
                            Text(reset).fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(updated)
                            Text(reset)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(isActive ? 0.75 : 0.5))
                .overlay {
                    if isActive {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.indigo.opacity(0.045))
                    }
                }
                .shadow(color: .black.opacity(0.035), radius: 3, y: 1)
        }
        .modifier(ButtonHoverFeedback(tint: .indigo, cornerRadius: 14, fillOpacity: 0.05))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isActive ? Color.indigo.opacity(0.8) : .white.opacity(0.8), lineWidth: isActive ? 2 : 1)
                .allowsHitTesting(false)
        }
    }
}
