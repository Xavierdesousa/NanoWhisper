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

    func show(audioLevelPublisher: PassthroughSubject<Float, Never>) {
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
        if let hosting = window?.contentView as? NSHostingView<RecordingOverlayView> {
            let size = hosting.fittingSize
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

    func transitionToLoading() {
        levelCancellable?.cancel()
        levelCancellable = nil
        viewModel.stopTimer()
        viewModel.state = .loading
    }

    func dismiss() {
        viewModel.state = .done

        // Hold the checkmark, then fade out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                self?.window?.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.window?.orderOut(nil)
                // Release the window so it is recreated fresh on the correct screen next time
                self?.window = nil
                self?.viewModel.state = .idle
                self?.viewModel.audioLevel = 0
            })
        }
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

    var body: some View {
        HStack(spacing: 10) {
            // Dot indicator with pulse
            PulsingDot(state: viewModel.state)

            // Bars — fixed height container
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

            // Timer or stop button
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
        case .idle, .done:
            return minHeight
        case .loading:
            return minHeight
        case .recording:
            let level = CGFloat(audioLevel) * barWeight
            return minHeight + (maxHeight - minHeight) * level
        case .loading:
            return minHeight
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
            .scaleEffect(scale)
            .opacity(pulsing ? 1.0 : 0.65)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

// MARK: - Loading Pulse Modifier

struct LoadingPulse: ViewModifier, Animatable {
    let isActive: Bool
    let index: Int
    let minHeight: CGFloat
    let maxHeight: CGFloat

    @State private var animating = false

    func body(content: Content) -> some View {
        if isActive {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.orange)
                .frame(width: 4, height: animating ? maxHeight * 0.6 : minHeight)
                .animation(
                    .easeInOut(duration: 0.45)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.1),
                    value: animating
                )
                .onAppear { animating = true }
                .onDisappear { animating = false }
        } else {
            content
        }
    }
}
