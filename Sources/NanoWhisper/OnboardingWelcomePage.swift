import Combine
import SwiftUI

// MARK: - Welcome page

/// The first page: the icon, the headline, the catch phrase, the recorder playing a short
/// dictation, the four facts and Continue. The elements arrive one by one (fade up); with
/// Reduce Motion everything, the recorder included, shows its resting frame at once.
struct WelcomePage: View {
    @ObservedObject var demo: WelcomeRecorderDemo
    let appIcon: NSImage
    let onContinue: () -> Void
    @State private var entered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Entrance delays (s), quick and in reading order: icon, headline, catch phrase,
    /// recorder, then the four facts together with Continue (maintainer, 2026-11-21: "it was
    /// too slow and staged; the four facts arrive at the same time").
    enum Delay {
        static let icon = 0.0
        static let headline = 0.08
        static let catchPhrase = 0.16
        static let recorder = WelcomeDictation.recorderAppears
        static let firstFact = 0.32
        static let factStep = 0.0
        static let button = 0.32
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 104, height: 104)
                .shadow(color: .black.opacity(0.16), radius: 6, y: 6)
                .fadeUp(entered, delay: Delay.icon)
                .accessibilityHidden(true)

            Text(OnboardingText.headline)
                .font(.system(size: 28, weight: .semibold))
                .tracking(-0.45)
                .foregroundStyle(OnboardingPalette.label)
                .padding(.top, 16)
                .fadeUp(entered, delay: Delay.headline)
                .accessibilityAddTraits(.isHeader)

            Text(OnboardingText.catchPhrase)
                .font(.system(size: 14))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(OnboardingPalette.secondaryLabel)
                .frame(maxWidth: 430)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .fadeUp(entered, delay: Delay.catchPhrase)

            // The real overlay view, fed by the demo (no microphone). Not interactive: the
            // pointer over it would otherwise show its Stop button.
            RecordingOverlayView(viewModel: demo.viewModel, onStop: {})
                .fixedSize()
                .shadow(color: .black.opacity(0.22), radius: 13, y: 10)
                .shadow(color: .black.opacity(0.16), radius: 1.5, y: 1)
                .allowsHitTesting(false)
                .frame(width: OverlayMetrics.cardWidth, height: OnboardingWindowPlacement.recorderSize.height, alignment: .top)
                .padding(.top, 24)
                .fadeUp(entered, delay: Delay.recorder)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(OnboardingText.welcomeRecorderLabel)

            Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 14) {
                GridRow {
                    fact(0)
                    fact(1)
                }
                GridRow {
                    fact(2)
                    fact(3)
                }
            }
            .frame(width: 470)
            .padding(.top, 26)

            Spacer(minLength: 18)

            Button(action: onContinue) {
                Text(OnboardingText.continueButton)
                    .frame(minWidth: 92)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .fadeUp(entered, delay: Delay.button)
        }
        .padding(.top, 50)
        .padding(.horizontal, 48)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            entered = true
            demo.start(reduceMotion: reduceMotion)
        }
        .onDisappear { demo.stop() }
    }

    private func fact(_ index: Int) -> some View {
        let fact = OnboardingText.facts[index]
        return HStack(alignment: .top, spacing: 10) {
            Group {
                if let systemImage = fact.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14))
                } else {
                    IBeamGlyph()
                        .stroke(style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                }
            }
            .foregroundStyle(OnboardingPalette.secondaryLabel)
            .frame(width: 18, height: 18)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(fact.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OnboardingPalette.label)
                Text(fact.detail)
                    .font(.system(size: 12))
                    .lineSpacing(1.5)
                    .foregroundStyle(OnboardingPalette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 221, alignment: .leading)
        .accessibilityElement(children: .combine)
        .fadeUp(entered, delay: Delay.firstFact + Double(index) * Delay.factStep)
    }
}

