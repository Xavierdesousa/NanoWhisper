import SwiftUI

/// Wording shared by the Settings panes and onboarding's setup page, so both say the same thing.
enum SettingsText {
    static let openAtLogin = "Open at login"
    static let sounds = "Play a sound when recording starts and stops"
    static let pauseMedia = "Pause music and videos while recording"
    static let keepHistory = "Keep a history of what you dictate"
    /// Also says where History opens: people did not find it (maintainer, 2026-11-21).
    static let keepHistoryCaption = "Encrypted, stays on this Mac. Open it from the menu bar icon."
    static let historyUnavailable = "History can’t be read right now. Turning it off deletes it."
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
            SettingsSection("Appearance") {
                AppearanceRow(selection: context.appearance)
                    .settingsRow()
            }
        }
    }
}

/// System, Light or Dark, for the whole app (Settings only, not in onboarding).
struct AppearanceRow: View {
    let selection: Binding<AppAppearance>

    static let title = "Theme"
    static let caption = "System follows macOS. Applies to every NanoWhisper window and to the recorder."

    var body: some View {
        SettingsRow(title: Self.title, caption: Self.caption) {
            Picker(Self.title, selection: selection) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
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
