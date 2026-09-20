import AppKit
import SwiftUI

@main
@MainActor
struct ScrollerChecks {
    static func main() {
        let rows = VStack {
            ForEach(0..<30) { index in Text("Row \(index)") }
        }
        let hosting = NSHostingView(rootView: ScrollView {
            rows.background(RunwayScrollerInstaller())
        }.frame(width: 200, height: 100))
        hosting.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        let scrollViews = descendants(of: hosting).compactMap { $0 as? NSScrollView }
        precondition(scrollViews.count == 1, "Expected one SwiftUI scroll view")
        precondition(scrollViews[0].verticalScroller is RunwayScroller,
                     "SwiftUI scroll view kept the default scroller")
        precondition(RunwayScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay) == 10)
        print("Scroller checks passed")
    }

    static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
