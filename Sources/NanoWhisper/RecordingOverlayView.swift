import AppKit
import SwiftUI

// MARK: - Palette

/// Colors of the "Voice note" overlay. The overlay is always dark, in both system appearances.
enum OverlayPalette {
    static func rgb(_ hex: UInt32, _ opacity: Double = 1) -> Color {
        Color(.sRGB,
              red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255,
              opacity: opacity)
    }

    /// The surface over the HUD material: the deep violet of the app icon's tile, slightly
    /// translucent, so the blurred desktop shows through (2026-11-20 feedback: the opaque
    /// violet "felt too AI"). Opacity chosen for text contrast with the material ignored
    /// (the worst case): see `OverlayContrastTests`.
    static let surfaceColor: UInt32 = 0x261445
    static let surfaceOpacity = 0.76
    static let surface = rgb(surfaceColor, surfaceOpacity)
    /// Surface with Reduce Transparency (no material): the same violet, opaque.
    static let solidSurface = rgb(0x24123F)
    /// The rim, after the lighter edge around the app icon's inner tile (#8C66B4 on the
    /// icon): lighter at the top, like the icon's.
    static let rimTop = rgb(0xA88BD6, 0.9)
    static let rimBottom = rgb(0x7A56AE, 0.75)
    /// nwOverlayText: stable text.
    static let textOpacity = 0.94
    static let text = Color.white.opacity(textOpacity)
    /// Result label ("Pasted").
    static let label = Color.white.opacity(0.92)
    static let timerOpacity = 0.72
    static let timer = Color.white.opacity(timerOpacity)
    static let timerStoppedOpacity = 0.68
    static let timerStopped = Color.white.opacity(timerStoppedOpacity)
    /// The tail of the live text that may still change: dimmer than the stable text, still
    /// at least 4.5:1.
    static let tailOpacity = 0.68
    static let tailOpacityTranscribing = 0.68
    static let transcribingLabelColor: UInt32 = 0xE9C4FE
    static let transcribingLabel = rgb(transcribingLabelColor)
    /// nwStop (systemRed, dark).
    static let stop = rgb(0xFF453A)
    static let success = rgb(0x30D158)
    static let warning = rgb(0xFF9F0A)

