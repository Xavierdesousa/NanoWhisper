import SwiftUI

/// General toggles, shared by Settings and onboarding. The history size is Settings-only
/// (`showsHistoryLimit`).
struct GeneralSettingsSection: View {
    let context: SettingsContext
    var showsHistoryLimit = false

    static let historyLimitChoices = [5, 10, 15, 25, 50, 100]

    var body: some View {
        Section("General") {
            Toggle("Launch at login", isOn: context.launchAtLogin)
            Toggle("Sound feedback", isOn: context.soundEnabled)
            Toggle("Pause media during recording", isOn: context.pauseMediaEnabled)
            Toggle("Live transcription (beta)", isOn: context.liveTranscriptionEnabled)
            Text("Shows the text in the overlay while you speak.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Save transcription history", isOn: context.historyEnabled)
                .disabled(context.historyUnavailable)
            if context.historyUnavailable {
                Label("History is unavailable: the encryption key could not be accessed.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if showsHistoryLimit && context.historyEnabled.wrappedValue {
                Picker("Transcriptions to keep", selection: context.maxHistoryCount) {
                    ForEach(Self.historyLimitChoices, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
            }
        }
    }
}
