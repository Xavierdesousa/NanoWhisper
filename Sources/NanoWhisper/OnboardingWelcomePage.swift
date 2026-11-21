import Combine
import SwiftUI

// MARK: - Welcome page

/// The first page, with the opening scene (`OpeningScene`): on an empty window a violet
/// sunrise rises from the bottom, the icon, "NanoWhisper" and the headline arrive and Get
/// Started pops from the back. Its press (or Return) hands over to the welcome: the icon and the
/// headline travel to their places, the aura shrinks into a halo behind the icon, and the catch
/// phrase, the recorder (which then plays its dictation), the four facts and Continue fade up.
/// With Reduce Motion: the title moment at once, then one cross-fade to the welcome at rest.
///
/// Only small layers follow the frame clock, and only while something moves
/// (`OpeningSceneClock.isAnimating`): the aura (rendered with Metal), the icon, the headline
/// with the catch phrase, and the title with Get Started (`SceneLayer`). The welcome's other
/// elements fade up with SwiftUI animations on the prototype's curve (`Arrival`), the breathing
/// while it waits is an animation of the aura's texture, and the recorder and Get Started are
/// equatable so the frames do not rebuild them. CPU, measured: wiki onboarding-and-settings,
/// "Opening scene".
struct WelcomePage: View {
    @ObservedObject var demo: WelcomeRecorderDemo
    @ObservedObject var scene: OpeningSceneClock
    let appIcon: NSImage
    let onContinue: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private typealias Layout = OpeningScene.Layout
    private typealias Tweak = OpeningScene.Tweak

    var body: some View {
        // Renders draw a still moment: the welcome's fades take the frame's values.
        let still = scene.fixedMoment.map {
            OpeningScene.frame(t: $0.t, pt: $0.pt, dark: colorScheme == .dark, reduceMotion: reduceMotion)
        }
        ZStack(alignment: .top) {
            SceneLayer(scene: scene) { frame, _ in
                OpeningAura(aura: frame.aura, dark: colorScheme == .dark,
                            glowCenterY: Layout.welcomeIconCenterY + frame.icon.offsetY)
            }
            .modifier(Breathing(isOn: scene.isWaiting && !scene.isPressed && !reduceMotion))
            .frame(width: Layout.width, height: Layout.height, alignment: .top)
            welcome(still)
            SceneLayer(scene: scene) { frame, date in
                titleMoment(frame, canPress: scene.canPress(at: date, reduceMotion: reduceMotion))
            }
        }
        .frame(width: Layout.width, height: Layout.height)
        .onAppear { scene.begin(reduceMotion: reduceMotion) }
        .onDisappear { demo.stop() }
    }

    /// Get Started: the welcome arrives, and the recorder's dictation starts its clock.
    private func press() {
        guard scene.press(reduceMotion: reduceMotion) else { return }
        demo.start(reduceMotion: reduceMotion)
    }

