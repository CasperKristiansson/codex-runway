import Charts
import SwiftUI

private enum AnalyticsRange: Int, CaseIterable, Identifiable {
    case week = 7, month = 30, year = 365
    var id: Int { rawValue }
    var label: String { switch self { case .week: "7d"; case .month: "30d"; case .year: "1y" } }
}

private struct AnalyticsPoint: Identifiable {
    let day: String
    let category: String
    let value: Double
    var id: String { "\(day)/\(category)" }
    var date: Date { ProfileCalendar.date(day) ?? .now }
}

private struct AnalyticsSeries {
    let points: [AnalyticsPoint]
    let categories: [(name: String, total: Double)]
    let total: Double
    let maximum: Double
}

struct AnalyticsView: View {
    @EnvironmentObject private var store: RunwayStore
    @Binding var selection: UUID?
    @State private var usageRange: AnalyticsRange = .month
    @State private var toolRange: AnalyticsRange = .week
    @State private var messageRange: AnalyticsRange = .week
    @State private var usageGroup = "Feature"
    @State private var messageGroup = "Model"
    @State private var planWindow = 10080
    @State private var planBreakdown = "thread_source"
    @State private var showsAllChats = false

    private let colors: [Color] = [
        Color(red: 0.16, green: 0.38, blue: 0.76),
        Color(red: 0.97, green: 0.47, blue: 0.18),
        Color(red: 0.24, green: 0.70, blue: 0.43),
        Color(red: 0.91, green: 0.34, blue: 0.65),
        Color(red: 0.47, green: 0.43, blue: 0.78)
    ]

