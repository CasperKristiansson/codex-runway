import AppKit
import SwiftUI

/// Keep AppKit's native scroll interaction, but draw a narrow runway-colored knob.
final class RunwayScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                      scrollerStyle: NSScroller.Style) -> CGFloat {
        10
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        // The drawer material is the track; a system track would look too heavy.
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let width = min(3, knob.width)
        let capsule = NSRect(x: knob.midX - width / 2, y: knob.minY,
                             width: width, height: knob.height)
        NSColor.systemIndigo.withAlphaComponent(0.52).setFill()
        NSBezierPath(roundedRect: capsule, xRadius: width / 2, yRadius: width / 2).fill()
    }
}

/// SwiftUI's indicator visibility is a preference that macOS may override when
/// a mouse is connected. Install the themed scroller on the actual scroll view.
struct RunwayScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> ScrollerProbeView { ScrollerProbeView() }
    func updateNSView(_ nsView: ScrollerProbeView, context: Context) { nsView.installIfPossible() }
}

final class ScrollerProbeView: NSView {
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        installIfPossible()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installIfPossible()
    }

    func installIfPossible() {
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? NSScrollView {
                if !(scrollView.verticalScroller is RunwayScroller) {
                    scrollView.scrollerStyle = .overlay
                    scrollView.verticalScroller = RunwayScroller()
                    scrollView.hasVerticalScroller = true
                }
                return
            }
            ancestor = view.superview
        }
    }
}
