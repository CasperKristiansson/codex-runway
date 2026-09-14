import SwiftUI

private final class SettingsTabState: ObservableObject {
    @Published var tab = 0
}

struct SettingsView: View {
    @EnvironmentObject private var store: RunwayStore
    @StateObject private var state = SettingsTabState()

    var body: some View {
        VStack(spacing: 0) {
            Picker("Panel", selection: $state.tab) {
                Text("Settings").tag(0)
                Text("Profile").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            .padding(.top, 20)
            .padding(.bottom, 16)
            Divider()
            if state.tab == 0 { accountSettings } else { ProfileView() }
        }
        .frame(width: 840, height: 620)
        .background(Color.white)
        .preferredColorScheme(.light)
    }

    private var accountSettings: some View {
        Form {
            Section("Accounts") {
                Text("Use the arrows to set the account order in the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(store.accounts) { account in
                    AccountSettingsRow(account: account)
                }

                Text("Inactive accounts are hidden from the dashboard and excluded from the graph. Their saved history is kept, and you can activate them again anytime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding()
        .background(Color.white)
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
                .help(account.isEnabled ? "Deactivate this account without deleting its history" : "Activate this account in the dashboard and graph")
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