    private var selectedAccount: CodexAccount? { store.accounts.first { $0.id == selection } }
    private var accounts: [CodexAccount] { selectedAccount.map { [$0] } ?? store.dashboardAccounts }
    private var saved: [(CodexAccount, AnalyticsArchive)] {
        accounts.compactMap { account in store.analyticsByAccount[account.id].map { (account, $0) } }
    }
    private func days(for range: AnalyticsRange) -> [String] {
        let calendar = ProfileCalendar.calendar
        let today = calendar.startOfDay(for: .now)
        return (0..<range.rawValue).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today).map(ProfileCalendar.key)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 27) {
                header
                if saved.isEmpty {
                    Text("Analytics will appear after this account has synced. Only the account currently signed in to Codex can be refreshed.")
                        .foregroundStyle(.secondary)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white, in: RoundedRectangle(cornerRadius: 16))
                } else {
                    usageSection
                    chatsSection
                    planSection
                    toolsSection
                    messagesSection
                }
            }
            .padding(.horizontal, 50)
            .padding(.vertical, 24)
        }
        .background(Color.white)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Analytics").font(.system(size: 27, weight: .regular))
                    Text("Saved usage across your Codex accounts")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await store.refreshAnalyticsForSignedInAccount() }
                } label: {
                    Label(store.isRefreshingAnalytics ? "Syncing…" : "Sync now", systemImage: "arrow.clockwise")
                }
                .disabled(store.isRefreshingAnalytics || store.activeAccountID == nil)
            }
            HStack {
                Picker("Account", selection: $selection) {
                    Text("All active accounts").tag(nil as UUID?)
                    ForEach(store.accounts) { account in
                        Text(account.name + (account.isEnabled ? "" : " · Inactive")).tag(Optional(account.id))
                    }
                }
                .labelsHidden()
                .frame(width: 260)
                Spacer()
                if let latest = saved.compactMap({ $0.1.messagesFetchedAt ?? $0.1.usageFetchedAt }).max() {
                    Text("Saved \(latest.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if selectedAccount == nil && saved.count < accounts.count {
                Text("\(saved.count) of \(accounts.count) active accounts have Analytics saved so far.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let error = store.analyticsRefreshError {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func rangePicker(_ selection: Binding<AnalyticsRange>) -> some View {
        Picker("Range", selection: selection) {
            ForEach(AnalyticsRange.allCases) { option in Text(option.label).tag(option) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 145)
    }

    private var usageSection: some View {
        let chartDays = days(for: usageRange)
        let series = makeSeries(usageBuckets(days: chartDays), days: chartDays, limit: 5)
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Usage history", subtitle: "Share of plan limits consumed by feature, model, or surface") {
                rangePicker($usageRange)
                Picker("Breakdown", selection: $usageGroup) {
                    Text("By feature").tag("Feature")
                    Text("By model").tag("Model")
                    Text("By surface").tag("Surface")
                }
                .labelsHidden().frame(width: 140)
            }
            VStack(alignment: .leading, spacing: 14) {
                if selectedAccount == nil {
                    Text("Combined percentage is weighted by each saved account's plan capacity.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                analyticsChart(series, kind: .bar, title: "Plan usage", unit: "% of limit", showsTotal: false)
                categorySummary(series, unit: "%")
            }
            .padding(18)
            .analyticsCard()
        }
    }

    private var planSection: some View {
        let periods = saved.flatMap { account, archive in
            archive.planPeriods.filter { $0.windowMinutes == planWindow }.map { (account.name, $0) }
        }.sorted { $0.1.startsAt > $1.1.startsAt }
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Plan usage history", subtitle: "Five-hour and weekly plan-limit periods") {
                Picker("Period", selection: $planWindow) {
                    Text("Weekly").tag(10080)
                    Text("Five-hour").tag(300)
                }
                .labelsHidden().frame(width: 140)
                Picker("Breakdown", selection: $planBreakdown) {
                    Text("By feature").tag("thread_source")
                    Text("By model").tag("model")
                    Text("By surface").tag("surface")
                }
                .labelsHidden().frame(width: 140)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Period")
                    Spacer()
                    Text("% of limit used")
                }
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color(white: 0.98))
                if periods.isEmpty {
                    Text("No saved periods yet").foregroundStyle(.secondary).padding(18)
                }
                ForEach(Array(periods.enumerated()), id: \.offset) { _, item in
                    planRow(accountName: item.0, period: item.1)
                    Divider()
                }
            }
            .analyticsCard()
        }
    }

    private var chatsSection: some View {
        let rows = saved.flatMap { account, archive in
            archive.chats.map { (account.name, $0) }
        }.filter { $0.1.weeklyLimitPercent != nil }
            .sorted { ($0.1.weeklyLimitPercent ?? 0) > ($1.1.weeklyLimitPercent ?? 0) }
        let displayed = showsAllChats ? rows : Array(rows.prefix(5))
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Top chats", subtitle: "Compare each saved task's plan and credit usage") { EmptyView() }
            VStack(spacing: 0) {
                HStack {
                    Text("Chat")
                    Spacer()
                    Text("% of weekly limit").frame(width: 120, alignment: .trailing)
                    Text("Credits used").frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.vertical, 11)
                .background(Color(white: 0.98))
                if displayed.isEmpty {
                    Text("No task-level usage saved yet").foregroundStyle(.secondary).padding(18)
                }
                ForEach(Array(displayed.enumerated()), id: \.offset) { _, item in
                    chatRow(accountName: item.0, chat: item.1)
                    Divider()
                }
            }
            .analyticsCard()
            if rows.count > 5 {
                Button(showsAllChats ? "Show less" : "Show more") { showsAllChats.toggle() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(white: 0.96), in: Capsule())
            }
        }
    }

    private func chatRow(accountName: String, chat: AnalyticsChat) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                if let value = chat.fiveHourLimitPercent {
                    HStack { Text("Five-hour limit"); Spacer(); Text(String(format: "%.2f%%", value)) }
                }
                ForEach(Array(chat.groups.enumerated()), id: \.offset) { _, item in
                    if let group = item.object {
                        HStack {
                            Text(group["model"]?.string ?? "Other")
                            Spacer()
                            Text(group["weekly_limit_percent"]?.number.map { String(format: "%.2f%%", $0) } ?? "—")
                        }
                    }
                }
                Text(chat.dataStatus.capitalized + " data")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.vertical, 8)
        } label: {
            HStack(spacing: 8) {
                Text(chat.title).lineLimit(1)
                if selectedAccount == nil { Text(accountName).foregroundStyle(.secondary).lineLimit(1) }
                Spacer(minLength: 8)
                Text(chat.weeklyLimitPercent.map { String(format: "%.2f%%", $0) } ?? "—")
                    .frame(width: 120, alignment: .trailing)
                Text(chat.balanceUsageCredits.flatMap(Double.init).map { String(format: "%.2f", $0) } ?? "—")
                    .frame(width: 90, alignment: .trailing)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func planRow(accountName: String, period: AnalyticsPlanPeriod) -> some View {
        let breakdown = period.breakdowns?.first { $0.dimension == planBreakdown }
        return DisclosureGroup {
            VStack(spacing: 7) {
                if let rows = breakdown?.rows.sorted(by: { $0.basisPoints > $1.basisPoints }), !rows.isEmpty {
                    ForEach(rows, id: \.key) { row in
                        HStack {
                            Text(featureName(row.key)).foregroundStyle(.secondary)
                            Spacer()
                            Text(percent(row.basisPoints)).monospacedDigit()
                        }
                    }
                } else {
                    Text("No breakdown saved for this period").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .padding(.vertical, 9)
        } label: {
            HStack {
                Text("\(String(period.startsAt.prefix(10))) – \(String(period.endsAt.prefix(10)))")
                if selectedAccount == nil {
                    Text(accountName).foregroundStyle(.secondary)
                }
                Spacer()
                Text(period.usedBasisPoints.map(percent) ?? "—")
                    .monospacedDigit().fontWeight(.medium)
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    private var toolsSection: some View {
        let chartDays = days(for: toolRange)
        let plugins = makeSeries(toolBuckets(\AnalyticsArchive.plugins, days: chartDays), days: chartDays, limit: 4)
        let skills = makeSeries(toolBuckets(\AnalyticsArchive.skills, days: chartDays), days: chartDays, limit: 4)
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Tool activity", subtitle: "Plugins and skills used over time") { rangePicker($toolRange) }
            VStack(spacing: 12) {
                analyticsChart(plugins, kind: .line, title: "Plugins called", unit: "calls")
                    .padding(18).analyticsCard()
                analyticsChart(skills, kind: .line, title: "Skills used", unit: "uses")
                    .padding(18).analyticsCard()
            }
        }
    }

    private var messagesSection: some View {
        let chartDays = days(for: messageRange)
        let series = makeSeries(messageBuckets(days: chartDays), days: chartDays, limit: 4)
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Messages", subtitle: "Messages sent over time") {
                rangePicker($messageRange)
                Picker("Breakdown", selection: $messageGroup) {
                    Text("By model").tag("Model")
                    Text("By surface").tag("Surface")
                }
                .labelsHidden().frame(width: 140)
            }
            analyticsChart(series, kind: .line, title: "Messages", unit: "messages")
                .padding(18).analyticsCard()
        }
    }

    private func sectionHeader<Controls: View>(_ title: String, subtitle: String,
                                                @ViewBuilder controls: () -> Controls) -> some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .medium))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            controls()
        }
    }

    private enum ChartKind { case line, bar }

    private func analyticsChart(_ series: AnalyticsSeries, kind: ChartKind, title: String, unit: String,
                                showsTotal: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTotal {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 12))
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(series.total.formatted(.number.precision(.fractionLength(unit == "% of limit" ? 1 : 0))))
                            .font(.system(size: 26, weight: .medium)).monospacedDigit()
                        Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            Chart(series.points) { point in
                if kind == .line {
                    LineMark(x: .value("Date", point.date), y: .value("Count", point.value))
                        .foregroundStyle(by: .value("Category", point.category))
                        .interpolationMethod(.linear)
                } else {
                    BarMark(x: .value("Date", point.date), y: .value("Usage", point.value))
                        .foregroundStyle(by: .value("Category", point.category))
                }
            }
            .chartForegroundStyleScale(domain: series.categories.map(\.name),
                                       range: Array(colors.prefix(series.categories.count)))
            .chartLegend(.hidden)
            .chartXScale(range: .plotDimension(startPadding: 25, endPadding: 50))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel() } }
            .chartYAxis { AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() } }
            .frame(height: 175)
            HStack(spacing: 14) {
                ForEach(Array(series.categories.enumerated()), id: \.offset) { index, category in
                    HStack(spacing: 4) {
                        Circle().fill(colors[index % colors.count]).frame(width: 8, height: 8)
                        Text(category.name).lineLimit(1)
                    }
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func categorySummary(_ series: AnalyticsSeries, unit: String) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 12) {
            ForEach(Array(series.categories.enumerated()), id: \.offset) { index, category in
                HStack(alignment: .top, spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(colors[index % colors.count]).frame(width: 3, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.name).font(.system(size: 11)).lineLimit(1)
                        Text(series.total > 0 ? String(format: "%.1f%%", category.total / series.total * 100) : "0%")
                            .font(.system(size: 15))
                    }
                }
            }
        }
    }

    private func messageBuckets(days: [String]) -> [String: [String: Double]] {
        var buckets: [String: [String: Double]] = [:]
        for (_, archive) in saved {
            for row in archive.messages where days.contains(row.date) {
                if messageGroup == "Model" {
                    let represented = (row.models ?? []).reduce(0) { $0 + ($1.turns ?? 0) }
                    for model in row.models ?? [] { add(Double(model.turns ?? 0), model.model, row.date, to: &buckets) }
                    let remainder = max(0, (row.totals?.turns ?? 0) - represented)
                    if remainder > 0 { add(Double(remainder), "Other", row.date, to: &buckets) }
                } else {
                    let represented = row.clients.reduce(0) { $0 + ($1.turns ?? 0) }
                    for client in row.clients { add(Double(client.turns ?? 0), surfaceName(client.clientId), row.date, to: &buckets) }
                    let remainder = max(0, (row.totals?.turns ?? 0) - represented)
                    if remainder > 0 { add(Double(remainder), "Other", row.date, to: &buckets) }
                }
            }
        }
        return buckets
    }

    private func toolBuckets(_ keyPath: KeyPath<AnalyticsArchive, [AnalyticsToolDay]>, days: [String]) -> [String: [String: Double]] {
        var buckets: [String: [String: Double]] = [:]
        for (_, archive) in saved {
            for row in archive[keyPath: keyPath] where days.contains(row.date) {
                for item in row.overviews {
                    add(Double(item.invocationCounts), item.displayName, row.date, to: &buckets)
                }
            }
        }
        return buckets
    }

    private func usageBuckets(days: [String]) -> [String: [String: Double]] {
        var buckets: [String: [String: Double]] = [:]
        let totalCapacity = saved.reduce(0.0) { $0 + ($1.0.capacityUnits ?? 1) }
        for (account, archive) in saved {
            let weight = selectedAccount == nil ? (account.capacityUnits ?? 1) / max(totalCapacity, 1) : 1
            for row in archive.usage where days.contains(row.date) {
                switch usageGroup {
                case "Model":
                    for model in row.models { add(model.credits * weight, model.model, row.date, to: &buckets) }
                case "Surface":
                    for (surface, value) in row.productSurfaceUsageValues {
                        add(value * weight, surfaceName(surface), row.date, to: &buckets)
                    }
                default:
                    for item in row.attribution {
                        add(item.value * weight, featureName(item.threadSource), row.date, to: &buckets)
                    }
                }
            }
        }
        return buckets
    }

    private func add(_ value: Double, _ name: String, _ date: String, to buckets: inout [String: [String: Double]]) {
        buckets[date, default: [:]][name, default: 0] += value
    }

    private func makeSeries(_ buckets: [String: [String: Double]], days: [String], limit: Int) -> AnalyticsSeries {
        var sums: [String: Double] = [:]
        for values in buckets.values {
            for (name, value) in values { sums[name, default: 0] += value }
        }
        let ordered = sums.filter { $0.value > 0 && $0.key.caseInsensitiveCompare("Other") != .orderedSame }
            .sorted { $0.value > $1.value }
        let selected = Array(ordered.prefix(limit)).map(\.key)
        let otherTotal = sums.filter { !selected.contains($0.key) }.values.reduce(0, +)
        let names = selected + (otherTotal > 0 ? ["Other"] : [])
        let categories = names.map { name -> (name: String, total: Double) in
            (name, name == "Other" ? otherTotal : sums[name] ?? 0)
        }
        let points = days.flatMap { date in
            names.map { name in
                let value = name == "Other"
                    ? buckets[date, default: [:]].filter { !selected.contains($0.key) }.values.reduce(0, +)
                    : buckets[date]?[name] ?? 0
                return AnalyticsPoint(day: date, category: name, value: value)
            }
        }
        let maximum = days.map { date in points.filter { $0.day == date }.reduce(0) { $0 + $1.value } }.max() ?? 0
        return AnalyticsSeries(points: points, categories: categories,
                               total: categories.reduce(0) { $0 + $1.total }, maximum: maximum)
    }

    private func featureName(_ key: String) -> String {
        switch key {
        case "task", "tasks", "user": "Tasks"
        case "memory_consolidation", "memory_update": "Memory updates"
        case "guardian_review", "auto_review": "Auto review"
        case "commit_message": "Commit messages"
        case "automation": "Automations"
        case "code_review": "Code review"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func surfaceName(_ key: String) -> String {
        switch key {
        case "desktop_app": "Desktop app"
        case "work_desktop": "Work desktop"
        case "vscode": "VS Code"
        case "cli": "CLI"
        case "web": "Web"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func percent(_ basisPoints: Double) -> String {
        let value = basisPoints / 100
        return value > 0 && value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
    }
}

private extension View {
    func analyticsCard() -> some View {
        background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.gray.opacity(0.18)))
    }
}
