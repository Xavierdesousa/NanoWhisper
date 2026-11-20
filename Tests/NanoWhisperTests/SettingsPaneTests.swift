import Carbon
import Foundation
import SwiftUI
import Testing
@testable import NanoWhisper

@Suite("Settings panes")
struct SettingsPaneTests {
    @Test("The Recorder pane is shown only when it has content")
    func visiblePanes() {
        #expect(SettingsPane.visible(recorderHasContent: true) == SettingsPane.allCases)
        #expect(SettingsPane.visible(recorderHasContent: false) == [.general, .engine, .permissions, .advanced])
        #expect(RecorderPane.hasContent(offersLiveTranscription: true))
        #expect(!RecorderPane.hasContent(offersLiveTranscription: false))
    }

    @Test("Settings reopens on the last pane while it is shown, else on General")
    func restoredPane() {
        let all = SettingsPane.allCases
        #expect(SettingsPane.restored(nil, from: all) == .general)
        #expect(SettingsPane.restored("advanced", from: all) == .advanced)
        #expect(SettingsPane.restored("unknown", from: all) == .general)
        #expect(SettingsPane.restored("recorder", from: SettingsPane.visible(recorderHasContent: false)) == .general)
    }

    @Test("Debug builds offer live transcription in the Recorder pane; production hides it", arguments: [false, true])
    @MainActor
    func recorderLiveToggle(offered: Bool) {
        let context = Fixtures.context(
            applied: Fixtures.parakeetUltra, state: Fixtures.ready, offersLiveTranscription: offered
        )
        var tree = ""
        dump(RecorderPane(context: context).body, to: &tree)
        #expect(tree.contains("\"\(RecorderPane.liveTranscriptionLabel)\"") == offered)
    }
}

@Suite("Shortcut keys")
struct ShortcutKeysTests {
    @Test("One key per box, modifiers in the macOS order")
    func keys() {
        let optionSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        #expect(optionSpace.keys.map(\.glyph) == ["⌥", "Space"])
        #expect(optionSpace.displayString == "⌥Space")

        let debug = BuildFlavor.debug.defaultShortcut
        #expect(debug.keys.map(\.glyph) == ["⌃", "⌥", "Space"])
        #expect(debug.displayString == "⌃⌥Space")
        #expect(debug.spokenDescription == "Control Option Space")

        let all = Shortcut(keyCode: UInt32(kVK_F5), modifiers: UInt32(cmdKey | shiftKey | optionKey | controlKey))
        #expect(all.keys.map(\.glyph) == ["⌃", "⌥", "⇧", "⌘", "F5"])
    }
}

@Suite("Engine pane status")
struct EnginePaneStatusTests {
    private let ultra = EngineConfiguration(modelType: .parakeet, parakeetVariant: .ultra, whisperSettings: WhisperSettings())
    private let ready = EngineState(isReady: true, setupComplete: true)

    private func status(_ state: EngineState, availability: ModelAvailability = .downloaded) -> EngineStatusDisplay {
        EngineStatusDisplay.resolve(applied: ultra, state: state, availability: availability)
    }

