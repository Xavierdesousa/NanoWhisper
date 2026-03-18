import SwiftUI
import Combine
import ServiceManagement

@MainActor
class AppState: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var isEngineReady = false
    @Published var lastTranscription = ""
    @Published var lastError: String?
    @Published var launchAtLogin = false {
        didSet { updateLaunchAtLogin() }
    }

    let audioRecorder = AudioRecorder()
    let transcriber = Transcriber()
    let hotkeyManager = HotkeyManager()
    let pasteManager = PasteManager()
    let setupManager = SetupManager()
    let settingsWindow = SettingsWindowController()

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
            try audioRecorder.startRecording()
            isRecording = true
        } catch {
            lastError = "Mic error: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
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
                return
            }

            lastTranscription = text
            pasteManager.pasteText(text)

            // Clean up temp file
            try? FileManager.default.removeItem(at: audioURL)
        }
    }

    func showSettings() {
        settingsWindow.show(appState: self)
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
