import Combine
import Foundation

@main
struct HoverChecks {
    @MainActor
    static func main() async throws {
        let hover = CapacityHoverSelection()
        var published: [Date?] = []
        let observation = hover.$date.dropFirst().sink { published.append($0) }
        let start = Date(timeIntervalSince1970: 1_800_000_000)

        for offset in 0..<500 { hover.move(to: start.addingTimeInterval(Double(offset))) }
        try await Task.sleep(for: .milliseconds(100))
        precondition(published == [start.addingTimeInterval(499)],
                     "Pointer bursts must publish only their final position")

        hover.move(to: start.addingTimeInterval(500))
        hover.end()
        try await Task.sleep(for: .milliseconds(100))
        precondition(published == [start.addingTimeInterval(499), nil],
                     "Leaving the chart must clear the hover without a delayed stale update")
        withExtendedLifetime(observation) {}
        print("Hover coalescing checks passed")
    }
}
