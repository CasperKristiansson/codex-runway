import Charts
import SwiftUI
import AppKit

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

private struct AnalyticsChatDisplayRow: Identifiable {
    let accountName: String
    let chat: AnalyticsChat
    var id: String { chat.threadID }
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
        let selectableDays = Set(chartDays)
        let buckets = usageBuckets(days: chartDays)
        let periodTotals = AnalyticsUsageBreakdown.totals(buckets)
        let series = makeSeries(buckets, days: chartDays, limit: 5)
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Usage history", subtitle: "Plan usage by day, feature, model, or surface") {
                rangePicker($usageRange)
                Picker("Breakdown", selection: $usageGroup) {
                    Text("By feature").tag("Feature")
                    Text("By model").tag("Model")
                    Text("By surface").tag("Surface")
                }
                .labelsHidden().frame(width: 140)
            }
            UsageDaySelectionHost { daySelection in
                let selectedDay = daySelection.wrappedValue.flatMap { selectableDays.contains($0) ? $0 : nil }
                return VStack(alignment: .leading, spacing: 14) {
                    if selectedAccount == nil {
                        Text("Combined percentage is weighted by each saved account's plan capacity.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    analyticsChart(series, kind: .bar, title: "Plan usage", unit: "% of limit", showsTotal: false,
                                   selection: daySelection, selectedDay: selectedDay, selectionDays: selectableDays,
                                   isUsageChart: true)
                    Text(selectedDay.map { "\($0) · share of that day's usage" }
                         ?? "\(usageRange.label) total · share of period usage")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    categorySummary(selectedDay.flatMap { buckets[$0] } ?? periodTotals)
                }
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
        let chatSyncTime = saved.count == 1 ? saved.first?.1.chatsFetchedAt : nil
        let subtitle = chatSyncTime.map {
            "Compare each saved task's plan and credit usage · Synced \($0.formatted(date: .abbreviated, time: .shortened))"
        } ?? "Compare each saved task's plan and credit usage"
        let rows = saved.flatMap { account, archive in
            archive.chats.map { AnalyticsChatDisplayRow(accountName: account.name, chat: $0) }
        }.filter { $0.chat.weeklyLimitPercent != nil }
            .sorted { ($0.chat.weeklyLimitPercent ?? 0) > ($1.chat.weeklyLimitPercent ?? 0) }
        let displayed = showsAllChats ? rows : Array(rows.prefix(5))
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Top chats", subtitle: subtitle) { EmptyView() }
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
                ForEach(displayed) { item in
                    AnalyticsChatRow(accountName: item.accountName, chat: item.chat,
                                     showsAccountName: selectedAccount == nil)
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
        let selectableDays = Set(chartDays)
        let plugins = makeSeries(toolBuckets(\AnalyticsArchive.plugins, days: chartDays), days: chartDays, limit: 4)
        let skills = makeSeries(toolBuckets(\AnalyticsArchive.skills, days: chartDays), days: chartDays, limit: 4)
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Tool activity", subtitle: "Plugins and skills used over time") { rangePicker($toolRange) }
            VStack(spacing: 12) {
                UsageDaySelectionHost { daySelection in
                    let selectedDay = daySelection.wrappedValue.flatMap { selectableDays.contains($0) ? $0 : nil }
                    return analyticsChart(plugins, kind: .line, title: "Plugins called", unit: "calls",
                                          selection: daySelection, selectedDay: selectedDay, selectionDays: selectableDays,
                                          showsHoverDetails: true)
                }
                .padding(18).analyticsCard()
                UsageDaySelectionHost { daySelection in
                    let selectedDay = daySelection.wrappedValue.flatMap { selectableDays.contains($0) ? $0 : nil }
                    return analyticsChart(skills, kind: .line, title: "Skills used", unit: "uses",
                                          selection: daySelection, selectedDay: selectedDay, selectionDays: selectableDays,
                                          showsHoverDetails: true)
                }
                .padding(18).analyticsCard()
            }
        }
    }

    private var messagesSection: some View {
        let chartDays = days(for: messageRange)
        let selectableDays = Set(chartDays)
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
            UsageDaySelectionHost { daySelection in
                let selectedDay = daySelection.wrappedValue.flatMap { selectableDays.contains($0) ? $0 : nil }
                return analyticsChart(series, kind: .line, title: "Messages", unit: "messages",
                                      selection: daySelection, selectedDay: selectedDay, selectionDays: selectableDays,
                                      showsHoverDetails: true)
            }
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
                                showsTotal: Bool = true, selection: Binding<String?>? = nil,
                                selectedDay: String? = nil, selectionDays: Set<String> = [],
                                isUsageChart: Bool = false, showsHoverDetails: Bool = false) -> some View {
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
                if let selectedDay, point.day == selectedDay && point.category == series.categories.first?.name {
                    RuleMark(x: .value("Selected day", point.date))
                        .foregroundStyle(Color.gray.opacity(0.45))
                }
            }
            .chartForegroundStyleScale(domain: series.categories.map(\.name),
                                       range: Array(series.categories.enumerated()).map {
                                           chartColor($0.element.name, index: $0.offset, isUsageChart: isUsageChart)
                                       })
            .chartLegend(.hidden)
            .chartXScale(range: .plotDimension(startPadding: 25, endPadding: 50))
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel() } }
            .chartYAxis { AxisMarks(position: .leading) { AxisGridLine(); AxisValueLabel() } }
            .modifier(UsageChartSelection(selection: selection, days: selectionDays))
            .overlay(alignment: .topTrailing) {
                if showsHoverDetails, let selectedDay {
                    activityHoverDetails(series, day: selectedDay, unit: unit)
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 175)
            HStack(spacing: 14) {
                ForEach(Array(series.categories.enumerated()), id: \.offset) { index, category in
                    HStack(spacing: 4) {
                        Circle().fill(chartColor(category.name, index: index, isUsageChart: isUsageChart))
                            .frame(width: 8, height: 8)
                        Text(category.name).lineLimit(1)
                    }
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func activityHoverDetails(_ series: AnalyticsSeries, day: String, unit: String) -> some View {
        let points = series.points.filter { $0.day == day && $0.value > 0 }
        let total = points.reduce(0) { $0 + $1.value }
        return VStack(alignment: .leading, spacing: 5) {
            Text(day).fontWeight(.semibold)
            if points.isEmpty {
                Text("No activity").foregroundStyle(.secondary)
            } else {
                ForEach(points) { point in
                    HStack(spacing: 10) {
                        Text(point.category).lineLimit(1)
                        Spacer(minLength: 6)
                        Text(point.value.formatted(.number.precision(.fractionLength(0))))
                            .monospacedDigit()
                    }
                }
                Text("Total \(unit): \(total.formatted(.number.precision(.fractionLength(0))))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 200, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func categorySummary(_ values: [String: Double]) -> some View {
        let categories = values.filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(6)
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 12) {
            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                HStack(alignment: .top, spacing: 7) {
                    RoundedRectangle(cornerRadius: 2).fill(chartColor(category.key, index: index, isUsageChart: true))
                        .frame(width: 3, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(category.key).font(.system(size: 11)).lineLimit(1)
                        Text(String(format: "%.1f%%", AnalyticsUsageBreakdown.share(of: category.value, in: values)))
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
        case "subagent": "Subagents"
        case "thread_description": "Task descriptions"
        case "automation": "Automations"
        case "code_review": "Code review"
        default: key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func chartColor(_ name: String, index: Int, isUsageChart: Bool) -> Color {
        guard isUsageChart && usageGroup == "Feature" else { return colors[index % colors.count] }
        return switch name {
        case "Tasks": Color(red: 0.16, green: 0.38, blue: 0.76)
        case "Memory updates": Color(red: 0.28, green: 0.74, blue: 0.43)
        case "Auto review": Color(red: 0.97, green: 0.49, blue: 0.20)
        case "Commit messages": Color(red: 0.90, green: 0.18, blue: 0.19)
        case "Subagents", "Subagent": Color(red: 0.18, green: 0.70, blue: 0.69)
        case "Task descriptions": Color(red: 0.91, green: 0.39, blue: 0.67)
        default: colors[index % colors.count]
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

private struct AnalyticsChatRow: View {
    let accountName: String
    let chat: AnalyticsChat
    let showsAccountName: Bool
    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text(chat.title).lineLimit(1)
                    if showsAccountName {
                        Text(accountName).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(chat.weeklyLimitPercent.map { String(format: "%.2f%%", $0) } ?? "—")
                        .frame(width: 120, alignment: .trailing)
                    Text(chat.balanceUsageCredits.flatMap(Double.init).map { String(format: "%.2f", $0) } ?? "—")
                        .frame(width: 90, alignment: .trailing)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(chat.title)")
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.set() }
                else { NSCursor.arrow.set() }
            }
            if isExpanded {
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
                .padding(.leading, 36)
                .padding(.trailing, 16)
                .padding(.bottom, 12)
            }
        }
    }
}

private struct UsageDaySelectionHost<Content: View>: View {
    @State private var selectedDay: String?
    let content: (Binding<String?>) -> Content

    var body: some View { content($selectedDay) }
}

private struct UsageChartSelection: ViewModifier {
    let selection: Binding<String?>?
    let days: Set<String>

    @ViewBuilder
    func body(content: Content) -> some View {
        if let selection {
            content.chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let plotFrame = proxy.plotFrame else { return }
                                let frame = geometry[plotFrame]
                                guard frame.contains(location),
                                      let date = proxy.value(atX: location.x - frame.minX, as: Date.self)
                                else {
                                    if selection.wrappedValue != nil { selection.wrappedValue = nil }
                                    return
                                }
                                let day = ProfileCalendar.key(date.addingTimeInterval(12 * 3_600))
                                let nextDay = days.contains(day) ? day : nil
                                if selection.wrappedValue != nextDay { selection.wrappedValue = nextDay }
                            case .ended:
                                if selection.wrappedValue != nil { selection.wrappedValue = nil }
                            }
                        }
                }
            }
        } else {
            content
        }
    }
}

private extension View {
    func analyticsCard() -> some View {
        background(.white, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.gray.opacity(0.18)))
    }
}
