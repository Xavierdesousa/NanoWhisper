import SwiftUI

// MARK: - Model comparison metrics view

/// Qualitative speed/accuracy summary for the selected model.
///
/// Bars are relative tiers, not measurements. The only figures shown are word error rates
/// published by FluidAudio for Parakeet (Documentation/ASR/ParakeetUltra.md): LibriSpeech
/// test-clean 2.27 % (v3) / 2.13 % (Ultra), FLEURS 24-language mean 14.81 % / 11.67 %.
struct ModelComparisonView: View {
    let modelType: TranscriptionModelType
    var parakeetVariant: ParakeetVariant = .v3
    var whisperModelSize: WhisperModelSize = .base

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            MetricBar(label: "Speed", tier: speed, color: .blue)
            MetricBar(label: "Accuracy", tier: accuracy, color: .green)

            // Key points
            VStack(alignment: .leading, spacing: 4) {
                ForEach(bulletPoints, id: \.self) { point in
                    HStack(alignment: .top, spacing: 4) {
                        Text("•")
                            .foregroundColor(.secondary)
                        Text(point)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
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

private struct MetricBar: View {
    let label: String
    let tier: MetricTier
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text(tier.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(0.15))
                        .frame(height: 6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: geo.size.width * tier.fraction, height: 6)
                }
            }
            .frame(height: 6)
        }
    }
}
