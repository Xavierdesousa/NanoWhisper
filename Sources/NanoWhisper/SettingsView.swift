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

/// One pane: its SwiftUI content at its own height, pinned to the top of the pane's area and
/// clipped to it. A window resize (pane switch, content change) never lays the content out at
/// another height, and nothing is drawn above the content area. Before, content laid out
/// taller than the window was centered by `NSHostingView` and showed through the translucent
/// toolbar: the dark band of 2026-11-20 (wiki: onboarding-and-settings).
final class SettingsPaneController: NSViewController {
    private let hosting: NSHostingController<AnyView>

    init(content: AnyView) {
        hosting = NSHostingController(rootView: content)
        // The hosting view takes its content's height through its intrinsic size, pinned to
        // the top of the pane's area only, so it never follows the window's height. Not
        // `.preferredContentSize` on the tab item: for the selected pane, `NSTabViewController`
        // turns it into a height constraint at priority 501, above the window's own size (500),
        // so Auto Layout snapped the window back to that height at every frame of a resize
        // animation while the window was animated elsewhere: the glitch of 2026-11-20.
        hosting.sizingOptions = [.intrinsicContentSize]
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Called with the new height when the content changes height (a Whisper option, a
    /// pending change, an update state).
    var onContentHeightChange: ((CGFloat) -> Void)?
    private var reportedHeight: CGFloat = 0

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: SettingsPane.width, height: 1))
        container.clipsToBounds = true
        // Follows the tab view (the window's content area) as the window resizes.
        container.autoresizingMask = [.width, .height]
        addChild(hosting)
        let content = hosting.view
        content.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        content.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentFrameDidChange), name: NSView.frameDidChangeNotification, object: content
        )
        view = container
        reportedHeight = contentHeight
    }

    /// The content's own height at the pane width, in whole points.
    var contentHeight: CGFloat {
        _ = view
        hosting.view.layoutSubtreeIfNeeded()
        return hosting.view.fittingSize.height.rounded(.up)
    }

    @objc private func contentFrameDidChange() {
        // Measured like `contentHeight` (the frame may sit on a half point), without a layout
        // pass: this runs inside one.
        let height = hosting.view.fittingSize.height.rounded(.up)
        guard abs(height - reportedHeight) > 0.5 else { return }
        reportedHeight = height
        onContentHeightChange?(height)
    }
}

/// Toolbar panes. `NSTabViewController` in toolbar style draws the pane items and titles the
/// window with the pane name; this controller sizes the window itself, one resize at a time.
///
/// On a pane switch the views are swapped at once (no crossfade: two panes on screen, each
/// laid out at the window's changing height, drew over each other and over the toolbar), the
/// window animates to the new pane's height with the pane hidden, then the pane fades in.
final class SettingsTabViewController: NSTabViewController {
    private let panes: [SettingsPane]
    var onSelect: ((SettingsPane) -> Void)?
    /// Tests turn the animation off to check the geometry of each step.
    var animatesResize = true
    private var resizeGeneration = 0
    /// The frame the window is animating to, while it does.
    private var animationTarget: NSRect?
    /// The pane hidden until the resize animation ends.
    private var revealedPane: NSView?
    private var isSelecting = false

    static let resizeDuration: TimeInterval = 0.2
    static let fadeInDuration: TimeInterval = 0.12

    init(panes: [(SettingsPane, SettingsPaneController)], selected: SettingsPane) {
        self.panes = panes.map(\.0)
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = []
        for (pane, controller) in panes {
            controller.title = pane.title
            let item = NSTabViewItem(viewController: controller)
            item.label = pane.title
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.systemImage, accessibilityDescription: pane.title)
            addTabViewItem(item)
            controller.onContentHeightChange = { [weak self, weak controller] height in
                guard let self, !self.isSelecting, let controller, controller === self.selectedController else { return }
                self.fitWindow(toContentHeight: height, animate: true, revealing: nil)
            }
        }
        selectedTabViewItemIndex = self.panes.firstIndex(of: selected) ?? 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var selectedPane: SettingsPane? {
        panes.indices.contains(selectedTabViewItemIndex) ? panes[selectedTabViewItemIndex] : nil
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // The tab view fills the content area at every frame of a window resize (the tab
        // controller pins it at priority 749 only).
        tabView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: view.topAnchor),
            tabView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tabView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tabView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func select(_ pane: SettingsPane) {
        if let index = panes.firstIndex(of: pane) { selectedTabViewItemIndex = index }
    }

