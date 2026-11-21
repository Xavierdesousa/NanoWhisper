import SwiftUI

// MARK: - Model comparison values

/// Qualitative speed/accuracy summary of one model.
///
/// Bars are relative tiers, not measurements. The only figures shown are word error rates
/// published by FluidAudio for Parakeet (Documentation/ASR/ParakeetUltra.md): LibriSpeech
/// test-clean 2.27 % (v3) / 2.13 % (Ultra), FLEURS 24-language mean 14.81 % / 11.67 %.
struct ModelComparison: Hashable {
    let modelType: TranscriptionModelType
    var parakeetVariant: ParakeetVariant = .v3
    var whisperModelSize: WhisperModelSize = .base

    /// Only the fields of the selected engine count: Whisper's size does not change Parakeet.
    static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.modelType == rhs.modelType else { return false }
        switch lhs.modelType {
        case .parakeet: return lhs.parakeetVariant == rhs.parakeetVariant
        case .whisper: return lhs.whisperModelSize == rhs.whisperModelSize
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(modelType)
        switch modelType {
        case .parakeet: hasher.combine(parakeetVariant)
        case .whisper: hasher.combine(whisperModelSize)
        }
    }

    /// Every model the Engine section can show, plus `current` (a stored size no longer
    /// offered). The comparison reserves the height of the tallest, so it never jumps.
    static func offered(including current: ModelComparison) -> [ModelComparison] {
        var models = ParakeetVariant.allCases.map { ModelComparison(modelType: .parakeet, parakeetVariant: $0) }
            + WhisperModelSize.selectable.map { ModelComparison(modelType: .whisper, whisperModelSize: $0) }
        if !models.contains(current) { models.append(current) }
        return models
    }

    var speed: MetricTier {
        switch modelType {
        case .parakeet:
            // Ultra runs at parity with v3 (FluidAudio benchmarks).
            return .highest
        case .whisper:
            switch whisperModelSize {
            case .tiny, .base: return .high
            case .small, .largev3Turbo: return .medium
            case .medium: return .low
            case .largev3: return .lowest
            }
        }
    }

    var accuracy: MetricTier {
        switch modelType {
        case .parakeet:
            switch parakeetVariant {
            case .v3: return .high
            case .ultra: return .highest
            }
        case .whisper:
            switch whisperModelSize {
            case .tiny: return .lowest
            case .base: return .low
            case .small: return .medium
            case .medium, .largev3Turbo: return .high
            case .largev3: return .highest
            }
        }
    }

    var bulletPoints: [String] {
        switch modelType {
        case .parakeet:
            let common = [
                "25 European languages, detected automatically — nothing to configure",
                "Fastest option: transcribes many times faster than real time",
            ]
            switch parakeetVariant {
            case .v3:
                return common + [
                    "Word error rate: 2.3% on English (LibriSpeech), 14.8% average across 24 European languages (FLEURS)",
                ]
            case .ultra:
                return common + [
                    "Post-trained v3: fewer errors in every measured language, same speed",
                    "Word error rate: 2.1% on English (LibriSpeech), 11.7% average across 24 European languages (FLEURS)",
                ]
            }
        case .whisper:
            var points = [
                "99 languages; set the language for best results on short clips",
                "Vocabulary hints help with names and technical terms",
            ]
            if let replacement = whisperModelSize.replacement {
                // Obsolete sizes are not offered; shown only if a stored choice still names one.
                points.append("No longer offered; replaced by \(replacement.displayName)")
                return points
            }
            switch whisperModelSize {
            case .tiny, .medium, .largev3:
                break // handled above
            case .base:
                points.append("Small and fast, but noticeably less accurate than larger sizes")
            case .small:
                points.append("Balanced size, speed and accuracy")
            case .largev3Turbo:
                points.append("OpenAI's turbo model: accuracy close to Large v3, much faster, a fifth of the download")
            }
            return points
        }
    }
}

// MARK: - Model comparison view

/// The speed and accuracy bars and the key points of the selected model, always shown under
/// the model picker. It keeps one height for every model (the tallest one's), so a change of
/// engine or model moves nothing: the bars slide to their new length (0.35 s) and the text
/// cross-fades (0.25 s). Reduce Motion: the bars change at once; the text still cross-fades.
struct ModelComparisonView: View {
    let modelType: TranscriptionModelType
    var parakeetVariant: ParakeetVariant = .v3
    var whisperModelSize: WhisperModelSize = .base

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let barAnimation = Animation.easeInOut(duration: 0.35)
    static let fadeAnimation = Animation.easeInOut(duration: 0.25)

    var comparison: ModelComparison {
        ModelComparison(modelType: modelType, parakeetVariant: parakeetVariant, whisperModelSize: whisperModelSize)
    }

    var speed: MetricTier { comparison.speed }
    var accuracy: MetricTier { comparison.accuracy }
    var bulletPoints: [String] { comparison.bulletPoints }

    var body: some View {
        let current = comparison
        VStack(alignment: .leading, spacing: 10) {
            MetricBar(label: "Speed", tier: current.speed, color: .blue, reduceMotion: reduceMotion)
            MetricBar(label: "Accuracy", tier: current.accuracy, color: .green, reduceMotion: reduceMotion)

            // Every model's points laid out in the same place, only the current one visible:
            // the tallest sets the height, and switching is a cross-fade.
            // The animation is scoped to the opacity: the same change of engine also changes
            // the layout around (Whisper's options appear, the window grows), and an
            // `.animation(_:value:)` here animated that too (the text slid down and back).
            ZStack(alignment: .topLeading) {
                ForEach(ModelComparison.offered(including: current), id: \.self) { model in
                    BulletList(points: model.bulletPoints)
                        .animation(Self.fadeAnimation) { $0.opacity(model == current ? 1 : 0) }
                        .accessibilityHidden(model != current)
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 2)
    }
}

private struct BulletList: View {
    let points: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(points, id: \.self) { point in
                HStack(alignment: .top, spacing: 4) {
                    Text("•")
                        .foregroundColor(.secondary)
                    Text(point)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Qualitative tiers

enum MetricTier: Int, CaseIterable {
    case lowest = 1, low, medium, high, highest

    /// Fill fraction of the bar.
    var fraction: Double { Double(rawValue) / Double(Self.allCases.count) }

    var label: String {
        switch self {
        case .lowest: return "Lowest"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .highest: return "Highest"
        }
    }
}

// MARK: - Metric bar component

/// The filled part of a bar, `fraction` of its width; animatable.
private struct BarFill: ViewModifier, Animatable {
    var fraction: Double
    let color: Color

    nonisolated var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geo.size.width * fraction)
            }
        }
    }
}

private struct MetricBar: View {
    let label: String
    let tier: MetricTier
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                // Every label in place, the current one shown: a cross-fade, never a slide.
                ZStack(alignment: .trailing) {
                    ForEach(MetricTier.allCases, id: \.self) { candidate in
                        Text(candidate.label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .animation(ModelComparisonView.fadeAnimation) { $0.opacity(candidate == tier ? 1 : 0) }
                    }
                }
            }
            // The track, and the fill drawn over it by an animatable modifier: only the fill's
            // fraction animates, never the bar's place (see the bullets above).
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.15))
                .frame(height: 6)
                .animation(reduceMotion ? nil : ModelComparisonView.barAnimation) {
                    $0.modifier(BarFill(fraction: tier.fraction, color: color))
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(tier.label)
    }
}
