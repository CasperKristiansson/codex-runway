import Charts
import SwiftUI

private final class CapacityGraphSelection: ObservableObject {
    @Published var range: CapacityGraphRange {
        didSet { UserDefaults.standard.set(range.rawValue, forKey: "codex-runway.graph-range.v1") }
    }
    @Published var showsPercent: Bool {
        didSet { UserDefaults.standard.set(showsPercent, forKey: "codex-runway.graph-percent.v1") }
    }
    @Published var mode: CapacityViewMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "codex-runway.capacity-view.v1") }
    }

    init() {
        range = CapacityGraphRange(rawValue: UserDefaults.standard.string(forKey: "codex-runway.graph-range.v1") ?? "") ?? .overview
        showsPercent = UserDefaults.standard.bool(forKey: "codex-runway.graph-percent.v1")
        mode = CapacityViewMode(rawValue: UserDefaults.standard.string(forKey: "codex-runway.capacity-view.v1") ?? "") ?? .graph
    }
}

private struct CapacityHoverGraph<Content: View>: View {
    @StateObject private var hover = CapacityHoverSelection()
    let content: (CapacityHoverSelection) -> Content

    var body: some View { content(hover) }
}

private enum CapacityViewMode: String, CaseIterable, Identifiable {
    case graph, table
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var icon: String { self == .graph ? "chart.xyaxis.line" : "tablecells" }
}

private enum CapacityGraphRange: String, CaseIterable, Identifiable {
    case overview, hour, sixHours, day, threeDays, week
    var id: String { rawValue }
    var label: String {
        switch self { case .overview: "Overview"; case .hour: "1h"; case .sixHours: "6h"; case .day: "1d"; case .threeDays: "3d"; case .week: "7d" }
    }
    var lookback: TimeInterval? {
        switch self { case .overview: nil; case .hour: 3_600; case .sixHours: 21_600; case .day: 86_400; case .threeDays: 3 * 86_400; case .week: 7 * 86_400 }
    }
    var tableInterval: TimeInterval {
        switch self {
        case .overview: 8 * 3_600
        case .hour: 10 * 60
        case .sixHours: 3_600
        case .day: 4 * 3_600
        case .threeDays: 12 * 3_600
        case .week: 86_400
        }
    }
}

