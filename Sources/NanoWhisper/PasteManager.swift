import AppKit
import Carbon
import os

/// What became of a dictated text.
enum PasteResult: Equatable, Sendable {
    /// ⌘V was sent to the app in front. Whether that app took the text cannot be known.
    case pasted
    /// NanoWhisper itself is in front, or no app is: nothing was sent.
    case noTarget
    /// Without Accessibility, macOS drops the ⌘V.
    case notPermitted
}

@MainActor
final class PasteManager {
    /// Time in seconds before the clipboard is restored after pasting
    private static let clipboardClearDelay: TimeInterval = 3.0

    private let clipboard: BorrowedClipboard
    private let isOtherAppInFront: () -> Bool
    private let isAccessibilityGranted: () -> Bool
    private let sendPaste: () -> Void

    convenience init() {
        self.init(
            pasteboard: .general,
            isOtherAppInFront: {
                guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
                return frontApp.bundleIdentifier != Bundle.main.bundleIdentifier
            },
            isAccessibilityGranted: { PasteManager.checkAccessibility(prompt: false) },
            sendPaste: PasteManager.simulatePaste
        )
    }

    /// Tests pass a private pasteboard and their own answers.
    init(
        pasteboard: NSPasteboard,
        isOtherAppInFront: @escaping () -> Bool,
        isAccessibilityGranted: @escaping () -> Bool,
        sendPaste: @escaping () -> Void
    ) {
        clipboard = BorrowedClipboard(pasteboard: pasteboard)
        self.isOtherAppInFront = isOtherAppInFront
        self.isAccessibilityGranted = isAccessibilityGranted
        self.sendPaste = sendPaste
    }

    /// Paste transcribed text into the active application (never NanoWhisper itself).
    func pasteText(_ text: String) -> PasteResult {
        guard isOtherAppInFront() else { return .noTarget }
        let isGranted = isAccessibilityGranted()

        // Put the text on the clipboard, simulate Cmd+V, then restore the clipboard after a delay.
        // Also without Accessibility, as before: the text can be pasted by hand until the
        // clipboard is restored.
        let changeCount = clipboard.put(text)
        sendPaste()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clipboardClearDelay) { [clipboard] in
            MainActor.assumeIsolated { clipboard.giveBack(ifUnchangedSince: changeCount) }
        }
        return isGranted ? .pasted : .notPermitted
    }

    private static func simulatePaste() {
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

    /// Check if we have accessibility permissions (needed for CGEvent posting)
    /// When `prompt` is true, shows the system dialog asking the user to grant access.
    static func checkAccessibility(prompt: Bool = true) -> Bool {
        let key: CFString = "AXTrustedCheckOptionPrompt" as CFString
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

/// The clipboard, borrowed for the time of a paste: holds the dictated text, then gets back
/// what it held before, unless someone else changed it meanwhile.
@MainActor
final class BorrowedClipboard {
    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "Paste")

    private let pasteboard: NSPasteboard
    private let limits: PasteboardSnapshot.Limits
    /// What to give back, and the change count of our last write.
    private var loan: (snapshot: PasteboardSnapshot, changeCount: Int)?

    init(pasteboard: NSPasteboard, limits: PasteboardSnapshot.Limits = .init()) {
        self.pasteboard = pasteboard
        self.limits = limits
    }

    /// Puts `text` on the clipboard, marked as transient and confidential, for this Mac only.
    /// - Returns: the change count to pass to `giveBack(ifUnchangedSince:)`.
    func put(_ text: String) -> Int {
        let snapshot: PasteboardSnapshot
        if let loan, loan.changeCount == pasteboard.changeCount {
            // Still our previous text: what to give back is what was there before it.
            snapshot = loan.snapshot
        } else {
            snapshot = PasteboardSnapshot(of: pasteboard, limits: limits)
            if snapshot.droppedTypes > 0 {
                Self.logger.notice("Clipboard saved without \(snapshot.droppedTypes, privacy: .public) of its types")
            }
        }
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: .nspasteboardTransient)
        item.setData(Data(), forType: .nspasteboardConcealed)
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.writeObjects([item])
        let changeCount = pasteboard.changeCount
        loan = (snapshot, changeCount)
        return changeCount
    }

    /// Restores the clipboard if its last change is the `put(_:)` that returned `changeCount`.
    func giveBack(ifUnchangedSince changeCount: Int) {
        // After a newer put, that put's own giveBack follows.
        guard let loan, loan.changeCount == changeCount else { return }
        self.loan = nil
        guard pasteboard.changeCount == changeCount else { return }
        loan.snapshot.restore(to: pasteboard)
    }
}
