import SwiftUI
import Combine
import ServiceManagement

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let text: String
    let date: Date

    init(text: String) {
        self.id = UUID()
        self.text = text
        self.date = Date()
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

    @Published var maxHistoryCount: Int = 15 {
        didSet {
            UserDefaults.standard.set(maxHistoryCount, forKey: Self.maxHistoryKey)
            // Trim history if new limit is lower
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

    private var cancellables = Set<AnyCancellable>()

    init() {
        hotkeyManager.onHotkeyPressed = { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }

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

        // Check accessibility on launch (prompts user)
        _ = PasteManager.checkAccessibility()

        // Begin: either setup or start engine directly
        if setupManager.needsSetup {
            setupManager.runSetup()
        } else {
            setupManager.setupComplete = true
        }
    }

    func startEngine() {
        lastError = nil
        transcriber.onReady = { [weak self] in
            Task { @MainActor in
                self?.isEngineReady = true
                self?.lastError = nil
            }
        }
        transcriber.onError = { [weak self] error in
            Task { @MainActor in
                self?.lastError = error
                self?.isEngineReady = false
            }
        }
        transcriber.start()
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
        } catch {
            lastError = "Mic error: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        sound.playStop()
        isRecording = false
        guard let audioURL = audioRecorder.stopRecording() else {
            lastError = "No audio recorded"
            return
        }

        isTranscribing = true

        Task {
            let text = await transcriber.transcribe(audioURL: audioURL)
            isTranscribing = false

            if text.isEmpty {
                lastError = "Empty transcription"
                sound.playNoResult()
                return
            }

            if historyEnabled {
                history.insert(HistoryEntry(text: text), at: 0)
                if history.count > maxHistoryCount {
                    history.removeLast()
                }
            }
            pasteManager.pasteText(text)

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
