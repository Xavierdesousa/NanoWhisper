import AppKit
import SwiftUI

/// The end of onboarding, "After setup: the menu bar takes over" (approved board): once the
/// user finishes setup, a popover from the status item says where NanoWhisper lives and how to
/// start. If the model was not ready then, one more popover says when it is.
///
/// Pure state; `MenuBarController` shows it in an `NSPopover` (`HandoffPopover`).
struct MenuBarHandoff: Equatable {
    enum Popover: Equatable {
        case none
        /// Right after Finish Setup ("NanoWhisper is in the menu bar").
        case setupDone
        /// The model became ready after setup was finished ("Parakeet Ultra is ready").
        case modelReady
    }

    private(set) var popover: Popover = .none
    /// The model was not ready when setup finished: say once when it is.
    private(set) var announcesReady = false

    /// Finish Setup (each completed onboarding, replays included).
    mutating func setupFinished(engineReady: Bool) {
        popover = .setupDone
        announcesReady = !engineReady
    }

    /// OK, a click anywhere else, or the menu opening.
    mutating func dismiss() {
        popover = .none
    }

    /// The model is ready: the pending announcement replaces whatever popover is showing,
    /// unless the menu is open (its model line already says so).
    mutating func engineChanged(isReady: Bool, menuIsOpen: Bool) {
        guard announcesReady, isReady else { return }
        announcesReady = false
        popover = menuIsOpen ? .none : .modelReady
    }

    /// Delay between Finish Setup and the popover, so it appears once the onboarding window
    /// has gone.
    static let showDelay: TimeInterval = 0.35

    // MARK: Debug trigger

    /// `--show-handoff` (debug builds only): shows the popover shortly after launch, to try it
    /// without going through onboarding.
    static let launchArgument = "--show-handoff"

    static func isRequestedAtLaunch(arguments: [String], flavor: BuildFlavor) -> Bool {
        flavor.isDebug && arguments.dropFirst().contains(launchArgument)
    }
}

/// What a handoff popover says.
struct HandoffMessage: Equatable {
    var title: String
    var body: String

    /// The text of `popover` for the model's current state, the record shortcut as the menu
    /// writes it ("⌥ Space") and the recorder's position. Nil when no popover shows.
    static func make(
        _ popover: MenuBarHandoff.Popover,
        appName: String,
        modelName: String,
        engine: EngineState,
        shortcut: Shortcut,
        recorderPosition: RecorderPosition
    ) -> HandoffMessage? {
        let keys = shortcut.menuEquivalentString
        let howTo = "Press \(keys) in any app to dictate, and again to stop. "
            + "The recorder appears at the \(recorderPosition.title.lowercased()) of the screen."
        let whenReady = "When it is ready, press \(keys) in any app to dictate."

        switch popover {
        case .none:
            return nil
        case .modelReady:
            return HandoffMessage(title: "\(modelName) is ready", body: howTo)
        case .setupDone:
            let title = "\(appName) is in the menu bar"
            switch ModelStatus.resolve(engine) {
            case .ready:
                return HandoffMessage(title: title, body: howTo + " History and Settings are in this menu.")
            case .downloading(let fraction):
                let progress = fraction.map { " (\(Int(($0 * 100).rounded()))%)" } ?? ""
                return HandoffMessage(title: title, body: "\(modelName) is still downloading\(progress). \(whenReady)")
            case .compiling:
                return HandoffMessage(title: title, body: "\(modelName) is being optimized for this Mac. \(whenReady)")
            case .loading:
                return HandoffMessage(title: title, body: "\(modelName) is still loading. \(whenReady)")
            case .failed:
                return HandoffMessage(title: title, body: "\(modelName) could not be set up. Open this menu to try again.")
            case .notLoaded:
                return HandoffMessage(title: title, body: "\(modelName) is not downloaded yet. Open this menu to download it.")
            }
        }
    }
}

// MARK: - Popover

/// The popover's content, as drawn on the board: a title, the text, OK on the right.
/// OK uses the system accent color (the board's colored button predates that decision), drawn
/// by `AccentButtonStyle`.
struct HandoffPopoverView: View {
    let message: HandoffMessage
    let onOK: () -> Void

    static let width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(message.title)
                .font(.system(size: 13, weight: .semibold))
            Text(message.body)
                .font(.system(size: 12))
                .lineSpacing(2.5) // 17 pt lines
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            HStack {
                Spacer()
                Button("OK", action: onOK)
                    .buttonStyle(AccentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
        .padding(EdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16))
        .frame(width: Self.width, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// A filled button in the system accent color, also while NanoWhisper is not the active app.
/// The popover is shown without activating the app, so it is never key, and a native
/// `.borderedProminent` button would always be drawn in its gray inactive look. Size from the
/// board: 24 pt high, 12 pt medium text, 12 pt side padding, radius 6.
struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Color(nsColor: .alternateSelectedControlTextColor))
            .padding(.horizontal, 12)
            .frame(minWidth: 48, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
            .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(configuration.isPressed ? 0.18 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// Hosts `HandoffPopoverView` in an `NSPopover`. A click on OK lands even while another app
/// is active (first mouse), so the user never has to click twice.
@MainActor
final class HandoffPopoverController: NSViewController {
    private final class HostingView: NSHostingView<HandoffPopoverView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private let hosting: HostingView
    var onDismiss: (() -> Void)?

    init(message: HandoffMessage) {
        hosting = HostingView(rootView: HandoffPopoverView(message: message, onOK: {}))
        super.init(nibName: nil, bundle: nil)
        hosting.rootView = HandoffPopoverView(message: message, onOK: { [weak self] in self?.onDismiss?() })
        loadViewIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Set as the popover's `contentSize` before it is shown: NSPopover places itself with its
    /// current size (320 × 320 by default) and, when the content is smaller, shrinks keeping its
    /// bottom edge, which left a gap of about 160 pt under the status item (measured in
    /// `HandoffPopoverWindowTests`).
    override func loadView() {
        view = hosting
        preferredContentSize = hosting.fittingSize
    }

    func update(_ message: HandoffMessage) {
        guard message != hosting.rootView.message else { return }
        hosting.rootView = HandoffPopoverView(message: message, onOK: { [weak self] in self?.onDismiss?() })
        preferredContentSize = hosting.fittingSize
    }

    /// The popover around this content, sized before it is shown (see `loadView`). Closed only
    /// by its owner (`.applicationDefined`): `.transient` would also close it when the app
    /// deactivates as the onboarding window goes, and it watches clicks only while NanoWhisper
    /// is active.
    func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = self
        popover.contentSize = preferredContentSize
        // The app's theme (Settings › General › Appearance): left nil, a popover takes the
        // appearance of the status item it points to, which is the menu bar's.
        popover.appearance = NSApp.appearance
        return popover
    }

    /// Escape, while the popover is key.
    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }
}
