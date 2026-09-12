import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: RunwayStore

    var body: some View {
        Form {
            Section("Accounts") {
                ForEach(store.accounts) { account in
                    AccountSettingsRow(account: account)
                }
                .onDelete(perform: store.removeAccounts)

                Button("Add account manually", action: store.addAccount)
            }

            Section("How V1 works") {
                Label("Every discovered account stays visible in the menu bar. Turning off planning excludes it only from the next-reset recommendation.", systemImage: "eye")
                Label("Refresh reads the signed-in Codex account's email, account ID, plan tier, and current rate-limit summary. A new identity gets a new row automatically.", systemImage: "arrow.clockwise")
                Label("No passwords, browser cookies, five-hour windows, token graphs, or automatic account switching are used in V1.", systemImage: "lock")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 660, height: 510)
    }
}

private struct AccountSettingsRow: View {
    @EnvironmentObject private var store: RunwayStore
    @State var account: CodexAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Account name", text: $account.name)
                    .textFieldStyle(.roundedBorder)
                TextField("Plan", text: $account.planName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                Toggle("Included in planning", isOn: $account.isEnabledForPlanning)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            HStack {
                TextField("Email (stored locally)", text: $account.email)
                    .textFieldStyle(.roundedBorder)
                Text(account.externalAccountID == nil ? "Not linked yet" : "Linked to active Codex account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: account) { _, changed in store.update(changed) }
    }
}
