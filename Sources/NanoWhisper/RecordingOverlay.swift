import SwiftUI
import Combine

// MARK: - Floating Panel (nonactivating = no focus steal)

private class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view that reports when its SwiftUI content's ideal size changes.
///
/// The controller sizes the panel itself (keeping its pinned edges in place), so it must know
/// when the content grows or shrinks. Reading `fittingSize` right after changing the view
/// model is not enough: SwiftUI has not re-rendered yet and returns the previous size, which
/// left the panel compact while the content had expanded (clipped text, no corners).
private final class OverlayHostingView: NSHostingView<RecordingOverlayView> {
    var onIdealSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onIdealSizeChange?()
    }
}

// MARK: - Overlay Window Controller

@MainActor
class RecordingOverlayController {
    /// The panel while it is shown (internal for the window tests).
    private(set) var window: NSWindow?
    /// Internal for the window tests, which put it in states (pointer over it) they cannot
    /// produce with events.
    let viewModel = RecordingOverlayViewModel()
    nonisolated(unsafe) private var screenObserver: Any?
    var onStop: (() -> Void)?

    /// Live transcription whose text the overlay shows (see `updateTranscript(_:for:)`).
    private var transcriptID: UUID?
    /// Recordings shown and not dismissed yet. A recording can start while the previous one
    /// is still being transcribed: the overlay then belongs to the newer one, and it is only
    /// dismissed once every recording it was shown for is done.
    private var activeRecordings = 0
    /// Incremented by every `show`, so a fade-out scheduled earlier never hides a newer recording.
    private var presentation = 0
    /// A resize to the content's new ideal size is scheduled (see `scheduleFit()`).
    private var fitScheduled = false

    /// How long the result stays before the fade-out: longer when final text is shown, to
    /// leave time to read its start.
    static let resultHold: TimeInterval = 0.8
    static let resultHoldWithText: TimeInterval = 1.2

    init() {
        // Watch for display configuration changes (plug/unplug monitor, arrangement change)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenChange()
            }
        }
    }

    deinit {
        if let obs = screenObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// Re-validate and reposition the overlay when screens change
    private func handleScreenChange() {
        guard let window = window, window.isVisible else { return }

        // Check if the window's current screen still exists
        let windowCenter = NSPoint(
            x: window.frame.midX,
            y: window.frame.midY
        )
        let stillOnScreen = NSScreen.screens.contains { NSMouseInRect(windowCenter, $0.frame, false) }

        if !stillOnScreen {
            // Window is stranded on a disappeared screen — reposition to mouse's current screen
            positionWindow()
        }

        // Ensure the overlay is still ordered front (macOS can demote it during display reconfiguration)
        window.orderFrontRegardless()
    }

    /// - Parameters:
    ///   - transcriptID: the live transcription of this recording, if any; only its updates
    ///     are shown.
    ///   - position: where the overlay appears (`AppState.recorderPosition`).
    func show(
        audioLevelPublisher: PassthroughSubject<Float, Never>,
        transcriptID: UUID? = nil,
        position: RecorderPosition = .defaultPosition
    ) {
        activeRecordings += 1
        presentation += 1
        self.transcriptID = transcriptID
        viewModel.transcript = nil
        viewModel.position = position
        viewModel.state = .recording
        viewModel.startTimer()
        viewModel.waveform.start(levels: audioLevelPublisher)

        let isNewWindow = window == nil
        if isNewWindow {
            // Drawn at the start of its appear animation, then animated in below.
            viewModel.isPresented = false
            let view = RecordingOverlayView(viewModel: viewModel, onStop: { [weak self] in
                self?.onStop?()
            })
            let hosting = OverlayHostingView(rootView: view)
            // The controller sizes the window itself, keeping its pinned edges in place when
            // the transcript appears. With the default options the hosting view would also
            // resize it, anchored at the bottom-left corner; the intrinsic size alone keeps
            // `fittingSize` accurate without that, and its changes are reported.
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.onIdealSizeChange = { [weak self] in self?.scheduleFit() }
            // First layout at the real size: content laid out at a placeholder size and then
            // moved could be picked up by an animation starting at the same moment.
            let size = hosting.fittingSize
            hosting.frame = NSRect(origin: .zero, size: size)

            let win = OverlayPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            win.isOpaque = false
            win.backgroundColor = .clear
            win.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
            win.hasShadow = true
            win.hidesOnDeactivate = false
            win.ignoresMouseEvents = false
            win.isMovableByWindowBackground = true
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            win.contentView = hosting

            self.window = win
        }

        // Let SwiftUI compute the ideal size, then resize the window to fit
        if let size = fittingSize() {
            window?.setContentSize(size)
        }

        positionWindow()
        window?.alphaValue = 0
        window?.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            window?.animator().alphaValue = 1
        }
        if isNewWindow {
            // The next turn, so SwiftUI has drawn the start state first.
            let presentation = self.presentation
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.presentation == presentation else { return }
                    self.viewModel.isPresented = true
                }
            }
            // The appear scale changes the drawn shape: recompute the shadow once it settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.window?.invalidateShadow() }
            }
        } else {
            viewModel.isPresented = true
        }
    }

    /// Show `transcript` (or remove the live text with `nil`) if `id` is the live
    /// transcription of the recording the overlay is showing; ignored otherwise.
    /// The panel follows the new size once SwiftUI has laid it out (`OverlayHostingView`).
    func updateTranscript(_ transcript: LiveTranscript?, for id: UUID) {
        guard id == transcriptID, window != nil else { return }
        viewModel.transcript = transcript
    }

    func transitionToLoading() {
        viewModel.waveform.markStopped()
        viewModel.stopTimer()
        viewModel.state = .loading
    }

    /// Show the result of a recording, hold it, then fade out. Ignored while a newer recording
    /// still uses the overlay.
    func dismiss(showing result: OverlayResult = .done) {
        activeRecordings = max(0, activeRecordings - 1)
        // A newer recording is still using the overlay.
        guard activeRecordings == 0 else { return }
        viewModel.waveform.stop()
        viewModel.stopTimer()
        viewModel.state = .finished(result)
        let presentation = self.presentation
        let hold = viewModel.visibleTranscript == nil ? Self.resultHold : Self.resultHoldWithText
        if window != nil {
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: result.title,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
        }

        // Hold the result, then fade out
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(hold * 1_000_000_000))
            guard let self, self.presentation == presentation else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self.window?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.presentation == presentation else { return }
                    self.window?.orderOut(nil)
                    self.window = nil
                    self.viewModel.state = .idle
                    self.viewModel.transcript = nil
                    self.viewModel.isPresented = false
                    self.viewModel.isPointerOver = false
                    self.transcriptID = nil
                }
            })
        }
    }

    private func fittingSize() -> NSSize? {
        guard let hosting = window?.contentView as? OverlayHostingView else { return nil }
        return hosting.fittingSize
    }

    /// Resize once the current SwiftUI update is over: the size changes while SwiftUI is
    /// updating the view, and resizing the window from there would re-enter its layout.
    private func scheduleFit() {
        guard !fitScheduled else { return }
        fitScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fitScheduled = false
                self.fitWindowToContent()
            }
        }
    }

    /// Resize for the transcript appearing or disappearing, keeping the edges pinned by the
    /// recorder position where they are (the overlay may have been dragged), on its screen.
    ///
    /// Not animated: the content is laid out at its new size at once, so during an animated
    /// window resize it was clipped by the smaller window (square corners, cut text).
    private func fitWindowToContent() {
        guard let window, let size = fittingSize(), size != window.frame.size else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        window.setFrame(viewModel.position.frame(fitting: size, from: window.frame, within: visible), display: true)
        // The shadow of a transparent window follows its drawn shape, computed once.
        window.invalidateShadow()
    }

    /// Place the overlay at the recorder position on the screen that has the pointer.
    private func positionWindow() {
        guard let window = window else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = screen else { return }
        window.setFrame(viewModel.position.initialFrame(size: window.frame.size, in: screen.visibleFrame), display: true)
    }
}

