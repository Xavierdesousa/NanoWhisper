import AppKit

/// Centers a window on the screen where the mouse cursor currently is.
func centerOnCurrentScreen(_ window: NSWindow) {
    // Disable state restoration so macOS doesn't override our position
    window.restorationClass = nil
    window.isRestorable = false

    let mouseLocation = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
        ?? NSScreen.main
        ?? NSScreen.screens.first

    guard let screen = screen else { return }

    let screenFrame = screen.visibleFrame
    let windowSize = window.frame.size
    let x = screenFrame.midX - windowSize.width / 2
    let y = screenFrame.midY - windowSize.height / 2

    window.setFrame(
        NSRect(x: x, y: y, width: windowSize.width, height: windowSize.height),
        display: true
    )
}
