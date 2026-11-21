import AppKit
import AVFoundation
import Combine
import os
import SwiftUI

extension AppState {
    /// The menu's inputs. Permissions are read when the menu opens (no polling).
    func menuState(microphoneGranted: Bool, accessibilityGranted: Bool) -> MenuState {
        MenuState(
            appName: BuildFlavor.current.displayName,
            debugHeader: nil, // 2026-11-20: the maintainer prefers no header, in both builds
            setupUnfinished: isFirstLaunch && !isOnboardingVisible,
            microphoneGranted: microphoneGranted,
            accessibilityGranted: accessibilityGranted,
            engine: engineState,
            modelName: engineConfiguration.modelName,
            modelSize: engineConfiguration.downloadSize,
            isRecording: isRecording,
            isTranscribing: isTranscribing,
            lastError: lastError,
            update: UpdateStatus(autoUpdater).state,
            historyEnabled: historyEnabled,
            historyUnavailable: historyUnavailable
        )
    }
}

/// The status item and its menu, built in AppKit from `MenuContent.lines(for:)`.
///
/// Why not SwiftUI's `MenuBarExtra`: in its menu style every item is a plain text button, so
/// it cannot draw the download bar or the shortcut as key boxes the design asks for. Here the
/// commands are native `NSMenuItem`s, except the two with something on the right (the
/// shortcut, the reason setup is unfinished) and the progress lines, which are views.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let appState: AppState
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var lines: [MenuLine] = []
    private var isMenuOpen = false
    private var iconKey: String?
    private var cancellables = Set<AnyCancellable>()

    /// End of onboarding: the popover under the status item (see `MenuBarHandoff`).
    private var handoff = MenuBarHandoff()
    private var popover: NSPopover?
    private var popoverContent: HandoffPopoverController?
    /// Close the popover on a click anywhere outside it: in another app (global) or in one of
    /// NanoWhisper's own windows, the status item included (local).
    private var clickMonitors: [Any] = []
    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "MenuBar")

    init(appState: AppState) {
        self.appState = appState
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        statusItem.menu = menu
        statusItem.button?.setAccessibilityTitle(BuildFlavor.current.displayName)
        updateIcon()

        // After the change (objectWillChange fires before it). The main queue also runs while
        // the menu is open (event tracking), so an open menu follows a download.
        appState.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.stateDidChange() }
            .store(in: &cancellables)
    }

    private func stateDidChange() {
        updateIcon()
        if isMenuOpen { refreshMenu() }
        handoff.engineChanged(isReady: appState.isEngineReady, menuIsOpen: isMenuOpen)
        updateHandoffPopover()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isMenuOpen = true
        dismissHandoff("menu opened")
    }

    func menuDidClose(_ menu: NSMenu) {
        isMenuOpen = false
        highlight(nil)
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        highlight(item)
    }

    private func highlight(_ item: NSMenuItem?) {
        for candidate in menu.items {
            (candidate.view as? MenuRowView)?.isHighlighted = candidate === item
        }
    }

    private func refreshMenu() {
        let state = appState.menuState(
            microphoneGranted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            accessibilityGranted: PasteManager.checkAccessibility(prompt: false)
        )
        let newLines = MenuContent.lines(for: state)
        if newLines.map(\.identity) == lines.map(\.identity), menu.items.count == newLines.count {
            // Same structure: update in place, so an open menu keeps its highlight.
            // Rows that draw the shortcut are always reconfigured: the shortcut is not part of
            // the line (their view skips unchanged models).
            for index in newLines.indices where newLines[index] != lines[index] || newLines[index].showsShortcut {
                configure(menu.items[index], newLines[index])
            }
        } else {
            menu.removeAllItems()
            for line in newLines {
                let item = line == .separator ? NSMenuItem.separator() : NSMenuItem()
                configure(item, line)
                menu.addItem(item)
            }
        }
        lines = newLines
    }

    private func configure(_ item: NSMenuItem, _ line: MenuLine) {
        switch line {
        case .separator:
            break
        case .header(let title, let detail):
            let text = NSMutableAttributedString(string: title, attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize),
                .foregroundColor: NSColor.labelColor,
            ])
            text.append(NSAttributedString(string: "\n\(detail)", attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
            item.attributedTitle = text
            item.isEnabled = false
        case .status(let text, let tone):
            item.title = text
            switch tone {
            case .normal:
                item.attributedTitle = nil
            case .recording, .failure:
                item.attributedTitle = NSAttributedString(string: text, attributes: [
                    .font: NSFont.menuFont(ofSize: 0),
                    .foregroundColor: NSColor.systemRed,
                ])
            }
            item.isEnabled = false
        case .progress(let text, let fraction):
            if let view = item.view as? MenuProgressView {
                view.update(text: text, fraction: fraction)
            } else {
                item.view = MenuProgressView(text: text, fraction: fraction)
            }
            item.isEnabled = false
        case .action(let action, let title, let isEnabled, let detail, let showsShortcut, let keyEquivalent):
            item.title = title
            item.isEnabled = isEnabled
            item.target = self
            item.action = #selector(performMenuAction(_:))
            item.representedObject = action
            if let keyEquivalent {
                item.keyEquivalent = keyEquivalent
                item.keyEquivalentModifierMask = .command
            }
            if detail != nil || showsShortcut {
                let model = MenuRowView.Model(
                    title: title, detail: detail,
                    shortcut: showsShortcut ? appState.shortcut : nil, isEnabled: isEnabled
                )
                if let view = item.view as? MenuRowView {
                    view.model = model
                } else {
                    let view = MenuRowView(model: model)
                    view.onPerform = { [weak self] in self?.run(action) }
                    item.view = view
                }
            }
        }
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? MenuAction else { return }
        run(action)
    }

    private func run(_ action: MenuAction) {
        switch action {
        case .finishSetup: appState.showOnboarding()
        case .toggleDictation: appState.toggleRecording()
        case .retrySetup: appState.switchModel(to: appState.selectedModelType)
        case .downloadModel: appState.loadSelectedModelIfIdle()
        case .installUpdate: Task { await appState.autoUpdater.downloadAndInstall() }
        case .showHistory: appState.showHistory()
        case .showSettings: appState.showSettings()
        case .quit: NSApplication.shared.terminate(nil)
        }
    }

    // MARK: Onboarding handoff

    /// Called when the user finishes onboarding (Finish Setup), each time, replays included:
    /// a popover under the status item says where NanoWhisper lives and how to start. It
    /// closes on OK, on a click anywhere else and when the menu opens; if the model is not
    /// ready yet, one more popover says when it is. It never activates the app, so the user
    /// stays in the app they go back to.
    func showOnboardingHandoff() {
        // After the onboarding window has gone, as on the board ("When the window closes…").
        DispatchQueue.main.asyncAfter(deadline: .now() + MenuBarHandoff.showDelay) { [weak self] in
            guard let self else { return }
            self.handoff.setupFinished(engineReady: self.appState.isEngineReady)
            // The menu is already open: no popover over it, but a model that is not ready yet
            // is still announced once it is.
            if self.isMenuOpen { self.handoff.dismiss() }
            self.updateHandoffPopover()
        }
    }

    private func dismissHandoff(_ reason: StaticString) {
        if handoff.popover != .none {
            Self.logger.info("Handoff popover dismissed: \(reason, privacy: .public)")
        }
        handoff.dismiss()
        updateHandoffPopover()
    }

    private var handoffMessage: HandoffMessage? {
        HandoffMessage.make(
            handoff.popover,
            appName: BuildFlavor.current.displayName,
            modelName: appState.engineConfiguration.modelName,
            engine: appState.engineState,
            shortcut: appState.shortcut,
            recorderPosition: appState.recorderPosition
        )
    }

    /// Shows, updates (a download's percentage, the switch to "ready") or closes the popover
    /// to match `handoff`.
    private func updateHandoffPopover() {
        guard let message = handoffMessage else {
            closeHandoffPopover()
            return
        }
        if let popoverContent, popover?.isShown == true {
            popoverContent.update(message)
            return
        }
        guard let button = statusItem.button, button.window != nil else {
            Self.logger.info("Handoff popover not shown: the status item has no window")
            handoff.dismiss()
            return
        }
        let content = HandoffPopoverController(message: message)
        content.onDismiss = { [weak self] in self?.dismissHandoff("OK or Escape") }
        let popover = content.makePopover()
        popover.delegate = self
        self.popover = popover
        popoverContent = content
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        button.highlight(true)
        installClickMonitors()
        let itemFrame = button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } ?? .zero
        let popoverFrame = content.view.window?.frame ?? .zero
        Self.logger.info("Handoff popover shown (\(String(describing: self.handoff.popover), privacy: .public)): popover \(NSStringFromRect(popoverFrame), privacy: .public) under item \(NSStringFromRect(itemFrame), privacy: .public)")
    }

    private func closeHandoffPopover() {
        removeClickMonitors()
        guard let popover else { return }
        self.popover = nil
        popoverContent = nil
        popover.close()
        if !isMenuOpen { statusItem.button?.highlight(false) }
    }

    func popoverDidClose(_ notification: Notification) {
        // Closed by the system (e.g. the status item went away): forget it.
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        Self.logger.info("Handoff popover closed by the system")
        popover = nil
        popoverContent = nil
        removeClickMonitors()
        handoff.dismiss()
        if !isMenuOpen { statusItem.button?.highlight(false) }
    }

    private func installClickMonitors() {
        guard clickMonitors.isEmpty else { return }
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissHandoff("click in another app") }
        }) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                if event.window == nil || event.window !== self.popoverContent?.view.window {
                    self.dismissHandoff("click outside the popover")
                }
            }
            return event
        }) {
            clickMonitors.append(local)
        }
    }

    private func removeClickMonitors() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors = []
    }

    // MARK: Icon

    /// The glyph, or a state symbol while the model is not ready; debug builds add the band.
    private func updateIcon() {
        let symbol: String?
        if appState.setupManager.isSettingUp {
            symbol = "arrow.down.circle"
        } else if !appState.isEngineReady {
            symbol = "mic.slash"
        } else {
            symbol = nil
        }
        let key = symbol ?? "menubar_icon"
        guard key != iconKey else { return }
        iconKey = key
        statusItem.button?.image = Self.icon(symbol: symbol)
    }

    private static func icon(symbol: String?) -> NSImage? {
        if BuildFlavor.current.isDebug {
            return MenuBarIcon.cached(symbol ?? "menubar_icon") {
                if let symbol { return MenuBarIcon.badged(systemSymbolName: symbol) }
                return glyph().map(MenuBarIcon.badged) ?? MenuBarIcon.badged(systemSymbolName: "mic")
            }
        }
        if let symbol {
            return NSImage(systemSymbolName: symbol, accessibilityDescription: BuildFlavor.current.displayName)
        }
        return glyph() ?? NSImage(systemSymbolName: "mic", accessibilityDescription: BuildFlavor.current.displayName)
    }

    private static func glyph() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "menubar_icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
}

