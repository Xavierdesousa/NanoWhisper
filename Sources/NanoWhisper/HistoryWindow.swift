import AppKit
import Combine
import SwiftUI

// MARK: - Keys (pure)

/// What the History window does with a key.
enum HistoryCommand: Equatable {
    case copy
    case delete
    case undo
    case redo
    case find
    case close
}

/// The window's own handling of ⌘C, ⌫, ⌘Z, ⌘F (and ⇧⌘Z, ⌘W). The app is a menu bar app
/// (accessory): it shows no menu bar and has no Edit menu while History is open, so nothing
/// may rely on menu key equivalents; the window routes these keys itself
/// (`HistoryWindow.performKeyEquivalent` and `sendEvent`), and the standard text editing keys
/// to the text that has focus.
enum HistoryKeyRouting {
    /// Where the keyboard focus is.
    enum Focus: Equatable {
        /// The list (or nothing that edits text).
        case list
        /// Typing in the search field.
        case searchField(hasSelection: Bool)
        /// Selectable text in the detail.
        case text(hasSelection: Bool)
    }

    enum Route: Equatable {
        case history(HistoryCommand)
        /// Sent to the focused text (`copy:`, `cut:`, `paste:`, `selectAll:`).
        case textAction(String)
        /// Not ours: normal handling.
        case pass
    }

    static let deleteKeyCodes: Set<UInt16> = [51, 117] // Delete, Forward Delete

    static func route(key: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags, focus: Focus) -> Route {
        let modifiers = modifiers.intersection([.command, .shift, .option, .control])
        let key = key.lowercased()
        var hasTextSelection = false
        var editsText = false
        switch focus {
        case .list: break
        case .searchField(let selection): hasTextSelection = selection; editsText = true
        case .text(let selection): hasTextSelection = selection
        }
        let inText = focus != .list

        if modifiers.isEmpty, deleteKeyCodes.contains(keyCode) {
            // Typing in the search field deletes characters; anywhere else, the dictation.
            return editsText ? .pass : .history(.delete)
        }
        switch (modifiers, key) {
        case ([.command], "c"):
            // A selection of words in the detail (or the search field) copies only those.
            return hasTextSelection ? .textAction("copy:") : .history(.copy)
        case ([.command], "z"): return .history(.undo)
        case ([.command, .shift], "z"): return .history(.redo)
        case ([.command], "f"): return .history(.find)
        case ([.command], "w"): return .history(.close)
        case ([.command], "a"): return inText ? .textAction("selectAll:") : .pass
        case ([.command], "x"): return editsText ? .textAction("cut:") : .pass
        case ([.command], "v"): return editsText ? .textAction("paste:") : .pass
        default: return .pass
        }
    }
}

// MARK: - Window

/// The History window: handles its keys itself (see `HistoryKeyRouting`) and shares the
/// model's undo manager, so ⌘Z undoes a delete or the typing in the search field, whichever
/// came last.
final class HistoryWindow: NSWindow {
    let model: HistoryWindowModel
    let toolbarController: HistoryToolbarController
    let contentController: HistoryContentController
    private var refreshScheduled = false
    /// Called after each refresh (`HistorySample` logs the invented window's state).
    var onRefresh: ((HistoryWindow) -> Void)?
    private var cancellables = Set<AnyCancellable>()

    static let defaultContentSize = NSSize(width: 880, height: 580)
    static let minimumContentSize = NSSize(width: 640, height: 420)

    init(model: HistoryWindowModel) {
        self.model = model
        toolbarController = HistoryToolbarController(model: model)
        contentController = HistoryContentController(model: model)
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        title = HistoryText.windowTitle
        // No `backgroundColor`: the system draws the window and its toolbar header as it does
        // Finder's, like Settings (wiki: onboarding-and-settings, "Window colors").
        toolbarStyle = .unified
        toolbar = toolbarController.toolbar
        contentViewController = contentController
        setContentSize(Self.defaultContentSize)
        contentMinSize = Self.minimumContentSize
        isReleasedWhenClosed = false
        isRestorable = false
        collectionBehavior = [.moveToActiveSpace]
        toolbarController.window = self
        model.confirmClearAll = { [weak self] count, done in
            HistoryAlerts.present(HistoryAlerts.clearAllAlert(count: count), on: self, completion: done)
        }
        model.objectWillChange
            .sink { [weak self] _ in self?.scheduleRefresh() }
            .store(in: &cancellables)
        refresh()
    }

    override var undoManager: UndoManager? { model.undoManager }

