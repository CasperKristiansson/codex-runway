import SwiftUI

enum CapacityViewMode: String, CaseIterable, Identifiable {
    case graph, table
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var icon: String { self == .graph ? "chart.xyaxis.line" : "tablecells" }
}

enum CapacityGraphRange: String, CaseIterable, Identifiable {
    case overview, hour, sixHours, day, threeDays, week
    var id: String { rawValue }
    var label: String {
        switch self { case .overview: "Overview"; case .hour: "1h"; case .sixHours: "6h"; case .day: "1d"; case .threeDays: "3d"; case .week: "7d" }
    }
    var lookback: TimeInterval? {
        switch self { case .overview: nil; case .hour: 3_600; case .sixHours: 21_600; case .day: 86_400; case .threeDays: 259_200; case .week: 604_800 }
    }
    var tableInterval: TimeInterval {
        switch self { case .overview: 28_800; case .hour: 600; case .sixHours: 3_600; case .day: 14_400; case .threeDays: 43_200; case .week: 86_400 }
    }
}

/// One preferences object for the popup, native Overview and embedded hub.
@MainActor
final class RunwayDisplayPreferences: ObservableObject {
    private let defaults: UserDefaults
    @Published var range: CapacityGraphRange { didSet { defaults.set(range.rawValue, forKey: "codex-runway.graph-range.v1") } }
    @Published var showsPercent: Bool { didSet { defaults.set(showsPercent, forKey: "codex-runway.graph-percent.v1") } }
    @Published var mode: CapacityViewMode { didSet { defaults.set(mode.rawValue, forKey: "codex-runway.capacity-view.v1") } }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        range = CapacityGraphRange(rawValue: defaults.string(forKey: "codex-runway.graph-range.v1") ?? "") ?? .overview
        showsPercent = defaults.bool(forKey: "codex-runway.graph-percent.v1")
        mode = CapacityViewMode(rawValue: defaults.string(forKey: "codex-runway.capacity-view.v1") ?? "") ?? .graph
    }
}
