import SwiftUI
import Combine
import ServiceManagement
import os

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isEngineReady = false
    @Published var lastError: String?

    /// Encrypted history, loaded at launch (see `HistoryStore`).
    let historyStore = HistoryStore()
    /// Newest first. Setting it (the History window's delete and clear) saves it.
    var history: [HistoryEntry] {
        get { historyStore.entries }
        set { historyStore.replaceEntries(newValue) }
    }
    /// The history file could not be decrypted (or encrypted): history is off until relaunch.
    var historyUnavailable: Bool { historyStore.isUnavailable }

    private static let historyEnabledKey = "historyEnabled"
    private static let maxHistoryKey = "maxHistoryCount"

    @Published var launchAtLogin = false {
        didSet { updateLaunchAtLogin() }
    }

    @Published var soundEnabled: Bool = true {
        didSet { sound.isEnabled = soundEnabled }
    }

    @Published var historyEnabled: Bool = true {
        didSet { UserDefaults.standard.set(historyEnabled, forKey: Self.historyEnabledKey) }
    }

    @Published var debugMode: Bool = false {
        didSet { UserDefaults.standard.set(debugMode, forKey: "debugMode") }
    }

    @Published var pauseMediaEnabled: Bool = false {
        didSet { UserDefaults.standard.set(pauseMediaEnabled, forKey: "pauseMediaEnabled") }
    }

    /// Show the text in the overlay while recording (see AppState+LiveTranscription.swift).
    @Published var liveTranscriptionEnabled: Bool = false {
        didSet { UserDefaults.standard.set(liveTranscriptionEnabled, forKey: Self.liveTranscriptionKey) }
    }

    /// Live transcription of the recording in progress, if any.
    var liveSession: LiveTranscriptionSession?

    private static let selectedModelKey = "selectedModelType"
    private static let whisperSettingsKey = WhisperSettings.defaultsKey

    @Published var selectedModelType: TranscriptionModelType = .parakeet {
        didSet {
            UserDefaults.standard.set(selectedModelType.rawValue, forKey: Self.selectedModelKey)
        }
    }

    /// Parakeet weights to use. Resolved at launch by `ParakeetVariant.loadOrMigrate(from:)`.
    @Published var parakeetVariant: ParakeetVariant = ParakeetVariant.newInstallDefault {
        didSet {
            UserDefaults.standard.set(parakeetVariant.rawValue, forKey: ParakeetVariant.defaultsKey)
        }
    }

    @Published var whisperSettings: WhisperSettings = WhisperSettings() {
        didSet {
            if let data = try? JSONEncoder().encode(whisperSettings) {
                UserDefaults.standard.set(data, forKey: Self.whisperSettingsKey)
            }
            // Update transcriber settings live
            transcriber.updateWhisperSettings(whisperSettings)
        }
    }

    @Published var maxHistoryCount: Int = 15 {
        didSet {
            UserDefaults.standard.set(maxHistoryCount, forKey: Self.maxHistoryKey)
            historyStore.trim(to: maxHistoryCount)
        }
    }

    let audioRecorder = AudioRecorder()
    let transcriber = Transcriber()
    let hotkeyManager = HotkeyManager()
    let pasteManager = PasteManager()
    let setupManager = SetupManager()
    let settingsWindow = SettingsWindowController()
    let historyWindow = HistoryWindowController()
    let sound = SoundManager()
    let recordingOverlay = RecordingOverlayController()
    let onboardingWindow = OnboardingWindowController()
    let autoUpdater = AutoUpdater.shared
    let mediaController = MediaController(
        playback: NowPlayingPlaybackController(source: MediaRemoteJXA())
    )
    /// Media session of the recording in progress; handed to its transcription when it stops.
    private var recordingMediaSession: MediaController.Session?

    static let onboardingCompleteKey = "onboardingComplete"
    var isFirstLaunch: Bool { !UserDefaults.standard.bool(forKey: Self.onboardingCompleteKey) }
    /// Whether the onboarding window is open (first launch, replay or `--onboarding`).
    @Published private(set) var isOnboardingVisible = false

    /// The record shortcut, mirrored from `hotkeyManager` so views update when it changes.
    @Published private(set) var shortcut: Shortcut = .default

    /// True while onboarding's last step (with its Try-it box) is showing. A recording
    /// started then, with the app active, is a test (see `DictationDestination`).
    @Published var capturesTestTranscription = false {
        didSet { if !capturesTestTranscription { testTranscription = nil } }
    }
    /// Text of the last test dictation; empty when nothing was recognized.
    @Published private(set) var testTranscription: String?
    /// Destination of the recording in progress, decided when it started.
    private var recordingDestination: DictationDestination = .paste

    /// The model is loaded but the transcription engine failed to start. Cleared when a
    /// new start (Retry, model switch) begins.
    @Published private(set) var engineError: String?

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Clean up any orphaned audio files from previous crashes
        TemporaryRecordings.removeOrphans()

        recordingOverlay.onStop = { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }

        shortcut = hotkeyManager.currentShortcut
        hotkeyManager.onHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }

        // Forward setupManager changes so SwiftUI re-renders menu bar
        setupManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Forward history changes (entries, unavailable) so the menu and History window update
        historyStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Forward autoUpdater changes so SwiftUI re-renders menu bar
        autoUpdater.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        // Watch for setup completion → start engine
        setupManager.$setupComplete
            .receive(on: DispatchQueue.main)
            .sink { [weak self] complete in
                if complete {
                    self?.startEngine()
                }
            }
            .store(in: &cancellables)

        // Check launch at login state
        if #available(macOS 13.0, *) {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }

        // Sync settings
        soundEnabled = sound.isEnabled
        if UserDefaults.standard.object(forKey: Self.historyEnabledKey) == nil {
            historyEnabled = true
        } else {
            historyEnabled = UserDefaults.standard.bool(forKey: Self.historyEnabledKey)
        }
        let storedMax = UserDefaults.standard.integer(forKey: Self.maxHistoryKey)
        maxHistoryCount = storedMax > 0 ? storedMax : 15
        debugMode = UserDefaults.standard.bool(forKey: "debugMode")
        if UserDefaults.standard.object(forKey: "pauseMediaEnabled") == nil {
            pauseMediaEnabled = false
        } else {
            pauseMediaEnabled = UserDefaults.standard.bool(forKey: "pauseMediaEnabled")
        }
        liveTranscriptionEnabled = UserDefaults.standard.bool(forKey: Self.liveTranscriptionKey)
        observeTerminationForLiveTranscription()

        // Only auto-prompt accessibility on subsequent launches
        if !isFirstLaunch {
            _ = PasteManager.checkAccessibility(prompt: false)
        }

        // Load persisted model selection
        if let raw = UserDefaults.standard.string(forKey: Self.selectedModelKey),
           let model = TranscriptionModelType(rawValue: raw) {
            selectedModelType = model
        }
        // Also rewrites settings that still name a removed model size (e.g. Medium).
        if let settings = WhisperSettings.loadOrMigrate(from: .standard) {
            whisperSettings = settings
        }
        // Existing installs keep Parakeet v3 (already on disk); new installs get Ultra.
        parakeetVariant = ParakeetVariant.loadOrMigrate(from: .standard)

        // Begin: either setup or start engine directly. On first launch a model that is not
        // on disk yet waits for onboarding, where the user sees its size before downloading.
        let deferSetup = ModelAvailability.shouldDeferSetupAtLaunch(
            isFirstLaunch: isFirstLaunch,
            modelType: selectedModelType,
            parakeetOnDisk: ModelAvailability.parakeetIsOnDisk(parakeetVariant)
        )
        if !deferSetup {
            setupManager.runSetup(
                modelType: selectedModelType,
                parakeetVariant: parakeetVariant,
                whisperSettings: whisperSettings
            )
        }

        // Start auto-update checks (every hour; a no-op in debug builds)
        autoUpdater.startPeriodicChecks()
    }

    nonisolated static let engineStartFailedMessage = "The transcription engine could not start. Click Retry to try again."

    func startEngine() {
        lastError = nil
        engineError = nil

        switch selectedModelType {
        case .parakeet:
            guard let models = setupManager.parakeetModels,
                  let variant = setupManager.loadedParakeetVariant else {
                engineError = Self.engineStartFailedMessage
                return
            }
            Task {
                do {
                    // The transcriber discards this engine (returns false) if a newer
                    // initialization or a model switch happened while it was loading.
                    let installed = try await transcriber.initializeParakeet(models: models)
                    guard installed,
                          selectedModelType == .parakeet,
                          setupManager.loadedParakeetVariant == variant else { return }
                    isEngineReady = true
                } catch {
                    // Ignore a failure of a start that a model switch already replaced.
                    guard selectedModelType == .parakeet,
                          setupManager.loadedParakeetVariant == variant,
                          !isEngineReady else { return }
                    engineError = Self.engineStartFailedMessage
                }
            }
        case .whisper:
            guard let engine = setupManager.whisperEngine else {
                engineError = Self.engineStartFailedMessage
                return
            }
            transcriber.initializeWhisper(engine: engine, settings: whisperSettings)
            isEngineReady = true
        }
    }

    /// Switch model type and/or Parakeet variant, downloading and reloading as needed.
    /// Uses the current `parakeetVariant` and `whisperSettings` unless a variant is given.
    /// Also the Retry action: with the model still in memory it only restarts the engine.
    func switchModel(to modelType: TranscriptionModelType, parakeetVariant variant: ParakeetVariant? = nil) {
        // A recording in progress keeps going; its live text stops (it holds the old models).
        cancelLiveTranscription()
        isEngineReady = false
        engineError = nil
        transcriber.invalidatePendingInitialization()
        selectedModelType = modelType
        if let variant {
            parakeetVariant = variant
        }
        let alreadyLoaded: Bool
        switch modelType {
        case .parakeet:
            alreadyLoaded = setupManager.parakeetModels != nil
                && setupManager.loadedParakeetVariant == parakeetVariant
        case .whisper:
            alreadyLoaded = setupManager.whisperEngine != nil
                && setupManager.loadedWhisperModelSize == whisperSettings.modelSize
        }
        // Release the previous model before loading another one; a model that is
        // already loaded is simply re-attached to the transcriber.
        if !alreadyLoaded {
            setupManager.resetForModelSwitch()
        }
        setupManager.runSetup(
            modelType: modelType,
            parakeetVariant: parakeetVariant,
            whisperSettings: whisperSettings
        )
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            guard isEngineReady else {
                lastError = "Model not loaded yet"
                return
            }
            startRecording()
        }
    }

    func startRecording() {
        lastError = nil

        // The session spans this recording and its transcription. Media detection runs in
        // the background, so the mic starts right away.
        let mediaSession = mediaController.beginSession(pauseMedia: pauseMediaEnabled)
        sound.playStart()
        let live = beginLiveTranscription() // nil unless enabled
        do {
            try audioRecorder.startRecording(onSamples: live?.sampleSink)
            recordingMediaSession = mediaSession
            recordingDestination = DictationDestination.atStart(
                testBoxShowing: capturesTestTranscription, appIsActive: NSApp.isActive
            )
            isRecording = true
            recordingOverlay.show(audioLevelPublisher: audioRecorder.audioLevelSubject, transcriptID: live?.id)
        } catch {
            cancelLiveTranscription()
            mediaController.endSession(mediaSession)
            lastError = "Could not access the microphone. Check System Settings > Privacy > Microphone."
        }
    }

    func stopRecording() {
        sound.playStop()
        isRecording = false
        let mediaSession = recordingMediaSession
        recordingMediaSession = nil
        // Abandon the live preview's decode in flight; its text stays until the final text.
        let live = liveSession
        liveSession = nil
        live?.stop()
        recordingOverlay.transitionToLoading()
        guard let audioURL = audioRecorder.stopRecording() else {
            if let mediaSession { mediaController.endSession(mediaSession) }
            lastError = "No audio recorded"
            recordingOverlay.dismiss()
            return
        }

        isTranscribing = true
        let destination = recordingDestination
        recordingDestination = .paste

        Task {
            defer {
                TemporaryRecordings.securelyDelete(at: audioURL)
                // Resumes media only if no other recording session is open by now.
                if let mediaSession { mediaController.endSession(mediaSession) }
            }

            let result = await transcriber.transcribe(audioURL: audioURL)
            // The overlay shows exactly the text delivered (pasted, or the Try-it box's).
            showFinalLiveText(result.text, for: live)
            isTranscribing = false
            recordingOverlay.dismiss()

            switch DictationOutcome.resolve(
                destination: destination, text: result.text, failure: result.failure,
                testBoxShowing: capturesTestTranscription
            ) {
            case .showTestResult(let text):
                testTranscription = text
                return
            case .discard:
                return
            case .noResult:
                lastError = "Empty transcription"
                sound.playNoResult()
                return
            case .failed(let failure):
                if destination == .onboardingTest { testTranscription = nil } // no stale result
                lastError = failure.message
                sound.playNoResult()
                return
            case .deliver:
                break
            }

            if historyEnabled && !historyUnavailable {
                historyStore.add(
                    HistoryEntry(text: result.text, debugInfo: result.debugInfo),
                    keepingAtMost: maxHistoryCount
                )
            }
            pasteManager.pasteText(result.text)
        }
    }

    func showHistory() {
        historyWindow.show(appState: self)
    }

    func showSettings() {
        settingsWindow.show(appState: self)
    }

    func updateShortcut(_ newShortcut: Shortcut) {
        hotkeyManager.updateShortcut(newShortcut)
        shortcut = hotkeyManager.currentShortcut
    }

    // MARK: - Onboarding

    /// Open onboarding (first launch, "Show Onboarding Again…" or `--onboarding`). Settings
    /// are kept as they are; nothing downloads unless the user applies another model.
    /// The app shows in the Dock while onboarding is open and returns to menu-bar-only after.
    func showOnboarding() {
        settingsWindow.close()
        NSApp.setActivationPolicy(.regular)
        isOnboardingVisible = true
        onboardingWindow.show(
            appState: self,
            onFinish: { [weak self] in self?.completeOnboarding() },
            onClose: { [weak self] in self?.onboardingWindowDidClose() }
        )
    }

    /// Finish or Skip Setup: remember onboarding as done and make sure a model loads.
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompleteKey)
        onboardingWindow.close()
        loadSelectedModelIfIdle()
    }

    /// The window closed by any means (Finish, Skip Setup or its close button). Closing it
    /// without finishing on first launch keeps the flag unset, so it shows again next launch.
    private func onboardingWindowDidClose() {
        isOnboardingVisible = false
        capturesTestTranscription = false
        NSApp.setActivationPolicy(.accessory)
    }

    /// Start the selected model's setup if nothing is loaded, loading or failed (the first
    /// launch defers it; see `ModelAvailability.shouldDeferSetupAtLaunch`).
    func loadSelectedModelIfIdle() {
        guard !isEngineReady, !setupManager.isSettingUp, !setupManager.setupComplete,
              setupManager.setupError == nil else { return }
        setupManager.runSetup(
            modelType: selectedModelType,
            parakeetVariant: parakeetVariant,
            whisperSettings: whisperSettings
        )
    }

    private func updateLaunchAtLogin() {
        if #available(macOS 13.0, *) {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                lastError = "Could not update login item settings."
            }
        }
    }
}
