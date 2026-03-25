import SwiftUI

// MARK: - Model comparison metrics view

struct ModelComparisonView: View {
    let modelType: TranscriptionModelType

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Speed bar
            MetricBar(
                label: "Speed",
                value: modelType == .parakeet ? 0.95 : 0.45,
                color: .blue,
                description: modelType == .parakeet ? "Very fast" : "Slower"
            )

            // Accuracy bar
            MetricBar(
                label: "Accuracy",
                value: modelType == .parakeet ? 0.82 : 0.97,
                color: .green,
                description: modelType == .parakeet ? "~80-85%" : "~95-100%"
            )

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

    private var bulletPoints: [String] {
        switch modelType {
        case .parakeet:
            return [
                "Multilingual by default — no language to configure",
                "Fastest transcription speed available",
                "Best for quick dictation and real-time use",
                "English-optimized but handles other languages",
            ]
        case .whisper:
            return [
                "Near-perfect accuracy when language is specified",
                "99 languages supported with dedicated models",
                "Vocabulary hints for technical terms and names",
                "Auto-detect mode available (less reliable on short clips)",
            ]
        }
    }
}

// MARK: - Metric bar component

private struct MetricBar: View {
    let label: String
    let value: Double  // 0.0 to 1.0
    let color: Color
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                Text(description)
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
                        .frame(width: geo.size.width * value, height: 6)
                }
            }
            .frame(height: 6)
        }
    }
}

