import SwiftUI

@MainActor
final class SettingsNavigationState: ObservableObject {
    @Published var tab = 3 {
        didSet {
            if tab == 1 || tab == 2 { selectedAccountID = nil }
        }
    }
    @Published var selectedAccountID: UUID?

    func resetAccountFilter() { selectedAccountID = nil }

}

struct SettingsView: View {
    @EnvironmentObject private var store: RunwayStore
    @EnvironmentObject private var backupManager: RunwayBackupManager
    @ObservedObject var navigation: SettingsNavigationState

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $navigation.tab) {
                Text("Overview").tag(3)
                Text("Settings").tag(0)
                Text("History").tag(1)
                Text("Analytics").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 460)
            .padding(.top, 20)
            .padding(.bottom, 16)
            Divider()
            if navigation.tab == 3 { OverviewView() }
            else if navigation.tab == 0 { accountSettings }
            else if navigation.tab == 1 { ProfileView(selection: $navigation.selectedAccountID) }
            else { AnalyticsView(selection: $navigation.selectedAccountID) }
        }
        .frame(width: 840, height: 620)
        .background(Color.white)
        .preferredColorScheme(.light)
    }

    private var accountSettings: some View {
        Form {
            Section("Saved Logins") {
                HStack {
                    Button("Add Account…") { Task { await store.addLogin() } }
                        .disabled(store.loginActionsDisabled || store.loginRecoveryPending)
                    Button("Save") { Task { await store.saveCurrentLogin() } }
                        .disabled(store.loginActionsDisabled || store.loginRecoveryPending)
                        .help("Save the current Codex login")
                    if store.isManagingLogin { ProgressView().controlSize(.small) }
                    if store.loginCanCancel {
                        Button("Cancel") { store.cancelLoginOperation() }
                    }
                    Spacer()
                    Button { store.reloadSavedLogins() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(store.isManagingLogin)
                    .help("Reload saved logins")
                    .accessibilityLabel("Reload saved logins")
                }
                if store.loginRecoveryPending {
                    Button("Recover Switch") { Task { await store.recoverLogin() } }
                        .disabled(store.loginActionsDisabled)
                }
                ForEach(store.savedLogins) { login in
                    HStack {
                        Text(login.email).font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Switch") { Task { await store.switchLogin(id: login.id) } }
                            .disabled(store.loginActionsDisabled || store.loginRecoveryPending)
                            .accessibilityLabel("Switch to \(login.email) and open Codex")
                        Button("Forget") { store.forgetLogin(id: login.id) }
                            .disabled(store.loginActionsDisabled || store.loginRecoveryPending)
                            .help("Remove this saved login from Keychain; keep the current login and account history")
                    }
                }
                if let message = store.loginStatusMessage {
                    Text(message).font(.caption)
                        .foregroundStyle(store.loginStatusIsError ? Color.red : Color.secondary)
                }
            }
            Section("Accounts") {
                ForEach(store.accounts) { account in
                    AccountSettingsRow(account: account)
                }
            }
            Section("Backups") {
                HStack {
                    Button("Choose Folder…") { chooseBackupFolder() }
                    if let path = backupManager.destinationPath {
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    } else {
                        Text("Choose a folder to start backups.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle("Back up automatically", isOn: Binding(
                    get: { backupManager.isEnabled },
                    set: { backupManager.setEnabled($0) }
                ))
                .disabled(backupManager.destinationPath == nil)
                Stepper("Keep daily backups for \(backupManager.keepDailyDays) days", value: Binding(
                    get: { backupManager.keepDailyDays },
                    set: { backupManager.setKeepDailyDays($0) }
                ), in: 1...365)
                .disabled(backupManager.destinationPath == nil)
                HStack {
                    Button("Back Up Now") { Task { await backupManager.backUpNow() } }
                        .disabled(backupManager.destinationPath == nil || backupManager.isWorking)
                    if backupManager.isWorking { ProgressView().controlSize(.small) }
                    if let last = backupManager.lastCompletedAt {
                        Text("Last backup: \(last.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("One backup per day while Runway is running. Older daily copies are removed after the selected period; the first backup of each month is kept permanently. ZIP files are not encrypted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let message = backupManager.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
        .background(Color.white)
    }

    private func chooseBackupFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Use for Backups"
        if panel.runModal() == .OK, let url = panel.url {
            backupManager.chooseDestination(url)
        }
    }
}

private struct AccountSettingsRow: View {
    @EnvironmentObject private var store: RunwayStore
    let account: CodexAccount

    private var index: Int? { store.accounts.firstIndex { $0.id == account.id } }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(account.name) · \(account.planName)")
                    .font(.headline)
                Text(account.email.isEmpty ? "No email available" : account.email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button {
                    store.moveAccount(id: account.id, by: -1)
                } label: {
                    Label("Move up", systemImage: "arrow.up")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(AccountActionButtonStyle())
                .disabled(index == nil || index == 0)
                .accessibilityLabel("Move \(account.name) up")
                .help("Move up")
                Button {
                    store.moveAccount(id: account.id, by: 1)
                } label: {
                    Label("Move down", systemImage: "arrow.down")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(AccountActionButtonStyle())
                .disabled(index == nil || index == store.accounts.count - 1)
                .accessibilityLabel("Move \(account.name) down")
                .help("Move down")
                Button {
                    store.setAccountEnabled(id: account.id, enabled: !account.isEnabled)
                } label: {
                    Label(account.isEnabled ? "Active" : "Inactive", systemImage: account.isEnabled ? "checkmark.circle.fill" : "pause.circle")
                        .frame(width: 76)
                }
                .buttonStyle(AccountActionButtonStyle(tint: account.isEnabled ? Color(red: 0.02, green: 0.40, blue: 0.35) : .secondary, showsState: true))
                .accessibilityLabel("\(account.isEnabled ? "Deactivate" : "Activate") \(account.name)")
                .accessibilityValue(account.isEnabled ? "Active" : "Inactive")
                .help(account.isEnabled ? "Exclude from current capacity; saved History and Analytics stay included in All accounts" : "Activate this account in the dashboard and graph")
            }
            .fixedSize()
        }
        .padding(.vertical, 4)
    }
}

private struct AccountActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var tint: Color = .indigo
    var showsState = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .frame(minWidth: 12, minHeight: 30)
            .padding(.horizontal, 10)
            .foregroundStyle(showsState ? tint : Color.primary.opacity(0.8))
            .background {
                shape.fill(.white.opacity(0.75))
                    .overlay {
                        shape.fill(tint.opacity(configuration.isPressed && isEnabled ? 0.16 : 0))
                    }
            }
            .overlay { shape.strokeBorder(.primary.opacity(0.10), lineWidth: 1) }
            .contentShape(shape)
            .modifier(ButtonHoverFeedback(tint: tint, cornerRadius: 8, fillOpacity: 0.09))
            .opacity(isEnabled ? 1 : 0.3)
    }
}
