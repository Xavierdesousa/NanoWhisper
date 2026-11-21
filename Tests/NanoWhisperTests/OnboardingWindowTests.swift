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

    @Test("Opening scene: the title moment waits, Return presses Get Started, the welcome arrives, the recorder records 125 ms after it to 0:04, transcribes, pastes, then rests still under the veil")
    func welcomeEntrance() async throws {
        let session = try ActiveApp()
        defer { session.end() }
        let demo = WelcomeRecorderDemo()
        let scene = OpeningSceneClock()
        let window = try Self.show(page: .welcome, demo: demo, scene: scene, dark: false)
        defer { window.close() }
        #expect(window.frame.size == OnboardingWindowPlacement.size)

        // The opening scene up to the title moment; CPU of this process while it plays (the
        // window server's compositing is not counted).
        let sceneStart = Date()
        let cpuBefore = Self.cpuTime()
        try await Task.sleep(nanoseconds: UInt64((OpeningScene.Times.titleMomentEnds + 0.1) * 1_000_000_000))
        let entranceCPU = (Self.cpuTime() - cpuBefore) / Date().timeIntervalSince(sceneStart)
        #expect(scene.isWaiting, "the title moment waits for the press")
        #expect(!scene.isAnimating, "no frames while it waits (the breathing is an animation)")
        let waitCPUStart = Self.cpuTime()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let waitingCPU = Self.cpuTime() - waitCPUStart
        let titleMoment = try Self.capture(window)

        // Return presses Get Started.
        let travelCPUStart = Self.cpuTime()
        Self.pressReturn(in: window)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(scene.isPressed, "Return pressed Get Started")
        let pressDate = try #require(scene.pressDate)
        var travelCPU = 0.0

        let recording = WelcomeDictation.recordingStarts
        let end = WelcomeDictation.recordingEnds
        // The veil has faded in.
        let rest = WelcomeDictation.endsAt(stoppedAt: nil) + WelcomeDictation.veilFade + 0.1
        var captured: [(Double, NSBitmapImageRep)] = [(-1, titleMoment)]
        let start = pressDate
        // The recorder has faded in (`recorderAppears` + 0.45 s) and waits idle until
        // `recording`: two frames in that short span, the second just before it.
        let idleStart = WelcomeDictation.entranceEnds + 0.02
        let idleEnd = recording - 0.04
        // The recorder's dictation (as before the scene), between two captures: the baseline.
        var dictationCPU = (start: 0.0, date: Date(), value: 0.0)
        let settled = OpeningScene.Times.sceneSettles
        for time in [idleStart, idleEnd, settled, recording + 0.5, recording + 1.5, recording + 2.5, recording + 4.1,
                     end + 0.45, end + 0.95, rest, rest + 1.0] {
            let wait = time - Date().timeIntervalSince(start)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            if time == settled {
                // The travel and the welcome's arrival (two captures included, ~3 % of it).
                travelCPU = (Self.cpuTime() - travelCPUStart) / Date().timeIntervalSince(pressDate)
                #expect(scene.isSettled && !scene.isAnimating, "the scene's frames stop once the welcome has arrived")
                continue
            }
            if time == recording + 1.5 {
                dictationCPU.value = (Self.cpuTime() - dictationCPU.start) / Date().timeIntervalSince(dictationCPU.date)
            }
            captured.append((time, try Self.capture(window)))
            if time == recording + 0.5 { dictationCPU = (Self.cpuTime(), Date(), 0) }
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
            if time == recording + 4.1 { #expect(demo.viewModel.elapsedFormatted == "0:04") }
            if time == end + 0.45 { #expect(demo.phase == .transcribing && demo.viewModel.state == .loading) }
            if time == end + 0.95 { #expect(demo.phase == .pasted && demo.viewModel.state == .finished(.pasted)) }
        }
        // At rest (nothing moves): the baseline of this test process.
        let restCPUStart = Self.cpuTime()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let restCPU = Self.cpuTime() - restCPUStart
        print(String(format: "Opening scene CPU (test process): entrance %.0f %%, waiting %.0f %%, travel %.0f %%, "
                     + "dictation %.0f %% (as before the scene), at rest %.0f %%",
                     entranceCPU * 100, waitingCPU * 100, travelCPU * 100, dictationCPU.value * 100, restCPU * 100))
        #expect(demo.phase == .ended && demo.showsReplay)
        #expect(!demo.isPlaying, "its clock is stopped under the veil")
        #expect(demo.viewModel.elapsedFormatted == "0:04")
        #expect(demo.viewModel.visibleTranscript?.finalText == OnboardingText.welcomeSentence)
        #expect(restCPU < 0.03, "nothing animates under the veil: \(restCPU)")

        // Paused means still: the idle card and the card under the veil draw the same pixels
        // over time (no capsule pulse, no caret blink, no waveform glide).
        let idleA = try #require(captured.first { $0.0 == idleStart }?.1)
        let idleB = try #require(captured.first { $0.0 == idleEnd }?.1)
        let restA = try #require(captured.first { $0.0 == rest }?.1)
        let restB = try #require(captured.first { $0.0 == rest + 1.0 }?.1)
        let recorder = Self.recorderRect(in: window)
        #expect(Self.samePixels(idleA, idleB, in: recorder), "the idle recorder does not move")
        #expect(Self.samePixels(restA, restB, in: recorder), "the recorder under the veil does not move")

        if let directory = OverlayCapture.directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (time, rep) in captured {
                let name = time < 0 ? "onboarding-welcome-title-moment" : String(format: "onboarding-welcome-press+%05.2fs", time)
                try OverlayCapture.write(rep, name, in: directory)
            }
        }
    }

    /// Hover (Stop under the pointer anywhere over the card) is not tested here: it follows the
    /// real pointer, whose events reach a window only through `NSApp.nextEvent`, and calling that
    /// in a Swift Testing process ended the process at the next `await` (exit 0, 2026-11-21).
    /// It was checked once by hand that way: wiki onboarding-and-settings, the welcome's recorder.
    @Test("The welcome's recorder: Stop (shown under the pointer) ends the recording; Replay plays it again from 0:00")
    func welcomeStopAndReplay() async throws {
        let session = try ActiveApp()
        defer { session.end() }
        let demo = WelcomeRecorderDemo()
        let scene = OpeningSceneClock()
        let window = try Self.show(page: .welcome, demo: demo, scene: scene, dark: true)
        defer { window.close() }
        try await Task.sleep(nanoseconds: UInt64((OpeningScene.Times.buttonPressable + 0.1) * 1_000_000_000))
        Self.pressReturn(in: window)
        try await Task.sleep(nanoseconds: UInt64((WelcomeDictation.recordingStarts + 0.6) * 1_000_000_000))
        #expect(demo.phase == .recording)
        let card = try #require(try Self.recorderFrame(in: window), "the recorder card in a capture")
        #expect(abs(card.width - OverlayMetrics.cardWidth) < 1 && abs(card.height - 106) < 1, "\(card)")

        // The pointer over it, as its hover sets it: Stop instead of the timer.
        demo.viewModel.isPointerOver = true
        try await Task.sleep(nanoseconds: 300_000_000)
        if let directory = OverlayCapture.directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try OverlayCapture.write(try Self.capture(window), "onboarding-welcome-pointer-stop", in: directory)
        }

        // A click on Stop (where the timer was): Transcribing at once, then Pasted, then the veil.
        let stop = NSPoint(x: card.maxX - OverlayMetrics.trailingPadding - OverlayMetrics.trailingSlotWidth / 2,
                           y: card.maxY - OverlayMetrics.headerHeight / 2)
        try await Self.click(at: stop, in: window)
        #expect(demo.stoppedAt != nil, "Stop was clicked")
        #expect(demo.phase == .transcribing)
        try await Task.sleep(nanoseconds: 1_300_000_000)
        #expect(demo.phase == .ended && demo.showsReplay)
        #expect(!demo.isPlaying, "its clock is stopped under the veil")

        // Replay, below the pasted line: from 0:00 again, then the whole flow to the veil.
        try await Self.click(at: NSPoint(x: card.midX, y: card.minY + 26), in: window)
        #expect(demo.phase == .recording, "Replay was clicked")
        #expect(demo.viewModel.elapsedFormatted == "0:00")
        try await Task.sleep(nanoseconds: UInt64((WelcomeDictation.recordingDuration + 1.4) * 1_000_000_000))
        #expect(demo.phase == .ended, "the whole flow again, to the veil")
    }

    /// The welcome recorder's card in a dark window (points, AppKit coordinates), found in a
    /// capture: its near-black surface and the violet glow inside its edge, on the window's
    /// #1F1F1F (its drop shadows only darken that grey a little).
    private static func recorderFrame(in window: NSWindow) throws -> NSRect? {
        let rep = try capture(window)
        let scale = CGFloat(rep.pixelsWide) / rep.size.width
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var pixel = [Int](repeating: 0, count: 4)
        // Between the catch phrase and the facts.
        for y in Int(220 * scale)..<Int(440 * scale) {
            for x in 0..<rep.pixelsWide {
                rep.getPixel(&pixel, atX: x, y: y)
                let (r, g, b) = (pixel[0], pixel[1], pixel[2])
                let surface = r < 14 && g < 14 && b < 14
                let glow = b > r + 12 && b > g + 25
                guard surface || glow else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        let top = CGFloat(minY) / scale, bottom = CGFloat(maxY + 1) / scale
        return NSRect(x: CGFloat(minX) / scale, y: window.frame.height - bottom,
                      width: CGFloat(maxX + 1 - minX) / scale, height: bottom - top)
    }

    /// A click, sent to the window as the window server would (down, then up 50 ms later).
    private static func click(at point: NSPoint, in window: NSWindow) async throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            window.sendEvent(event)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    @Test("Open Onboarding again: the same window restarts from the opening scene; without restart it is only brought front")
    func restartFromScene() async throws {
        let session = try ActiveApp()
        defer { session.end() }
        let controller = OnboardingWindowController()
        var scenes: [OpeningSceneClock] = []
        var closes = 0
        func content() -> AnyView {
            let scene = OpeningSceneClock()
            scenes.append(scene)
            return AnyView(OnboardingTestHost(
                model: OnboardingModel(page: .welcome), demo: WelcomeRecorderDemo(), scene: scene, tryState: TryState(),
                context: Fixtures.onboardingContext(microphone: .granted, accessibility: .granted)))
        }
        controller.show(restart: true, recorder: .topCenter, onClose: { closes += 1 }, makeContent: content)
        let window = try #require(controller.openWindow)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(scenes.count == 1)
        #expect(scenes[0].hasStarted)
        #expect(scenes[0].press(reduceMotion: false), "the first run reaches the welcome")
        let frame = window.frame

        // Finish Setup… / --onboarding: the open window as it is.
        controller.show(restart: false, recorder: .topCenter, onClose: { closes += 1 }, makeContent: content)
        #expect(scenes.count == 1)
        #expect(controller.openWindow === window)

        // The debug button: the same window, new content, the scene from its start.
        controller.show(restart: true, recorder: .topCenter, onClose: { closes += 1 }, makeContent: content)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(scenes.count == 2)
        #expect(controller.openWindow === window)
        #expect(window.frame == frame, "the window stays where it is")
        #expect(scenes[1].hasStarted && !scenes[1].isPressed, "the new scene plays from its start")
        #expect(closes == 0, "restarting is not closing")
    }

    /// CPU time (user + system) of this process, in seconds.
    private static func cpuTime() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Return, as the keyboard sends it to the key window.
    private static func pressReturn(in window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                isARepeat: false, keyCode: 36
            ) else { continue }
            NSApp.sendEvent(event)
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
        let window = try Self.show(page: .tryIt, demo: WelcomeRecorderDemo(), scene: OpeningSceneClock(), dark: dark, tryIt: state)
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
        page: OnboardingPage, demo: WelcomeRecorderDemo, scene: OpeningSceneClock, dark: Bool, tryIt: TryState? = nil
    ) throws -> NSWindow {
        let content = OnboardingTestHost(
            model: OnboardingModel(page: page), demo: demo, scene: scene, tryState: tryIt ?? TryState(),
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
    let scene: OpeningSceneClock
    @ObservedObject var tryState: OnboardingWindowTests.TryState
    let context: SettingsContext

    var body: some View {
        var inputs = Fixtures.tryIt(tryState.stage)
        inputs.showsLiveWords = true
        return OnboardingContent(
            model: model, demo: demo, scene: scene, context: context, tryIt: inputs, appIcon: Fixtures.appIcon,
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
