import SwiftUI
import Combine
import ServiceManagement

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

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isEngineReady = false
    @Published var history: [HistoryEntry] = [] {
        didSet { saveHistory() }
    }
    @Published var lastError: String?

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

    private var cancellables = Set<AnyCancellable>()

    init() {
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
        history = Self.loadHistory()

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

        // Check accessibility on launch (prompts user)
        _ = PasteManager.checkAccessibility()

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
                lastError = "Engine init failed: \(error.localizedDescription)"
                isEngineReady = false
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
            lastError = "Mic error: \(error.localizedDescription)"
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

            // Clean up temp file
            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    func showHistory() {
        historyWindow.show(appState: self)
    }

    func showSettings() {
        settingsWindow.show(appState: self)
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: Self.historyFileURL)
        }
    }

    private static func loadHistory() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: historyFileURL),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data) else {
            return []
        }
        return entries
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
                lastError = "Login item error: \(error.localizedDescription)"
            }
        }
    }
}
