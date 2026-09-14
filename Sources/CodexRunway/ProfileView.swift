import SwiftUI

private final class ProfileViewState: ObservableObject {
    @Published var selection: UUID?
    @Published var mode = ProfileHeatmap.Mode.daily
}

struct ProfileView: View {
    @EnvironmentObject private var store: RunwayStore
    @StateObject private var state = ProfileViewState()
    private var selection: UUID? { state.selection }
    private var mode: ProfileHeatmap.Mode { state.mode }

    private var selectedAccount: CodexAccount? { store.accounts.first { $0.id == selection } }
    private var included: [CodexAccount] { selectedAccount.map { [$0] } ?? store.dashboardAccounts }
    private var profile: AccountProfile? {
        if let selectedAccount { return selectedAccount.profile }
        return AccountProfile.combined(included.compactMap(\.profile), now: .now)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                HStack {
                    Picker("Account", selection: $state.selection) {
                        Text("All active accounts").tag(nil as UUID?)
                        ForEach(store.accounts) { account in
                            Text(account.name + (account.isEnabled ? "" : " · Inactive")).tag(Optional(account.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                    Spacer()
                    if let error = store.profileRefreshError ?? store.refreshError {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .help(error)
                            .accessibilityLabel("Profile refresh error: \(error)")
                    }
                    Button {
                        Task { await store.refreshProfile() }
                    } label: {
                        Label(store.isRefreshingProfile ? "Refreshing…" : "Refresh profile", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                    .help("Fetch the currently signed-in account, even if its saved profile is less than 6h old.")
                }
                .padding(.bottom, 22)

                ZStack {
                    Circle().fill(Color(red: 0.95, green: 0.77, blue: 0.19))
                    if let account = selectedAccount {
                        Text(String(account.name.prefix(2)).uppercased()).font(.system(size: 28, weight: .light)).foregroundStyle(.white)
                    } else {
                        Image(systemName: "person.2.fill").font(.system(size: 26)).foregroundStyle(.white)
                    }
                }
                .frame(width: 76, height: 76)
                Text(selectedAccount?.name ?? "All active accounts")
                    .font(.system(size: 23)).padding(.top, 16)
                HStack(spacing: 8) {
                    Text(selectedAccount?.displayEmail ?? "\(included.filter { $0.profile != nil }.count)/\(included.count) profiles saved")
                    if let account = selectedAccount {
                        Text(account.planName).padding(.horizontal, 7).padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(.gray.opacity(0.18)))
                    }
                }
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.top, 6)

                stats.padding(.top, 32)
                HStack {
                    Text("Token activity").font(.system(size: 14, weight: .medium))
                    Spacer()
                    ForEach(ProfileHeatmap.Mode.allCases, id: \.self) { item in
                        Button(item.rawValue) { state.mode = item }
                            .buttonStyle(.plain)
                            .foregroundStyle(mode == item ? Color.primary : .secondary)
                            .padding(.horizontal, 3)
                            .modifier(ButtonHoverFeedback(tint: .blue, cornerRadius: 4))
                    }
                }
                .padding(.top, 32).padding(.bottom, 12)
                ProfileHeatmap(days: profile?.dailyUsageBuckets ?? [], mode: mode)
                    .opacity(profile?.hasDailyData == true ? 1 : 0.45)
            }
            .padding(.horizontal, 50).padding(.vertical, 20)
        }
        .background(.white)
    }

    private var stats: some View {
        HStack(spacing: 0) {
            stat(ProfileFormat.tokens(profile?.summary.lifetimeTokens), "Lifetime tokens")
            Divider().frame(height: 36)
            stat(ProfileFormat.tokens(profile?.summary.peakDailyTokens), "Peak tokens")
            Divider().frame(height: 36)
            stat(ProfileFormat.duration(profile?.summary.longestRunningTurnSec), "Longest chat")
                .help("Longest-running agent turn reported by Codex")
            Divider().frame(height: 36)
            stat(ProfileFormat.days(profile?.summary.currentStreakDays), "Current streak")
            Divider().frame(height: 36)
            stat(ProfileFormat.days(profile?.summary.longestStreakDays), "Longest streak")
        }
        .padding(.vertical, 12)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.gray.opacity(0.14)))
    }

    private func stat(_ value: String, _ title: String) -> some View {
        VStack(spacing: 4) {
            Text(value).foregroundStyle(.primary)
            Text(title).foregroundStyle(.secondary)
        }
        .font(.system(size: 13)).frame(maxWidth: .infinity)
    }

}

private final class HeatmapHoverState: ObservableObject {
    struct Cell: Equatable { let week: Int; let row: Int }
    @Published var cell: Cell?
}

struct ProfileHeatmap: View {
    enum Mode: String, CaseIterable { case daily = "Daily", weekly = "Weekly", cumulative = "Cumulative" }
    let days: [ProfileDay]
    let mode: Mode
    var now: Date = .now
    @StateObject private var hover = HeatmapHoverState()

