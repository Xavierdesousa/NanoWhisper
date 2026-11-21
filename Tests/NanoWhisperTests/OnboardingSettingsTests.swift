import AVFoundation
import Foundation
import Testing
@testable import NanoWhisper

@Suite("Launch options")
struct LaunchOptionsTests {
    @Test("No arguments: nothing forced")
    func none() {
        let options = LaunchOptions(arguments: ["/Applications/NanoWhisper.app/Contents/MacOS/NanoWhisper"])
        #expect(options == LaunchOptions())
        #expect(!options.showsOnboardingAtLaunch(onboardingComplete: true))
        #expect(options.showsOnboardingAtLaunch(onboardingComplete: false))
    }

    @Test("--onboarding shows it even when completed")
    func showOnboarding() {
        let options = LaunchOptions(arguments: ["NanoWhisper", "--onboarding"])
        #expect(options.showOnboarding)
        #expect(!options.resetOnboarding)
        #expect(options.showsOnboardingAtLaunch(onboardingComplete: true))
    }

    @Test("--reset-onboarding only resets, and shows it")
    func reset() {
        let options = LaunchOptions(arguments: ["NanoWhisper", "--reset-onboarding"])
        #expect(options.resetOnboarding)
        #expect(!options.showOnboarding)
        #expect(options.showsOnboardingAtLaunch(onboardingComplete: true))
    }

    @Test("Unknown arguments, Xcode's -Key value pairs and the executable path are ignored")
    func ignoresOthers() {
        let options = LaunchOptions(arguments: [
            "--onboarding", "-NSDocumentRevisionsDebugMode", "YES", "-psn_0_12345", "--onboardingx",
        ])
        // The first element is the executable path, never an option.
        #expect(options == LaunchOptions())
        let both = LaunchOptions(arguments: ["NanoWhisper", "--reset-onboarding", "-AppleLanguages", "(en)", "--onboarding"])
        #expect(both == LaunchOptions(showOnboarding: true, resetOnboarding: true))
    }
}

@Suite("Permission status")
struct PermissionStatusTests {
    @Test("Microphone authorization maps to one action each")
    func microphone() {
        #expect(PermissionStatus.microphone(.authorized) == .granted)
        #expect(PermissionStatus.microphone(.notDetermined) == .notDetermined)
        #expect(PermissionStatus.microphone(.denied) == .denied)
        #expect(PermissionStatus.microphone(.restricted) == .denied)
    }

    @Test("Accessibility: Grant until the prompt was shown, then Open Settings")
    func accessibility() {
        #expect(PermissionStatus.accessibility(trusted: true, promptShown: false) == .granted)
        #expect(PermissionStatus.accessibility(trusted: true, promptShown: true) == .granted)
        #expect(PermissionStatus.accessibility(trusted: false, promptShown: false) == .notDetermined)
        #expect(PermissionStatus.accessibility(trusted: false, promptShown: true) == .denied)
    }

    @Test("Every permission links to its privacy pane; one action per status")
    func descriptions() {
        #expect(Permission.allCases == [.microphone, .accessibility])
        #expect(Permission.actionTitle(for: .notDetermined) == "Allow…")
        #expect(Permission.actionTitle(for: .denied) == "Open System Settings")
        #expect(Permission.actionTitle(for: .granted) == nil)
        for permission in Permission.allCases {
            #expect(permission.settingsURL.scheme == "x-apple.systempreferences")
            #expect(permission.settingsURL.absoluteString.hasSuffix(permission == .microphone
                ? "Privacy_Microphone" : "Privacy_Accessibility"))
        }
    }
}

@Suite("Model section")
struct ModelSectionLogicTests {
    private let ultra = EngineConfiguration(modelType: .parakeet, parakeetVariant: .ultra, whisperSettings: WhisperSettings())

    private var whisperSmall: EngineConfiguration {
        var config = ultra
        config.modelType = .whisper
        config.whisperSettings.modelSize = .small
        return config
    }

    @Test("Names and sizes follow the selected engine")
    func namesAndSizes() {
        #expect(ultra.modelName == "Parakeet Ultra")
        #expect(ultra.downloadSize == "~630 MB")
        #expect(whisperSmall.modelName == "Whisper Small")
        #expect(whisperSmall.downloadSize == "~490 MB")
    }

    @Test("Only engine, Parakeet version or Whisper size change the model")
    func changesModel() {
        var v3 = ultra
        v3.parakeetVariant = .v3
        #expect(v3.changesModel(from: ultra))
        #expect(whisperSmall.changesModel(from: ultra))

        var withLanguage = whisperSmall
        withLanguage.whisperSettings.language = "fr"
        withLanguage.whisperSettings.promptText = "NanoWhisper"
        #expect(!withLanguage.changesModel(from: whisperSmall))

        var largerWhisper = whisperSmall
        largerWhisper.whisperSettings.modelSize = .largev3
        #expect(largerWhisper.changesModel(from: whisperSmall))

        // A Whisper setting edited while Parakeet is in use does not reload Parakeet.
        var parakeetWithWhisperEdit = ultra
        parakeetWithWhisperEdit.whisperSettings.modelSize = .tiny
        #expect(!parakeetWithWhisperEdit.changesModel(from: ultra))
    }

