import AppKit
import SwiftUI

/// Own the window shape rather than inheriting MenuBarExtra's private frame.
@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private static let panelWidth: CGFloat = 420
    private static let minimumUsableHeight: CGFloat = 120
    private let store: RunwayStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let panel = AccountStatusPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered, defer: false
    )
    private var hostingController: NSHostingController<AnyView>?
    private var contentMaximumHeight: CGFloat?
    private var lastValidPanelHeight: CGFloat?
    private var settingsWindow: NSWindow?
    private let settingsNavigation = SettingsNavigationState()
    private var localMonitor: Any?
    private var globalMonitor: Any?

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
        let hosting = NSHostingController(rootView: panelContent(maximumHeight: maximumHeight))
        // SwiftUI's changing intrinsic height must not resize the NSWindow
        // independently of sizeAndPositionPanel(), which pins its top edge.
        hosting.sizingOptions = []
        hostingController = hosting
        panel.contentViewController = hosting
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
        guard let hostingController, let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame
            ?? NSScreen.screens.first(where: { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) })?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSRect(x: anchor.midX - Self.panelWidth, y: 0, width: Self.panelWidth, height: 800)
        let maximumHeight = max(200, anchor.minY - screen.minY - 12)
        // Account updates already reach the existing root via EnvironmentObject.
        // Replacing it during a drop restarts layout while AppKit is measuring it.
        if contentMaximumHeight != maximumHeight {
            contentMaximumHeight = maximumHeight
            hostingController.rootView = panelContent(maximumHeight: maximumHeight)
        }
        let width = min(Self.panelWidth, max(1, screen.width - 12))
        let measuredHeight = hostingController.sizeThatFits(in: NSSize(width: width, height: maximumHeight)).height
        let height: CGFloat
        if measuredHeight.isFinite, measuredHeight >= Self.minimumUsableHeight {
            height = min(measuredHeight, maximumHeight)
            lastValidPanelHeight = height
        } else {
            // SwiftUI can briefly report a zero intrinsic size while published
            // refresh state is replacing the button label and graph values.
            // Retain the last usable height instead of moving a tiny panel to
            // the status item where its content is clipped off-screen.
            height = min(lastValidPanelHeight ?? max(panel.frame.height, Self.minimumUsableHeight), maximumHeight)
        }
        let x = max(screen.minX + 6, min(anchor.midX - width / 2, screen.maxX - width - 6))
        let frame = NSRect(x: x, y: anchor.minY - height - 5, width: width, height: height)
        if panel.frame != frame {
            panel.setFrame(frame, display: panel.isVisible)
            panel.invalidateShadow()
        }
    }

    private func panelContent(maximumHeight: CGFloat) -> AnyView {
        AnyView(
            FittingMenuPanel(maximumHeight: maximumHeight,
                content: AnyView(MenuBarView(
                    openSettings: { [weak self] in self?.showSettings() },
                    openAccountHistory: { [weak self] accountID in self?.showAccountHistory(accountID) }
                ).environmentObject(store)))
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
            let hosting = NSHostingView(rootView: SettingsView(navigation: settingsNavigation).environmentObject(store))
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showAccountHistory(_ accountID: UUID) {
        settingsNavigation.showProfile(for: accountID)
        showSettings()
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
            ScrollView {
                content.background(RunwayScrollerInstaller())
            }
            .frame(height: maximumHeight)
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
