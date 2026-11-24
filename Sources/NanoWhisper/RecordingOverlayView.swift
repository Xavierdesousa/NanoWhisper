import AppKit
import SwiftUI

// MARK: - Palette

/// What the "Voice note" overlay draws the same way in both appearances.
enum OverlayPalette {
    static func rgb(_ hex: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255,
              opacity: opacity)
    }

    static func nsColor(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A soft violet glow inside the edge, fading toward the middle (2026-11-20: "not a border,
    /// a violet shadow from the outside in, very sober").
    static let innerGlowColor: UInt32 = 0xA947FF
    static let innerGlowRadius: CGFloat = 6

    /// The record capsule (Foundations "Capsule"), the icon's violet in both appearances.
    static let capsule = LinearGradient(
        stops: [.init(color: rgb(0xC27DFF), location: 0),
                .init(color: rgb(0x9924FF), location: 0.6),
                .init(color: rgb(0x8A1FF0), location: 1)],
        startPoint: .top, endPoint: .bottom)
    static let capsuleEdge = rgb(0xFFEBFF, 0.55)
}

/// The overlay's colours in one appearance: `.dark` (as built, 2026-11-20) and `.light`
/// (Claude Design canvas, page "Recording overlay", row "Light appearance", notes
/// `ovl-light-notes`, 2026-11-21). The overlay follows the app's appearance (Settings ›
/// General › Appearance), so the panel and the welcome's recorder pick one from their
/// effective appearance (`colorScheme`). Text contrast is checked over the worst wallpapers:
/// `OverlayContrastTests`.
struct OverlayColors: Equatable, Sendable {
    /// A colour from the design's table: hex and opacity.
    struct Tone: Equatable, Sendable {
        var hex: UInt32
        var opacity: Double = 1
        var color: Color { OverlayPalette.rgb(hex, opacity) }
        var nsColor: NSColor { OverlayPalette.nsColor(hex, CGFloat(opacity)) }
    }

    /// A drop shadow below the overlay (SwiftUI radius: half the design's CSS blur).
    struct DropShadow: Equatable, Sendable {
        var tone: Tone
        var radius: CGFloat
        var y: CGFloat
    }

    /// A glow of the record capsule: its colour at the breath's peak, and its radius there and
    /// at rest (the dim end, or paused).
    struct Glow: Equatable, Sendable {
        var tone: Tone
        var radius: CGFloat
        var dimOpacity: Double
        var dimRadius: CGFloat
    }

    /// The surface (no blur): black 90 % in dark (2026-11-20: the maintainer preferred a neutral
    /// black to the icon's violet, then asked for it darker), white 94 % in light.
    var surface: Tone
    /// The surface with Reduce Transparency: opaque.
    var solidSurface: Tone
    var innerGlowOpacity: Double
    /// A hairline inside the edge (light only), 0.5 pt.
    var rim: Tone?
    /// The drop shadows: a soft one below, and a tight one at the edge.
    var farShadow: DropShadow
    var nearShadow: DropShadow
    /// Text and bars: white in dark, a violet-tinted near-black in light.
    var ink: UInt32
    /// Settled text.
    var textOpacity: Double
    /// The tail of the live text that may still change: dimmer, still at least 4.5:1.
    var tailOpacity: Double
    var timerOpacity: Double
    var timerStoppedOpacity: Double
    /// The result's label ("Pasted").
    var labelOpacity: Double
    var transcribingLabel: UInt32
    /// The transcribing sweep: its lit bars, and the dim dots under it (ink).
    var sweepLit: UInt32
    var sweepDimOpacity: Double
    var capsulePulse: Glow
    var capsuleGlow: Glow
    /// The capsule while transcribing: lighter, no glow.
    var capsuleTranscribingTop: UInt32
    var capsuleTranscribingBottom: UInt32
    var capsuleTranscribingEdge: Tone
    var caretTop: UInt32
    var caretBottom: UInt32
    var caretGlow: Tone
    /// nwStop, success and warning: the system colours of the appearance.
    var stop: UInt32
    var success: UInt32
    var warning: UInt32

    static let dark = OverlayColors(
        surface: Tone(hex: 0x000000, opacity: 0.9),
        solidSurface: Tone(hex: 0x1C1C1E),
        innerGlowOpacity: 0.32,
        rim: nil,
        farShadow: DropShadow(tone: Tone(hex: 0x000000, opacity: 0.22), radius: 13, y: 10),
        nearShadow: DropShadow(tone: Tone(hex: 0x000000, opacity: 0.16), radius: 1.5, y: 1),
        ink: 0xFFFFFF,
        textOpacity: 0.94, tailOpacity: 0.68, timerOpacity: 0.72, timerStoppedOpacity: 0.68, labelOpacity: 0.92,
        transcribingLabel: 0xE9C4FE,
        sweepLit: 0xE9C4FE, sweepDimOpacity: 0.32,
        capsulePulse: Glow(tone: Tone(hex: 0xD9A6FF), radius: 7, dimOpacity: 0.25, dimRadius: 1),
        capsuleGlow: Glow(tone: Tone(hex: 0xAA3CFF, opacity: 0.9), radius: 14, dimOpacity: 0, dimRadius: 2),
        capsuleTranscribingTop: 0xEBD2FE, capsuleTranscribingBottom: 0xDB98FE,
        capsuleTranscribingEdge: Tone(hex: 0xDB98FE, opacity: 0.6),
        caretTop: 0xDB98FE, caretBottom: 0x9924FF, caretGlow: Tone(hex: 0xAA3CFF, opacity: 0.9),
        stop: 0xFF453A, success: 0x30D158, warning: 0xFF9F0A
    )

    static let light = OverlayColors(
        surface: Tone(hex: 0xFFFFFF, opacity: 0.94),
        solidSurface: Tone(hex: 0xFFFFFF),
        innerGlowOpacity: 0.30,
        rim: Tone(hex: 0x1A1325, opacity: 0.14),
        farShadow: DropShadow(tone: Tone(hex: 0x281050, opacity: 0.16), radius: 13, y: 10),
        nearShadow: DropShadow(tone: Tone(hex: 0x1A1325, opacity: 0.10), radius: 1.5, y: 1),
        ink: 0x1A1325,
        textOpacity: 0.92, tailOpacity: 0.64, timerOpacity: 0.68, timerStoppedOpacity: 0.64, labelOpacity: 0.90,
        transcribingLabel: 0x7A1FD6,
        sweepLit: 0x8A1FF0, sweepDimOpacity: 0.25,
        // On white the capsule's glow is smaller and softer.
        capsulePulse: Glow(tone: Tone(hex: 0xBE78FF, opacity: 0.75), radius: 4, dimOpacity: 0.3, dimRadius: 1),
        capsuleGlow: Glow(tone: Tone(hex: 0xAA3CFF, opacity: 0.45), radius: 8, dimOpacity: 0, dimRadius: 2),
        capsuleTranscribingTop: 0xDDB8FF, capsuleTranscribingBottom: 0xB477FF,
        capsuleTranscribingEdge: Tone(hex: 0x9924FF, opacity: 0.45),
        caretTop: 0xB86BFF, caretBottom: 0x8A1FF0, caretGlow: Tone(hex: 0x9628FF, opacity: 0.5),
        stop: 0xFF3B30, success: 0x34C759, warning: 0xFF9500
    )

    static func forScheme(_ scheme: ColorScheme) -> OverlayColors {
        scheme == .dark ? .dark : .light
    }

    /// The palette of an AppKit appearance (dark, high-contrast dark: `.dark`; else `.light`).
    static func forAppearance(_ appearance: NSAppearance) -> OverlayColors {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }

    var isDark: Bool { self == .dark }

    func ink(_ opacity: Double) -> Color { OverlayPalette.rgb(ink, opacity) }
    var text: Color { ink(textOpacity) }
    var label: Color { ink(labelOpacity) }
    var timer: Color { ink(timerOpacity) }
    var timerStopped: Color { ink(timerStoppedOpacity) }

    var capsuleTranscribing: LinearGradient {
        LinearGradient(colors: [OverlayPalette.rgb(capsuleTranscribingTop), OverlayPalette.rgb(capsuleTranscribingBottom)],
                       startPoint: .top, endPoint: .bottom)
    }
}

extension View {
    /// The overlay's drop shadows in `colors` (the welcome's recorder; the live panel draws them
    /// in a separate click-through window, `OverlayShadowPanel`).
    func overlayDropShadows(_ colors: OverlayColors) -> some View {
        shadow(color: colors.farShadow.tone.color, radius: colors.farShadow.radius, y: colors.farShadow.y)
            .shadow(color: colors.nearShadow.tone.color, radius: colors.nearShadow.radius, y: colors.nearShadow.y)
    }
}

// MARK: - Metrics

enum OverlayMetrics {
    static let headerHeight: CGFloat = 36
    static let cornerRadius: CGFloat = 18
    static let leadingPadding: CGFloat = 14
    static let trailingPadding: CGFloat = 12
    static let itemSpacing: CGFloat = 10
    /// Width of the compact overlay (a capsule: height 36, radius 18).
    static let compactWidth: CGFloat = 184
    /// Width of the card with live text.
    static let cardWidth: CGFloat = 380
    static let textInset: CGFloat = 16
    static let textBottomInset: CGFloat = 13
    static let trailingSlotWidth: CGFloat = 30
}

// MARK: - SwiftUI View

/// "Voice note": a capsule with the record indicator, a scrolling waveform and the timer; with
/// live text, the same capsule grows into a card below its own header. Dark or light with the
/// effective appearance (`OverlayColors`).
struct RecordingOverlayView: View {
    @ObservedObject var viewModel: RecordingOverlayViewModel
    var onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var colors: OverlayColors { .forScheme(colorScheme) }

    var body: some View {
        let transcript = viewModel.visibleTranscript
        VStack(alignment: .leading, spacing: 0) {
            header(hasText: transcript != nil)
            if let transcript {
                LiveTranscriptText(
                    stableText: transcript.stableText,
                    volatileText: transcript.volatileText,
                    colors: colors,
                    showsCaret: viewModel.state == .recording,
                    caretBlinks: !viewModel.isPaused,
                    isFinal: transcript.isFinal,
                    lineCount: viewModel.transcriptLineCount
                )
                .padding(.horizontal, OverlayMetrics.textInset)
                .padding(.bottom, OverlayMetrics.textBottomInset)
                .modifier(FadeIn(duration: 0.12))
            }
        }
        .frame(width: transcript != nil ? OverlayMetrics.cardWidth : nil)
        .frame(minWidth: OverlayMetrics.compactWidth)
        .background(OverlayBackground(cornerRadius: OverlayMetrics.cornerRadius, colors: colors))
        .clipShape(RoundedRectangle(cornerRadius: OverlayMetrics.cornerRadius, style: .circular))
        // Appear: scale 0.96 → 1 from the pinned edge (the window fades in meanwhile).
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { content in
            content.scaleEffect(viewModel.isPresented || reduceMotion ? 1 : 0.96,
                                anchor: viewModel.position.unitPoint)
        }
        .onHover { hovering in
            viewModel.isPointerOver = hovering
        }
    }

    // MARK: Header

    private var isTranscribing: Bool { viewModel.state == .loading }

    private func header(hasText: Bool) -> some View {
        HStack(spacing: OverlayMetrics.itemSpacing) {
            switch viewModel.state {
            // The trailing item takes the remaining width (no `Spacer`: the stack's spacing
            // would apply on both of its sides and widen the compact capsule).
            case .finished(let result):
                ResultBadge(result: result, colors: colors)
                trailing {
                    if result.isSuccess {
                        timerText(color: colors.timerStopped)
                    } else if let detail = result.detail {
                        Text(detail)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(colors.timerStopped)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            case .idle, .recording, .loading:
                RecordIndicator(isTranscribing: isTranscribing, isPaused: viewModel.isPaused, colors: colors)
                    // A new indicator when it pauses or resumes: a repeating animation already
                    // running is not stopped by later non-animated changes (the capsule kept
                    // pulsing on the welcome's frozen card), and a resumed one starts again.
                    .id(viewModel.isPaused)
                // In the card the waveform takes the header's whole width (2026-11-20
                // feedback); in the capsule it keeps its 26 bars.
                OverlayWaveformView(waveform: viewModel.waveform, isTranscribing: isTranscribing, fillsWidth: hasText,
                                    revision: viewModel.waveform.revision, colors: colors)
                trailing(flexible: !hasText) {
                    if isTranscribing && (hasText || reduceMotion) {
                        Text("Transcribing…")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.1)
                            .foregroundStyle(OverlayPalette.rgb(colors.transcribingLabel))
                            .lineLimit(1)
                            .fixedSize()
                    } else {
                        timerOrStopButton
                    }
                }
            }
        }
        .padding(.leading, OverlayMetrics.leadingPadding)
        .padding(.trailing, OverlayMetrics.trailingPadding)
        .frame(height: OverlayMetrics.headerHeight)
    }

    /// The trailing item: it takes the remaining width, unless the waveform does.
    @ViewBuilder
    private func trailing(flexible: Bool = true, @ViewBuilder _ content: () -> some View) -> some View {
        if flexible {
            content().frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            content().fixedSize()
        }
    }

    private func timerText(color: Color) -> some View {
        Text(viewModel.elapsedFormatted)
            .font(.system(size: 12, weight: .medium).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(minWidth: OverlayMetrics.trailingSlotWidth, alignment: .trailing)
    }

    /// Timer, or the Stop button while the pointer is over a recording.
    private var timerOrStopButton: some View {
        let showsStop = viewModel.isPointerOver && viewModel.state == .recording
        return ZStack(alignment: .trailing) {
            timerText(color: viewModel.state == .recording ? colors.timer : colors.timerStopped)
                .opacity(showsStop ? 0 : 1)

            Button(action: onStop) {
                // The symbol keeps its square centred in the circle at any position (a circle
                // with an overlaid 7 pt square rendered off by a pixel on half-point origins).
                Image(systemName: "stop.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, OverlayPalette.rgb(colors.stop))
                    .font(.system(size: 20))
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
            .opacity(showsStop ? 1 : 0)
            .allowsHitTesting(showsStop)
            // Centred under the timer it replaces, not pushed against the edge.
            .frame(width: OverlayMetrics.trailingSlotWidth)
        }
        .frame(minWidth: OverlayMetrics.trailingSlotWidth, alignment: .trailing)
        .animation(.easeOut(duration: 0.15), value: showsStop)
    }
}

// MARK: - Background

/// The translucent surface, or an opaque one with Reduce Transparency, with the violet inner
/// shadow and, in light, a hairline rim inside the edge.
private struct OverlayBackground: View {
    let cornerRadius: CGFloat
    let colors: OverlayColors
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        // An inner shadow: violet at the edge, fading to the surface within ~10 pt.
        shape.fill((reduceTransparency ? colors.solidSurface.color : colors.surface.color)
            .shadow(.inner(color: OverlayPalette.rgb(OverlayPalette.innerGlowColor, colors.innerGlowOpacity),
                           radius: OverlayPalette.innerGlowRadius)))
            .overlay {
                if let rim = colors.rim {
                    shape.strokeBorder(rim.color, lineWidth: 0.5)
                }
            }
    }
}

// MARK: - Record indicator

/// The glowing capsule from the app icon, 6 × 14 pt. It breathes while recording (glow
/// radius and opacity, 2.4 s) and turns light, without glow, while transcribing. Static with
/// Reduce Motion. Paused (onboarding's welcome at rest): still, at the dim end of its breath.
struct RecordIndicator: View {
    let isTranscribing: Bool
    var isPaused = false
    var colors: OverlayColors = .dark
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 6, height: 14)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        let breathes = !reduceMotion && !isTranscribing && !isPaused
        let glow = !isPaused && (breathing || !breathes)
        Group {
            if isTranscribing {
                shape.fill(colors.capsuleTranscribing)
                    .overlay(shape.strokeBorder(colors.capsuleTranscribingEdge.color, lineWidth: 0.5))
            } else {
                shape.fill(OverlayPalette.capsule)
                    .overlay(shape.strokeBorder(OverlayPalette.capsuleEdge, lineWidth: 1))
            }
        }
        .frame(width: Self.size.width, height: Self.size.height)
        // The repeating animation applies to the glow only. Attached to the whole view
        // (`.animation(_:value:)`), it also picked up the indicator's position when `onAppear`
        // ran while the overlay was being laid out (a recording started from a SwiftUI button,
        // as in onboarding's Try-it), and the indicator slid back and forth.
        .animation(breathes ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : nil) { content in
            content
                .brightness(glow && breathes ? 0.18 : 0)
                .scaleEffect(glow && breathes ? 1.18 : 1)
                .shadow(color: Self.tone(colors.capsulePulse, glow: glow, hidden: isTranscribing),
                        radius: glow ? colors.capsulePulse.radius : colors.capsulePulse.dimRadius)
                .shadow(color: Self.tone(colors.capsuleGlow, glow: glow, hidden: isTranscribing),
                        radius: glow ? colors.capsuleGlow.radius : colors.capsuleGlow.dimRadius)
        }
        .onAppear { breathing = true }
        .accessibilityHidden(true)
    }

    /// A glow's colour at the breath's peak (`glow`) or at rest; none while transcribing.
    private static func tone(_ glow: OverlayColors.Glow, glow isOn: Bool, hidden: Bool) -> Color {
        OverlayPalette.rgb(glow.tone.hex, hidden ? 0 : (isOn ? glow.tone.opacity : glow.dimOpacity))
    }
}

// MARK: - Result

/// Check and "Pasted", or a warning sign and what went wrong. The badge scales in (0.2 s).
private struct ResultBadge: View {
    let result: OverlayResult
    let colors: OverlayColors
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(OverlayPalette.rgb(result.isSuccess ? colors.success : colors.warning))
                if result.isSuccess {
                    CheckMark()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                } else {
                    ExclamationMark().fill(Color.white)
                }
            }
            .frame(width: 16, height: 16)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2)) { content in
                content.scaleEffect(shown || reduceMotion ? 1 : 0.4)
            }
            Text(result.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(colors.label)
                .lineLimit(1)
                .fixedSize()
        }
        .onAppear { shown = true }
        .accessibilityElement(children: .combine)
    }
}

