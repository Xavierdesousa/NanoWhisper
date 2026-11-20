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
///
/// With `NANOWHISPER_CAPTURE_DIR=<dir>` too, every state is also saved as PNGs in `<dir>`, over
/// a light and a dark wallpaper, and at each recorder position on a whole screen.
@Suite("OverlayWindow", .serialized, .enabled(if: ProcessInfo.processInfo.environment["NANOWHISPER_WINDOW_TESTS"] != nil))
@MainActor
struct OverlayWindowTests {

    @Test("The panel grows with the live text instead of clipping it, from its pinned edges",
          arguments: RecorderPosition.allCases)
    func panelFollowsContent(position: RecorderPosition) async throws {
        let (controller, levels) = (RecordingOverlayController(), PassthroughSubject<Float, Never>())
        let id = UUID()
        controller.show(audioLevelPublisher: levels, transcriptID: id, position: position)
        try await Task.sleep(nanoseconds: 300_000_000)
        let compactWindow = try #require(controller.window)
        let compact = compactWindow.frame
        #expect(compact.size == NSSize(width: 184, height: 36))
        let visible = try #require(compactWindow.screen?.visibleFrame)
        #expect(compact == position.initialFrame(size: compact.size, in: visible))

        var transcript = LiveTranscript()
        transcript.update(partial: "Bonjour, ceci est un test")
        controller.updateTranscript(transcript, for: id)
        try await Task.sleep(nanoseconds: 300_000_000)

        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        #expect(window.frame.size == content.fittingSize)
        #expect(window.frame.size == NSSize(width: 380, height: 87))
        switch position.verticalAnchor {
        case .top: #expect(window.frame.maxY == compact.maxY, "the top edge stays in place")
        case .bottom: #expect(window.frame.minY == compact.minY, "the bottom edge stays in place")
        }
        switch position.horizontalAnchor {
        case .left: #expect(window.frame.minX == compact.minX)
        case .center: #expect(abs(window.frame.midX - compact.midX) <= 0.5)
        case .right: #expect(window.frame.maxX == compact.maxX)
        }

        // Transcribing and the final text keep the card's size.
        controller.transitionToLoading()
        transcript.finalize("Bonjour, ceci est un test.")
        controller.updateTranscript(transcript, for: id)
        controller.dismiss(showing: .pasted)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(controller.window?.frame == window.frame)
        await Self.waitUntilHidden(controller)
    }

