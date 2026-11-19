import SwiftUI
import Combine

// MARK: - Floating Panel (nonactivating = no focus steal)

private class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Overlay Window Controller

@MainActor
class RecordingOverlayController {
    private var window: NSWindow?
    private var viewModel = RecordingOverlayViewModel()
    private var levelCancellable: AnyCancellable?
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

    /// - Parameter transcriptID: the live transcription of this recording, if any; only its
    ///   updates are shown.
    func show(audioLevelPublisher: PassthroughSubject<Float, Never>, transcriptID: UUID? = nil) {
        activeRecordings += 1
        presentation += 1
        self.transcriptID = transcriptID
        viewModel.transcript = nil
        viewModel.state = .recording
        viewModel.audioLevel = 0
        viewModel.startTimer()

        // Subscribe to audio levels
        levelCancellable = audioLevelPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.viewModel.audioLevel = level
            }

        if window == nil {
            let view = RecordingOverlayView(viewModel: viewModel, onStop: { [weak self] in
                self?.onStop?()
            })
            let hosting = NSHostingView(rootView: view)
            // The controller sizes the window itself, keeping its top edge in place when the
            // transcript appears. With the default options the hosting view would also resize
            // it, anchored at the bottom-left corner; the intrinsic size alone keeps
            // `fittingSize` accurate without that.
            hosting.sizingOptions = [.intrinsicContentSize]
            hosting.frame = NSRect(x: 0, y: 0, width: 180, height: 48)

            let win = OverlayPanel(
                contentRect: NSRect(x: 0, y: 0, width: 180, height: 48),
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
    }

    /// Show `transcript` (or remove the live text with `nil`) if `id` is the live
    /// transcription of the recording the overlay is showing; ignored otherwise.
    func updateTranscript(_ transcript: LiveTranscript?, for id: UUID) {
        guard id == transcriptID, window != nil else { return }
        let wasShowingText = viewModel.visibleTranscript != nil
        viewModel.transcript = transcript
        if (viewModel.visibleTranscript != nil) != wasShowingText {
            fitWindowToContent()
        }
    }

    func transitionToLoading() {
        levelCancellable?.cancel()
        levelCancellable = nil
        viewModel.stopTimer()
        viewModel.state = .loading
    }

    func dismiss() {
        activeRecordings = max(0, activeRecordings - 1)
        // A newer recording is still using the overlay.
        guard activeRecordings == 0 else { return }
        viewModel.state = .done
        let presentation = self.presentation

        // Hold the checkmark, then fade out
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
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
                    self.viewModel.audioLevel = 0
                    self.viewModel.transcript = nil
                    self.transcriptID = nil
                }
            })
        }
    }

    private func fittingSize() -> NSSize? {
        guard let hosting = window?.contentView as? NSHostingView<RecordingOverlayView> else { return nil }
        return hosting.fittingSize
    }

    /// Resize for the transcript appearing or disappearing, keeping the top edge and the
    /// horizontal center where they are (the overlay may have been dragged), on its screen.
    private func fitWindowToContent() {
        guard let window, let size = fittingSize() else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let frame = Self.frame(fitting: size, from: window.frame, within: visible)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(frame, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                window.animator().setFrame(frame, display: true)
            }
        }
    }

    /// Frame of `size` with the same top edge and horizontal center as `current`, moved back
    /// inside `visible` if it would stick out.
    static func frame(fitting size: NSSize, from current: NSRect, within visible: NSRect?) -> NSRect {
        var frame = NSRect(
            x: (current.midX - size.width / 2).rounded(),
            y: current.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if let visible {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        return frame
    }

    private func positionWindow() {
        guard let window = window else { return }
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen = screen else { return }

        let x = screen.frame.midX - window.frame.width / 2
        let y = screen.visibleFrame.maxY - window.frame.height - 12
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - View Model

enum OverlayState {
    case idle, recording, loading, done
}

@MainActor
class RecordingOverlayViewModel: ObservableObject {
    @Published var state: OverlayState = .idle
    @Published var audioLevel: Float = 0
    @Published var elapsedSeconds: Int = 0
    /// Live transcript of the recording, if live transcription is on.
    @Published var transcript: LiveTranscript?

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

// MARK: - SwiftUI View

struct RecordingOverlayView: View {
    @ObservedObject var viewModel: RecordingOverlayViewModel
    var onStop: () -> Void

    @State private var isHovering = false

    private let barCount = 10
    private let barWidth: CGFloat = 2.5
    private let barSpacing: CGFloat = 2
    private let maxBarHeight: CGFloat = 20
    private let minBarHeight: CGFloat = 3

    /// Width of the transcript text when the overlay shows live text.
    static let transcriptWidth: CGFloat = 360

    var body: some View {
        Group {
            if let transcript = viewModel.visibleTranscript {
                // Live text: same controls on top, the last lines of the transcript below.
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        PulsingDot(state: viewModel.state)
                        bars
                        Spacer(minLength: 0)
                        timerOrStopButton
                    }
                    LiveTranscriptText(stableText: transcript.stableText, volatileText: transcript.volatileText)
                }
                .frame(width: Self.transcriptWidth)
            } else {
                HStack(spacing: 10) {
                    // Dot indicator with pulse
                    PulsingDot(state: viewModel.state)
                    bars
                    timerOrStopButton
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.75))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // Bars — fixed height container
    private var bars: some View {
        Group {
            if viewModel.state == .loading {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                    HStack(spacing: barSpacing) {
                        ForEach(0..<barCount, id: \.self) { index in
                            let phase = timeline.date.timeIntervalSinceReferenceDate
                            let wave = sin(phase * 3.0 + Double(index) * 0.7)
                            let height = minBarHeight + (maxBarHeight - minBarHeight) * 0.45 * (wave + 1) / 2
                            RoundedRectangle(cornerRadius: barWidth / 2)
                                .fill(Color.orange)
                                .frame(width: barWidth, height: height)
                        }
                    }
                }
            } else {
                HStack(spacing: barSpacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        BarView(
                            index: index,
                            state: viewModel.state,
                            audioLevel: viewModel.audioLevel,
                            minHeight: minBarHeight,
                            maxHeight: maxBarHeight,
                            barWidth: barWidth
                        )
                    }
                }
            }
        }
        .frame(height: maxBarHeight)
    }

    // Timer or stop button
    private var timerOrStopButton: some View {
        ZStack {
            Text(viewModel.elapsedFormatted)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.secondary)
                .opacity(isHovering && viewModel.state == .recording ? 0 : 1)

            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.red)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .opacity(isHovering && viewModel.state == .recording ? 1 : 0)
        }
        .frame(minWidth: 28)
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

// MARK: - Live transcript

/// The last lines of the live transcript: final text in the primary color, the tail that may
/// still change dimmed. Fixed height, so updates never resize the overlay; older lines scroll
/// out at the top.
struct LiveTranscriptText: View {
    let stableText: String
    let volatileText: String

    static let lineCount = 2
    static let fontSize: CGFloat = 13
    static let lineSpacing: CGFloat = 2
    /// Height of `lineCount` lines of the transcript font.
    static let height: CGFloat = {
        let lineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize))
        return ceil(lineHeight * CGFloat(lineCount) + lineSpacing * CGFloat(lineCount - 1))
    }()

    var body: some View {
        LatestLinesLayout {
            (Text(stableText).foregroundStyle(.primary) + Text(volatileText).foregroundStyle(.secondary))
                .font(.system(size: Self.fontSize))
                .lineSpacing(Self.lineSpacing)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.height)
        .clipped()
        // The overlay background is always dark.
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stableText + volatileText)
    }
}