// MARK: - Item views

/// Horizontal metrics of view-based menu items, matched to native items in a menu without
/// a state column (`showsStateColumn = false`).
enum MenuMetrics {
    /// From the menu's edge to the title text: 16 pt, where native titles start in the macOS 26+
    /// menu (measured on macOS 27.2, 2026-11-21; 14 pt matched the pre-26 design the app ran in
    /// while its build recorded SDK 14, see docs/wiki/build-and-release.md).
    static let textInset: CGFloat = 16
    /// From the menu's edge to the selection background.
    static let selectionInset: CGFloat = 5
    static let rowHeight: CGFloat = 22
    static let minimumWidth: CGFloat = 280
}

/// A command with something on its right (the record shortcut as key boxes, or a reason).
/// Draws its own selection, since a menu item with a view draws nothing by itself.
final class MenuRowView: NSView {
    struct Model: Equatable {
        var title: String
        var detail: String?
        var shortcut: Shortcut?
        var isEnabled: Bool
    }

    var model: Model {
        didSet { if model != oldValue { render() } }
    }

    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            selection.isHidden = !(isHighlighted && model.isEnabled)
            render()
        }
    }

    var onPerform: (() -> Void)?

    private let selection = NSVisualEffectView()
    private let hosting: NSHostingView<MenuRowLabel>

    init(model: Model) {
        self.model = model
        hosting = NSHostingView(rootView: MenuRowLabel(model: model, isHighlighted: false))
        let width = max(MenuMetrics.minimumWidth, hosting.fittingSize.width)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: MenuMetrics.rowHeight))
        autoresizingMask = [.width]

        selection.material = .selection
        selection.state = .active
        selection.isEmphasized = true
        selection.wantsLayer = true
        selection.layer?.cornerRadius = 4
        selection.isHidden = true
        selection.frame = bounds.insetBy(dx: MenuMetrics.selectionInset, dy: 0)
        selection.autoresizingMask = [.width, .height]
        addSubview(selection)

        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(model.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func render() {
        hosting.rootView = MenuRowLabel(model: model, isHighlighted: isHighlighted && model.isEnabled)
        setAccessibilityLabel(model.title)
    }

    /// Clicks land on this view, not on the hosted SwiftUI label.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        guard model.isEnabled else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onPerform?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard model.isEnabled else { return false }
        enclosingMenuItem?.menu?.cancelTracking()
        onPerform?()
        return true
    }
}