    /// The welcome as built; before the press only the icon and the headline show, at the title
    /// moment's places.
    private func welcome(_ still: OpeningScene.Frame?) -> some View {
        VStack(spacing: 0) {
            SceneLayer(scene: scene) { frame, _ in icon(frame) }
                .frame(width: Layout.welcomeIconSize, height: Layout.welcomeIconSize)

            SceneLayer(scene: scene) { frame, _ in headline(frame) }

            WelcomeRecorder(demo: demo)
                .equatable()
                .modifier(Arrival(isShown: scene.isPressed, delay: Tweak.recorderAt, still: still?.recorder))
                .padding(.top, 24)

            Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 14) {
                GridRow {
                    fact(0, still)
                    fact(1, still)
                }
                GridRow {
                    fact(2, still)
                    fact(3, still)
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
            // Return presses Get Started first, then Continue once it is arriving.
            .keyboardShortcut(scene.canContinue ? .defaultAction : nil)
            .disabled(!scene.canContinue)
            .modifier(Arrival(isShown: scene.isPressed, delay: Tweak.continueAt, still: still?.continueButton))
        }
        .padding(.top, 50)
        .padding(.horizontal, 48)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The icon: at the title moment 118 pt under the title, blurred and smaller as it arrives;
    /// then 104 pt at the top.
    private func icon(_ frame: OpeningScene.Frame) -> some View {
        Image(nsImage: appIcon)
            .resizable()
            .interpolation(.high)
            .frame(width: Layout.welcomeIconSize, height: Layout.welcomeIconSize)
            .blur(radius: frame.icon.blur)
            .scaleEffect(frame.icon.scale)
            .shadow(color: frame.icon.shadowColor.color, radius: frame.icon.shadowRadius, y: frame.icon.shadowY)
            .offset(y: frame.icon.offsetY)
            .opacity(frame.icon.opacity)
            .accessibilityHidden(true)
    }

    /// The headline, then the catch phrase that rides with it (one group, so they never overlap).
    private func headline(_ frame: OpeningScene.Frame) -> some View {
        VStack(spacing: 0) {
            Text(OnboardingText.headline)
                .font(.system(size: Layout.welcomeHeadlineSize, weight: .semibold))
                .tracking(-0.45)
                .foregroundStyle(frame.headline.color.color)
                .scaleEffect(frame.headline.scale)
                .offset(y: frame.headline.offsetY)
                .opacity(frame.headline.opacity)
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)

            Text(OnboardingText.catchPhrase)
                .font(.system(size: 14))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(OnboardingPalette.secondaryLabel)
                .frame(maxWidth: 430)
                .fixedSize(horizontal: false, vertical: true)
                .offset(y: frame.catchPhrase.offsetY)
                .opacity(frame.catchPhrase.opacity)
                .accessibilityHidden(frame.catchPhrase.opacity < 0.01)
                .padding(.top, 6)
        }
    }

    /// "NanoWhisper" and Get Started, centred under the icon until the press.
    private func titleMoment(_ frame: OpeningScene.Frame, canPress: Bool) -> some View {
        let pressed = scene.isPressed
        return ZStack {
            Text(OnboardingText.sceneTitle)
                .font(.system(size: Tweak.titleSize, weight: .semibold))
                .tracking(-0.02 * Tweak.titleSize)
                .foregroundStyle(frame.titleColor.color)
                .lineLimit(1)
                .fixedSize()
                .offset(y: frame.title.offsetY)
                .opacity(frame.title.opacity)
                .position(x: Layout.centerX, y: Layout.titleTop + Layout.titleLineHeight / 2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHidden(pressed)

            GetStartedButton(canPress: canPress, action: press)
                .equatable()
                .background(GetStartedShadow(strength: frame.button.shadow, dark: colorScheme == .dark))
                .scaleEffect(frame.button.scale)
                .opacity(frame.button.opacity)
                .position(x: Layout.centerX, y: Layout.buttonTop + Tweak.buttonHeight / 2)
                .accessibilityHidden(pressed)
        }
        .frame(width: Layout.width, height: Layout.height)
    }

    private func fact(_ index: Int, _ still: OpeningScene.Frame?) -> some View {
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
        .modifier(Arrival(isShown: scene.isPressed, delay: Tweak.factsAt + Double(index) * Tweak.factsStagger,
                          still: still?.facts[index]))
    }
}

/// A part of the scene redrawn at each display frame while the scene moves: its content is a
/// function of the scene's frame (and the date) only. Small on purpose (see `WelcomePage`).
private struct SceneLayer<Content: View>: View {
    @ObservedObject var scene: OpeningSceneClock
    @ViewBuilder let content: (OpeningScene.Frame, Date) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !scene.isAnimating)) { context in
            let moment = scene.moment(at: context.date)
            content(OpeningScene.frame(t: moment.t, pt: moment.pt, dark: colorScheme == .dark, reduceMotion: reduceMotion),
                    context.date)
        }
    }
}

