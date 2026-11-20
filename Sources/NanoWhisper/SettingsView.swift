import SwiftUI

// MARK: - Panes

/// The panes of the Settings window, shown as toolbar items (the shape of Settings in Mail,
/// Safari or Xcode). Each pane is short; the window resizes to the selected one.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case engine
    case recorder
    case permissions
    case advanced

    var id: Self { self }

    /// Width of every pane; the height follows the content.
    static let width: CGFloat = 640
    /// UserDefaults key of the last selected pane, so Settings reopens where it was left.
    static let defaultsKey = "settingsPane"

    var title: String {
        switch self {
        case .general: return "General"
        case .engine: return "Engine"
        case .recorder: return "Recorder"
        case .permissions: return "Permissions"
        case .advanced: return "Advanced"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .engine: return "cpu"
        case .recorder: return "capsule.portrait"
        case .permissions: return "checkmark.shield"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// The pane to open: the stored one if it is still shown, else General.
    static func restored(_ storedValue: String?, from visible: [SettingsPane]) -> SettingsPane {
        if let storedValue, let pane = SettingsPane(rawValue: storedValue), visible.contains(pane) {
            return pane
        }
        return visible.first ?? .general
    }
}

/// One pane, bound to the running app.
private struct LiveSettingsPane: View {
    let pane: SettingsPane
    @ObservedObject var appState: AppState
    @ObservedObject var permissions: PermissionMonitor
    /// Engine choices are edited here and take effect on Apply (see `EnginePane`).
    @State private var draft: EngineConfiguration

    init(pane: SettingsPane, appState: AppState, permissions: PermissionMonitor) {
        self.pane = pane
        self.appState = appState
        self.permissions = permissions
        _draft = State(initialValue: appState.engineConfiguration)
    }

    var body: some View {
        let context = appState.settingsContext(permissions: permissions)
        switch pane {
        case .general:
            GeneralPane(context: context)
        case .engine:
            EnginePane(draft: $draft, context: context)
                // The applied configuration changed elsewhere (onboarding, a migration): an
                // untouched draft follows it; an edited one is kept.
                .onChange(of: appState.engineConfiguration) { old, new in
                    if draft == old { draft = new }
                }
        case .recorder:
            RecorderPane(context: context)
        case .permissions:
            // Polls only while the pane is visible; the window controller also stops it on close.
            PermissionsPane(context: context)
                .onAppear { permissions.start() }
                .onDisappear { permissions.stop() }
        case .advanced:
            AdvancedPane(
                updates: UpdateStatus(appState.autoUpdater),
                actions: UpdateActions(
                    check: { [autoUpdater = appState.autoUpdater] in
                        Task { await autoUpdater.checkForUpdates() }
                    },
                    install: { [autoUpdater = appState.autoUpdater] in
                        Task { await autoUpdater.downloadAndInstall() }
                    }
                ),
                debugMode: $appState.debugMode,
                showOnboarding: { appState.showOnboarding() }
            )
        }
    }
}

// MARK: - Window

/// Toolbar panes. `NSTabViewController` in toolbar style draws the pane items, titles the
/// window with the pane name and resizes the window to the selected pane's
/// `preferredContentSize` (set by each `NSHostingController` from the SwiftUI content).
final class SettingsTabViewController: NSTabViewController {
    private let panes: [SettingsPane]
    var onSelect: ((SettingsPane) -> Void)?

    init(panes: [(SettingsPane, NSViewController)], selected: SettingsPane) {
        self.panes = panes.map(\.0)
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        for (pane, controller) in panes {
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: pane.title)
            addTabViewItem(item)
        }
        selectedTabViewItemIndex = self.panes.firstIndex(of: selected) ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var selectedPane: SettingsPane? {
        panes.indices.contains(selectedTabViewItemIndex) ? panes[selectedTabViewItemIndex] : nil
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        // The window does not always follow on its own (it kept the previous pane's height
        // in the sizing test), so fit it to the new pane explicitly.
        if let controller = tabViewItem?.viewController {
            controller.view.layoutSubtreeIfNeeded()
            fitWindow(to: controller.view.fittingSize, animate: true)
        }
        if let selectedPane { onSelect?(selectedPane) }
    }

    /// The selected pane's content changed height (a Whisper choice, a pending change, an
    /// update state): follow it, keeping the window's top edge in place.
    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        guard viewController === tabViewItems[safe: selectedTabViewItemIndex]?.viewController else { return }
        fitWindow(to: viewController.preferredContentSize, animate: true)
    }

    /// Size the window's content to `size`, keeping the top edge.
    func fitWindow(to size: NSSize, animate: Bool) {
        guard let window = view.window, size.width > 0, size.height > 0 else { return }
        let current = window.contentRect(forFrameRect: window.frame)
        guard abs(current.height - size.height) > 0.5 || abs(current.width - size.width) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: current.origin, size: size))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: animate && window.isVisible)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// The Settings window. AppKit-managed, as the app is a menu bar app (accessory policy):
/// it opens from the menu, centered on the screen with the pointer, and its content is
/// rebuilt at each opening so the Engine draft starts from the applied settings.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var permissions: PermissionMonitor?

    func show(appState: AppState) {
        if let window, window.isVisible {
            window.collectionBehavior = [.moveToActiveSpace]
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let permissions = PermissionMonitor()
        self.permissions = permissions
        let tabs = Self.makeTabs(selectedFrom: UserDefaults.standard) { pane in
            AnyView(LiveSettingsPane(pane: pane, appState: appState, permissions: permissions))
        }
        tabs.onSelect = { UserDefaults.standard.set($0.rawValue, forKey: SettingsPane.defaultsKey) }

        let w = Self.makeWindow(tabs: tabs)
        w.delegate = self
        centerOnCurrentScreen(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    static func makeTabs(
        panes: [SettingsPane] = SettingsPane.allCases,
        selectedFrom defaults: UserDefaults,
        content: (SettingsPane) -> AnyView
    ) -> SettingsTabViewController {
        let controllers: [(SettingsPane, NSViewController)] = panes.map { pane in
            let hosting = NSHostingController(rootView: content(pane))
            hosting.sizingOptions = [.preferredContentSize]
            return (pane, hosting)
        }
        let selected = SettingsPane.restored(defaults.string(forKey: SettingsPane.defaultsKey), from: panes)
        return SettingsTabViewController(panes: controllers, selected: selected)
    }

    static func makeWindow(tabs: SettingsTabViewController) -> NSWindow {
        let w = NSWindow(contentViewController: tabs)
        w.styleMask = [.titled, .closable]
        w.toolbarStyle = .preference
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.collectionBehavior = [.moveToActiveSpace]
        // The tab controller resizes the window when the pane changes, not for the first one.
        if let selected = tabs.tabViewItems[safe: tabs.selectedTabViewItemIndex]?.viewController {
            selected.view.layoutSubtreeIfNeeded()
            tabs.fitWindow(to: selected.view.fittingSize, animate: false)
        }
        return w
    }

    func close() {
        window?.close()
    }

    /// Tear the SwiftUI content down with the window and stop the permission polling (a
    /// closed window keeps its content, and `onDisappear` does not run).
    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        permissions?.stop()
        permissions = nil
        closing.contentViewController = nil
        window = nil
    }
}