    @Test("The record indicator stays in place when the recording starts from a SwiftUI button")
    func indicatorStaysInPlace() async throws {
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
        try #require(controller.window != nil, "the synthesized click did not start the recording")
        // The appear animation (scale 0.96 → 1, spring 0.3 s) is meant to move it; after it,
        // nothing may (the bug was a slide that repeated forever).
        try await Task.sleep(nanoseconds: 500_000_000)

        let feeder = LevelFeeder(levels)
        defer { feeder.stop() }
        var centers: [NSPoint] = []
        for _ in 0..<25 {
            if let frame = Self.indicatorFrame(in: controller) { centers.append(NSPoint(x: frame.midX, y: frame.midY)) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(centers.count == 25)
        let xs = centers.map(\.x), ys = centers.map(\.y)
        // The breathing changes the glow, not the capsule; a slide moves its center.
        #expect((xs.max() ?? 0) - (xs.min() ?? 0) <= 2)
        #expect((ys.max() ?? 0) - (ys.min() ?? 0) <= 2)
        await Self.dismissAndWait(controller)
    }

    @Test("The header does not move when the card opens, while transcribing, or for the result")
    func headerStaysInPlace() async throws {
        let (controller, levels) = (RecordingOverlayController(), PassthroughSubject<Float, Never>())
        let id = UUID()
        controller.show(audioLevelPublisher: levels, transcriptID: id)
        try await Task.sleep(nanoseconds: 700_000_000)
        let compact = try #require(Self.indicatorFrame(in: controller))

        var transcript = LiveTranscript()
        transcript.update(partial: "Let’s move the release to Thursday so")
        controller.updateTranscript(transcript, for: id)
        try await Task.sleep(nanoseconds: 400_000_000)
        let card = try #require(Self.indicatorFrame(in: controller))
        controller.transitionToLoading()
        try await Task.sleep(nanoseconds: 400_000_000)
        let transcribing = try #require(Self.indicatorFrame(in: controller, transcribing: true))

        // Same place in the window's top-left corner (pixels, y down from the top).
        #expect(abs(card.midX - compact.midX) <= 1 && abs(card.minY - compact.minY) <= 1)
        #expect(abs(transcribing.midX - compact.midX) <= 1 && abs(transcribing.midY - compact.midY) <= 1)
        controller.dismiss(showing: .pasted)
        await Self.waitUntilHidden(controller)
    }

    @Test("The overlay text is the final text, and the panel keeps the card for it")
    func finalTextShown() async throws {
        let (controller, levels) = (RecordingOverlayController(), PassthroughSubject<Float, Never>())
        let id = UUID()
        controller.show(audioLevelPublisher: levels, transcriptID: id)
        var transcript = LiveTranscript()
        transcript.update(partial: "The notes are ready")
        controller.updateTranscript(transcript, for: id)
        controller.transitionToLoading()
        transcript.finalize("The notes are ready.")
        controller.updateTranscript(transcript, for: id)
        controller.dismiss(showing: .pasted)
        #expect(controller.viewModel.visibleTranscript?.finalText == "The notes are ready.")
        #expect(controller.viewModel.state == .finished(.pasted))
        await Self.waitUntilHidden(controller)
    }

    // MARK: - Captures

    @Test("Captures of every state, light and dark, at every position",
          .enabled(if: OverlayCapture.directory != nil))
    func captures() async throws {
        let directory = try #require(OverlayCapture.directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let previousAppearance = NSApp.appearance
        defer { NSApp.appearance = previousAppearance }

        for wallpaper in OverlayCapture.Wallpaper.allCases {
            NSApp.appearance = NSAppearance(named: wallpaper == .light ? .aqua : .darkAqua)
            try await captureStates(wallpaper: wallpaper, into: directory)
        }
        for position in RecorderPosition.allCases {
            for wallpaper in OverlayCapture.Wallpaper.allCases {
                NSApp.appearance = NSAppearance(named: wallpaper == .light ? .aqua : .darkAqua)
                try await capturePosition(position, wallpaper: wallpaper, into: directory)
            }
        }
        try captureAccessibilityFallbacks(into: directory)
        try capturePicker(into: directory)
    }

    private static let firstLine = "Let’s move the release to Thursday so"
    private static let longPartials = [
        "The notes are ready. Let’s move the release to Thursday so the team has time to review the",
        "The notes are ready. Let’s move the release to Thursday so the team has time to review the changelog and the",
    ]
    private static let finalText = "The notes are ready. Let’s move the release to Thursday so the team has time to review the changelog and the migration notes."

    private func captureStates(wallpaper: OverlayCapture.Wallpaper, into directory: URL) async throws {
        let name = { (state: String) in "state-\(state)-\(wallpaper.rawValue)" }

        // Compact: recording, pointer over it, transcribing, done, nothing to paste, failed.
        for result in [OverlayResult.pasted, .noSpeech, .failed] {
            let (controller, levels) = (RecordingOverlayController(), PassthroughSubject<Float, Never>())
            controller.show(audioLevelPublisher: levels)
            let feeder = LevelFeeder(levels)
            try await Task.sleep(nanoseconds: 1_600_000_000)
            if result == .pasted {
                try OverlayCapture.save(controller, name("1-recording"), wallpaper: wallpaper, in: directory)
                controller.viewModel.isPointerOver = true
                try await Task.sleep(nanoseconds: 300_000_000)
                try OverlayCapture.save(controller, name("2-pointer-over-stop"), wallpaper: wallpaper, in: directory)
                controller.viewModel.isPointerOver = false
            }
            feeder.stop()
            controller.transitionToLoading()
            if result == .pasted {
                try await Task.sleep(nanoseconds: 100_000_000)
                try OverlayCapture.save(controller, name("3a-transcribing-sinking"), wallpaper: wallpaper, in: directory)
                try await Task.sleep(nanoseconds: 700_000_000)
                try OverlayCapture.save(controller, name("3-transcribing"), wallpaper: wallpaper, in: directory)
            }
            controller.dismiss(showing: result)
            try await Task.sleep(nanoseconds: 400_000_000)
            let label = ["pasted": "4-done", "noSpeech": "5-nothing-to-paste", "failed": "6-failed"]
            try OverlayCapture.save(controller, name(label["\(result)"]!), wallpaper: wallpaper, in: directory)
            await Self.waitUntilHidden(controller)
        }

        // Live text: first line, long text, transcribing with text, final text.
        let (controller, levels) = (RecordingOverlayController(), PassthroughSubject<Float, Never>())
        let id = UUID()
        controller.show(audioLevelPublisher: levels, transcriptID: id)
        let feeder = LevelFeeder(levels)
        var transcript = LiveTranscript()
        transcript.update(partial: "Let’s move the release to")
        transcript.update(partial: Self.firstLine)
        controller.updateTranscript(transcript, for: id)
        try await Task.sleep(nanoseconds: 1_400_000_000)
        try OverlayCapture.save(controller, name("7-live-first-line"), wallpaper: wallpaper, in: directory)
        for partial in Self.longPartials { transcript.update(partial: partial) }
        controller.updateTranscript(transcript, for: id)
        try await Task.sleep(nanoseconds: 600_000_000)
        try OverlayCapture.save(controller, name("8-live-long"), wallpaper: wallpaper, in: directory)
        feeder.stop()
        controller.transitionToLoading()
        try await Task.sleep(nanoseconds: 800_000_000)
        try OverlayCapture.save(controller, name("9-live-transcribing"), wallpaper: wallpaper, in: directory)
        transcript.finalize(Self.finalText)
        controller.updateTranscript(transcript, for: id)
        controller.dismiss(showing: .pasted)
        try await Task.sleep(nanoseconds: 500_000_000)
        try OverlayCapture.save(controller, name("10-live-final"), wallpaper: wallpaper, in: directory)
        await Self.waitUntilHidden(controller)
    }

    private func capturePosition(
        _ position: RecorderPosition, wallpaper: OverlayCapture.Wallpaper, into directory: URL
    ) async throws {
        let (controller, levels) = (RecordingOverlayController(), PassthroughSubject<Float, Never>())
        let id = UUID()
        controller.show(audioLevelPublisher: levels, transcriptID: id, position: position)
        let feeder = LevelFeeder(levels)
        defer { feeder.stop() }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        try OverlayCapture.saveOnScreen(controller, "position-\(position.rawValue)-1-compact-\(wallpaper.rawValue)",
                                        wallpaper: wallpaper, in: directory)
        var transcript = LiveTranscript()
        for partial in Self.longPartials { transcript.update(partial: partial) }
        controller.updateTranscript(transcript, for: id)
        try await Task.sleep(nanoseconds: 500_000_000)
        try OverlayCapture.saveOnScreen(controller, "position-\(position.rawValue)-2-live-\(wallpaper.rawValue)",
                                        wallpaper: wallpaper, in: directory)
        controller.dismiss(showing: .pasted)
        await Self.waitUntilHidden(controller)
    }

    /// Reduce Motion and Reduce Transparency cannot be switched on for a test process, so the
    /// same view is hosted in a test panel with the environment values set.
    private func captureAccessibilityFallbacks(into directory: URL) throws {
        let model = RecordingOverlayViewModel(waveform: OverlayWaveform(staticHistory: RecordingOverlayPreview.history))
        model.elapsedSeconds = 12
        for (name, state, reduceMotion, reduceTransparency) in [
            ("reduce-transparency-recording", OverlayState.recording, false, true),
            ("reduce-motion-transcribing", OverlayState.loading, true, false),
        ] {
            model.state = state
            let view = RecordingOverlayView(viewModel: model, onStop: {})
                .environment(\._accessibilityReduceMotion, reduceMotion)
                .environment(\._accessibilityReduceTransparency, reduceTransparency)
            for wallpaper in OverlayCapture.Wallpaper.allCases {
                try OverlayCapture.saveHosted(view, named: "\(name)-\(wallpaper.rawValue)", wallpaper: wallpaper, in: directory)
            }
        }
    }

    private func capturePicker(into directory: URL) throws {
        for position in RecorderPosition.allCases {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let picker = PickerHarness(selection: position)
                    .padding(14)
                    .background(Color(nsColor: .windowBackgroundColor))
                let hosting = NSHostingView(rootView: picker)
                hosting.appearance = NSAppearance(named: appearance)
                let size = hosting.fittingSize
                hosting.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: appearance)
                window.contentView = hosting
                window.alphaValue = 0
                window.orderFrontRegardless()
                defer { window.orderOut(nil) }
                hosting.layoutSubtreeIfNeeded()
                let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                let suffix = appearance == .aqua ? "light" : "dark"
                try rep.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("picker-\(position.rawValue)-\(suffix).png"))
            }
        }
    }

    // MARK: - Helpers

    /// Dismiss and wait for the hold and fade-out.
    private static func dismissAndWait(_ controller: RecordingOverlayController, showing result: OverlayResult = .done) async {
        controller.dismiss(showing: result)
        await waitUntilHidden(controller)
    }

    /// Waits for the hold and fade-out (at most 1.6 s). In a test process the window's
    /// `animator()` alpha animations do not run (no `NSApp.run()`): the panel stays at
    /// alpha 0 and is never ordered out, so tests use their own controller's `window`
    /// rather than looking for a visible panel.
    static func waitUntilHidden(_ controller: RecordingOverlayController) async {
        for _ in 0..<16 where controller.window != nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The record capsule's frame in pixels of the window's own drawing (y down): its violet
    /// (or, while transcribing, light lilac) pixels in horizontal runs of at least 70 % of its
    /// 6 pt width. The bars are white and 2 pt wide; the glow is much darker.
    private static func indicatorFrame(in controller: RecordingOverlayController, transcribing: Bool = false) -> NSRect? {
        guard let window = controller.window, let rep = OverlayCapture.capturePanel(window) else { return nil }
        let scale = CGFloat(rep.pixelsWide) / window.frame.width
        let minRun = Int(6 * 0.7 * scale)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<rep.pixelsHigh {
            var run = 0
            for x in 0..<rep.pixelsWide {
                let match = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB).map { c in
                    transcribing
                        ? c.blueComponent > 0.85 && c.redComponent > 0.8 && c.greenComponent > 0.55 && c.greenComponent < 0.9
                        : c.blueComponent > 0.75 && c.redComponent > 0.45 && c.blueComponent - c.greenComponent > 0.4
                } ?? false
                run = match ? run + 1 : 0
                if run >= minRun {
                    minX = min(minX, x - run + 1); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        return maxX >= 0 ? NSRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1) : nil
    }
}

/// The picker with its own state, as Settings will bind it.
private struct PickerHarness: View {
    @State var selection: RecorderPosition
    var body: some View {
        RecorderPositionPicker(selection: $selection).frame(width: 560, alignment: .leading)
    }
}

/// Sends speech-like levels every 85 ms, like `AudioRecorder`'s tap (4096 frames at 48 kHz).
@MainActor
final class LevelFeeder {
    private var timer: Timer?
    private var t: Double = 0
    private let subject: PassthroughSubject<Float, Never>

    init(_ subject: PassthroughSubject<Float, Never>) {
        self.subject = subject
        let timer = Timer(timeInterval: 0.085, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.t += 0.085
                self.subject.send(Self.level(at: self.t))
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// The design's simulated voice: syllables with short gaps.
    static func level(at t: Double) -> Float {
        let gap = sin(t * 1.7) > 0.82 ? 0.15 : 1
        let syllable = abs(sin(t * 9.1)) * (0.55 + 0.45 * abs(sin(t * 2.3 + 1)))
        return Float(max(0.02, min(1, gap * (0.12 + 0.88 * syllable))))
    }
}

/// Saves captures of the overlay panel composited over a wallpaper.
///
/// `cacheDisplay` draws the panel's own views. The behind-window material is composited by the
/// window server, and the window shadow too, so neither is in the capture: the wallpaper shows
/// through the 14 % of the surface fill without blur, and a shadow like the design's is drawn.
@MainActor
enum OverlayCapture {
    nonisolated static var directory: URL? {
        ProcessInfo.processInfo.environment["NANOWHISPER_CAPTURE_DIR"].map { URL(fileURLWithPath: $0) }
    }

    enum Wallpaper: String, CaseIterable { case light, dark }

    static func capturePanel(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let frameView = window.contentView?.superview,
              let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return nil }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep
    }

    /// The panel alone, with a margin of wallpaper.
    static func save(_ controller: RecordingOverlayController, _ name: String, wallpaper: Wallpaper, in directory: URL) throws {
        let window = try #require(controller.window)
        let rep = try #require(capturePanel(window))
        try write(compose(rep, pointSize: window.frame.size, wallpaper: wallpaper), name, in: directory)
    }

    /// A view hosted in a test panel like the overlay's.
    static func saveHosted<V: View>(_ view: V, named name: String, wallpaper: Wallpaper, in directory: URL) throws {
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSPanel(contentRect: hosting.frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = hosting
        window.alphaValue = 0
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        hosting.layoutSubtreeIfNeeded()
        let frameView = try #require(hosting.superview)
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try write(compose(rep, pointSize: size, wallpaper: wallpaper), name, in: directory)
    }

    /// The panel at its place on its screen, drawn at half size, with the menu bar and Dock
    /// areas (outside the visible frame) shaded.
    static func saveOnScreen(_ controller: RecordingOverlayController, _ name: String, wallpaper: Wallpaper, in directory: URL) throws {
        let window = try #require(controller.window)
        let screen = try #require(window.screen)
        let rep = try #require(capturePanel(window))
        let scale: CGFloat = 1 // pixels per point in the output; the screen is drawn at 1×
        let size = NSSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        let out = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        let bounds = NSRect(origin: .zero, size: size)
        drawWallpaper(wallpaper, in: bounds)
        // Menu bar and Dock: outside the visible frame.
        let visible = screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        NSColor(white: wallpaper == .light ? 1 : 0.1, alpha: 0.55).setFill()
        NSRect(x: 0, y: visible.maxY * scale, width: size.width, height: size.height - visible.maxY * scale).fill()
        NSColor(white: wallpaper == .light ? 1 : 0.3, alpha: 0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: size.width / 2 - 320 * scale, y: 4 * scale,
                                         width: 640 * scale, height: max(0, visible.minY - 8) * scale),
                     xRadius: 16, yRadius: 16).fill()
        let frame = window.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        drawPanel(rep, in: NSRect(x: frame.minX * scale, y: frame.minY * scale,
                                  width: frame.width * scale, height: frame.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        try write(out, name, in: directory)
    }

    private static func compose(_ rep: NSBitmapImageRep, pointSize: NSSize, wallpaper: Wallpaper) throws -> NSBitmapImageRep {
        let margin: CGFloat = 28
        let pixelScale = CGFloat(rep.pixelsWide) / pointSize.width
        let size = NSSize(width: (pointSize.width + margin * 2) * pixelScale,
                          height: (pointSize.height + margin * 2) * pixelScale)
        let out = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        drawWallpaper(wallpaper, in: NSRect(origin: .zero, size: size))
        drawPanel(rep, in: NSRect(x: margin * pixelScale, y: margin * pixelScale,
                                  width: CGFloat(rep.pixelsWide), height: CGFloat(rep.pixelsHigh)),
                  shadowScale: pixelScale)
        NSGraphicsContext.restoreGraphicsState()
        return out
    }

    /// The panel with a shadow like the design's (0 10 28 black 28 %).
    private static func drawPanel(_ rep: NSBitmapImageRep, in rect: NSRect, shadowScale: CGFloat = 1) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * shadowScale)
        shadow.shadowBlurRadius = 28 * shadowScale
        shadow.set()
        rep.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The design's wallpapers: soft color blobs on a light or a dark ground.
    private static func drawWallpaper(_ wallpaper: Wallpaper, in rect: NSRect) {
        let blobs: [(x: CGFloat, y: CGFloat, color: UInt32, reach: CGFloat)]
        let ground: UInt32
        switch wallpaper {
        case .light:
            ground = 0xF3F0F7
            blobs = [(0.12, 0.2, 0xFAD3E6, 0.5), (0.85, 0.15, 0xCFE2FF, 0.55), (0.6, 1.0, 0xFFF0C2, 0.5)]
        case .dark:
            ground = 0x0C0F1C
            blobs = [(0.18, 0.25, 0x2C3D6E, 0.55), (0.82, 0.75, 0x43215C, 0.55), (0.55, 0.0, 0x1D4A55, 0.4)]
        }
        color(ground).setFill()
        rect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for blob in blobs {
            let center = CGPoint(x: rect.minX + rect.width * blob.x, y: rect.maxY - rect.height * blob.y)
            let radius = max(rect.width, rect.height) * blob.reach
            let colors = [color(blob.color).cgColor, color(blob.color, alpha: 0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            else { continue }
            context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                       endRadius: radius, options: [])
        }
    }

    private static func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func write(_ rep: NSBitmapImageRep, _ name: String, in directory: URL) throws {
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