    /// The record capsule (Foundations "Capsule").
    static let capsule = LinearGradient(
        stops: [.init(color: rgb(0xC27DFF), location: 0),
                .init(color: rgb(0x9924FF), location: 0.6),
                .init(color: rgb(0x8A1FF0), location: 1)],
        startPoint: .top, endPoint: .bottom)
    static let capsuleEdge = rgb(0xFFEBFF, 0.55)
    static let capsuleGlow = rgb(0xAA3CFF)
    /// The capsule while transcribing: lighter, no glow.
    static let capsuleTranscribing = LinearGradient(
        colors: [rgb(0xEBD2FE), rgb(0xDB98FE)], startPoint: .top, endPoint: .bottom)
    static let capsuleTranscribingEdge = rgb(0xDB98FE, 0.6)
    static let caretTop = NSColor(srgbRed: 0xDB / 255, green: 0x98 / 255, blue: 0xFE / 255, alpha: 1)
    static let caretBottom = NSColor(srgbRed: 0x99 / 255, green: 0x24 / 255, blue: 0xFF / 255, alpha: 1)
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

/// "Voice note": a dark capsule with the record indicator, a scrolling waveform and the timer;
/// with live text, the same capsule grows into a card below its own header.
struct RecordingOverlayView: View {
    @ObservedObject var viewModel: RecordingOverlayViewModel
    var onStop: () -> Void
    /// False in previews inside other windows (Settings): a solid fill instead of the
    /// behind-window material.
    var showsMaterial = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let transcript = viewModel.visibleTranscript
        VStack(alignment: .leading, spacing: 0) {
            header(hasText: transcript != nil)
            if let transcript {
                LiveTranscriptText(
                    stableText: transcript.stableText,
                    volatileText: transcript.volatileText,
                    tailOpacity: viewModel.state == .loading
                        ? OverlayPalette.tailOpacityTranscribing : OverlayPalette.tailOpacity,
                    showsCaret: viewModel.state == .recording,
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
        .background(OverlayBackground(cornerRadius: OverlayMetrics.cornerRadius, showsMaterial: showsMaterial))
        .clipShape(RoundedRectangle(cornerRadius: OverlayMetrics.cornerRadius, style: .circular))
        .environment(\.colorScheme, .dark)
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
                ResultBadge(result: result)
                trailing {
                    if result.isSuccess {
                        timerText(color: OverlayPalette.timerStopped)
                    }
                }
            case .idle, .recording, .loading:
                RecordIndicator(isTranscribing: isTranscribing)
                // In the card the waveform takes the header's whole width (2026-11-20
                // feedback); in the capsule it keeps its 26 bars.
                OverlayWaveformView(waveform: viewModel.waveform, isTranscribing: isTranscribing, fillsWidth: hasText)
                trailing(flexible: !hasText) {
                    if isTranscribing && (hasText || reduceMotion) {
                        Text("Transcribing…")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.1)
                            .foregroundStyle(OverlayPalette.transcribingLabel)
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
            timerText(color: viewModel.state == .recording ? OverlayPalette.timer : OverlayPalette.timerStopped)
                .opacity(showsStop ? 0 : 1)

            Button(action: onStop) {
                Circle()
                    .fill(OverlayPalette.stop)
                    .overlay(
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 7, height: 7)
                    )
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop recording")
            .opacity(showsStop ? 1 : 0)
            .allowsHitTesting(showsStop)
        }
        .frame(minWidth: OverlayMetrics.trailingSlotWidth, alignment: .trailing)
        .animation(.easeOut(duration: 0.15), value: showsStop)
    }
}

// MARK: - Background

/// HUD material (behind the window) under the translucent violet fill, or a solid fill with
/// Reduce Transparency; a 1 pt rim inside, after the app icon's tile edge.
private struct OverlayBackground: View {
    let cornerRadius: CGFloat
    var showsMaterial = true
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .circular)
        ZStack {
            if reduceTransparency {
                shape.fill(OverlayPalette.solidSurface)
            } else {
                if showsMaterial {
                    OverlayMaterial(cornerRadius: cornerRadius)
                }
                shape.fill(OverlayPalette.surface)
            }
        }
        .overlay(shape.strokeBorder(
            LinearGradient(colors: [OverlayPalette.rimTop, OverlayPalette.rimBottom],
                           startPoint: .top, endPoint: .bottom),
            lineWidth: 1
        ))
    }
}

/// `NSVisualEffectView` with the HUD material, always dark, masked to the overlay's shape.
private struct OverlayMaterial: NSViewRepresentable {
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        view.maskImage = Self.mask(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// A stretchable rounded rectangle: the corners keep their radius at any size.
    private static func mask(cornerRadius radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Record indicator

/// The glowing capsule from the app icon, 6 × 14 pt. It breathes while recording (glow
/// radius and opacity, 2.4 s) and turns light, without glow, while transcribing. Static with
/// Reduce Motion.
struct RecordIndicator: View {
    let isTranscribing: Bool
    @State private var breathing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size = CGSize(width: 6, height: 14)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        let breathes = !reduceMotion && !isTranscribing
        let glow = breathing || !breathes
        Group {
            if isTranscribing {
                shape.fill(OverlayPalette.capsuleTranscribing)
                    .overlay(shape.strokeBorder(OverlayPalette.capsuleTranscribingEdge, lineWidth: 0.5))
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
        .animation(breathes ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : nil) { content in
            content
                .shadow(color: OverlayPalette.capsuleGlow.opacity(isTranscribing ? 0 : (glow ? 0.85 : 0.55)),
                        radius: glow ? 4.5 : 2)
        }
        .onAppear { breathing = true }
        .accessibilityHidden(true)
    }
}

// MARK: - Result

/// Check and "Pasted", or a warning sign and what went wrong. The badge scales in (0.2 s).
private struct ResultBadge: View {
    let result: OverlayResult
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(result.isSuccess ? OverlayPalette.success : OverlayPalette.warning)
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
                .foregroundStyle(OverlayPalette.label)
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

/// The last lines of the live transcript: settled words in white, the tail that may still
/// change dimmed (never another hue), and the glowing caret where the next words will land.
/// Fixed height (`lineCount` lines), so updates never resize the overlay; the newest line sits
/// at the bottom and older lines fade out at the top edge.
struct LiveTranscriptText: View {
    let stableText: String
    let volatileText: String
    var tailOpacity: Double = OverlayPalette.tailOpacity
    /// The caret blinks after the last word while recording.
    var showsCaret = false
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
            if showsCaret && !reduceMotion {
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
        var text = Text(stableText).foregroundStyle(OverlayPalette.text)
            + Text(volatileText).foregroundStyle(Color.white.opacity(tailOpacity))
        if let caret {
            text = text + Text(Image(nsImage: Caret.image(caret))).baselineOffset(Caret.baselineOffset)
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

    @MainActor private static var cache: [Phase: NSImage] = [:]

    @MainActor static func image(_ phase: Phase) -> NSImage {
        if let image = cache[phase] { return image }
        let image = NSImage(
            size: NSSize(width: leadingGap + size.width + glowPadding, height: size.height),
            flipped: false
        ) { _ in
            let rect = NSRect(x: leadingGap, y: 0, width: size.width, height: size.height)
            let path = NSBezierPath(roundedRect: rect, xRadius: size.width / 2, yRadius: size.width / 2)
            let alpha: CGFloat = phase == .on ? 1 : 0.25
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = NSColor(srgbRed: 0xAA / 255, green: 0x3C / 255, blue: 1, alpha: 0.9 * alpha)
            glow.shadowBlurRadius = 3
            glow.shadowOffset = .zero
            glow.set()
            OverlayPalette.caretBottom.withAlphaComponent(alpha).setFill()
            path.fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGradient(starting: OverlayPalette.caretTop.withAlphaComponent(alpha),
                       ending: OverlayPalette.caretBottom.withAlphaComponent(alpha))?
                .draw(in: path, angle: -90)
            return true
        }
        cache[phase] = image
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
