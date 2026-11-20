import SwiftUI

/// Wording shared by the Settings panes and onboarding, so both say the same thing.
enum SettingsText {
    static let openAtLogin = "Open at login"
    static let sounds = "Play a sound when recording starts and stops"
    static let pauseMedia = "Pause music and videos while recording"
    static let keepHistory = "Keep a history of what you dictate"
    static let keepHistoryCaption = "Encrypted, stays on this Mac."
    static let historyUnavailable = "History is unavailable: the encryption key could not be accessed."
    static let keepLast = "Keep the last"

    static func historyLimit(_ count: Int) -> String {
        count == 1 ? "1 transcription" : "\(count) transcriptions"
    }
}

// MARK: - Settings pane

/// Settings › General: the shortcut, what happens when you dictate, history.
struct GeneralPane: View {
    let context: SettingsContext

    var body: some View {
        SettingsPaneForm {
            Section("Shortcut") {
                ShortcutRecorderRow(shortcut: context.shortcut, onChange: context.setShortcut)
            }
            Section("When you dictate") {
                DictationBehaviorToggles(context: context)
            }
            Section("History") {
                HistorySettingsRows(context: context, showsLimit: true)
            }
        }
    }
}

// MARK: - Shared rows

/// Open at login, sounds, pause media.
struct DictationBehaviorToggles: View {
    let context: SettingsContext

    var body: some View {
        SettingsToggle(title: SettingsText.openAtLogin, isOn: context.launchAtLogin)
        SettingsToggle(title: SettingsText.sounds, isOn: context.soundEnabled)
        SettingsToggle(title: SettingsText.pauseMedia, isOn: context.pauseMediaEnabled)
    }
}

/// History on/off and, in Settings, how many transcriptions to keep.
struct HistorySettingsRows: View {
    let context: SettingsContext
    var showsLimit: Bool

    static let limitChoices = [5, 10, 15, 25, 50, 100]

    var body: some View {
        SettingsToggle(
            title: SettingsText.keepHistory, caption: SettingsText.keepHistoryCaption,
            isOn: context.historyEnabled
        )
        .disabled(context.historyUnavailable)
        if context.historyUnavailable {
            Label(SettingsText.historyUnavailable, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        } else if showsLimit {
            Picker(SettingsText.keepLast, selection: context.maxHistoryCount) {
                ForEach(Self.limitChoices, id: \.self) { count in
                    Text(SettingsText.historyLimit(count)).tag(count)
                }
            }
            .disabled(!context.historyEnabled.wrappedValue)
        }
    }
}

// MARK: - Onboarding

/// General toggles on onboarding's Shortcut step (Settings shows them in `GeneralPane` and,
/// for live transcription, `RecorderPane`).
struct GeneralSettingsSection: View {
    let context: SettingsContext

    static let liveTranscriptionLabel = "Live transcription (beta)"

    private var liveTranscriptionAvailable: Bool {
        LiveTranscriptionSupport.isAvailable(for: context.appliedEngine)
    }

    var body: some View {
        Section("General") {
            DictationBehaviorToggles(context: context)
            if context.offersLiveTranscription {
                Toggle(Self.liveTranscriptionLabel, isOn: context.liveTranscriptionEnabled)
                    .disabled(!liveTranscriptionAvailable)
                Text(liveTranscriptionAvailable
                     ? "Shows the text in the overlay while you speak."
                     : LiveTranscriptionSupport.unavailableExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HistorySettingsRows(context: context, showsLimit: false)
        }
    }
}