/// The text cursor of "Pasted for you", from the design's 24 × 24 glyph.
private struct IBeamGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 24
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
        var path = Path()
        path.move(to: p(9, 4.5))
        path.addQuadCurve(to: p(12, 6.5), control: p(12, 4.6))
        path.addLine(to: p(12, 17.5))
        path.addQuadCurve(to: p(9, 19.5), control: p(12, 19.4))
        path.move(to: p(15, 4.5))
        path.addQuadCurve(to: p(12, 6.5), control: p(12, 4.6))
        path.move(to: p(12, 17.5))
        path.addQuadCurve(to: p(15, 19.5), control: p(12, 19.4))
        path.move(to: p(10, 12))
        path.addLine(to: p(14, 12))
        return path
    }
}

// MARK: - The recorder's simulated dictation

/// Plays `WelcomeDictation` in the real recorder's view model, levels and words fed
/// programmatically (no microphone): idle at 0:00 (paused: still capsule, no text, flat
/// waveform), then the recording (pulsing capsule, running timer, moving waveform, words
/// arriving), then frozen mid-sentence and paused again: the capsule, caret, timer and
/// waveform all stop.
@MainActor
final class WelcomeRecorderDemo: ObservableObject {
    enum Phase: Equatable {
        /// The page arrives; the recorder waits at 0:00.
        case idle
        case recording
        /// Stopped mid-sentence, and stays.
        case frozen
    }

    let viewModel: RecordingOverlayViewModel
    private let levels = PassthroughSubject<Float, Never>()
    private var timer: Timer?
    private var startDate: Date?
    private(set) var phase = Phase.idle
    var isFrozen: Bool { phase == .frozen }

    init() {
        viewModel = RecordingOverlayViewModel()
        viewModel.state = .recording
        viewModel.showsCardWhileEmpty = true
        viewModel.transcript = LiveTranscript()
        viewModel.elapsedSeconds = 0
        viewModel.isPaused = true
        // Flat and still (no per-frame timeline) until the recording starts.
        viewModel.waveform.freeze(with: LevelHistory())
    }

    /// Start when the window opens (time 0 of `WelcomeDictation`). With Reduce Motion the
    /// resting frame shows at once. Starts once.
    func start(reduceMotion: Bool) {
        guard startDate == nil, !isFrozen else { return }
        if reduceMotion {
            showFrozen()
            return
        }
        startDate = Date()
        let timer = Timer(timeInterval: WelcomeDictation.levelInterval, repeats: true) { [weak self] timer in
            // The demo is gone (window closed): stop firing.
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated { self.tick(at: Date()) }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Advances the demo to `time` seconds after the window opened (the timer calls it every
    /// 20 ms; tests call it directly).
    func advance(to time: TimeInterval) {
        guard !isFrozen, time >= WelcomeDictation.recordingStarts else { return }
        if time >= WelcomeDictation.freezeTime {
            showFrozen()
            return
        }
        if phase == .idle {
            phase = .recording
            viewModel.waveform.start(levels: levels)
            viewModel.isPaused = false
        }
        levels.send(WelcomeDictation.level(at: time))
        show(at: time)
    }

    private func tick(at date: Date) {
        guard let startDate else { return }
        advance(to: date.timeIntervalSince(startDate))
    }

    /// The frame the welcome rests on, paused: the sentence on up to three lines, the last
    /// words dimmer, a steady caret, a still capsule and waveform, 0:05.
    func showFrozen() {
        timer?.invalidate()
        timer = nil
        // Live bars as they are when it ran; computed the same way when it never ran.
        viewModel.waveform.freeze(with: phase == .recording ? nil : WelcomeDictation.frozenHistory())
        phase = .frozen
        show(at: WelcomeDictation.freezeTime)
        viewModel.isPaused = true
        // Redraw now: the still waveform no longer needs its per-frame timeline.
        viewModel.objectWillChange.send()
    }

    /// The page went away: stop feeding the recorder.
    func stop() {
        timer?.invalidate()
        timer = nil
        if phase == .recording { viewModel.waveform.stop() }
    }

    private func show(at time: TimeInterval) {
        let seconds = WelcomeDictation.elapsedSeconds(at: time)
        if viewModel.elapsedSeconds != seconds { viewModel.elapsedSeconds = seconds }
        let text = WelcomeDictation.text(at: time)
        if viewModel.transcript?.stableText != text.stable || viewModel.transcript?.volatileText != text.volatile {
            viewModel.transcript = LiveTranscript(stable: text.stable, volatile: text.volatile)
        }
    }
}