/// A welcome element arriving after the press: it fades up `fadeRise` over `fadeDuration` on
/// the onboarding's curve, `delay` after the press (the prototype's `fu`, so the same values
/// as `OpeningScene.frame`); with Reduce Motion, a 0.3 s cross-fade. A still moment (renders)
/// takes the frame's values instead.
private struct Arrival: ViewModifier {
    let isShown: Bool
    let delay: Double
    let still: OpeningScene.Fade?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if let still {
            content
                .offset(y: still.offsetY)
                .opacity(still.opacity)
                .accessibilityHidden(still.opacity < 0.01)
        } else {
            let tweak = OpeningScene.Tweak.self
            content
                .animation(reduceMotion
                           ? .linear(duration: OpeningScene.Times.reduceMotionCrossFade)
                           : .timingCurve(0.2, 0.7, 0.2, 1, duration: tweak.fadeDuration).delay(delay)) {
                    $0.opacity(isShown ? 1 : 0).offset(y: isShown || reduceMotion ? 0 : tweak.fadeRise)
                }
                .accessibilityHidden(!isShown)
        }
    }
}

/// The welcome's recorder: the real overlay view, fed by the demo (no microphone), with the
/// overlay's drop shadows in the window's appearance. Not interactive: the pointer over it
/// would otherwise show its Stop button. Equatable on its demo, so the page's updates do not
/// rebuild it.
private struct WelcomeRecorder: View, Equatable {
    let demo: WelcomeRecorderDemo
    @Environment(\.colorScheme) private var colorScheme

    nonisolated static func == (a: WelcomeRecorder, b: WelcomeRecorder) -> Bool { a.demo === b.demo }

    var body: some View {
        RecordingOverlayView(viewModel: demo.viewModel, onStop: {})
            .fixedSize()
            .overlayDropShadows(.forScheme(colorScheme))
            .allowsHitTesting(false)
            .frame(width: OverlayMetrics.cardWidth, height: OnboardingWindowPlacement.recorderSize.height, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OnboardingText.welcomeRecorderLabel)
    }
}

/// The aura: an ellipse of the icon's violets whose centre sits below the bottom edge, with
/// its brighter rim while it rises. With Reduce Motion, after the press: a halo of the second
/// colour behind the icon. Rendered with Metal (`drawingGroup`): drawn by Core Graphics, the
/// gradient was redrawn into the layer on the main thread at every frame. Drawn `bleed` points
/// below the window, so its breathing (a scale of the whole texture around the aura's centre,
/// below the bottom edge) never uncovers the bottom edge.
private struct OpeningAura: View {
    let aura: OpeningScene.Aura
    let dark: Bool
    let glowCenterY: Double

    private typealias Layout = OpeningScene.Layout
    static let bleed: Double = 20

    var body: some View {
        let radii = Layout.auraRadii
        let center = CGPoint(x: Layout.auraCenter.x + aura.offset.width, y: Layout.auraCenter.y + aura.offset.height)
        ZStack {
            ellipse(aura.stops.map { Gradient.Stop(color: $0.color.color, location: $0.location) }, radii: radii)
                .opacity(aura.opacity)
                .position(center)
            if aura.rimOpacity > 0 {
                ellipse(rimStops, radii: radii)
                    .opacity(aura.rimOpacity)
                    .blendMode(dark ? .screen : .normal)
                    .position(center)
            }
            if aura.glowOpacity > 0 {
                let size = OpeningScene.Tweak.glowSize
                Circle()
                    .fill(RadialGradient(
                        stops: OpeningScene.glowStops(dark: dark).map { Gradient.Stop(color: $0.color.color, location: $0.location) },
                        center: .center, startRadius: 0, endRadius: size / 2))
                    .frame(width: size, height: size)
                    .opacity(aura.glowOpacity)
                    .position(x: Layout.centerX, y: glowCenterY)
            }
        }
        .frame(width: Layout.width, height: Layout.height + Self.bleed)
        .clipped()
        .drawingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func ellipse(_ stops: [Gradient.Stop], radii: CGSize) -> some View {
        Ellipse()
            .fill(EllipticalGradient(stops: stops, center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5))
            .frame(width: 2 * radii.width, height: 2 * radii.height)
            .scaleEffect(x: max(0.0001, aura.scaleX), y: max(0.0001, aura.scaleY))
    }

    /// The rim: a ring just inside the last colour stop.
    private var rimStops: [Gradient.Stop] {
        let edge = 1 - OpeningScene.Tweak.softness
        let color = aura.rimColor
        return [.init(color: color.with(alpha: 0).color, location: max(0, edge - 0.12)),
                .init(color: color.with(alpha: 0.55).color, location: edge - 0.03),
                .init(color: color.with(alpha: 0).color, location: min(1, edge + 0.07))]
    }
}

/// The aura's breathing while the title moment waits: 1 → 1 + `breathing` and back, ease
/// in-out, around the aura's centre. A new identity when it starts or stops: a running
/// repeating animation is not stopped by later changes.
private struct Breathing: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        let layout = OpeningScene.Layout.self
        let anchor = UnitPoint(x: layout.auraCenter.x / layout.width,
                               y: layout.auraCenter.y / (layout.height + OpeningAura.bleed))
        content.modifier(BreathingScale(isOn: isOn, anchor: anchor)).id(isOn)
    }
}

