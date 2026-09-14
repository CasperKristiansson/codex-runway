import Charts
import SwiftUI

private final class CapacityGraphSelection: ObservableObject {
    @Published var date: Date?
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
                        Text("\(report.remaining, specifier: "%.1f") / \(report.total, specifier: "%.0f") units")
                            .font(.subheadline.weight(.semibold))
                    } else if report.total > 0 {
                        Text("— / \(report.total, specifier: "%.0f") units").font(.subheadline)
                    }
                }
                summary(report)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if report.hasAssumedResets {
                    Text("Includes assumed resets · next dates unknown until synced")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if report.total > 0 {
                    graph(report, now: context.date)
                        .frame(height: 100)
                }
            }
            .padding(10)
            .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    @ViewBuilder
    private func summary(_ report: CapacityReport) -> some View {
        if let issue = report.issue {
            Text(issue).foregroundStyle(.secondary)
        } else if let projection = report.projection, let rate = report.ratePerHour {
            VStack(alignment: .leading, spacing: 3) {
                if rate == 0 {
                    Text("No usage observed · estimated balance stays flat")
                        .foregroundStyle(.secondary)
                } else if let exhaustion = projection.exhaustedAt {
                    Text("May run out \(exhaustion.formatted(.dateTime.month(.abbreviated).day().hour().minute())) · slow down ~\(Int((report.reductionPercent ?? 0).rounded(.up)))%")
                        .foregroundStyle(Color(red: 0.55, green: 0.20, blue: 0.06))
                } else {
                    Text("\(report.hasAssumedResets ? "Estimated runway" : "Pace fits the next resets") · lowest balance \(projection.minimum, specifier: "%.1f") units")
                        .foregroundStyle(.indigo)
                }
                Text("\(rate * 24, specifier: "%.2f") units/day · \(averageLabel(report))")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func averageLabel(_ report: CapacityReport) -> String {
        let hours = report.averageHistoryHours ?? 0
        if hours >= 719 { return "30-day average" }
        let history = hours >= 24 ? String(format: "%.1fd", hours / 24) : String(format: "%.0fh", hours)
        return "\(history) average"
    }

    private func graph(_ report: CapacityReport, now: Date) -> some View {
        let start = now.addingTimeInterval(-2 * CapacityForecast.day)
        let futureResets = report.resets.filter { $0.projected && $0.date > now }
        let nextReset = futureResets.min { $0.date < $1.date }
        let end = max(now.addingTimeInterval(2 * CapacityForecast.day),
                      (futureResets.map(\.date).max() ?? now).addingTimeInterval(0.25 * CapacityForecast.day))
        // Include the preceding reading so the line can enter the visible range.
        let preceding = report.history.last { $0.date < start }
        let history = (preceding.map { [$0] } ?? []) + report.history.filter { $0.date >= start }
        return Chart {
            RectangleMark(xStart: .value("Today", now), xEnd: .value("Future", end),
                          yStart: .value("Minimum", 0), yEnd: .value("Maximum", report.total))
                .foregroundStyle(Color.indigo.opacity(0.045))
            ForEach(history) { point in
                LineMark(x: .value("Date", point.date), y: .value("Units", point.units), series: .value("Series", "history"))
                    .foregroundStyle(.indigo)
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.8))
                PointMark(x: .value("Date", point.date), y: .value("Units", point.units))
                    .foregroundStyle(.indigo.opacity(0.65))
                    .symbolSize(5)
            }
            ForEach(report.projection?.points ?? []) { point in
                LineMark(x: .value("Date", point.date), y: .value("Units", point.units), series: .value("Series", "projection"))
                    .foregroundStyle(.indigo)
                    .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
            }
            ForEach(report.resets.filter { $0.date >= start && $0.date <= end }) { reset in
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
            RuleMark(x: .value("Now", now))
                .foregroundStyle(Color.indigo.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 2))
            if report.hasBalance {
                PointMark(x: .value("Today", now), y: .value("Current balance", report.remaining))
                    .foregroundStyle(.indigo)
                    .symbolSize(32)
            }
            if let date = selection.date {
                RuleMark(x: .value("Inspect", date)).foregroundStyle(.indigo.opacity(0.2))
            }
        }
        .chartLegend(.hidden)
        .chartXScale(domain: start...end)
        .chartPlotStyle { plot in plot.clipped() }
        .chartYScale(domain: 0...max(report.total, history.map(\.units).max() ?? 0))
        .chartXAxis {
            AxisMarks(values: [start, now.addingTimeInterval(-CapacityForecast.day), now, now.addingTimeInterval(end.timeIntervalSince(now) / 2), end]) { value in
                AxisGridLine().foregroundStyle(.gray.opacity(0.12))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(abs(date.timeIntervalSince(now)) < 1 ? "Today" : date.formatted(.dateTime.day().month(.abbreviated)))
                            .font(.system(size: 9, weight: abs(date.timeIntervalSince(now)) < 1 ? .bold : .regular)).fixedSize()
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, report.total / 2, report.total]) { value in
                AxisGridLine().foregroundStyle(.gray.opacity(0.15))
                AxisValueLabel {
                    if let units = value.as(Double.self) {
                        Text(units, format: .number.precision(.fractionLength(0...1)))
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
                                selection.date = frame.contains(location) ? proxy.value(atX: location.x - frame.minX, as: Date.self) : nil
                            }
                        case .ended: selection.date = nil
                        }
                    }
            }
        }
        .overlay(alignment: .topLeading) {
            if let date = selection.date,
               let value = CapacityForecast.value(at: date, in: date > now ? (report.projection?.points ?? []) : report.history) {
                Text("\(date.formatted(.dateTime.day().month(.abbreviated).hour().minute())) · \(value, specifier: "%.1f") units")
                    .font(.system(size: 10))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel("Combined allowance remaining over the past 2 days through upcoming account resets. History connects saved readings; future balances are estimates. The horizontal guide shows the estimated balance before the next reset.")
    }

}