    /// Updates once the change is applied (`objectWillChange` comes before it).
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        subtitle = model.subtitle
        toolbarController.refresh()
        contentController.refresh()
        onRefresh?(self)
    }

    // MARK: Keys

    var keyFocus: HistoryKeyRouting.Focus {
        guard let responder = firstResponder, responder !== self else { return .list }
        if let textView = responder as? NSTextView {
            let hasSelection = textView.selectedRange().length > 0
            return textView.isFieldEditor ? .searchField(hasSelection: hasSelection) : .text(hasSelection: hasSelection)
        }
        // SwiftUI's selectable text is not an `NSTextView` on macOS 26 (`AppKitTextInteractionView`,
        // an `NSCoreInteractionView`); it tells whether words are selected through the validation
        // of `copy:` (checked in a test process, 2026-11-21: false, then true after `selectAll:`).
        let copy = NSMenuItem(title: "Copy", action: Self.copySelector, keyEquivalent: "c")
        if !(responder is NSTableView), responder.responds(to: Self.copySelector),
           let canCopy = (responder as AnyObject).validateMenuItem?(copy) {
            return .text(hasSelection: canCopy)
        }
        return .list
    }

    private static let copySelector = #selector(NSText.copy(_:))

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, handle(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        // ⌫ is not a key equivalent: it reaches the window as a key down.
        if event.type == .keyDown, !event.modifierFlags.contains(.command), handle(event) { return }
        super.sendEvent(event)
    }

    /// Route one key down. Returns whether it was handled.
    func handle(_ event: NSEvent) -> Bool {
        let route = HistoryKeyRouting.route(
            key: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode,
            modifiers: event.modifierFlags, focus: keyFocus
        )
        switch route {
        case .pass:
            return false
        case .textAction(let selector):
            return firstResponder?.tryToPerform(Selector(selector), with: nil) ?? false
        case .history(let command):
            perform(command)
            return true
        }
    }

    func perform(_ command: HistoryCommand) {
        switch command {
        case .copy: if !model.copySelection() { NSSound.beep() }
        case .delete: if !model.deleteSelection() { NSSound.beep() }
        case .undo: if model.canUndo { model.undo() } else { NSSound.beep() }
        case .redo: model.redo()
        case .find: toolbarController.beginSearch()
        case .close: performClose(nil)
        }
        scheduleRefresh()
    }
}

// MARK: - Toolbar

/// Copy (first, the primary action) and Delete, then the search field. Tooltips name the
/// shortcuts.
@MainActor
final class HistoryToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    /// Copy and Delete, one group (a momentary segmented control).
    static let actionsItem = NSToolbarItem.Identifier("history.actions")
    static let searchItem = NSToolbarItem.Identifier("history.search")

    static let copyTip = "Copy the selected dictation (⌘C)"
    static let deleteTip = "Delete the selected dictation (⌫)"
    static let searchTip = "Search (⌘F)"

    let model: HistoryWindowModel
    let toolbar = NSToolbar(identifier: "History")
    weak var window: HistoryWindow?
    /// Segment 0: Copy (symbol and title), segment 1: Delete (symbol).
    private(set) lazy var actions = makeActions()
    static let copySegment = 0
    static let deleteSegment = 1
    private(set) var searchToolbarItem: NSSearchToolbarItem?

    init(model: HistoryWindowModel) {
        self.model = model
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.actionsItem, Self.searchItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.actionsItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = "Copy and Delete"
            item.view = actions
            return item
        case Self.searchItem:
            let item = NSSearchToolbarItem(itemIdentifier: identifier)
            item.label = "Search"
            item.toolTip = Self.searchTip
            item.preferredWidthForSearchField = 210
            // Without a cap the field takes all the free toolbar width (macOS 26).
            item.searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 210).isActive = true
            item.searchField.placeholderString = "Search"
            item.searchField.delegate = self
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.toolTip = Self.searchTip
            searchToolbarItem = item
            return item
        default:
            return nil
        }
    }

    private func makeActions() -> NSSegmentedControl {
        let control = NSSegmentedControl(
            images: [Self.symbol("doc.on.doc", "Copy"), Self.symbol("trash", "Delete")],
            trackingMode: .momentary, target: self, action: #selector(actionClicked(_:))
        )
        control.setLabel("Copy", forSegment: Self.copySegment)
        control.setToolTip(Self.copyTip, forSegment: Self.copySegment)
        control.setToolTip(Self.deleteTip, forSegment: Self.deleteSegment)
        return control
    }

    private static func symbol(_ name: String, _ description: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
    }

    /// The check of "Copied", in green (not a template, so the control keeps its color).
    private static let greenCheckmark: NSImage = {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
        return NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")?
            .withSymbolConfiguration(configuration) ?? NSImage()
    }()

    @objc private func actionClicked(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case Self.copySegment: model.copySelection()
        case Self.deleteSegment: model.deleteSelection()
        default: break
        }
    }

    func beginSearch() {
        guard model.state == .entries, let item = searchToolbarItem else { NSSound.beep(); return }
        item.beginSearchInteraction()
        if window?.firstResponder !== item.searchField.currentEditor() {
            window?.makeFirstResponder(item.searchField)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        model.setQuery(field.stringValue)
    }

    /// The search field cleared with its button or Esc.
    func searchFieldDidEndSearching(_ sender: NSSearchField) {
        model.setQuery(sender.stringValue)
    }

    func refresh() {
        let enabled = model.canActOnSelection
        actions.setEnabled(enabled || model.showsCopied, forSegment: Self.copySegment)
        actions.setEnabled(enabled, forSegment: Self.deleteSegment)
        // "Copied" with a check for 1.5 s, by mouse or ⌘C.
        let copied = model.showsCopied
        actions.setLabel(copied ? "Copied" : "Copy", forSegment: Self.copySegment)
        actions.setImage(copied ? Self.greenCheckmark : Self.symbol("doc.on.doc", "Copy"), forSegment: Self.copySegment)
        if let item = searchToolbarItem {
            let searchable = model.state == .entries
            // No search where there is no list (empty, off, unavailable), as drawn.
            if #available(macOS 15.0, *) { item.isHidden = !searchable }
            item.searchField.isEnabled = searchable
            if item.searchField.stringValue != model.query { item.searchField.stringValue = model.query }
        }
    }
}