/// Lays out its content at full height: from the top while it fits, and aligned to the
/// bottom once it is taller, so the latest lines stay visible and older ones move out above.
private struct LatestLinesLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            let height = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subview.place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + min(0, bounds.height - height)),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: height)
            )
        }
    }
}

// MARK: - Individual Bar

struct BarView: View {
    let index: Int
    let state: OverlayState
    let audioLevel: Float
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let barWidth: CGFloat

    // Each bar gets a slightly different weight for a natural look
    private var barWeight: CGFloat {
        let weights: [CGFloat] = [0.5, 0.7, 0.85, 1.0, 0.9, 0.75, 0.95, 0.8, 0.65, 0.55]
        return weights[index % weights.count]
    }

    private var barHeight: CGFloat {
        switch state {
        case .idle, .done, .loading:
            return minHeight
        case .recording:
            let level = CGFloat(audioLevel) * barWeight
            return minHeight + (maxHeight - minHeight) * level
        }
    }

    var body: some View {
        RoundedRectangle(cornerRadius: barWidth / 2)
            .fill(barColor)
            .frame(width: barWidth, height: barHeight)
            .animation(.easeOut(duration: 0.08), value: audioLevel)
    }

    private var barColor: Color {
        switch state {
        case .recording: return .red
        case .loading: return .orange
        case .done: return .green
        case .idle: return .gray
        }
    }
}

// MARK: - Pulsing Dot

struct PulsingDot: View {
    let state: OverlayState
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dotColor: Color {
        switch state {
        case .recording: return .red
        case .loading: return .orange
        case .done: return .green
        case .idle: return .gray
        }
    }

    private var scale: CGFloat {
        pulsing ? 1.15 : 0.9
    }

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .scaleEffect(reduceMotion ? 1 : scale)
            .opacity(reduceMotion ? 1 : (pulsing ? 1.0 : 0.65))
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
