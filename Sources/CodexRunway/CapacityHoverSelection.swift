import Combine
import Foundation

/// Keeps pointer movement local to the chart and publishes only the latest
/// position in each short frame, including the final position of a drag.
@MainActor
final class CapacityHoverSelection: ObservableObject {
    @Published private(set) var date: Date?
    private var pendingDate: Date?
    private var pendingUpdate: Task<Void, Never>?

    func move(to date: Date?) {
        guard let date else { end(); return }
        pendingDate = date
        guard pendingUpdate == nil else { return }
        pendingUpdate = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled, let self else { return }
            if self.date != self.pendingDate { self.date = self.pendingDate }
            self.pendingUpdate = nil
        }
    }

    func end() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        pendingDate = nil
        if date != nil { date = nil }
    }
}
