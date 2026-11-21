import AppKit
import Combine
import SwiftUI
import Testing
@testable import NanoWhisper

/// The real onboarding window shown on screen (fixture content, no `AppState`, no microphone),
/// with the real recorder panel for Try it. Opt-in, because it shows windows and activates the
/// test process:
///
///     NANOWHISPER_WINDOW_TESTS=1 swift test --filter OnboardingWindow
///
/// With `NANOWHISPER_CAPTURE_DIR=<dir>` too, PNGs of the welcome's entrance (frames from 0 to
/// 9 s) and of Try it with the recorder at its place on the screen are saved in `<dir>`.
@Suite("OnboardingWindow", .serialized, .enabled(if: ProcessInfo.processInfo.environment["NANOWHISPER_WINDOW_TESTS"] != nil))
@MainActor
struct OnboardingWindowTests {

    @Test("Welcome: the page arrives with the recorder idle, it records 125 ms later, then stops paused at 0:03")
    func welcomeEntrance() async throws {
        let session = try ActiveApp()
        defer { session.end() }
        let demo = WelcomeRecorderDemo()
        let window = try Self.show(page: .welcome, demo: demo, dark: false)
        defer { window.close() }
        #expect(window.frame.size == OnboardingWindowPlacement.size)

        let recording = WelcomeDictation.recordingStarts
        let end = WelcomeDictation.freezeTime
        var captured: [(Double, NSBitmapImageRep)] = []
        let start = Date()
        // The recorder has faded in (`recorderAppears` + `FadeUp.duration`) and waits idle until
        // `recording`: two frames in that short span, the second just before it.
        let idleStart = WelcomeDictation.recorderAppears + FadeUp.duration + 0.03
        let idleEnd = recording - 0.05
        for time in [0.12, idleStart, idleEnd, recording + 0.5, recording + 1.5, recording + 2.5,
                     end + 0.3, end + 1.0] {
            let wait = time - Date().timeIntervalSince(start)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            captured.append((time, try Self.capture(window)))
            if time == idleEnd {
                #expect(demo.phase == .idle, "idle until the recording starts")
                #expect(demo.viewModel.isPaused)
                #expect(demo.viewModel.elapsedFormatted == "0:00")
                #expect(demo.viewModel.visibleTranscript?.isEmpty == true)
            }
            if time == recording + 1.5 {
                #expect(demo.phase == .recording)
                #expect(!demo.viewModel.isPaused)
                #expect(demo.viewModel.visibleTranscript?.isEmpty == false, "words are arriving")
            }
        }
        #expect(demo.isFrozen)
        #expect(demo.viewModel.isPaused)
        #expect(demo.viewModel.elapsedFormatted == "0:03")
        #expect(demo.viewModel.visibleTranscript?.volatileText == " we’ll see")
        #expect(demo.viewModel.waveform.isStatic)

        // Paused means still: the idle card and the frozen card draw the same pixels over time
        // (no capsule pulse, no caret blink, no waveform glide).
        let idleA = try #require(captured.first { $0.0 == idleStart }?.1)
        let idleB = try #require(captured.first { $0.0 == idleEnd }?.1)
        let restA = try #require(captured.first { $0.0 == end + 0.3 }?.1)
        let restB = try #require(captured.first { $0.0 == end + 1.0 }?.1)
        let recorder = Self.recorderRect(in: window)
        #expect(Self.samePixels(idleA, idleB, in: recorder), "the idle recorder does not move")
        #expect(Self.samePixels(restA, restB, in: recorder), "the frozen recorder does not move")

        if let directory = OverlayCapture.directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (time, rep) in captured {
                try OverlayCapture.write(rep, String(format: "onboarding-welcome-t%05.2fs", time), in: directory)
            }
            // The resting frame in dark too.
            let dark = try Self.show(page: .welcome, demo: WelcomeRecorderDemo(), dark: true)
            try await Task.sleep(nanoseconds: UInt64((end + 0.5) * 1_000_000_000))
            try OverlayCapture.write(try Self.capture(dark), "onboarding-welcome-rest-dark", in: directory)
            dark.close()
        }
    }

    /// The recorder card's area in the welcome window's frame view, in points (y down): the
    /// card is 380 pt wide, centered, below the catch phrase.
    private static func recorderRect(in window: NSWindow) -> NSRect {
        let width = window.frame.width
        return NSRect(x: (width - OverlayMetrics.cardWidth) / 2 - 8, y: 250, width: OverlayMetrics.cardWidth + 16, height: 140)
    }

    /// Whether two captures have the same pixels in `rect` (points, y down), within a small
    /// tolerance for compositing noise.
    private static func samePixels(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in rect: NSRect) -> Bool {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return false }
        let scale = CGFloat(a.pixelsWide) / a.size.width
        let x0 = max(0, Int(rect.minX * scale)), x1 = min(a.pixelsWide, Int(rect.maxX * scale))
        let y0 = max(0, Int(rect.minY * scale)), y1 = min(a.pixelsHigh, Int(rect.maxY * scale))
        var differing = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let ca = a.colorAt(x: x, y: y), let cb = b.colorAt(x: x, y: y) else { continue }
                let delta = abs(ca.redComponent - cb.redComponent) + abs(ca.greenComponent - cb.greenComponent)
                    + abs(ca.blueComponent - cb.blueComponent)
                if delta > 0.03 { differing += 1 }
            }
        }
        return differing == 0
    }

    @Test("Try it: the real recorder at Top Center never covers the window", arguments: [false, true])
    func tryItWithRecorder(dark: Bool) async throws {
        let session = try ActiveApp()
        defer { session.end() }
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = previousAppearance }

        let state = TryState()
        let window = try Self.show(page: .tryIt, demo: WelcomeRecorderDemo(), dark: dark, tryIt: state)
        defer { window.close() }
        OnboardingWindowController.place(window, recorder: .topCenter, on: window.screen)

        // The recorder, shown the way `AppState.startRecording` shows it, with live words.
        let (overlay, levels) = (RecordingOverlayController(), PassthroughSubject<Float, Never>())
        let id = UUID()
        overlay.show(audioLevelPublisher: levels, transcriptID: id, position: .topCenter)
        let feeder = LevelFeeder(levels)
        defer { feeder.stop() }
        state.stage = .listening
        var transcript = LiveTranscript()
        transcript.update(partial: "Let’s meet on Thursday at ten and go through the")
        transcript.update(partial: "Let’s meet on Thursday at ten and go through the launch checklist")
        overlay.updateTranscript(transcript, for: id)
        try await Task.sleep(nanoseconds: 1_400_000_000)

        let panel = try #require(overlay.window)
        #expect(panel.screen == window.screen, "both on the screen with the pointer")
        #expect(panel.frame.size == NSSize(width: 380, height: 106), "the card, the recorder at its largest")
        #expect(!panel.frame.intersects(window.frame), "the recorder never covers the window")

        let suffix = dark ? "dark" : "light"
        let wallpaper: OverlayCapture.Wallpaper = dark ? .dark : .light
        let directory = OverlayCapture.directory
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Self.saveScreen(window: window, panel: panel, wallpaper: wallpaper,
                                name: "onboarding-try-listening-on-screen-\(suffix)", in: directory)
            try Self.saveSmallScreen(window: window, panel: panel, wallpaper: wallpaper,
                                     name: "onboarding-try-listening-1440x900-\(suffix)", in: directory)
        }

        feeder.stop()
        overlay.transitionToLoading()
        state.stage = .transcribing
        try await Task.sleep(nanoseconds: 900_000_000)
        if let directory {
            try Self.saveScreen(window: window, panel: panel, wallpaper: wallpaper,
                                name: "onboarding-try-transcribing-on-screen-\(suffix)", in: directory)
        }
        transcript.finalize("Let’s meet on Thursday at ten and go through the launch checklist together.")
        overlay.updateTranscript(transcript, for: id)
        overlay.dismiss(showing: .done)
        state.stage = .result("Let’s meet on Thursday at ten and go through the launch checklist together.")
        try await Task.sleep(nanoseconds: 400_000_000)
        if let directory {
            try Self.saveScreen(window: window, panel: panel, wallpaper: wallpaper,
                                name: "onboarding-try-result-done-on-screen-\(suffix)", in: directory)
        }
        await OverlayWindowTests.waitUntilHidden(overlay)
        if let directory {
            try Self.saveScreen(window: window, panel: nil, wallpaper: wallpaper,
                                name: "onboarding-try-result-on-screen-\(suffix)", in: directory)
        }
    }

    // MARK: - Helpers

    /// The Try it inputs, changed by the test as the app would change them.
    final class TryState: ObservableObject {
        @Published var stage: TryItStage = .ready
    }

    /// The real window (`OnboardingWindowController.makeWindow`) with fixture content, placed as
    /// the app places it and shown, key, in an active app.
    private static func show(
        page: OnboardingPage, demo: WelcomeRecorderDemo, dark: Bool, tryIt: TryState? = nil
    ) throws -> NSWindow {
        let content = OnboardingTestHost(
            model: OnboardingModel(page: page), demo: demo, tryState: tryIt ?? TryState(),
            context: Fixtures.onboardingContext(microphone: .granted, accessibility: .granted)
        )
        let window = OnboardingWindowController.makeWindow(content: content)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        OnboardingWindowController.place(window, recorder: .topCenter)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    static func capture(_ window: NSWindow) throws -> NSBitmapImageRep {
        try #require(OverlayCapture.capturePanel(window))
    }

    /// The whole screen (1 pt = 1 px): wallpaper, the menu bar band, the onboarding window and
    /// the recorder at their real frames.
    private static func saveScreen(
        window: NSWindow, panel: NSWindow?, wallpaper: OverlayCapture.Wallpaper, name: String, in directory: URL
    ) throws {
        let screen = try #require(window.screen)
        let origin = screen.frame.origin
        let place = { (frame: NSRect) in frame.offsetBy(dx: -origin.x, dy: -origin.y) }
        try saveComposite(
            size: screen.frame.size, visible: place(screen.visibleFrame), wallpaper: wallpaper,
            window: (try capture(window), place(window.frame)),
            panel: try panel.map { (try capture($0), place($0.frame)) },
            name: name, in: directory
        )
    }

    /// The same windows on a 1440 × 900 screen (menu bar 24 pt), placed by the app's rules.
    private static func saveSmallScreen(
        window: NSWindow, panel: NSWindow, wallpaper: OverlayCapture.Wallpaper, name: String, in directory: URL
    ) throws {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 876)
        let windowFrame = OnboardingWindowPlacement.frame(in: visible, recorder: .topCenter)
        let panelFrame = RecorderPosition.topCenter.initialFrame(size: panel.frame.size, in: visible)
        #expect(!panelFrame.intersects(windowFrame))
        try saveComposite(
            size: NSSize(width: 1440, height: 900), visible: visible, wallpaper: wallpaper,
            window: (try capture(window), windowFrame), panel: (try capture(panel), panelFrame),
            name: name, in: directory
        )
    }

    private static func saveComposite(
        size: NSSize, visible: NSRect, wallpaper: OverlayCapture.Wallpaper,
        window: (NSBitmapImageRep, NSRect), panel: (NSBitmapImageRep, NSRect)?, name: String, in directory: URL
    ) throws {
        let out = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        OverlayCapture.drawWallpaper(wallpaper, in: NSRect(origin: .zero, size: size))
        // The menu bar (outside the visible frame, at the top).
        NSColor(white: wallpaper == .light ? 1 : 0.12, alpha: 0.7).setFill()
        NSRect(x: 0, y: visible.maxY, width: size.width, height: size.height - visible.maxY).fill()
        // The window, with a drawn shadow (the window server's is not in captures).
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: wallpaper == .light ? 0.22 : 0.5)
        shadow.shadowOffset = NSSize(width: 0, height: -22)
        shadow.shadowBlurRadius = 56
        shadow.set()
        let clip = NSBezierPath(roundedRect: window.1, xRadius: 12, yRadius: 12)
        NSColor.black.setFill()
        clip.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        window.0.draw(in: window.1, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        if let panel {
            OverlayCapture.drawPanel(panel.0, in: panel.1)
        }
        NSGraphicsContext.restoreGraphicsState()
        try OverlayCapture.write(out, name, in: directory)
    }
}

/// The onboarding content with fixture inputs, its Try it stage driven by the test.
private struct OnboardingTestHost: View {
    @ObservedObject var model: OnboardingModel
    let demo: WelcomeRecorderDemo
    @ObservedObject var tryState: OnboardingWindowTests.TryState
    let context: SettingsContext

    var body: some View {
        var inputs = Fixtures.tryIt(tryState.stage)
        inputs.showsLiveWords = true
        return OnboardingContent(
            model: model, demo: demo, context: context, tryIt: inputs, appIcon: Fixtures.appIcon,
            modelChoice: { AnyView(EmptyView()) }
        )
    }
}

/// The test process as a regular, active app while windows are shown (key windows draw their
/// controls in the active look).
@MainActor
private struct ActiveApp {
    private let previousPolicy: NSApplication.ActivationPolicy

    init() throws {
        let app = NSApplication.shared
        previousPolicy = app.activationPolicy()
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
    }

    func end() {
        NSApplication.shared.setActivationPolicy(previousPolicy)
    }
}
