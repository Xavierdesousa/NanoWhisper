import AppKit
import SwiftUI

// The onboarding window's look, from the design's "Icon" direction (Claude Design canvas
// "NanoWhisper Redesign", page "Onboarding", boards onb3-*): grouped rows like a native form,
// the system accent color for every control (no violet outside the recorder), light and dark.

// MARK: - Colors

/// The design's surface and text colors, light and dark. Controls use the system accent color.
enum OnboardingPalette {
    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    /// The window: #F2F2F4 / #1E1E20.
    static let windowNSColor = dynamic("nwOnboardingWindow", light: hex(0xF2F2F4), dark: hex(0x1E1E20))
    static let window = Color(nsColor: windowNSColor)
    /// A group of rows: white / #2A2A2D.
    static let group = Color(nsColor: dynamic("nwOnboardingGroup", light: .white, dark: hex(0x2A2A2D)))
    /// Lines between rows and above the footer.
    static let separator = Color(nsColor: dynamic("nwOnboardingSeparator", light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08)))
    /// Edges of groups, empty circles and tags.
    static let border = Color(nsColor: dynamic("nwOnboardingBorder", light: NSColor(white: 0, alpha: 0.14), dark: NSColor(white: 1, alpha: 0.14)))
    static let label = Color(nsColor: dynamic("nwOnboardingLabel", light: hex(0x1C1C1E), dark: hex(0xF2F2F4)))
    /// Captions and secondary text: #5E5E64 / #A8A8AF.
    static let secondaryLabel = Color(nsColor: dynamic("nwOnboardingSecondary", light: hex(0x5E5E64), dark: hex(0xA8A8AF)))
    /// The empty part of a ring.
    static let track = Color(nsColor: dynamic("nwOnboardingTrack", light: NSColor(white: 0, alpha: 0.10), dark: NSColor(white: 1, alpha: 0.13)))
    /// A warning's sign and its ring.
    static let warning = Color(nsColor: dynamic("nwOnboardingWarning", light: hex(0xA35200), dark: hex(0xFFAE45)))
    static let warningRing = Color(nsColor: dynamic("nwOnboardingWarningRing", light: hex(0xFF9500), dark: hex(0xFF9F0A)))
    /// A caption that says something is wrong.
    static let problem = Color(nsColor: dynamic("nwOnboardingProblem", light: hex(0xC4271E), dark: hex(0xFF6961)))
}

// MARK: - Grouped rows

/// A section title and its group of rows.
struct OnboardingSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(OnboardingPalette.label)
                .padding(.leading, 2)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(OnboardingPalette.group))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(OnboardingPalette.border, lineWidth: 0.5))
        }
    }
}

/// The line between two rows of a group.
struct OnboardingRowDivider: View {
    var body: some View {
        Rectangle().fill(OnboardingPalette.separator).frame(height: 0.5)
    }
}

/// Secondary text under a row title: 11.5 pt.
struct OnboardingCaption: View {
    let text: String
    var isProblem = false

    init(_ text: String, isProblem: Bool = false) {
        self.text = text
        self.isProblem = isProblem
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(isProblem ? OnboardingPalette.problem : OnboardingPalette.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// "Required" (stronger) or "Recommended" after a row title.
struct OnboardingTag: View {
    let text: String
    var isStrong = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.1)
            .foregroundStyle(isStrong ? OnboardingPalette.label : OnboardingPalette.secondaryLabel)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(OnboardingPalette.border, lineWidth: isStrong ? 1 : 0.5))
            .fixedSize()
    }
}

// MARK: - The circle that becomes a check

/// 20 pt: an empty circle, a check in the accent color, a warning, a ring that fills with a
/// download, or a turning arc while working without a percentage.
struct SetupMarkView: View {
    let mark: SetupMark
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let size: CGFloat = 20
    private static let ringWidth: CGFloat = 2.3

    var body: some View {
        ZStack {
            switch mark {
            case .empty:
                Circle().strokeBorder(OnboardingPalette.border, lineWidth: 1.5)
            case .checked:
                Circle().fill(Color.accentColor)
                PoppingIn {
                    CheckGlyph()
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2.1, lineCap: .round, lineJoin: .round))
                        .frame(width: 11, height: 11)
                }
            case .attention:
                Circle().strokeBorder(OnboardingPalette.warningRing, lineWidth: 1.5)
                PoppingIn {
                    ExclamationGlyph().fill(OnboardingPalette.warning).frame(width: 11, height: 11)
                }
            case .progress(let fraction):
                ring
                Circle()
                    .inset(by: Self.ringWidth / 2)
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: Self.ringWidth))
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : .linear(duration: 0.3), value: fraction)
            case .busy:
                ring
                if reduceMotion {
                    arc(rotation: 0)
                } else {
                    TimelineView(.animation) { context in
                        arc(rotation: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360)
                    }
                }
            }
        }
        .frame(width: Self.size, height: Self.size)
        .accessibilityHidden(true)
    }

    private var ring: some View {
        Circle().inset(by: Self.ringWidth / 2).stroke(OnboardingPalette.track, lineWidth: Self.ringWidth)
    }

    private func arc(rotation: Double) -> some View {
        Circle()
            .inset(by: Self.ringWidth / 2)
            .trim(from: 0, to: 0.28)
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
            .rotationEffect(.degrees(rotation - 90))
    }
}

/// Scales its content in from 0.4 when it appears (0.25 s), as the design's check does.
private struct PoppingIn<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .animation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
                $0.scaleEffect(shown || reduceMotion ? 1 : 0.4).opacity(shown || reduceMotion ? 1 : 0)
            }
            .onAppear { shown = true }
    }
}