    private var weeks: [[Date]] {
        let calendar = ProfileCalendar.calendar
        let today = calendar.startOfDay(for: now)
        let first = today.addingTimeInterval(-364 * 86_400)
        let sunday = first.addingTimeInterval(-Double(calendar.component(.weekday, from: first) - 1) * 86_400)
        let count = Int(today.timeIntervalSince(sunday) / (7 * 86_400)) + 1
        return (0..<count).map { week in
            (0..<7).map { sunday.addingTimeInterval(Double(week * 7 + $0) * 86_400) }
        }
    }

    var body: some View {
        let weeks = weeks
        let values = Dictionary(days.map { ($0.startDate, $0.tokens) }, uniquingKeysWith: { _, new in new })
        let weekly = weeks.map { week in week.reduce(Int64(0)) { $0 + (values[ProfileCalendar.key($1)] ?? 0) } }
        let cumulative = weekly.indices.map { weekly.prefix($0 + 1).reduce(Int64(0), +) }
        let totals = mode == .cumulative ? cumulative : weekly
        let maximum = max(1, mode == .daily ? (days.map(\.tokens).max() ?? 0) : (totals.max() ?? 0))
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 3) {
                ForEach(weeks.indices, id: \.self) { week in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { row in
                            let date = weeks[week][row]
                            let value = mode == .daily ? values[ProfileCalendar.key(date)] ?? 0 : totals[week]
                            let ratio = Double(value) / Double(maximum)
                            let level = mode == .daily ? (value == 0 ? 0 : max(1, Int(ceil(ratio * 4)))) : (row >= 7 - Int(ceil(ratio * 7)) && value > 0 ? 4 : 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(color(level))
                                .frame(height: 11)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 3)
                                        .strokeBorder(Color.blue, lineWidth: hover.cell == .init(week: week, row: row) ? 1.5 : 0)
                                }
                                // Weekly bars represent a total, not a value for
                                // each weekday; keep the current week's bar visible.
                                .opacity(mode != .daily || date <= now ? 1 : 0)
                                .contentShape(Rectangle())
                                .onHover { entered in
                                    let cell = HeatmapHoverState.Cell(week: week, row: row)
                                    if entered && (mode != .daily || date <= now) { hover.cell = cell }
                                    else if hover.cell == cell { hover.cell = nil }
                                }
                                .accessibilityLabel("\(ProfileCalendar.key(date)), \(value) tokens")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .overlay {
                GeometryReader { geometry in
                    let stride = (geometry.size.width + 3) / Double(weeks.count)
                    if let cell = hover.cell, weeks.indices.contains(cell.week) {
                        let date = mode == .daily ? weeks[cell.week][cell.row] : weeks[cell.week][0]
                        let value = mode == .daily ? values[ProfileCalendar.key(date)] ?? 0 : totals[cell.week]
                        VStack(alignment: .leading, spacing: 7) {
                            Text(mode == .daily ? ProfileFormat.day(date) : "Week of \(ProfileFormat.day(date))")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(white: 0.42))
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(ProfileFormat.tokens(value))
                                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color(red: 0.18, green: 0.40, blue: 0.79))
                                    .monospacedDigit()
                                Text("tokens")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color(white: 0.42))
                            }
                            if mode == .cumulative {
                                Text("Cumulative total")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color(white: 0.5))
                            }
                        }
                        .padding(.horizontal, 13)
                        .padding(.vertical, 11)
                        .frame(width: 190, alignment: .leading)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.black.opacity(0.07)))
                        .shadow(color: .black.opacity(0.09), radius: 10, y: 4)
                        .position(x: min(max((Double(cell.week) + 0.5) * stride, 95), geometry.size.width - 95),
                                  y: Double(cell.row) * 14 - (mode == .cumulative ? 52 : 43))
                        .allowsHitTesting(false)
                    }
                }
                .allowsHitTesting(false)
            }
            .zIndex(1)
            .onDisappear { hover.cell = nil }
            .onChange(of: mode) { _, _ in hover.cell = nil }
            .onChange(of: days) { _, _ in hover.cell = nil }
            HStack(spacing: 3) {
                ForEach(weeks.indices, id: \.self) { index in
                    let date = weeks[index][0]
                    let month = ProfileCalendar.calendar.component(.month, from: date)
                    let previousMonth = index > 0 ? ProfileCalendar.calendar.component(.month, from: weeks[index - 1][0]) : -1
                    Color.clear.frame(height: 15).frame(maxWidth: .infinity)
                        .overlay(alignment: .leading) {
                            if month != previousMonth && index > 0 && index < weeks.count - 1 {
                                Text(ProfileCalendar.calendar.shortMonthSymbols[month - 1])
                                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                            }
                        }
                }
            }
        }
    }

    private func color(_ level: Int) -> Color {
        level == 0 ? Color(white: 0.95) : Color(red: 0.18, green: 0.40, blue: 0.79).opacity([0, 0.22, 0.43, 0.67, 1][level])
    }
}
