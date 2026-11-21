import SwiftUI

/// Wording shared by the Settings panes and onboarding's setup page, so both say the same thing.
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
            SettingsSection("Shortcut") {
                ShortcutRecorderRow(shortcut: context.shortcut, onChange: context.setShortcut)
                    .settingsRow()
            }
            SettingsSection("When you dictate") {
                DictationBehaviorToggles(context: context)
            }
            SettingsSection("History") {
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
            .settingsRow()
        GroupedRowDivider()
        SettingsToggle(title: SettingsText.sounds, isOn: context.soundEnabled)
            .settingsRow()
        GroupedRowDivider()
        SettingsToggle(title: SettingsText.pauseMedia, isOn: context.pauseMediaEnabled)
            .settingsRow()
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
        .settingsRow()
        if context.historyUnavailable {
            GroupedRowDivider()
            Label(SettingsText.historyUnavailable, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
                .settingsRow()
        } else if showsLimit {
            GroupedRowDivider()
            SettingsPickerRow(
                title: SettingsText.keepLast, selection: context.maxHistoryCount,
                items: Self.limitChoices, itemTitle: SettingsText.historyLimit
            )
            .disabled(!context.historyEnabled.wrappedValue)
            .settingsRow()
        }
    }
}
