import SwiftUI

private final class ButtonHoverState: ObservableObject {
    @Published var isHovered = false
}

struct ButtonHoverFeedback: ViewModifier {
    @StateObject private var hover = ButtonHoverState()
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: Color
    var cornerRadius: CGFloat = 10
    var fillOpacity: Double = 0.1

    func body(content: Content) -> some View {
        let highlighted = isEnabled && hover.isHovered
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(tint.opacity(highlighted ? fillOpacity : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(tint.opacity(highlighted ? 0.3 : 0), lineWidth: 1)
                    }
                    .allowsHitTesting(false)
            }
            .onHover { hover.isHovered = $0 }
            .onDisappear { hover.isHovered = false }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: highlighted)
    }
}