/// The check of a 16 pt badge (design: M4.6 8.2 l2.2 2.2 4.6 -4.8).
private struct CheckMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 16
        var path = Path()
        path.move(to: CGPoint(x: 4.6 * s, y: 8.2 * s))
        path.addLine(to: CGPoint(x: 6.8 * s, y: 10.4 * s))
        path.addLine(to: CGPoint(x: 11.4 * s, y: 5.6 * s))
        return path
    }
}

/// The exclamation mark of a 16 pt badge.
private struct ExclamationMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 16
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 7.1 * s, y: 3.3 * s, width: 1.8 * s, height: 6.4 * s),
                            cornerSize: CGSize(width: 0.9 * s, height: 0.9 * s))
        path.addEllipse(in: CGRect(x: 6.95 * s, y: 10.35 * s, width: 2.1 * s, height: 2.1 * s))
        return path
    }
}

/// Fades the content in once, when it appears. The animation applies to the opacity only, so
/// it never picks up the layout of the panel growing at the same moment.
private struct FadeIn: ViewModifier {
    let duration: TimeInterval
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .animation(.easeOut(duration: duration)) { $0.opacity(shown ? 1 : 0) }
            .onAppear { shown = true }
    }
}

// MARK: - Live transcript

/// The last lines of the live transcript: settled words in the ink, the tail that may still
/// change dimmed (never another hue), and the glowing caret where the next words will land.
/// Fixed height (`lineCount` lines), so updates never resize the overlay; the newest line sits
/// at the bottom and older lines fade out at the top edge.
struct LiveTranscriptText: View {
    let stableText: String
    let volatileText: String
    var colors: OverlayColors = .dark
    /// The caret blinks after the last word while recording.
    var showsCaret = false
    /// False: the caret stays on, still (a paused recording: onboarding's welcome at rest).
    var caretBlinks = true
    /// The final text (what is pasted): cross-faded in.
    var isFinal = false
    var lineCount = LiveTranscriptText.defaultLineCount

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Three lines (2026-11-20 feedback: two were cramped). The layout follows `lineCount`;
    /// four also fits (captured in `OverlayWindowTests`).
    static let defaultLineCount = 3
    static let fontSize: CGFloat = 13
    /// Distance from one baseline to the next.
    static let lineHeight: CGFloat = 19
    /// Height of `lines` lines.
    static func height(lines: Int) -> CGFloat { lineHeight * CGFloat(lines) }
    var height: CGFloat { Self.height(lines: lineCount) }
    /// Height of the top fade.
    static let fadeHeight: CGFloat = 9