private struct BreathingScale: ViewModifier {
    let isOn: Bool
    let anchor: UnitPoint
    @State private var inhaled = false

    func body(content: Content) -> some View {
        let tweak = OpeningScene.Tweak.self
        content
            .animation(isOn ? .easeInOut(duration: tweak.breathingPeriod / 2).repeatForever(autoreverses: true) : nil) {
                $0.scaleEffect(isOn && inhaled ? 1 + tweak.breathing : 1, anchor: anchor)
            }
            .onAppear { inhaled = true }
    }
}

/// Get Started. Equatable on whether it takes a press: the scene's frames move it (scale,
/// opacity) without rebuilding it (its action closure would otherwise make it differ at every
/// frame).
private struct GetStartedButton: View, Equatable {
    let canPress: Bool
    let action: () -> Void

    nonisolated static func == (a: GetStartedButton, b: GetStartedButton) -> Bool { a.canPress == b.canPress }

    var body: some View {
        Button(OnboardingText.getStarted, action: action)
            .buttonStyle(GetStartedButtonStyle())
            .keyboardShortcut(canPress ? .defaultAction : nil)
            .disabled(!canPress)
    }
}

/// Get Started: a white capsule, 44 pt high.
private struct GetStartedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let tweak = OpeningScene.Tweak.self
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .tracking(-0.1)
            .foregroundStyle(OpeningScene.RGBA(tweak.buttonTextColor).color)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, (tweak.buttonHeight * 0.6).rounded())
            .frame(minWidth: tweak.buttonWidth, minHeight: tweak.buttonHeight, maxHeight: tweak.buttonHeight)
            .background(Capsule().fill(OpeningScene.RGBA(tweak.buttonFillColor).color))
            .contentShape(Capsule())
            .brightness(configuration.isPressed ? -0.05 : 0)
    }
}

/// Get Started's shadows, growing with the pop as if the button came forward (the capsule itself
/// lies under the button's).
private struct GetStartedShadow: View {
    /// 0…1, with the pop.
    let strength: Double
    let dark: Bool

    var body: some View {
        let tweak = OpeningScene.Tweak.self
        let tint = OpeningScene.RGBA(tweak.buttonShadowColor)
        Capsule()
            .fill(OpeningScene.RGBA(tweak.buttonFillColor).color)
            .shadow(color: tint.with(alpha: 0.2 * strength).color, radius: 1, y: 1)
            .shadow(color: tint.with(alpha: (dark ? 0.28 : 0.16) * strength).color, radius: 11, y: 8 * strength)
            .allowsHitTesting(false)
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

    /// Start at the press of Get Started (time 0 of `WelcomeDictation`). With Reduce Motion the
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

    /// Advances the demo to `time` seconds after the press of Get Started (the timer calls it
    /// every 20 ms; tests call it directly).
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
