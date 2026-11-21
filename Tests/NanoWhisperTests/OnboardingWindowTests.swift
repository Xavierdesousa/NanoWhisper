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
/// 4 s) and of Try it with the recorder at its place on the screen are saved in `<dir>`.
@Suite("OnboardingWindow", .serialized, .enabled(if: ProcessInfo.processInfo.environment["NANOWHISPER_WINDOW_TESTS"] != nil))
@MainActor
struct OnboardingWindowTests {

    @Test("Welcome: the elements arrive, the recorder plays its dictation, then rests at 0:03")
    func welcomeEntrance() async throws {
        let session = try ActiveApp()
        defer { session.end() }
        let demo = WelcomeRecorderDemo()
        let window = try Self.show(page: .welcome, demo: demo, dark: false)
        defer { window.close() }
        #expect(window.frame.size == OnboardingWindowPlacement.size)

        var captured: [(Double, NSBitmapImageRep)] = []
        let start = Date()
        for time in [0.12, 0.3, 0.55, 0.9, 1.5, 2.2, 3.0, 4.2] {
            let wait = time - Date().timeIntervalSince(start)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            captured.append((time, try Self.capture(window)))
            if time == 2.2 {
                let text = demo.viewModel.visibleTranscript
                #expect(text?.isEmpty == false, "words are arriving")
                #expect(!demo.isFrozen)
            }
        }
        #expect(demo.isFrozen)
        #expect(demo.viewModel.elapsedFormatted == "0:03")
        #expect(demo.viewModel.visibleTranscript?.volatileText == " team review")
        #expect(demo.viewModel.waveform.isStatic)

        if let directory = OverlayCapture.directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (time, rep) in captured {
                try OverlayCapture.write(rep, String(format: "onboarding-welcome-t%.2fs", time), in: directory)
            }
            // The resting frame in dark too.
            let dark = try Self.show(page: .welcome, demo: WelcomeRecorderDemo(), dark: true)
            try await Task.sleep(nanoseconds: 4_200_000_000)
            try OverlayCapture.write(try Self.capture(dark), "onboarding-welcome-rest-dark", in: directory)
            dark.close()
        }
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