    private static let fontLineHeight = NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize))
    private static let lineSpacing = max(0, lineHeight - fontLineHeight)
    /// Half the leading above the first line and below the last, as in a CSS line box.
    private static let halfLeading = lineSpacing / 2

    var body: some View {
        Group {
            if showsCaret && caretBlinks && !reduceMotion {
                TimelineView(.periodic(from: .now, by: 0.2)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                    lines(caret: phase < 0.6 ? .on : .dim)
                }
            } else {
                lines(caret: showsCaret ? .on : nil)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .mask(
            LinearGradient(
                stops: [.init(color: .clear, location: 0),
                        .init(color: .black, location: Self.fadeHeight / height)],
                startPoint: .top, endPoint: .bottom)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stableText + volatileText)
    }

    private func lines(caret: Caret.Phase?) -> some View {
        LatestLinesLayout {
            text(caret: caret)
                .font(.system(size: Self.fontSize))
                .tracking(-0.05)
                .lineSpacing(Self.lineSpacing)
                .padding(.vertical, Self.halfLeading)
                .contentTransition(.interpolate)
                .animation(reduceMotion ? nil : .easeOut(duration: isFinal ? 0.15 : 0.2), value: stableText + volatileText)
        }
    }

    private func text(caret: Caret.Phase?) -> Text {
        var text = Text(stableText).foregroundStyle(colors.text)
            + Text(volatileText).foregroundStyle(colors.ink(colors.tailOpacity))
        if let caret {
            text = text + Text(Image(nsImage: Caret.image(caret, colors: colors))).baselineOffset(Caret.baselineOffset)
        }
        return text
    }
}

/// The text caret: an inline capsule 2.5 × 14 pt with the capsule gradient and a glow, 3 pt
/// after the last word. Drawn as an image so it flows with the text.
enum Caret {
    enum Phase { case on, dim }

    static let size = CGSize(width: 2.5, height: 14)
    static let leadingGap: CGFloat = 3
    /// Room for the glow after the caret, inside the image. None above or below: a taller
    /// image would make its line taller than the others.
    static let glowPadding: CGFloat = 2
    /// The caret's bottom sits 2 pt below the baseline.
    static let baselineOffset: CGFloat = -2

    private struct Key: Hashable {
        var phase: Phase
        var isDark: Bool
    }

    @MainActor private static var cache: [Key: NSImage] = [:]

    /// The caret in `colors` (its gradient and glow differ in light).
    @MainActor static func image(_ phase: Phase, colors: OverlayColors = .dark) -> NSImage {
        let key = Key(phase: phase, isDark: colors.isDark)
        if let image = cache[key] { return image }
        let top = OverlayPalette.nsColor(colors.caretTop), bottom = OverlayPalette.nsColor(colors.caretBottom)
        let glowColor = OverlayPalette.nsColor(colors.caretGlow.hex)
        let glowOpacity = CGFloat(colors.caretGlow.opacity)
        let image = NSImage(
            size: NSSize(width: leadingGap + size.width + glowPadding, height: size.height),
            flipped: false
        ) { _ in
            let rect = NSRect(x: leadingGap, y: 0, width: size.width, height: size.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: size.width / 2, yRadius: size.width / 2)
            let alpha: CGFloat = phase == .on ? 1 : 0.25
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = glowColor.withAlphaComponent(glowOpacity * alpha)
            glow.shadowBlurRadius = 3
            glow.shadowOffset = .zero
            glow.set()
            bottom.withAlphaComponent(alpha).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: top.withAlphaComponent(alpha), ending: bottom.withAlphaComponent(alpha))?
                .draw(in: path, angle: -90)
            return true
        }
        cache[key] = image
        return image
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
