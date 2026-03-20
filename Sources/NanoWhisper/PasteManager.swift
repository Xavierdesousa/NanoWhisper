import AppKit
import Carbon

class PasteManager {
    /// Time in seconds before the clipboard is cleared after pasting
    private static let clipboardClearDelay: TimeInterval = 3.0

    /// Paste transcribed text into the active application
    /// Returns false if no suitable target app was found
    @discardableResult
    func pasteText(_ text: String) -> Bool {
        // Verify there's a frontmost app that can receive paste (not us)
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.bundleIdentifier != Bundle.main.bundleIdentifier else {
            return false
        }

        let pasteboard = NSPasteboard.general

        // Save current clipboard contents to restore later
        let previousContents = pasteboard.string(forType: .string)

        // Set transcribed text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let changeCountAfterSet = pasteboard.changeCount

        // Simulate Cmd+V, then restore/clear clipboard after delay
        simulatePaste()
        scheduleClipboardCleanup(
            previousContents: previousContents,
            changeCountAfterSet: changeCountAfterSet
        )
        return true
    }

    private func simulatePaste() {
        // Small delay to ensure pasteboard is ready
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            let source = CGEventSource(stateID: .hidSystemState)

            // Key down: Cmd + V
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
            keyDown?.flags = .maskCommand
            keyDown?.post(tap: .cghidEventTap)

            // Key up
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
            keyUp?.flags = .maskCommand
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    private func scheduleClipboardCleanup(
        previousContents: String?,
        changeCountAfterSet: Int
    ) {
        let delay = Self.clipboardClearDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let pasteboard = NSPasteboard.general

            // Only restore/clear if the clipboard hasn't been modified by the user or another app
            guard pasteboard.changeCount == changeCountAfterSet else { return }

            pasteboard.clearContents()
            // Restore previous clipboard content if it existed
            if let previous = previousContents {
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    /// Check if we have accessibility permissions (needed for CGEvent posting)
    /// When `prompt` is true, shows the system dialog asking the user to grant access.
    @MainActor
    static func checkAccessibility(prompt: Bool = true) -> Bool {
        let key: CFString = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