// MARK: - Content

/// The list and detail side by side (an `NSSplitViewController`, the list as a content list
/// like Mail's and Notes' middle column), or one message for empty, off and unavailable.
@MainActor
final class HistoryContentController: NSViewController {
    let model: HistoryWindowModel
    let splitController = NSSplitViewController()
    private let messageController: NSHostingController<HistoryMessageView>
    private var showsSplit: Bool?

    init(model: HistoryWindowModel) {
        self.model = model
        messageController = NSHostingController(rootView: HistoryMessageView(model: model))
        messageController.sizingOptions = []
        super.init(nibName: nil, bundle: nil)

        let list = NSHostingController(rootView: HistoryListView(model: model))
        list.sizingOptions = []
        let detail = NSHostingController(rootView: HistoryDetailView(model: model))
        detail.sizingOptions = []
        let listItem = NSSplitViewItem(contentListWithViewController: list)
        listItem.minimumThickness = HistoryStyle.listMinWidth
        listItem.maximumThickness = HistoryStyle.listMaxWidth
        listItem.canCollapse = false
        // The list keeps its width when the window resizes; the detail takes the rest.
        listItem.holdingPriority = NSLayoutConstraint.Priority(260)
        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = HistoryStyle.detailMinWidth
        detailItem.canCollapse = false
        splitController.addSplitViewItem(listItem)
        splitController.addSplitViewItem(detailItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: HistoryWindow.defaultContentSize))
        refresh()
    }

    func refresh() {
        _ = view
        let split = model.state == .entries
        guard split != showsSplit else { return }
        let firstTime = showsSplit == nil
        showsSplit = split
        let incoming: NSViewController = split ? splitController : messageController
        let outgoing: NSViewController = split ? messageController : splitController
        outgoing.view.removeFromSuperview()
        outgoing.removeFromParent()
        addChild(incoming)
        incoming.view.frame = view.bounds
        incoming.view.autoresizingMask = [.width, .height]
        view.addSubview(incoming.view)
        if split && firstTime {
            splitController.splitView.layoutSubtreeIfNeeded()
            splitController.splitView.setPosition(HistoryStyle.listWidth, ofDividerAt: 0)
        }
    }
}

// MARK: - Controller

/// Opens the History window from the menu. The window and its model live until the app quits
/// (closing only hides it), so the undo history of deletes survives a close.
@MainActor
final class HistoryWindowController {
    private var window: HistoryWindow?
    private var cancellables = Set<AnyCancellable>()

    func show(appState: AppState) {
        let window = self.window ?? makeWindow(appState: appState)
        window.model.prepareForOpening()
        window.refresh()
        window.collectionBehavior = [.moveToActiveSpace]
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow(appState: AppState) -> HistoryWindow {
        let model = HistoryWindowModel(store: appState.historyStore, settings: Self.settings(of: appState))
        model.turnOn = { [weak appState] in appState?.setHistoryEnabled(true) }
        model.openSettings = { [weak appState] in appState?.showSettings(pane: .general) }
        let window = HistoryWindow(model: model)
        // Size and place kept between launches (and where it was left within one); the first
        // time, centered on the screen with the pointer.
        if !window.setFrameUsingName("History") {
            centerOnCurrentScreen(window)
        }
        window.setFrameAutosaveName("History")
        window.contentController.splitController.splitView.autosaveName = "HistorySplit"
        appState.objectWillChange
            .sink { [weak appState, weak model] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let appState, let model else { return }
                        let settings = Self.settings(of: appState)
                        if model.settings != settings { model.settings = settings }
                    }
                }
            }
            .store(in: &cancellables)
        self.window = window
        return window
    }

    static func settings(of appState: AppState) -> HistorySettingsSnapshot {
        HistorySettingsSnapshot(
            isEnabled: appState.historyEnabled, keptCount: appState.maxHistoryCount,
            showsDebugInfo: appState.debugMode, shortcut: appState.shortcut
        )
    }
}
