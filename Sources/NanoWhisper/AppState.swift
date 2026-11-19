import SwiftUI
import Combine
import CryptoKit
import ServiceManagement
import os

struct TranscriptionDebugInfo: Codable {
    let audioDuration: Double?
    let transcribeDuration: Double?
    let rtf: Double?

    enum CodingKeys: String, CodingKey {
        case audioDuration = "audio_duration"
        case transcribeDuration = "transcribe_duration"
        case rtf
    }
}

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let text: String
    let date: Date
    var debugInfo: TranscriptionDebugInfo?

    init(text: String, debugInfo: TranscriptionDebugInfo? = nil) {
        self.id = UUID()
        self.text = text
        self.date = Date()
        self.debugInfo = debugInfo
    }
}

// MARK: - Encrypted history storage

private enum HistoryCrypto {
    private static let logger = Logger(subsystem: "com.moonji.nanowhisper", category: "HistoryCrypto")
    private static let salt = "com.moonji.nanowhisper.history.v1".data(using: .utf8)!

    /// Derive a stable AES-256 key from the machine's hardware UUID via HKDF.
    /// No Keychain needed — the key is deterministic and machine-bound.
    static func symmetricKey() -> SymmetricKey? {
        guard let uuid = hardwareUUID() else {
            logger.error("Could not read hardware UUID")
            return nil
        }
        let ikm = SymmetricKey(data: Data(uuid.utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, outputByteCount: 32)
    }

    /// Read the IOPlatformUUID (stable across reboots, unique per machine)
    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { return nil }
        return uuid
    }


    static func encrypt(_ data: Data) -> Data? {
        guard let key = symmetricKey() else {
            logger.error("Encryption failed — no symmetric key available")
            return nil
        }
        guard let sealedBox = try? AES.GCM.seal(data, using: key),
              let combined = sealedBox.combined else {
            logger.error("AES-GCM seal failed")
            return nil
        }
        return combined
    }

