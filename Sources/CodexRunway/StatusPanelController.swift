import AppKit
import Combine
import SwiftUI

/// Own the window shape rather than inheriting MenuBarExtra's private frame.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let store: RunwayStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = AccountStatusPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false
    )
    private var hostingView: NSHostingView<AnyView>?
    private var contentMaximumHeight: CGFloat?
    private var settingsWindow: NSWindow?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var storeSubscription: AnyCancellable?

    init(store: RunwayStore) {
        self.store = store
        super.init()
        if let button = statusItem.button {
            button.image = RunwayBrand.menuBarMark
            button.image?.isTemplate = true
            button.toolTip = "Codex Runway"
            button.target = self
            button.action = #selector(togglePanel)
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .aqua)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let maximumHeight = NSScreen.main?.visibleFrame.height ?? 800
        contentMaximumHeight = maximumHeight
        let hosting = NSHostingView(rootView: panelContent(maximumHeight: maximumHeight))
        // Retain intrinsic measurement, but do not impose hosting min/max
        // window constraints: this panel owns its size and top-edge anchor.
        hosting.sizingOptions = [.intrinsicContentSize]
        hostingView = hosting
        panel.contentView = hosting
        storeSubscription = store.objectWillChange.sink { [weak self] _ in
            // Published changes arrive before the stored value is updated.
            DispatchQueue.main.async {
                guard let self, self.panel.isVisible else { return }
                self.sizeAndPositionPanel()
            }
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            hidePanel()
            return
        }
        sizeAndPositionPanel()
        panel.makeKeyAndOrderFront(nil)
        sizeAndPositionPanel()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel, event.window !== self.statusItem.button?.window {
                    self.hidePanel()
                }
            }
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func sizeAndPositionPanel() {
        guard let hostingView, let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? anchor
        let maximumHeight = max(200, anchor.minY - screen.minY - 12)
        // Account updates already reach the existing root via EnvironmentObject.
        // Replacing it during a drop restarts layout while AppKit is measuring it.
        if contentMaximumHeight != maximumHeight {
            contentMaximumHeight = maximumHeight
            hostingView.rootView = panelContent(maximumHeight: maximumHeight)
        }
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        let x = max(screen.minX + 6, min(anchor.midX - size.width / 2, screen.maxX - size.width - 6))
        let frame = NSRect(x: x, y: anchor.minY - size.height - 5, width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: panel.isVisible)
            panel.invalidateShadow()
        }
    }

    private func panelContent(maximumHeight: CGFloat) -> AnyView {
        AnyView(
            FittingMenuPanel(maximumHeight: maximumHeight,
                content: AnyView(MenuBarView(openSettings: { [weak self] in self?.showSettings() }).environmentObject(store)))
        )
    }

    private func hidePanel() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        panel.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hidePanel()
    }

    private func showSettings() {
        hidePanel()
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.title = "Codex Runway Settings"
            window.isReleasedWhenClosed = false
            let hosting = NSHostingView(rootView: SettingsView().environmentObject(store))
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Preserve the natural three-card height on large screens; allow scrolling
/// when the added graph or an error would otherwise extend below the display.
struct FittingMenuPanel: View {
    let maximumHeight: CGFloat
    let content: AnyView

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView { content }.frame(height: maximumHeight)
        }
        .frame(width: 420)
        .frame(maxHeight: maximumHeight, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private final class AccountStatusPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        orderOut(sender)
    }
}
