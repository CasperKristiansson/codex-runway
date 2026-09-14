import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: RunwayStore

    var body: some View {
        Form {
            Section("Accounts") {
                Text("Use the arrows to set the account order in the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(store.accounts) { account in
                    AccountSettingsRow(account: account)
                }
                .onDelete(perform: store.removeAccounts)

                Text("Remove deletes the account’s saved data from this app. If it’s still signed in to Codex, the next refresh adds it again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 660, height: 510)
    }
}

private struct AccountSettingsRow: View {
    @EnvironmentObject private var store: RunwayStore
    let account: CodexAccount

    private var index: Int? { store.accounts.firstIndex { $0.id == account.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("\(account.name) · \(account.planName)")
                    .font(.headline)
                Text(account.email.isEmpty ? "No email available" : account.email)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text("Account \((index ?? 0) + 1)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    store.moveAccount(id: account.id, by: -1)
                } label: {
                    Label("Move up", systemImage: "arrow.up")
                }
                .disabled(index == nil || index == 0)
                .accessibilityLabel("Move \(account.name) up")
                Button {
                    store.moveAccount(id: account.id, by: 1)
                } label: {
                    Label("Move down", systemImage: "arrow.down")
                }
                .disabled(index == nil || index == store.accounts.count - 1)
                .accessibilityLabel("Move \(account.name) down")
                Button(role: .destructive) {
                    store.removeAccount(id: account.id)
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .modifier(ButtonHoverFeedback(tint: .red))
                .help("Remove \(account.name) and its saved usage from Codex Runway")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}
