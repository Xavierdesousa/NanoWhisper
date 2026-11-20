import SwiftUI

/// Settings › Recorder: where the recorder appears, and live transcription (debug builds).
struct RecorderPane: View {
    let context: SettingsContext

    static let liveTranscriptionLabel = "Show words in the recorder as you speak"

    private var liveTranscriptionAvailable: Bool {
        LiveTranscriptionSupport.isAvailable(for: context.appliedEngine)
    }

    var body: some View {
        SettingsPaneForm {
            // The picker is the Voice note overlay's own control (`RecorderPositionPicker.swift`).
            Section {
                RecorderPositionPicker(selection: context.recorderPosition)
                    .padding(.vertical, 4)
            } header: {
                Text("Recorder position")
            } footer: {
                SettingsCaption(RecorderPositionPicker.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if context.offersLiveTranscription {
                Section {
                    SettingsToggle(
                        title: Self.liveTranscriptionLabel,
                        caption: liveTranscriptionAvailable
                            ? "Available in debug builds while it is in beta."
                            : LiveTranscriptionSupport.unavailableExplanation,
                        isOn: context.liveTranscriptionEnabled
                    )
                    .disabled(!liveTranscriptionAvailable)
                } header: {
                    HStack(spacing: 6) {
                        Text("Live transcription")
                        SettingsBadge(text: "Beta")
                    }
                }
            }
        }
    }
}