    @Test("Ready, downloading, optimizing, loading, not downloaded")
    func states() {
        #expect(status(ready) == EngineStatusDisplay(title: "Parakeet Ultra", detail: "In use, on this Mac.", accessory: .ready))
        #expect(status(EngineState(isSettingUp: true, progressText: "Downloading model (42%)...")) == EngineStatusDisplay(
            title: "Downloading Parakeet Ultra", detail: "42% of ~630 MB.", progress: .fraction(0.42)))
        #expect(status(EngineState(isSettingUp: true, progressText: "Preparing download...")).progress == .indeterminate)
        #expect(status(EngineState(isSettingUp: true, progressText: "Compiling model...")).accessory == .spinner)
        #expect(status(EngineState(setupComplete: true)).detail == "Loading…")
        #expect(status(EngineState(), availability: .notDownloaded) == EngineStatusDisplay(
            title: "Parakeet Ultra", detail: "Not downloaded · ~630 MB", accessory: .load("Download")))
    }

    @Test("Failures say which step failed and offer Try Again")
    func failures() {
        let setup = status(EngineState(error: "No network."))
        #expect(setup == EngineStatusDisplay(title: "Could not set up Parakeet Ultra", detail: "No network.",
                                             isFailure: true, accessory: .tryAgain))
        let start = status(EngineState(setupComplete: true, initializationError: AppState.engineStartFailedMessage))
        #expect(start.title == "Parakeet Ultra could not start")
        #expect(start.accessory == .tryAgain)
    }

    @Test("Migration switchover: download of the new model while the previous one is in use")
    func upgrade() {
        var downloading = ready
        downloading.upgrade = ModelUpgrade(from: .parakeet(.v3), to: .parakeet(.ultra), status: .downloading(fraction: 0.42))
        #expect(status(downloading) == EngineStatusDisplay(
            title: "Downloading Parakeet Ultra",
            detail: "42% of ~630 MB. Parakeet TDT 0.6B v3 stays in use until it is ready.",
            progress: .fraction(0.42)))
        var deferred = ready
        deferred.upgrade = ModelUpgrade(from: .parakeet(.v3), to: .parakeet(.ultra), status: .deferred)
        #expect(status(deferred) == EngineStatusDisplay(
            title: "Parakeet TDT 0.6B v3",
            detail: "In use, on this Mac. Parakeet Ultra will download at next launch.",
            accessory: .ready))
    }

    @Test("Pending change: the download is stated before the click; the size rule is kept")
    func pending() {
        var v3 = ultra
        v3.parakeetVariant = .v3
        let download = EngineApplyDisplay.resolve(draft: v3, applied: ultra, state: ready, availability: .notDownloaded)
        #expect(download == EngineApplyDisplay(
            title: "Parakeet TDT 0.6B v3 needs a ~480 MB download",
            detail: "Dictation pauses until it is ready.", applyTitle: "Download & Apply"))
        let onDisk = EngineApplyDisplay.resolve(draft: v3, applied: ultra, state: ready, availability: .downloaded)
        #expect(onDisk.applyTitle == "Apply")
        #expect(onDisk.detail == "Parakeet TDT 0.6B v3 is already on this Mac.")

        var whisperLanguage = ultra
        whisperLanguage.whisperSettings.language = "fr"
        let instant = EngineApplyDisplay.resolve(draft: whisperLanguage, applied: ultra, state: ready, availability: .downloaded)
        #expect(instant == EngineApplyDisplay(title: "Changes not applied", detail: "Takes effect immediately.", applyTitle: "Apply"))
    }
}

@Suite("Update status")
struct UpdateStatusTests {
    private func status(
        enabled: Bool = true, checking: Bool = false, downloading: Bool = false,
        available: Bool = false, latest: String? = nil, lastCheck: Date? = nil
    ) -> UpdateStatus {
        UpdateStatus(
            isEnabled: enabled, isChecking: checking, isDownloading: downloading, downloadProgress: 0.5,
            updateAvailable: available, latestVersion: latest, lastCheckDate: lastCheck, error: nil,
            appName: "NanoWhisper", currentVersion: "0.0.6"
        )
    }

    @Test("Disabled wins, then checking, downloading, available, up to date")
    func precedence() {
        #expect(status(enabled: false, checking: true, available: true, latest: "0.0.7").state == .disabled)
        #expect(status(checking: true, downloading: true).state == .checking)
        #expect(status(downloading: true, available: true, latest: "0.0.7").state == .downloading(version: "0.0.7", progress: 0.5))
        #expect(status(available: true, latest: "0.0.7").state == .available(version: "0.0.7"))
        #expect(status(available: true, latest: nil).state == .upToDate(lastChecked: nil))
    }

    @Test("Wording")
    func wording() {
        #expect(status(enabled: false).note == "Updates are disabled in debug builds.")
        #expect(status(available: true, latest: "0.0.7").note == "Version 0.0.7 is available.")
        #expect(status().note == "Checks for updates every hour.")
        #expect(status(lastCheck: Date()).note.hasPrefix("You’re up to date. Last checked: "))
        #expect(status().versionLine == "NanoWhisper 0.0.6")
    }
}
