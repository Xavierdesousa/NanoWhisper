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

    /// Encrypted history, loaded at launch (see `HistoryStore`). The History window edits it
    /// through `HistoryWindowModel`.
    let historyStore = HistoryStore()
    /// The history file could not be decrypted (or encrypted): history is off until relaunch.
    var historyUnavailable: Bool { historyStore.isUnavailable }

    private static let historyEnabledKey = HistorySettings.enabledKey
    private static let maxHistoryKey = HistorySettings.maxCountKey

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

    /// On for a new install, off for an older install that never chose (`NewInstallDefaults`).
    @Published var pauseMediaEnabled: Bool = false {
        didSet { UserDefaults.standard.set(pauseMediaEnabled, forKey: NewInstallDefaults.pauseMediaKey) }
    }

    /// Show the text in the overlay while recording (see AppState+LiveTranscription.swift).
    @Published var liveTranscriptionEnabled: Bool = false {
        didSet { UserDefaults.standard.set(liveTranscriptionEnabled, forKey: Self.liveTranscriptionKey) }
    }

    /// Where the recording overlay appears (`RecorderPosition.defaultsKey`, Top Center by
    /// default). Applies from the next recording.
    @Published var recorderPosition: RecorderPosition = RecorderPosition.load(from: .standard) {
        didSet { recorderPosition.save(to: .standard) }
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

    /// Previous models of unfinished migrations (see `ModelMigrations`), persisted.
    private(set) var pendingModelMoves = PendingModelMoves() {
        didSet { pendingModelMoves.save(to: .standard) }
    }

    /// A model loaded by a background upgrade, waiting for a moment with no recording in
    /// progress to be installed in the transcriber.
    enum PendingEngine {
        case parakeet(Transcriber.PreparedParakeet)
        case whisper(WhisperEngine)
    }
    private var pendingEngine: PendingEngine?
    /// The obsolete-model cleanup waits for recordings and transcriptions in flight.
    private var obsoleteModelCleanupDeferred = false

    /// File operations on the downloaded models (shared with `setupManager`).
    var modelStore: ModelStore { setupManager.store }

    /// Parakeet weights to use. Resolved at launch by `ParakeetVariant.loadOrMigrate(from:)`
    /// and `ModelMigrations`.
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

    @Published var maxHistoryCount: Int = HistorySettings.defaultMaxCount {
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

    /// True while onboarding's Try it page is showing. A recording started then, with the app
    /// active, is a test (see `DictationDestination`).
    @Published var capturesTestTranscription = false {
        didSet { if !capturesTestTranscription { testTranscription = nil } }
    }
    /// Text of the last test dictation; empty when nothing was recognized.
    @Published private(set) var testTranscription: String?
    /// Finish Setup was clicked and the onboarding window closed: the menu bar takes over
    /// (`AppDelegate` shows the "After setup" popover under the status item).
    var onOnboardingFinished: (() -> Void)?
    /// Destination of the recording in progress, decided when it started.
    private var recordingDestination: DictationDestination = .paste

    /// The model is loaded but the transcription engine failed to start. Cleared when a
    /// new start (Retry, model switch) begins.
    @Published private(set) var engineError: String?

    private var cancellables = Set<AnyCancellable>()
    private var interruptedRecordingsTask: Task<Void, Never>?

    init() {
        // Whether the app ran before. Read before anything below writes to the defaults.
        let isExistingInstall = ModelMigrations.isExistingInstall(.standard)

        recordingOverlay.onStop = { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }

        // The input changed mid-recording and the recorder could not continue on the new one:
        // transcribe what was recorded rather than keep showing a recording that hears nothing.
        audioRecorder.onInputLost = { [weak self] in
            guard let self, self.isRecording else { return }
            self.stopRecording(keepingTail: false) // the input is gone: nothing more to hear
            self.lastError = "Recording stopped: the microphone changed"
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
        historyEnabled = HistorySettings.isEnabled(in: .standard)
        maxHistoryCount = HistorySettings.maxCount(in: .standard)
        // Once, after the update that made "off" mean "nothing kept": a file kept while
        // history was off is deleted, silently.
        if HistorySettings.runOffCleanupOnce(defaults: .standard, store: historyStore) {
            Self.logger.notice("History was off: the history file kept from before was deleted")
        }
        debugMode = UserDefaults.standard.bool(forKey: "debugMode")
        // Stored, so it does not change once this install counts as an existing one.
        pauseMediaEnabled = NewInstallDefaults.apply(isExistingInstall: isExistingInstall, to: .standard)
        liveTranscriptionEnabled = UserDefaults.standard.bool(forKey: Self.liveTranscriptionKey)
        observeTerminationForLiveTranscription()

        // Recordings left by a crash: kept if they hold audio, transcribed silently into
        // History once the engine is ready and the app idle (after the history settings above).
        recoverInterruptedRecordings()

        // Only auto-prompt accessibility on subsequent launches
        if !isFirstLaunch {
            _ = PasteManager.checkAccessibility(prompt: false)
        }

        // Load persisted model selection.
        if let raw = UserDefaults.standard.string(forKey: Self.selectedModelKey),
           let model = TranscriptionModelType(rawValue: raw) {
            selectedModelType = model
        }
        let storedWhisper = WhisperSettings.load(from: .standard)
        // What 0.0.5 resolved (existing installs on v3, new installs on Ultra)...
        let storedParakeet = ParakeetVariant.loadOrMigrate(from: .standard)
        // ...then the migration steps not applied yet, and obsolete-model replacements.
        let migration = ModelMigrations.run(
            on: .standard,
            choices: ModelChoices(parakeet: storedParakeet, whisper: (storedWhisper ?? WhisperSettings()).modelSize),
            isExistingInstall: isExistingInstall
        ) { choices in
            // Written by the property observers, before the step is recorded as applied.
            parakeetVariant = choices.parakeet
            if var settings = storedWhisper {
                // Only the size changes; language and vocabulary hint are kept.
                settings.modelSize = choices.whisper
                whisperSettings = settings
            } else if choices.whisper != whisperSettings.modelSize {
                whisperSettings.modelSize = choices.whisper
            }
        }
        for move in migration.applied {
            Self.logger.info("Model migration: \(move.from.displayName, privacy: .public) → \(move.to.displayName, privacy: .public)")
        }
        pendingModelMoves = migration.pending

        setupManager.onUpgradeLoaded = { [weak self] in self?.adoptUpgradedModel() }

        // Begin: either setup or start engine directly. On first launch a model that is not
        // on disk yet waits for onboarding, where the user sees its size before downloading.
        let previousParakeet = pendingModelMoves.parakeet
        let deferSetup = ModelAvailability.shouldDeferSetupAtLaunch(
            isFirstLaunch: isFirstLaunch,
            modelType: selectedModelType,
            parakeetOnDisk: ModelAvailability.parakeetIsOnDisk(parakeetVariant)
                || previousParakeet.map(ModelAvailability.parakeetIsOnDisk) == true
        )
        if !deferSetup {
            runSelectedModelSetup()
        }

        // Start auto-update checks (every hour; a no-op in debug builds)
        autoUpdater.startPeriodicChecks()
    }

    nonisolated static let engineStartFailedMessage = "The transcription engine could not start."

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
                    let installed = try await transcriber.initializeParakeet(models: models, variant: variant)
                    guard installed,
                          selectedModelType == .parakeet,
                          setupManager.loadedParakeetVariant == variant else { return }
                    isEngineReady = true
                    engineDidBecomeReady()
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
            transcriber.initializeWhisper(engine: engine, settings: whisperSettings, size: setupManager.loadedWhisperModelSize)
            isEngineReady = true
            engineDidBecomeReady()
        }
    }

    /// Set up the selected model, smoothly if a migration moved this engine (the previous
    /// model keeps working while the new one downloads).
    private func runSelectedModelSetup() {
        setupManager.runSetup(
            modelType: selectedModelType,
            parakeetVariant: parakeetVariant,
            whisperSettings: whisperSettings,
            previousModel: pendingModelMoves.previousModel(for: selectedModelType)
        )
    }

    /// The model selected for the engine in use.
    var selectedModel: SpeechModel {
        ModelChoices(parakeet: parakeetVariant, whisper: whisperSettings.modelSize).model(for: selectedModelType)
    }

    func clearPendingModelMove(_ engine: TranscriptionModelType) {
        pendingModelMoves.clear(engine)
    }

    /// The transcriber runs a model: finish a migration whose new model is the one in use,
    /// then remove obsolete model folders.
    private func engineDidBecomeReady() {
        if pendingModelMoves.previousModel(for: selectedModelType) != nil,
           setupManager.loadedModels.contains(selectedModel) {
            pendingModelMoves.clear(selectedModelType)
        }
        removeObsoleteModelsInBackground()
    }

    // MARK: - Background upgrade (migration switchover)

    /// A background upgrade loaded the selected model: prepare its engine while the previous
    /// one keeps working, then install it when no recording is in progress.
    private func adoptUpgradedModel() {
        switch selectedModelType {
        case .parakeet:
            guard let models = setupManager.parakeetModels,
                  setupManager.loadedParakeetVariant == parakeetVariant else { return }
            let variant = parakeetVariant
            Task {
                do {
                    let prepared = try await transcriber.prepareParakeet(models: models, variant: variant)
                    guard selectedModelType == .parakeet, parakeetVariant == variant,
                          setupManager.loadedParakeetVariant == variant else { return }
                    pendingEngine = .parakeet(prepared)
                    installPendingEngineIfIdle()
                } catch {
                    // The previous engine stays installed; the next launch tries again.
                    Self.logger.error("Could not start the upgraded engine: \(error.localizedDescription, privacy: .public)")
                }
            }
        case .whisper:
            guard let engine = setupManager.whisperEngine,
                  setupManager.loadedWhisperModelSize == whisperSettings.modelSize else { return }
            pendingEngine = .whisper(engine)
            installPendingEngineIfIdle()
        }
    }

    /// Install a pending upgraded engine unless a recording is in progress (that recording
    /// keeps the engine it started with; `stopRecording` calls this once it is submitted).
    private func installPendingEngineIfIdle() {
        guard !isRecording, !isFinishingRecording, let pending = pendingEngine else { return }
        pendingEngine = nil
        switch pending {
        case .parakeet(let prepared):
            guard transcriber.installPrepared(prepared) else { return }
        case .whisper(let engine):
            transcriber.initializeWhisper(engine: engine, settings: whisperSettings, size: setupManager.loadedWhisperModelSize)
        }
        // Also covers a previous engine whose start was overtaken by the upgrade.
        isEngineReady = true
        engineError = nil
        engineDidBecomeReady()
    }

    // MARK: - Model cleanup

    nonisolated private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "AppState")

    /// Folders this app must keep: the selected model, what is loaded, previous models of
    /// unfinished migrations.
    var modelFoldersInUse: Set<ModelFolder> {
        ModelCleanupPolicy.inUse(selected: selectedModel, loaded: setupManager.loadedModels, pending: pendingModelMoves)
    }

    /// Folders the other flavor (production or debug) may use, from its stored settings.
    /// Reads its preferences; never writes them.
    var modelFoldersOfOtherFlavor: Set<ModelFolder> {
        let other: BuildFlavor = BuildFlavor.current == .production ? .debug : .production
        return ModelCleanupPolicy.usedByOtherFlavor(UserDefaults(suiteName: other.bundleIdentifier))
    }

    /// Remove obsolete model folders, once the selected model is loaded. Off the main thread
    /// (the lock may wait for another NanoWhisper process); failures are only logged. The
    /// Whisper cache (~/Documents) is touched only when the user is on Whisper.
    private func removeObsoleteModelsInBackground() {
        guard isEngineReady else { return }
        // A recording or queued transcription may still hold the previous engine (whose model
        // may be the obsolete one): wait until they are done.
        guard !isRecording, !isFinishingRecording, transcriber.pendingTranscriptions == 0 else {
            obsoleteModelCleanupDeferred = true
            return
        }
        obsoleteModelCleanupDeferred = false
        let keep = modelFoldersInUse.union(modelFoldersOfOtherFlavor)
        let includeWhisper = selectedModelType == .whisper
        let store = modelStore
        Task.detached(priority: .utility) {
            let report = store.removeObsoleteModels(keeping: keep, includeWhisperCache: includeWhisper)
            if !report.removed.isEmpty {
                Self.logger.info("Removed \(report.removed.count) obsolete model folder(s), \(report.freedBytes) bytes")
            }
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
        pendingEngine = nil
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
        // With a pending migration this is also its retry (the Retry action).
        runSelectedModelSetup()
    }

    func toggleRecording() {
        // The few hundred ms after a stop, while the last words are still being captured: a
        // press does nothing (the microphone is still in use by the recording being stopped).
        if isFinishingRecording { return }
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
        // Never while the previous recording is still capturing its tail: it owns the microphone
        // and its delayed finish would stop the new one (every start path goes through here).
        guard !isRecording, !isFinishingRecording else { return }
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
            recordingOverlay.show(
                audioLevelPublisher: audioRecorder.audioLevelSubject, transcriptID: live?.id, position: recorderPosition
            )
        } catch {
            cancelLiveTranscription()
            mediaController.endSession(mediaSession)
            lastError = "Could not access the microphone. Check System Settings > Privacy > Microphone."
            installPendingEngineIfIdle()
        }
    }

    /// Audio still recorded after the user stops, so a last word spoken while pressing the
    /// shortcut is not cut off (2026-11-20: users tend to stop a little early).
    static let recordingTail: Duration = .milliseconds(300)
    /// True between a stop and the moment the microphone actually stops (`recordingTail`).
    private(set) var isFinishingRecording = false

    /// Stop the dictation: the overlay switches to transcribing at once, the microphone keeps
    /// recording for `recordingTail` (unless `keepingTail` is false), then the recording is
    /// closed and transcribed.
    func stopRecording(keepingTail: Bool = true) {
        guard isRecording else { return }
        isRecording = false
        isFinishingRecording = true
        // Abandon the live preview's decode in flight; its text stays until the final text.
        let live = liveSession
        liveSession = nil
        live?.stop()
        recordingOverlay.transitionToLoading()
        // Captured at the stop, not after the tail: the recording keeps the destination and the
        // engine it had when the user stopped, even if the settings change during the tail.
        let destination = recordingDestination
        recordingDestination = .paste
        let configuration = transcriber.currentConfiguration
        guard keepingTail else {
            finishStoppingRecording(live: live, destination: destination, configuration: configuration)
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.recordingTail)
            self?.finishStoppingRecording(live: live, destination: destination, configuration: configuration)
        }
    }

    private func finishStoppingRecording(
        live: LiveTranscriptionSession?,
        destination: DictationDestination,
        configuration: Transcriber.Configuration
    ) {
        isFinishingRecording = false
        // After the tail, so the stop sound is not recorded into it.
        sound.playStop()
        // After the engine for this recording is captured below: an upgraded engine that
        // arrived during the recording is installed for the next one.
        defer { installPendingEngineIfIdle() }
        let mediaSession = recordingMediaSession
        recordingMediaSession = nil
        guard let audioURL = audioRecorder.stopRecording() else {
            if let mediaSession { mediaController.endSession(mediaSession) }
            lastError = "No audio recorded"
            recordingOverlay.dismiss(showing: .noAudio)
            return
        }

        isTranscribing = true

        Task {
            defer {
                TemporaryRecordings.securelyDelete(at: audioURL)
                // Resumes media only if no other recording session is open by now.
                if let mediaSession { mediaController.endSession(mediaSession) }
            }

            let result = await transcriber.transcribe(audioURL: audioURL, configuration: configuration)
            let outcome = DictationOutcome.resolve(
                destination: destination, text: result.text, failure: result.failure,
                testBoxShowing: capturesTestTranscription
            )
            // The overlay shows exactly the text delivered (pasted, or the Try-it box's).
            showFinalLiveText(result.text, for: live)
            isTranscribing = false
            recordingOverlay.dismiss(showing: OverlayResult(outcome))
            if obsoleteModelCleanupDeferred {
                removeObsoleteModelsInBackground()
            }

            switch outcome {
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

    // MARK: - Recordings interrupted by a crash

    /// At launch: this build's recordings left by a crash (see `InterruptedRecordings`) are
    /// transcribed once each, silently (no overlay, sound, paste or message), into History at
    /// their recording date. They wait until the engine is ready and nothing is recorded or
    /// transcribed, so the user's dictations go first.
    private func recoverInterruptedRecordings() {
        let historyAvailable = historyEnabled && !historyUnavailable
        let collection = InterruptedRecordings.collect(historyAvailable: historyAvailable)
        let found = collection.candidates.count + collection.deletedAttempted + collection.deletedTooShort
            + collection.deletedTooOld + collection.deletedUnreadable + collection.deletedHistoryOff
        if found > 0 {
            InterruptedRecordings.logger.notice(
                "Interrupted recordings at launch: \(collection.candidates.count, privacy: .public) to transcribe (\(collection.repairedHeaders, privacy: .public) headers repaired); deleted \(collection.deletedAttempted, privacy: .public) already attempted, \(collection.deletedTooShort, privacy: .public) too short, \(collection.deletedTooOld, privacy: .public) too old, \(collection.deletedUnreadable, privacy: .public) unreadable, \(collection.deletedHistoryOff, privacy: .public) with history off"
            )
        }
        guard !collection.candidates.isEmpty else { return }
        let recovery = InterruptedRecordingRecovery(.init(
            isIdle: { [weak self] in
                guard let self else { return false }
                return self.isEngineReady && !self.isRecording && !self.isFinishingRecording
                    && !self.isTranscribing
                    && self.transcriber.pendingTranscriptions == 0
            },
            historyAvailable: { [weak self] in
                guard let self else { return false }
                return self.historyEnabled && !self.historyUnavailable
            },
            transcribe: { [weak self] url in
                guard let self else { return .failed(.noEngine) }
                return await self.transcriber.transcribe(audioURL: url)
            },
            addToHistory: { [weak self] entry in
                guard let self else { return }
                self.historyStore.insert(entry, keepingAtMost: self.maxHistoryCount)
            }
        ))
        interruptedRecordingsTask = Task { await recovery.run(collection.candidates) }
    }

    func showHistory() {
        historyWindow.show(appState: self)
    }

    /// The "Keep a history" switch (Settings › General, onboarding's setup page). Turning it off
    /// with dictations kept first asks "Turn off history and delete it?"; on Turn Off and Delete
    /// the history is deleted (`HistoryStore.deleteAll`) and turned off, on Cancel it stays on.
    /// Nothing kept: off at once, no alert.
    func setHistoryEnabled(_ isOn: Bool) {
        HistoryTurnOff.setEnabled(
            isOn, current: historyEnabled, store: historyStore,
            apply: { [weak self] in self?.historyEnabled = $0 },
            confirm: { [weak self] count, done in
                // The switch shows on again while the alert is up (and after Cancel).
                self?.objectWillChange.send()
                HistoryAlerts.confirmTurnOff(count: count, completion: done)
            }
        )
    }

    /// Open Settings, on `pane` if given (else where it was left).
    func showSettings(pane: SettingsPane? = nil) {
        settingsWindow.show(appState: self, pane: pane)
    }

    func updateShortcut(_ newShortcut: Shortcut) {
        hotkeyManager.updateShortcut(newShortcut)
        shortcut = hotkeyManager.currentShortcut
    }

    // MARK: - Onboarding

    /// Open onboarding (first launch, "Finish Setup…", "Show Onboarding Again…" or
    /// `--onboarding`). Settings are kept as they are; the model downloads when the setup page
    /// opens, unless it is already on this Mac. The app shows in the Dock while onboarding is
    /// open and returns to menu-bar-only after.
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

    /// A page of the onboarding window appeared.
    func onboardingPageDidAppear(_ page: OnboardingPage) {
        capturesTestTranscription = page.capturesTestTranscription
        switch page {
        case .welcome:
            break
        case .setup:
            // The first launch held the download back until now (`shouldDeferSetupAtLaunch`).
            loadSelectedModelIfIdle()
            // A new install opens at login: registered now that the switch shows it, once.
            if NewInstallDefaults.takeLaunchAtLogin(from: .standard), !launchAtLogin {
                launchAtLogin = true
            }
        case .tryIt:
            loadSelectedModelIfIdle()
        }
    }

    /// Clear the last test's text (Try Again on onboarding's Try it page).
    func clearTestTranscription() {
        testTranscription = nil
    }

    /// Finish Setup: remember onboarding as done, close the window, make sure a model loads,
    /// then let the menu bar take over (`onOnboardingFinished`).
    func completeOnboarding() {
        OnboardingCompletion.finish(
            defaults: .standard,
            closeWindow: { onboardingWindow.close() },
            loadModel: { loadSelectedModelIfIdle() },
            handoff: onOnboardingFinished
        )
    }

    /// The window closed by any means (Finish Setup or its close button). Closing it without
    /// finishing on first launch keeps the flag unset, so it shows again next launch.
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
        runSelectedModelSetup()
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