struct MenuRowLabel: View {
    let model: MenuRowView.Model
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(model.title)
            Spacer(minLength: 20)
            if let detail = model.detail {
                Text(detail)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
            }
            if let shortcut = model.shortcut {
                // Plain glyphs, like the native key equivalents (⌘,) on the other items.
                Text(shortcut.menuEquivalentString)
                    .foregroundStyle(isHighlighted ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
        .foregroundStyle(isHighlighted ? Color.white
                         : model.isEnabled ? Color.primary : Color(nsColor: .disabledControlTextColor))
        .lineLimit(1)
        .padding(.leading, MenuMetrics.textInset)
        .padding(.trailing, MenuMetrics.textInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// A disabled line with a progress bar under it (a model or update download).
final class MenuProgressView: NSView {
    private let hosting: NSHostingView<MenuProgressLabel>

    init(text: String, fraction: Double?) {
        hosting = NSHostingView(rootView: MenuProgressLabel(text: text, fraction: fraction))
        let size = hosting.fittingSize
        super.init(frame: NSRect(x: 0, y: 0, width: max(MenuMetrics.minimumWidth, size.width), height: size.height))
        autoresizingMask = [.width]
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(text: String, fraction: Double?) {
        let label = MenuProgressLabel(text: text, fraction: fraction)
        guard label != hosting.rootView else { return }
        hosting.rootView = label
    }
}

struct MenuProgressLabel: View, Equatable {
    let text: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(text)
                .font(.system(size: NSFont.menuFont(ofSize: 0).pointSize))
                .foregroundStyle(Color(nsColor: .disabledControlTextColor))
                .lineLimit(1)
            Group {
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .controlSize(.small)
            .frame(width: 200)
        }
        .padding(.leading, MenuMetrics.textInset)
        .padding(.trailing, MenuMetrics.textInset)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