    /// The height of a pane's content, shown or not.
    func contentHeight(of pane: SettingsPane) -> CGFloat? {
        guard let index = panes.firstIndex(of: pane) else { return nil }
        return (tabViewItems[index].viewController as? SettingsPaneController)?.contentHeight
    }

    private var selectedController: SettingsPaneController? {
        tabViewItems.indices.contains(selectedTabViewItemIndex)
            ? tabViewItems[selectedTabViewItemIndex].viewController as? SettingsPaneController
            : nil
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        // The incoming pane's first layout reports its height as a content change; the switch
        // below sizes the window for it (with the pane hidden).
        isSelecting = true
        super.tabView(tabView, didSelect: tabViewItem)
        isSelecting = false
        if let controller = tabViewItem?.viewController as? SettingsPaneController {
            fitWindow(toContentHeight: controller.contentHeight, animate: true, revealing: controller.view)
        }
        if let selectedPane { onSelect?(selectedPane) }
    }

    /// Size the window to the selected pane at once (first display, renders).
    func fitWindowToSelectedPane() {
        guard let controller = selectedController else { return }
        fitWindow(toContentHeight: controller.contentHeight, animate: false, revealing: controller.view)
    }

    /// Resize the window's content to `height`, keeping the top edge. With `revealing`, that
    /// view is hidden during the animation and fades in after it.
    private func fitWindow(toContentHeight height: CGFloat, animate: Bool, revealing paneView: NSView?) {
        guard let window = view.window, height > 0 else { return }
        let top = animationTarget?.maxY ?? window.frame.maxY
        var frame = window.frameRect(forContentRect: NSRect(
            origin: .zero, size: NSSize(width: SettingsPane.width, height: height)
        ))
        frame.origin = NSPoint(x: window.frame.minX, y: top - frame.height)
        // Heights are measured in whole points from a fitting size that can sit on a half
        // point, so the same content can measure one point apart: not a change.
        let tolerance: CGFloat = 1.5
        // Already on its way there (the new pane's size can also arrive as a content change
        // while it is being shown): let that animation finish, and reveal this pane with it.
        if let animationTarget, abs(animationTarget.height - frame.height) < tolerance {
            if let paneView, paneView !== revealedPane {
                revealedPane?.alphaValue = 1
                revealedPane = paneView
                paneView.alphaValue = 0
            }
            return
        }
        resizeGeneration += 1
        let generation = resizeGeneration
        let changes = abs(frame.height - window.frame.height) > tolerance || abs(frame.width - window.frame.width) > 0.5
        let animated = animate && animatesResize && changes && window.isVisible
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated else {
            animationTarget = nil
            if changes { window.setFrame(frame, display: true) }
            revealedPane?.alphaValue = 1
            revealedPane = nil
            paneView?.alphaValue = 1
            return
        }
        // A pane hidden by an interrupted animation is shown when this one ends.
        if let paneView {
            revealedPane?.alphaValue = 1
            revealedPane = paneView
            paneView.alphaValue = 0
        }
        animationTarget = frame
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.resizeGeneration == generation else { return }
                self.animationTarget = nil
                guard let pane = self.revealedPane else { return }
                self.revealedPane = nil
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.fadeInDuration
                    pane.animator().alphaValue = 1
                }
            }
        })
        // Never leave a pane hidden if the animation ends without calling its completion.
        let deadline = DispatchTime.now() + Self.resizeDuration + Self.fadeInDuration + 0.3
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self, weak paneView] in
            MainActor.assumeIsolated {
                // Also if the fade-in started but did not run (an interrupted animation).
                if let paneView, paneView.alphaValue < 1 { paneView.alphaValue = 1 }
                guard let self, self.resizeGeneration == generation else { return }
                self.animationTarget = nil
                self.revealedPane?.alphaValue = 1
                self.revealedPane = nil
            }
        }
    }
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
        let controllers = panes.map { pane in (pane, SettingsPaneController(content: content(pane))) }
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
        tabs.fitWindowToSelectedPane()
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
