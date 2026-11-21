import AppKit

/// Turning history off deletes it (maintainer's decision, 2026-11-21): with dictations kept
/// the user confirms first; with nothing kept it is off at once.
@MainActor
enum HistoryTurnOff {
    /// - Parameters:
    ///   - apply: stores the new value of the switch.
    ///   - confirm: asks "Turn off history and delete it?" for `count` dictations and calls
    ///     back with `true` for Turn Off and Delete.
    static func setEnabled(
        _ isOn: Bool, current: Bool, store: HistoryStore, defaults: UserDefaults = .standard,
        apply: @escaping (Bool) -> Void,
        confirm: (_ count: Int, _ done: @escaping (Bool) -> Void) -> Void
    ) {
        guard !isOn, current else {
            if isOn != current { apply(isOn) }
            return
        }
        let count = store.entries.count
        guard count > 0 else {
            // Nothing kept: no alert. An empty file left on disk goes too.
            if !store.deleteAll() { HistorySettings.retryOffCleanup(defaults: defaults) }
            apply(false)
            return
        }
        confirm(count) { [weak store] confirmed in
            guard confirmed, let store else { return }
            // Off either way (the user asked); a file that could not be deleted is deleted at
            // the next launch.
            if !store.deleteAll() { HistorySettings.retryOffCleanup(defaults: defaults) }
            apply(false)
        }
    }
}

/// The two alerts about deleting history, as drawn on the History boards.
@MainActor
enum HistoryAlerts {
    static func turnOffAlert(count: Int) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Turn off history and delete it?"
        let kept = count == 1 ? "The 1 dictation kept on this Mac is deleted" : "The \(count) dictations kept on this Mac are deleted"
        alert.informativeText = "\(kept), and new ones won’t be kept. You can’t undo this."
        let delete = alert.addButton(withTitle: "Turn Off and Delete")
        delete.hasDestructiveAction = true
        // Return must not delete: only a click (or Space on the focused button) does.
        delete.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert
    }

    static func clearAllAlert(count: Int) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = count == 1 ? "Delete 1 dictation?" : "Delete all \(count) dictations?"
        alert.informativeText = "They are deleted from this Mac. You can’t undo this."
        let delete = alert.addButton(withTitle: "Delete All")
        delete.hasDestructiveAction = true
        delete.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert
    }

    /// Settings › General (or onboarding): as a sheet on the window in front.
    static func confirmTurnOff(count: Int, completion: @escaping (Bool) -> Void) {
        present(turnOffAlert(count: count), on: NSApp.keyWindow, completion: completion)
    }

    static func present(_ alert: NSAlert, on window: NSWindow?, completion: @escaping (Bool) -> Void) {
        if let window, window.isVisible {
            alert.beginSheetModal(for: window) { response in
                completion(response == .alertFirstButtonReturn)
            }
        } else {
            completion(alert.runModal() == .alertFirstButtonReturn)
        }
    }
}