    @Test("Availability: loaded or on disk is downloaded; Whisper on disk is never probed")
    func availability() {
        #expect(ModelAvailability.resolve(ultra, loadedParakeet: .ultra, loadedWhisper: nil, parakeetOnDisk: { _ in false }) == .downloaded)
        #expect(ModelAvailability.resolve(ultra, loadedParakeet: .v3, loadedWhisper: nil, parakeetOnDisk: { $0 == .ultra }) == .downloaded)
        #expect(ModelAvailability.resolve(ultra, loadedParakeet: .v3, loadedWhisper: nil, parakeetOnDisk: { _ in false }) == .notDownloaded)
        #expect(ModelAvailability.resolve(whisperSmall, loadedParakeet: nil, loadedWhisper: .small, parakeetOnDisk: { _ in true }) == .downloaded)
        #expect(ModelAvailability.resolve(whisperSmall, loadedParakeet: nil, loadedWhisper: .base, parakeetOnDisk: { _ in true }) == .unknown)
    }

    @Test("First launch waits for onboarding only when Parakeet still has to be downloaded")
    func deferredSetup() {
        #expect(ModelAvailability.shouldDeferSetupAtLaunch(isFirstLaunch: true, modelType: .parakeet, parakeetOnDisk: false))
        #expect(!ModelAvailability.shouldDeferSetupAtLaunch(isFirstLaunch: true, modelType: .parakeet, parakeetOnDisk: true))
        #expect(!ModelAvailability.shouldDeferSetupAtLaunch(isFirstLaunch: true, modelType: .whisper, parakeetOnDisk: false))
        #expect(!ModelAvailability.shouldDeferSetupAtLaunch(isFirstLaunch: false, modelType: .parakeet, parakeetOnDisk: false))
    }

    @Test("Status of the applied model")
    func status() {
        #expect(ModelStatus.resolve(EngineState(isReady: true, setupComplete: true)) == .ready)
        #expect(ModelStatus.resolve(EngineState()) == .notLoaded)
        #expect(ModelStatus.resolve(EngineState(setupComplete: true)) == .loading)
        #expect(ModelStatus.resolve(EngineState(error: "Model setup failed.")) == .failed("Model setup failed."))
        #expect(ModelStatus.resolve(EngineState(isSettingUp: true, progressText: "Preparing download...")) == .downloading(fraction: nil))
        #expect(ModelStatus.resolve(EngineState(isSettingUp: true, progressText: "Downloading model (42%)...")) == .downloading(fraction: 0.42))
        #expect(ModelStatus.resolve(EngineState(isSettingUp: true, progressText: "Downloading Whisper Small...")) == .downloading(fraction: nil))
        #expect(ModelStatus.resolve(EngineState(isSettingUp: true, progressText: "Compiling model...")) == .compiling)
        #expect(ModelStatus.downloadFraction(from: "Downloading model (100%)...") == 1)
        #expect(ModelStatus.downloadFraction(from: "Setup complete!") == nil)
    }