/// The check of the 12 × 12 design glyph: M2.6 6.4 l2.3 2.3 4.6 -5.
private struct CheckGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 12
        var path = Path()
        path.move(to: CGPoint(x: 2.6 * s, y: 6.4 * s))
        path.addLine(to: CGPoint(x: 4.9 * s, y: 8.7 * s))
        path.addLine(to: CGPoint(x: 9.5 * s, y: 3.7 * s))
        return path
    }
}

/// The exclamation mark of the 12 × 12 design glyph.
struct ExclamationGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 12
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 5, y: 1.6, width: 2, height: 6.2).applying(.init(scaleX: s, y: s)),
                            cornerSize: CGSize(width: s, height: s))
        path.addEllipse(in: CGRect(x: 5, y: 8.4, width: 2, height: 2).applying(.init(scaleX: s, y: s)))
        return path
    }
}

// MARK: - Motion

/// The welcome's entrance: each element fades up 10 pt over 0.45 s after its delay. Only the
/// opacity and offset animate, never the layout.
struct FadeUp: ViewModifier {
    let isShown: Bool
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .timingCurve(0.2, 0.7, 0.2, 1, duration: 0.45).delay(delay)) {
            $0.opacity(isShown || reduceMotion ? 1 : 0).offset(y: isShown || reduceMotion ? 0 : 10)
        }
    }
}

extension View {
    func fadeUp(_ isShown: Bool, delay: Double) -> some View {
        modifier(FadeUp(isShown: isShown, delay: delay))
    }
}

// MARK: - Text with the shortcut inline

/// A sentence with the shortcut's key caps inside it ("Press ⌥ Space, say a sentence, …"),
/// wrapped and centered like text.
struct InlineShortcutText: View {
    let before: String
    let shortcut: Shortcut
    let after: String
    var fontSize: CGFloat = 14
    var lineHeight: CGFloat = 20

    private var spaceWidth: CGFloat {
        (" " as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize)]).width
    }

    var body: some View {
        let before = Self.words(self.before)
        let after = Self.words(self.after)
        InlineFlowLayout(lineHeight: lineHeight) {
            ForEach(Array(before.enumerated()), id: \.offset) { index, word in
                word.text.layoutValue(key: LeadingGap.self, value: index == 0 ? 0 : spaceWidth)
            }
            ShortcutKeysView(shortcut: shortcut, size: .small)
                .padding(.horizontal, 1)
                .layoutValue(key: LeadingGap.self, value: self.before.isEmpty ? 0 : spaceWidth)
            ForEach(Array(after.enumerated()), id: \.offset) { index, word in
                word.text.layoutValue(key: LeadingGap.self, value: index == 0 && !self.after.hasPrefix(" ") ? 0 : spaceWidth)
            }
        }
        .font(.system(size: fontSize))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(self.before) \(shortcut.spokenDescription)\(self.after)")
    }

    private struct Word { let text: Text }

    private static func words(_ string: String) -> [Word] {
        string.split(separator: " ").map { Word(text: Text(String($0))) }
    }
}

private struct LeadingGap: LayoutValueKey {
    static let defaultValue: CGFloat = 0
}

/// Lays its items out in lines like words, each line centered; an item starts a new line when
/// it does not fit. Items are centered vertically on their line.
private struct InlineFlowLayout: Layout {
    let lineHeight: CGFloat

    private struct Line {
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
        var width: CGFloat = 0
    }

    private func lines(for subviews: Subviews, width: CGFloat) -> [Line] {
        var lines: [Line] = [Line()]
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let gap = lines[lines.count - 1].items.isEmpty ? 0 : subview[LeadingGap.self]
            if !lines[lines.count - 1].items.isEmpty, lines[lines.count - 1].width + gap + size.width > width {
                lines.append(Line())
            }
            var line = lines[lines.count - 1]
            let x = line.items.isEmpty ? 0 : line.width + gap
            line.items.append((index, x, size))
            line.width = x + size.width
            lines[lines.count - 1] = line
        }
        return lines
    }

    /// Balanced, like CSS `text-wrap: balance`: as many lines as needed at `width`, each as
    /// even as possible (no single word left alone on the last line).
    private func balancedLines(for subviews: Subviews, width: CGFloat) -> [Line] {
        let greedy = lines(for: subviews, width: width)
        guard greedy.count > 1, width.isFinite else { return greedy }
        var low: CGFloat = 0
        var high = width
        for _ in 0..<12 {
            let mid = (low + high) / 2
            if lines(for: subviews, width: mid).count <= greedy.count { high = mid } else { low = mid }
        }
        return lines(for: subviews, width: high)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let lines = balancedLines(for: subviews, width: width)
        let widest = lines.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? widest, height: CGFloat(lines.count) * lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (row, line) in balancedLines(for: subviews, width: bounds.width).enumerated() {
            let originX = bounds.minX + (bounds.width - line.width) / 2
            let midY = bounds.minY + CGFloat(row) * lineHeight + lineHeight / 2
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: originX + item.x, y: midY), anchor: .leading, proposal: ProposedViewSize(item.size))
            }
        }
    }
}

// MARK: - App icon

/// The app's icon (the debug build's has its band).
enum OnboardingAppIcon {
    @MainActor static var image: NSImage {
        NSImage(named: "AppIcon") ?? NSApp?.applicationIconImage ?? NSImage()
    }
}
