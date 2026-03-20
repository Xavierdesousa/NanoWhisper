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
    private static let keychainService = "com.moonji.nanowhisper.history"
    private static let keychainAccount = "encryption-key"
    private static let logger = Logger(subsystem: "com.moonji.nanowhisper", category: "HistoryCrypto")

    /// Retrieve or create the AES-256 key stored in the Keychain
    static func symmetricKey() -> SymmetricKey? {
        // Try to load existing key
        if let key = loadKey(service: keychainService) {
            return key
        }

        // Generate a new key
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }

        guard storeKey(keyData, service: keychainService) else { return nil }
        return newKey
    }

    private static func loadKey(service: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            return SymmetricKey(data: data)
        }
        if status != errSecItemNotFound {
            logger.error("Keychain read failed for service \(service) with status \(status)")
        }
        return nil
    }

    @discardableResult
    private static func storeKey(_ keyData: Data, service: String) -> Bool {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            logger.error("Keychain write failed for service \(service) with status \(status)")
            return false
        }
        return true
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
            historyEnabled = false
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

        // Only auto-prompt accessibility on subsequent launches
        if !isFirstLaunch {
            _ = PasteManager.checkAccessibility(prompt: false)
        }

        // Begin: either setup or start engine directly
        setupManager.runSetup()
    }

    func startEngine() {
        guard let models = setupManager.models else {
            lastError = "Models not loaded"
            return
        }

        lastError = nil

        Task {
            do {
                try await transcriber.initialize(models: models)
                isEngineReady = true
                lastError = nil
            } catch {
                lastError = "Failed to initialize the transcription engine. Please restart the app."
            }
        }
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
        do {
            sound.playStart()
            try audioRecorder.startRecording()
            isRecording = true
            recordingOverlay.show(audioLevelPublisher: audioRecorder.audioLevelSubject)
        } catch {
            lastError = "Could not access the microphone. Check System Settings > Privacy > Microphone."
        }
    }

    func stopRecording() {
        sound.playStop()
        isRecording = false
        recordingOverlay.transitionToLoading()
        guard let audioURL = audioRecorder.stopRecording() else {
            lastError = "No audio recorded"
            recordingOverlay.dismiss()
            return
        }

        isTranscribing = true

        Task {
            defer { Self.securelyDeleteFile(at: audioURL) }

            let result = await transcriber.transcribe(audioURL: audioURL)
            isTranscribing = false
            recordingOverlay.dismiss()

            if result.text.isEmpty {
                lastError = "Empty transcription"
                sound.playNoResult()
                return
            }

            if historyEnabled {
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
            // Encryption failed — do NOT write plaintext. Disable history.
            historyUnavailable = true
            historyEnabled = false
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
