import AppKit
import Combine
import SwiftUI
import Testing
@testable import NanoWhisper

/// The real recording overlay panel, shown on screen and captured from its window (not an
/// offscreen render of the SwiftUI view). Opt-in, because it shows windows and activates the
/// test process:
///
///     NANOWHISPER_WINDOW_TESTS=1 swift test --filter OverlayWindow
@Suite("OverlayWindow", .serialized, .enabled(if: ProcessInfo.processInfo.environment["NANOWHISPER_WINDOW_TESTS"] != nil))
@MainActor
struct OverlayWindowTests {

    @Test("The panel grows with the live text instead of clipping it")
    func panelFollowsContent() async throws {
        let (controller, levels) = (RecordingOverlayController(), PassthroughSubject<Float, Never>())
        let id = UUID()
        controller.show(audioLevelPublisher: levels, transcriptID: id)
        try await Task.sleep(nanoseconds: 300_000_000)
        let compact = try #require(Self.overlayWindow()).frame

        var transcript = LiveTranscript()
        transcript.update(partial: "Bonjour, ceci est un test")
        controller.updateTranscript(transcript, for: id)
        try await Task.sleep(nanoseconds: 300_000_000)

        let window = try #require(Self.overlayWindow())
        let content = try #require(window.contentView)
        #expect(window.frame.size == content.fittingSize)
        #expect(window.frame.width > compact.width)
        #expect(window.frame.height > compact.height)
        #expect(window.frame.maxY == compact.maxY, "the top edge stays in place")
        await Self.dismissAndWait(controller)
    }

    @Test("The record dot stays in place when the recording starts from a SwiftUI button")
    func dotStaysInPlace() async throws {
        // As in onboarding's Try-it: the app is active, and a SwiftUI button in its key window
        // starts the recording.
        let app = NSApplication.shared
        let previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        defer { app.setActivationPolicy(previousPolicy) }
        let controller = RecordingOverlayController()
        let levels = PassthroughSubject<Float, Never>()
        let host = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 300, height: 160),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = NSHostingView(rootView: Button("Record a Test") {
            controller.show(audioLevelPublisher: levels)
        }.padding(40))
        host.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { host.close() }
        try await Task.sleep(nanoseconds: 500_000_000)

        let center = NSPoint(x: host.contentView!.bounds.midX, y: host.contentView!.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            host.sendEvent(try #require(NSEvent.mouseEvent(
                with: type, location: center, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: host.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        try #require(Self.overlayWindow() != nil, "the synthesized click did not start the recording")

        var centers: [NSPoint] = []
        for _ in 0..<20 {
            if let frame = Self.dotFrame() { centers.append(NSPoint(x: frame.midX, y: frame.midY)) }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(centers.count == 20)
        let xs = centers.map(\.x), ys = centers.map(\.y)
        // The pulse scales the dot about its center; a slide moves the center.
        #expect((xs.max() ?? 0) - (xs.min() ?? 0) <= 2)
        #expect((ys.max() ?? 0) - (ys.min() ?? 0) <= 2)
        await Self.dismissAndWait(controller)
    }

    // MARK: - Helpers

    /// Dismiss and wait until the panel has faded out, so the next test finds only its own.
    private static func dismissAndWait(_ controller: RecordingOverlayController) async {
        controller.dismiss()
        try? await Task.sleep(nanoseconds: 1_400_000_000)
    }

    private static func overlayWindow() -> NSWindow? {
        NSApp.windows.first { String(describing: type(of: $0)).contains("OverlayPanel") && $0.isVisible }
    }

    /// The red dot's frame in pixels of the window's own drawing: red pixels in horizontal
    /// runs of at least 70 % of the dot's width (the level bars are much narrower).
    private static func dotFrame() -> NSRect? {
        guard let frameView = overlayWindow()?.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        let minRun = Int(8 * 0.7 * CGFloat(rep.pixelsWide) / frameView.bounds.width)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            var run = 0
            for x in 0..<rep.pixelsWide {
                let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
                let red = c.map { $0.redComponent > 0.3 && $0.redComponent > $0.greenComponent + 0.2 && $0.redComponent > $0.blueComponent + 0.2 } ?? false
                run = red ? run + 1 : 0
                if run >= minRun {
                    minX = min(minX, x - run + 1); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        return maxX >= 0 ? NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
    }
}
