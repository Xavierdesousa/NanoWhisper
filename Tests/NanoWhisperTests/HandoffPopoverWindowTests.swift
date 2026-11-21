import AppKit
import Carbon
import SwiftUI
import Testing
@testable import NanoWhisper

/// The real end-of-onboarding popover (`HandoffPopoverController.makePopover()`), anchored to a
/// real status item of the test process. Opt-in, because it puts an item in the menu bar and
/// shows a popover:
///
///     NANOWHISPER_WINDOW_TESTS=1 swift test --filter HandoffPopoverWindow
///
/// With `NANOWHISPER_CAPTURE_DIR=<dir>` too, the popover window (frame, arrow, content) is
/// saved as `<dir>/handoff-popover-*.png`. Its material is drawn by the window server, so the
/// capture shows the frame view only (its glass edge comes out as a colored fringe).
@Suite("HandoffPopoverWindow", .serialized, .enabled(if: ProcessInfo.processInfo.environment["NANOWHISPER_WINDOW_TESTS"] != nil))
@MainActor
struct HandoffPopoverWindowTests {
    private static let captureDirectory = ProcessInfo.processInfo.environment["NANOWHISPER_CAPTURE_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    private static func message(_ popover: MenuBarHandoff.Popover, _ engine: EngineState) throws -> HandoffMessage {
        try #require(HandoffMessage.make(
            popover, appName: "NanoWhisper", modelName: "Parakeet Ultra", engine: engine,
            shortcut: Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
            recorderPosition: .topCenter
        ))
    }

    @Test("Under the status item, 300 pt wide, follows its text, closed by OK and Escape")
    func popoverUnderStatusItem() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        defer { NSStatusBar.system.removeStatusItem(item) }
        let button = try #require(item.button)
        button.image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Test")
        try await Task.sleep(for: .milliseconds(300))
        let buttonWindow = try #require(button.window)
        let buttonOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        let downloading = EngineState(isSettingUp: true, progressText: "Downloading model (48%)...")
        let ready = EngineState(isReady: true, setupComplete: true)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            let content = HandoffPopoverController(message: try Self.message(.setupDone, downloading))
            var dismissals = 0
            content.onDismiss = { dismissals += 1 }
            let popover = content.makePopover()
            popover.animates = false
            popover.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            button.highlight(true)
            try await Task.sleep(for: .milliseconds(400))

            #expect(popover.isShown)
            let popoverWindow = try #require(content.view.window)
            expectUnder(popoverWindow, buttonOnScreen)
            #expect(abs(content.view.frame.width - HandoffPopoverView.width) < 1)
            #expect(!NSApp.isActive) // shown without activating the app
            try capture(popoverWindow, "handoff-popover-downloading-\(suffix)")

            // The model becomes ready while it is open: the text changes in place and the
            // popover keeps pointing at the item.
            content.update(try Self.message(.modelReady, ready))
            try await Task.sleep(for: .milliseconds(400))
            expectUnder(popoverWindow, buttonOnScreen)
            try capture(popoverWindow, "handoff-popover-ready-\(suffix)")

            content.update(try Self.message(.setupDone, ready))
            try await Task.sleep(for: .milliseconds(400))
            expectUnder(popoverWindow, buttonOnScreen)
            try capture(popoverWindow, "handoff-popover-setup-done-\(suffix)")

            // A click on OK (bottom right of the content), sent to the popover's window while
            // the app is not active. The hosting view is flipped.
            let okInContent = NSPoint(x: HandoffPopoverView.width - 16 - 14, y: content.view.bounds.height - 14 - 12)
            let okInWindow = content.view.convert(okInContent, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try #require(NSEvent.mouseEvent(
                    with: type, location: okInWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: popoverWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
                ))
                popoverWindow.sendEvent(event)
                try await Task.sleep(for: .milliseconds(50))
            }
            #expect(dismissals == 1, "OK")

            content.cancelOperation(nil) // Escape
            #expect(dismissals == 2, "Escape")
            popover.close()
            button.highlight(false)
            try await Task.sleep(for: .milliseconds(300))
            #expect(!popover.isShown)
        }
    }

    /// The popover's top (its arrow) is at the item's bottom edge, and it spans the item. The
    /// window has a 13 pt margin for the shadow, so its frame starts a few points above the tip
    /// (measured: 3 pt above the item's bottom, macOS 27.2).
    private func expectUnder(_ popoverWindow: NSWindow, _ button: NSRect) {
        let frame = popoverWindow.frame
        #expect(frame.maxY <= button.minY + 14, "popover \(frame), item \(button)")
        #expect(frame.maxY >= button.minY - 12, "popover \(frame), item \(button)")
        #expect(frame.minX < button.midX && frame.maxX > button.midX, "popover \(frame), item \(button)")
    }

    private func capture(_ window: NSWindow, _ name: String) throws {
        guard let directory = Self.captureDirectory else { return }
        let frameView = try #require(window.contentView?.superview)
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