    @Test("Buttons say when they download, and captions give the size first")
    func actionText() {
        #expect(ModelActionText.applyTitle(availability: .notDownloaded, loadsModel: true) == "Download & Apply")
        #expect(ModelActionText.applyTitle(availability: .downloaded, loadsModel: true) == "Apply")
        #expect(ModelActionText.applyTitle(availability: .unknown, loadsModel: true) == "Apply")
        #expect(ModelActionText.applyTitle(availability: .notDownloaded, loadsModel: false) == "Apply")

        #expect(ModelActionText.applyDetail(whisperSmall, availability: .notDownloaded, loadsModel: true)
            == "Downloads Whisper Small (~490 MB).")
        #expect(ModelActionText.applyDetail(whisperSmall, availability: .unknown, loadsModel: true)
            .contains("~490 MB"))
        #expect(ModelActionText.applyDetail(whisperSmall, availability: .downloaded, loadsModel: false)
            == "Takes effect immediately.")

        #expect(ModelActionText.loadTitle(availability: .notDownloaded) == "Download")
        #expect(ModelActionText.loadTitle(availability: .downloaded) == "Load")
        #expect(ModelActionText.notLoadedDetail(ultra, availability: .notDownloaded) == "Not downloaded · ~630 MB")
    }

    @Test("Apply loads a model when it changes, or when nothing is ready and no setup runs")
    func applyLoadsModel() {
        let ready = EngineState(isReady: true, setupComplete: true)
        #expect(!ready.applyLoadsModel(changesModel: false))
        #expect(ready.applyLoadsModel(changesModel: true))
        // A download in progress is never restarted by a settings-only change.
        #expect(!EngineState(isSettingUp: true).applyLoadsModel(changesModel: false))
        // Idle: first launch before the download, failed setup, failed engine start.
        #expect(EngineState().applyLoadsModel(changesModel: false))
        #expect(EngineState(error: "failed").applyLoadsModel(changesModel: false))
        #expect(EngineState(setupComplete: true, initializationError: "failed").applyLoadsModel(changesModel: false))
    }

    @Test("First launch, deferred Parakeet download: a hidden Whisper edit says it downloads Parakeet")
    func deferredDownloadAfterWhisperEdit() {
        var draft = ultra
        draft.whisperSettings.language = "fr"   // edited while Whisper was selected, then switched back
        #expect(!draft.changesModel(from: ultra))
        let loadsModel = EngineState().applyLoadsModel(changesModel: draft.changesModel(from: ultra))
        let availability = ModelAvailability.resolve(draft, loadedParakeet: nil, loadedWhisper: nil, parakeetOnDisk: { _ in false })
        #expect(ModelActionText.applyTitle(availability: availability, loadsModel: loadsModel) == "Download & Apply")
        #expect(ModelActionText.applyDetail(draft, availability: availability, loadsModel: loadsModel)
            == "Downloads Parakeet Ultra (~630 MB).")
    }

    @Test("Failed Whisper setup, then a language change: the caption gives the download size")
    func failedWhisperThenLanguageChange() {
        var draft = whisperSmall
        draft.whisperSettings.language = "de"
        #expect(!draft.changesModel(from: whisperSmall))
        let failed = EngineState(error: "Model setup failed. Please check your internet connection and try again.")
        let loadsModel = failed.applyLoadsModel(changesModel: draft.changesModel(from: whisperSmall))
        let availability = ModelAvailability.resolve(draft, loadedParakeet: nil, loadedWhisper: nil, parakeetOnDisk: { _ in true })
        #expect(availability == .unknown)
        let detail = ModelActionText.applyDetail(draft, availability: availability, loadsModel: loadsModel)
        #expect(detail.hasPrefix("Downloads Whisper Small (~490 MB)"))
        #expect(detail != "Takes effect immediately.")
    }

    @Test("Engine start failure shows as failed (Retry), not as an endless Loading")
    func initializationFailure() {
        let message = AppState.engineStartFailedMessage
        let failedStart = EngineState(setupComplete: true, initializationError: message)
        #expect(ModelStatus.resolve(failedStart) == .failed(message))
        #expect(!ModelStatus.resolve(failedStart).isInProgress)
        #expect(!message.contains("restart"))
        // A retry clears the error: back to Loading while the engine starts again.
        #expect(ModelStatus.resolve(EngineState(setupComplete: true)) == .loading)
        // A setup error wins over an engine error; a ready engine wins over both.
        #expect(ModelStatus.resolve(EngineState(error: "setup", initializationError: "start")) == .failed("setup"))
        #expect(ModelStatus.resolve(EngineState(isReady: true, setupComplete: true, initializationError: "start")) == .ready)
    }
}

@Suite("Dictation destination")
struct DictationDestinationTests {
    @Test("A recording started from the Try-it step with the app in front is a test")
    func startAsTest() {
        #expect(DictationDestination.atStart(testBoxShowing: true, appIsActive: true) == .onboardingTest)
    }

    @Test("A recording started for another app, or outside the Try-it step, pastes")
    func startAsPaste() {
        #expect(DictationDestination.atStart(testBoxShowing: true, appIsActive: false) == .paste)
        #expect(DictationDestination.atStart(testBoxShowing: false, appIsActive: true) == .paste)
        #expect(DictationDestination.atStart(testBoxShowing: false, appIsActive: false) == .paste)
    }

    @Test("A test stays a test: shown while the box is there, dropped once onboarding moved on")
    func testOutcome() {
        #expect(DictationOutcome.resolve(destination: .onboardingTest, text: "Hello", testBoxShowing: true) == .showTestResult("Hello"))
        #expect(DictationOutcome.resolve(destination: .onboardingTest, text: "", testBoxShowing: true) == .showTestResult(""))
        // Onboarding closed, finished, skipped or went Back during transcription: never pasted or saved.
        #expect(DictationOutcome.resolve(destination: .onboardingTest, text: "Hello", testBoxShowing: false) == .discard)
    }

    @Test("A normal dictation is delivered even if the Try-it step is showing when it finishes")
    func pasteOutcome() {
        #expect(DictationOutcome.resolve(destination: .paste, text: "Hello", testBoxShowing: true) == .deliver("Hello"))
        #expect(DictationOutcome.resolve(destination: .paste, text: "Hello", testBoxShowing: false) == .deliver("Hello"))
        #expect(DictationOutcome.resolve(destination: .paste, text: "", testBoxShowing: true) == .noResult)
    }
}
