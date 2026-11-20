import SwiftUI

/// Settings › Recorder: where the recorder appears, and live transcription (debug builds).
struct RecorderPane: View {
    let context: SettingsContext

    static let liveTranscriptionLabel = "Show words in the recorder as you speak"

    /// Whether the pane has anything to show in this build (it is hidden otherwise).
    // RECORDER POSITION: return true once `RecorderPositionPicker` is wired below.
    static func hasContent(offersLiveTranscription: Bool) -> Bool {
        offersLiveTranscription
    }

    private var liveTranscriptionAvailable: Bool {
        LiveTranscriptionSupport.isAvailable(for: context.appliedEngine)
    }

    var body: some View {
        SettingsPaneForm {
            // RECORDER POSITION: the "Recorder position" section goes here, first in the pane.
            // `RecorderPositionPicker(selection:)` and `AppState.recorderPosition` come from
            // the Voice note overlay (feat/voice-note-overlay); not implemented here on purpose.
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