    static func decrypt(_ data: Data) -> Data? {
        guard let key = symmetricKey() else {
            logger.error("Decryption failed — no symmetric key available")
            return nil
        }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: data),
              let decrypted = try? AES.GCM.open(sealedBox, using: key) else {
            logger.error("AES-GCM open failed — data may be corrupted or key mismatch")
            return nil
        }
        return decrypted
    }
}

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isEngineReady = false
    private var historyLoaded = false
    @Published var history: [HistoryEntry] = [] {
        didSet { if historyLoaded { saveHistory() } }
    }
    @Published var lastError: String?
    @Published var historyUnavailable = false

    private static let historyEnabledKey = "historyEnabled"
    private static let maxHistoryKey = "maxHistoryCount"
    private static let historyFileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("NanoWhisper", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

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
        didSet {
            UserDefaults.standard.set(pauseMediaEnabled, forKey: "pauseMediaEnabled")
            if pauseMediaEnabled {
                if #available(macOS 14.2, *) {
                    let controller = mediaController
                    Task.detached { controller.requestAudioCaptureAccess() }
                }
            }
        }
    }

    /// Show the transcript in the overlay while recording, then paste that same text
    /// (Parakeet only; see AppState+LiveTranscription.swift).
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
            if history.count > maxHistoryCount {
                history = Array(history.prefix(maxHistoryCount))
            }
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
    let mediaController = MediaController()

    private static let onboardingCompleteKey = "onboardingComplete"
    var isFirstLaunch: Bool { !UserDefaults.standard.bool(forKey: Self.onboardingCompleteKey) }

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Clean up any orphaned audio files from previous crashes
        Self.cleanupOrphanedAudioFiles()

        recordingOverlay.onStop = { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }

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

        // Load persisted history
        let loaded = Self.loadHistory()
        history = loaded.entries
        historyLoaded = true
        if loaded.cryptoFailed {
            historyUnavailable = true
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

        // Begin: either setup or start engine directly
        setupManager.runSetup(
            modelType: selectedModelType,
            parakeetVariant: parakeetVariant,
            whisperSettings: whisperSettings
        )

        // Start auto-update checks (every hour)
        autoUpdater.startPeriodicChecks()
    }

    func startEngine() {
        lastError = nil

        switch selectedModelType {
        case .parakeet:
            guard let models = setupManager.parakeetModels,
                  let variant = setupManager.loadedParakeetVariant else {
                lastError = "Models not loaded"
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
                    lastError = "Failed to initialize the transcription engine. Please restart the app."
                }
            }
        case .whisper:
            guard let engine = setupManager.whisperEngine else {
                lastError = "Whisper model not loaded"
                return
            }
            transcriber.initializeWhisper(engine: engine, settings: whisperSettings)
            isEngineReady = true
        }
    }

    /// Switch model type and/or Parakeet variant, downloading and reloading as needed.
    /// Uses the current `parakeetVariant` and `whisperSettings` unless a variant is given.
    func switchModel(to modelType: TranscriptionModelType, parakeetVariant variant: ParakeetVariant? = nil) {
        // A recording in progress keeps going; its live text stops (it holds the old models).
        cancelLiveTranscription()
        isEngineReady = false
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

        // Check audio BEFORE playing the start sound to avoid CoreAudio false positive
        if pauseMediaEnabled {
            mediaController.pauseIfPlaying()
        }
        sound.playStart()
        let live = beginLiveTranscription() // nil unless enabled and on Parakeet
        do {
            try audioRecorder.startRecording(onSamples: live?.sampleSink)
            isRecording = true
            recordingOverlay.show(audioLevelPublisher: audioRecorder.audioLevelSubject, transcriptID: live?.id)
        } catch {
            cancelLiveTranscription()
            mediaController.resumeIfPaused()
            lastError = "Could not access the microphone. Check System Settings > Privacy > Microphone."
        }
    }

    func stopRecording() {
        sound.playStop()
        isRecording = false
        let live = liveSession // finished by transcribeRecording, or cancelled below
        liveSession = nil
        recordingOverlay.transitionToLoading()
        guard let audioURL = audioRecorder.stopRecording() else {
            live?.cancel()
            lastError = "No audio recorded"
            recordingOverlay.dismiss()
            return
        }

        isTranscribing = true

        Task {
            defer {
                Self.securelyDeleteFile(at: audioURL)
                mediaController.resumeIfPaused()
            }

            // Live text when it finalized, otherwise the batch pass as before.
            let result = await transcribeRecording(at: audioURL, live: live)
            isTranscribing = false
            recordingOverlay.dismiss()

            if result.text.isEmpty {
                lastError = "Empty transcription"
                sound.playNoResult()
                return
            }

            if historyEnabled && !historyUnavailable {
                let entry = HistoryEntry(text: result.text, debugInfo: result.debugInfo)
                history.insert(entry, at: 0)
                if history.count > maxHistoryCount {
                    history.removeLast()
                }
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

    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompleteKey)
        onboardingWindow.close()
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - History persistence (encrypted)

    private func saveHistory() {
        guard let json = try? JSONEncoder().encode(history) else { return }
        if let encrypted = HistoryCrypto.encrypt(json) {
            try? encrypted.write(to: Self.historyFileURL)
        } else {
            // Encryption failed — do NOT write plaintext.
            historyUnavailable = true
        }
    }

    /// Returns `(entries, cryptoFailed)`. When the file exists but decryption fails,
    /// `cryptoFailed` is `true` so the caller can surface the issue to the user.
    private static func loadHistory() -> (entries: [HistoryEntry], cryptoFailed: Bool) {
        guard let data = try? Data(contentsOf: historyFileURL) else { return ([], false) }

        if let decrypted = HistoryCrypto.decrypt(data),
           let entries = try? JSONDecoder().decode([HistoryEntry].self, from: decrypted) {
            return (entries, false)
        }

        // Decryption failed — Keychain unavailable or key corrupted.
        // Do NOT fall back to plaintext to avoid silent data exposure.
        return ([], true)
    }

    // MARK: - Secure file operations

    /// Overwrite a file with zeros before deleting it, preventing forensic recovery
    private static func securelyDeleteFile(at url: URL) {
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            let fileSize = fileHandle.seekToEndOfFile()
            fileHandle.seek(toFileOffset: 0)
            let zeroData = Data(count: Int(fileSize))
            fileHandle.write(zeroData)
            fileHandle.closeFile()
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// Remove any orphaned nanowhisper_*.wav files left by a previous crash
    private static func cleanupOrphanedAudioFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in contents where file.lastPathComponent.hasPrefix("nanowhisper_") && file.pathExtension == "wav" {
            securelyDeleteFile(at: file)
        }
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