struct CapacityGraphView: View {
    @EnvironmentObject private var store: RunwayStore
    @StateObject private var selection = CapacityGraphSelection()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let report = CapacityForecast.report(accounts: store.accounts, now: context.date)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Combined runway").font(.subheadline.weight(.semibold))
                    Spacer()
                    if report.hasBalance {
                        Text(balanceLabel(report))
                            .font(.subheadline.weight(.semibold))
                    } else if report.total > 0 {
                        Text(emptyBalanceLabel(report)).font(.subheadline)
                    }
                }
                summary(report, showsPercent: selection.showsPercent)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if report.issue == nil, let rate = report.ratePerHour {
                    Text("\(paceLabel(rate * 24, percent: selection.showsPercent)) · \(averageLabel(report))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help(report.usesTimeOfDay
                            ? "Forecast follows your observed time-of-day pattern. The daily average is unchanged; saved balances and reset assumptions still apply."
                            : "Forecast uses a steady average while learning your time-of-day pattern.")
                }
                HStack(spacing: 6) {
                    Text("View")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Display", selection: $selection.mode) {
                        ForEach(CapacityViewMode.allCases) { mode in
                            Image(systemName: mode.icon).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 58)
                    .help("Switch between graph and table")
                    Spacer()
                    Text("Range")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Graph range", selection: $selection.range) {
                        ForEach(CapacityGraphRange.allCases) { range in Text(range.label).tag(range) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    Divider().frame(height: 15)
                    Text("Units")
                        .font(.caption)
                        .foregroundStyle(selection.showsPercent ? .secondary : .primary)
                    Toggle("Percentage scale", isOn: $selection.showsPercent)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .fixedSize()
                    Text("%")
                        .font(.caption)
                        .foregroundStyle(selection.showsPercent ? .primary : .secondary)
                }
                .help("Capacity scale: Pro 20× equals 100%, and Pro 5× equals 25%")
                if report.total > 0 {
                    Group {
                        if selection.mode == .graph {
                            CapacityHoverGraph { hover in
                                graph(report, range: selection.range, now: context.date, hover: hover)
                            }
                            .id(selection.range)
                            .frame(height: CapacityDisplayLayout.height)
                        } else {
                            table(report, range: selection.range, now: context.date)
                        }
                    }
                    // Range and view changes must not alter the open panel's frame.
                    .frame(height: CapacityDisplayLayout.height, alignment: .top)
                }
            }
            .padding(10)
            .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func table(_ report: CapacityReport, range: CapacityGraphRange, now: Date) -> some View {
        let end = CapacityForecast.alignedIntervalEnd(now: now, duration: range.tableInterval)
        let start = end.addingTimeInterval(-(range.lookback ?? 2 * CapacityForecast.day))
        let rows = CapacityForecast.intervals(points: report.history, resets: report.resets,
            start: start, end: end, duration: range.tableInterval).reversed()
        let upcoming = range == .overview
            ? report.resets.filter { $0.projected && $0.date > now }.sorted { $0.date < $1.date }
            : []
        return VStack(spacing: 3) {
            HStack(spacing: 8) {
                Text("Interval").frame(maxWidth: .infinity, alignment: .leading)
                Text("Used").frame(width: 78, alignment: .trailing)
                Text("Balance").frame(width: 72, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(height: CapacityDisplayLayout.headerHeight)
            Divider()
            if range == .overview {
                ScrollView(.vertical) {
                    tableRows(Array(rows), upcoming: upcoming, range: range)
                        .background(RunwayScrollerInstaller())
                }
                .frame(height: CapacityDisplayLayout.rowsHeight)
            } else {
                tableRows(Array(rows), upcoming: [], range: range)
                    .frame(height: CapacityDisplayLayout.rowsHeight, alignment: .top)
            }
        }
        .accessibilityLabel(range == .overview
            ? "Combined allowance history and upcoming resets table"
            : "Combined allowance history table for the past \(range.label)")
    }

    private func tableRows(_ rows: [CapacityInterval], upcoming: [CapacityReset],
                           range: CapacityGraphRange) -> some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                Text("Not enough saved history for this range")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    historyRow(row, range: range)
                        .id(index)
                }
            }
            if !upcoming.isEmpty {
                sectionLabel("Upcoming resets")
                    .id(rows.count)
                ForEach(Array(upcoming.enumerated()), id: \.offset) { index, reset in
                    upcomingResetRow(reset)
                        .id(rows.count + 1 + index)
                }
            }
        }
    }

    private func historyRow(_ row: CapacityInterval, range: CapacityGraphRange) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                Text(intervalLabel(row, range: range))
                if !row.resets.isEmpty {
                    Image(systemName: "arrow.clockwise")
                        .foregroundStyle(.teal)
                    if row.resets.count > 1 {
                        Text("\(row.resets.count)")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.teal)
                    }
                }
            }
                .help(resetHelp(row.resets))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(usageLabel(row.consumedUnits))
                .frame(width: 78, alignment: .trailing)
            Text(capacityLabel(row.endUnits, percent: selection.showsPercent, decimals: 1))
                .frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 10))
        .frame(height: CapacityDisplayLayout.rowHeight)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: CapacityDisplayLayout.resetSectionHeight, alignment: .bottom)
    }

    private func upcomingResetRow(_ reset: CapacityReset) -> some View {
        HStack(spacing: 8) {
            Text(reset.accountName).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(reset.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                .foregroundStyle(.teal)
                .frame(width: 158, alignment: .trailing)
        }
        .font(.system(size: 10))
        .frame(height: CapacityDisplayLayout.rowHeight)
        .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    private func intervalLabel(_ row: CapacityInterval, range: CapacityGraphRange) -> String {
        if range == .week || range == .overview {
            return row.start.formatted(.dateTime.day().month(.abbreviated))
        }
        if range == .threeDays {
            return "\(row.start.formatted(.dateTime.weekday(.abbreviated))) \(row.start.formatted(.dateTime.hour()))–\(row.end.formatted(.dateTime.hour()))"
        }
        return "\(row.start.formatted(.dateTime.hour().minute()))–\(row.end.formatted(.dateTime.hour().minute()))"
    }

    private func usageLabel(_ units: Double) -> String {
        let displayed = selection.showsPercent ? CapacityForecast.percentage(forUnits: units) : units
        if abs(displayed) < 0.005 { return "—" }
        if selection.showsPercent { return String(format: "%.1f%%", displayed) }
        return String(format: "%.2f", displayed)
    }

    private func resetHelp(_ resets: [CapacityReset]) -> String {
        guard !resets.isEmpty else { return "" }
        return resets.map {
            "\($0.accountName): \($0.assumed ? "assumed" : "confirmed") reset at \($0.date.formatted(.dateTime.hour().minute()))"
        }.joined(separator: "\n")
    }

    @ViewBuilder
    private func summary(_ report: CapacityReport, showsPercent: Bool) -> some View {
        if let issue = report.issue {
            Text(issue).foregroundStyle(.secondary)
        } else if let projection = report.projection, let rate = report.ratePerHour {
            if rate == 0 {
                Text("No usage observed · estimated balance stays flat")
                    .foregroundStyle(.secondary)
            } else if let exhaustion = projection.exhaustedAt {
                Text(exhaustionWarning(exhaustion, projection: projection, showsPercent: showsPercent))
                    .foregroundStyle(Color(red: 0.55, green: 0.20, blue: 0.06))
            } else {
                Text("\(report.hasAssumedResets ? "Estimated runway" : "Pace fits the next resets") · lowest balance \(capacityLabel(projection.minimum, percent: showsPercent, decimals: showsPercent ? 0 : 1))")
                    .foregroundStyle(.indigo)
            }
        }
    }

    private func averageLabel(_ report: CapacityReport) -> String {
        let hours = report.averageHistoryHours ?? 0
        let history = hours >= 719 ? "30d" : hours >= 24 ? String(format: "%.1fd", hours / 24) : String(format: "%.0fh", hours)
        return "\(history) avg" + (report.usesTimeOfDay ? " · daily pattern" : "")
    }

    private func exhaustionWarning(_ exhaustion: Date, projection: CapacitySimulation, showsPercent: Bool) -> String {
        let date = exhaustion.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        let early = projection.shortfallAt.map { " (\(durationLabel($0.timeIntervalSince(exhaustion))) early)" } ?? ""
        guard let shortfall = projection.shortfallUnits else { return "May run out \(date)\(early)" }
        return "May run out \(date)\(early) · projected \(deficitLabel(shortfall, percent: showsPercent))"
    }

    private func durationLabel(_ interval: TimeInterval) -> String {
        let totalHours = max(0, Int((interval / 3_600).rounded()))
        let days = totalHours / 24
        let hours = totalHours % 24
        if days > 0, hours > 0 { return "\(days)d \(hours)h" }
        if days > 0 { return "\(days)d" }
        return "\(hours)h"
    }

    private func deficitLabel(_ units: Double, percent: Bool) -> String {
        percent
            ? String(format: "−%.0f%% at reset", CapacityForecast.percentage(forUnits: units))
            : String(format: "−%.1f units at reset", units)
    }

    private func graph(_ report: CapacityReport, range: CapacityGraphRange, now: Date,
                       hover: CapacityHoverSelection) -> some View {
        let isOverview = range == .overview
        let start = now.addingTimeInterval(-(range.lookback ?? 2 * CapacityForecast.day))
        let futureResets = isOverview ? report.resets.filter { $0.projected && $0.date > now } : []
        let nextReset = futureResets.min { $0.date < $1.date }
        let end = isOverview ? max(now.addingTimeInterval(2 * CapacityForecast.day),
                                   (futureResets.map(\.date).max() ?? now).addingTimeInterval(0.25 * CapacityForecast.day)) : now
        // Include the preceding reading so the line can enter the visible range.
        let preceding = report.history.last { $0.date < start }
        let visibleHistory = report.history.filter { $0.date >= start && $0.date <= end }
        let history = (preceding.map { [$0] } ?? []) + visibleHistory
        let visibleResets = report.resets.filter { $0.date >= start && $0.date <= end && (isOverview || !$0.projected) }
        let yDomain = isOverview ? 0...max(report.total, history.map(\.units).max() ?? 0) : historicalDomain(visibleHistory, total: report.total)
        return Chart {
            if isOverview {
                RectangleMark(xStart: .value("Today", now), xEnd: .value("Future", end),
                              yStart: .value("Minimum", 0), yEnd: .value("Maximum", report.total))
                    .foregroundStyle(Color.indigo.opacity(0.045))
            }
            ForEach(history) { point in
                LineMark(x: .value("Date", point.date), y: .value("Units", point.units), series: .value("Series", "history"))
                    .foregroundStyle(.indigo)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                PointMark(x: .value("Date", point.date), y: .value("Units", point.units))
                    .foregroundStyle(.indigo.opacity(0.65))
                    .symbolSize(5)
            }
            ForEach(isOverview ? (report.projection?.points ?? []) : []) { point in
                LineMark(x: .value("Date", point.date), y: .value("Units", point.units), series: .value("Series", "projection"))
                    .foregroundStyle(.indigo)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            ForEach(visibleResets) { reset in
                RuleMark(x: .value("Reset", reset.date))
                    .foregroundStyle(.teal.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: reset.projected || reset.assumed ? [2, 3] : []))
            }
            if let reset = nextReset {
                RuleMark(x: .value("Next reset", reset.date))
                    .foregroundStyle(.teal)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                if reset.hasEstimate {
                    RuleMark(xStart: .value("Today", now), xEnd: .value("Next reset", reset.date),
                             y: .value("Balance before reset", reset.before))
                        .foregroundStyle(.teal.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            if isOverview {
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(Color.indigo.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
            if report.hasBalance {
                PointMark(x: .value("Today", now), y: .value("Current balance", report.remaining))
                    .foregroundStyle(.indigo)
                    .symbolSize(32)
            }
            if let date = hover.date {
                RuleMark(x: .value("Inspect", date)).foregroundStyle(.indigo.opacity(0.2))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: start...end)
        .chartPlotStyle { plot in plot.clipped() }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: axisDates(from: start, through: end)) { value in
                AxisGridLine().foregroundStyle(.gray.opacity(0.12))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date, range: range, now: now))
                            .font(.system(size: 9, weight: abs(date.timeIntervalSince(now)) < 1 ? .bold : .regular)).fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [yDomain.lowerBound, (yDomain.lowerBound + yDomain.upperBound) / 2, yDomain.upperBound]) { value in
                AxisGridLine().foregroundStyle(.gray.opacity(0.15))
                AxisValueLabel {
                    if let units = value.as(Double.self) {
                        Text(axisCapacityLabel(units, percent: selection.showsPercent))
                            .font(.system(size: 9))
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let reset = nextReset, let plotFrame = proxy.plotFrame,
                   let x = proxy.position(forX: reset.date) {
                    Text("Next reset")
                        .font(.system(size: 9))
                        .foregroundStyle(.teal)
                        .position(x: geometry[plotFrame].minX + x - 26, y: geometry[plotFrame].minY + 7)
                        .allowsHitTesting(false)
                }
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            if let plotFrame = proxy.plotFrame {
                                let frame = geometry[plotFrame]
                                hover.move(to: frame.contains(location)
                                    ? proxy.value(atX: location.x - frame.minX, as: Date.self) : nil)
                            }
                        case .ended: hover.end()
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if let date = hover.date {
                let reset = visibleResets.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
                let tolerance = end.timeIntervalSince(start) / 55
                let nearbyReset = reset.flatMap { abs($0.date.timeIntervalSince(date)) <= tolerance ? $0 : nil }
                let points = isOverview && date > now ? (report.projection?.points ?? []) : report.history
                if let nearbyReset {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(nearbyReset.accountName) · \(nearbyReset.assumed ? "Assumed reset" : nearbyReset.projected ? "Upcoming reset" : "Confirmed reset")")
                            .fontWeight(.semibold)
                        Text(nearbyReset.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
                    }
                    .font(.system(size: 10)).padding(.horizontal, 7).padding(.vertical, 5)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).allowsHitTesting(false)
                } else if let value = CapacityForecast.value(at: date, in: points) {
                    Text("\(date.formatted(.dateTime.day().month(.abbreviated).hour().minute())) · \(capacityLabel(value, percent: selection.showsPercent, decimals: 1))")
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
                }
            }
        }
        .accessibilityLabel(isOverview ? "Combined allowance history and forecast through upcoming account resets." : "Combined allowance history for the past \(range.label), including confirmed and assumed resets.")
    }

    private func historicalDomain(_ points: [CapacityPoint], total: Double) -> ClosedRange<Double> {
        let values = points.map(\.units)
        guard let minimum = values.min(), let maximum = values.max() else { return 0...max(1, total) }
        let padding = max((maximum - minimum) * 0.12, max(total * 0.025, 0.1))
        var lower = max(0, minimum - padding), upper = min(total, maximum + padding)
        if upper - lower < 0.2 {
            lower = max(0, minimum - 0.1); upper = min(total, maximum + 0.1)
        }
        if upper <= lower { upper = lower + 0.2 }
        return lower...upper
    }

    private func axisDates(from start: Date, through end: Date) -> [Date] {
        (0...4).map { start.addingTimeInterval(end.timeIntervalSince(start) * Double($0) / 4) }
    }

    private func axisLabel(_ date: Date, range: CapacityGraphRange, now: Date) -> String {
        if range == .overview { return abs(date.timeIntervalSince(now)) < 1 ? "Today" : date.formatted(.dateTime.day().month(.abbreviated)) }
        if range == .threeDays || range == .week { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.hour().minute())
    }

    private func balanceLabel(_ report: CapacityReport) -> String {
        if selection.showsPercent {
            return String(format: "%.0f%% / %.0f%%", CapacityForecast.percentage(forUnits: report.remaining), CapacityForecast.percentage(forUnits: report.total))
        }
        return String(format: "%.1f / %.0f units", report.remaining, report.total)
    }

    private func emptyBalanceLabel(_ report: CapacityReport) -> String {
        selection.showsPercent ? String(format: "— / %.0f%%", CapacityForecast.percentage(forUnits: report.total)) : String(format: "— / %.0f units", report.total)
    }

    private func capacityLabel(_ units: Double, percent: Bool, decimals: Int) -> String {
        if percent { return String(format: decimals == 0 ? "%.0f%%" : "%.1f%%", CapacityForecast.percentage(forUnits: units)) }
        return String(format: decimals == 1 ? "%.1f units" : "%.0f units", units)
    }

    private func paceLabel(_ unitsPerDay: Double, percent: Bool) -> String {
        percent ? String(format: "%.1f%%/day", CapacityForecast.percentage(forUnits: unitsPerDay)) : String(format: "%.2f units/day", unitsPerDay)
    }

    private func axisCapacityLabel(_ units: Double, percent: Bool) -> String {
        percent ? String(format: "%.0f%%", CapacityForecast.percentage(forUnits: units)) : String(format: "%.1f", units)
    }

}