// MARK: - Result

/// What the overlay shows when a recording is over, before it fades out.
enum OverlayResult: Equatable, Sendable {
    /// The text was pasted into the frontmost app.
    case pasted
    /// The text went elsewhere (onboarding's Try-it box), or nowhere because that box is gone.
    case done
    /// The engine ran and recognized nothing.
    case noSpeech
    /// The recording produced no audio file.
    case noAudio
    /// The engine failed (see `TranscriptionFailure`).
    case failed

    init(_ outcome: DictationOutcome) {
        switch outcome {
        case .deliver: self = .pasted
        case .showTestResult(let text): self = text.isEmpty ? .noSpeech : .done
        case .discard: self = .done
        case .noResult: self = .noSpeech
        case .failed: self = .failed
        }
    }

    /// Header text, also announced to VoiceOver.
    var title: String {
        switch self {
        case .pasted: return "Pasted"
        case .done: return "Done"
        case .noSpeech: return "No speech detected"
        case .noAudio: return "No audio recorded"
        case .failed: return "Transcription failed"
        }
    }

    /// A check (success) or a warning sign.
    var isSuccess: Bool {
        switch self {
        case .pasted, .done: return true
        case .noSpeech, .noAudio, .failed: return false
        }
    }
}

// MARK: - View Model

enum OverlayState: Equatable {
    case idle, recording, loading
    case finished(OverlayResult)
}

@MainActor
class RecordingOverlayViewModel: ObservableObject {
    @Published var state: OverlayState = .idle
    @Published var elapsedSeconds: Int = 0
    /// Live transcript of the recording, if live transcription is on.
    @Published var transcript: LiveTranscript?
    /// Where the overlay is pinned: the anchor of its appear animation.
    @Published var position: RecorderPosition = .defaultPosition
    /// False while the panel appears (drawn slightly smaller), true once shown.
    @Published var isPresented = true
    /// The pointer is over the overlay: a recording shows Stop instead of the timer.
    @Published var isPointerOver = false

    /// Waveform data; redrawn by its own timeline, not through this object's updates.
    let waveform: OverlayWaveform

    init(waveform: OverlayWaveform = OverlayWaveform()) {
        self.waveform = waveform
    }

    /// The transcript when it has text to show; the overlay is compact otherwise.
    var visibleTranscript: LiveTranscript? {
        guard let transcript, !transcript.isEmpty else { return nil }
        return transcript
    }

    private var timer: Timer?

    func startTimer() {
        elapsedSeconds = 0
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    var elapsedFormatted: String {
        let m = elapsedSeconds / 60
        let s = elapsedSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
