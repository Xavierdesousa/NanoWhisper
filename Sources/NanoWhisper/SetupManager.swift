import Foundation
import FluidAudio

@MainActor
class SetupManager: ObservableObject {
    @Published var isSettingUp = false
    @Published var setupProgress = ""
    @Published var setupComplete = false
    @Published var setupError: String?

    private(set) var parakeetModels: AsrModels?
    private(set) var whisperEngine: WhisperEngine?

    var needsSetup: Bool {
        parakeetModels == nil && whisperEngine == nil
    }

    func runSetup(modelType: TranscriptionModelType, whisperSettings: WhisperSettings = WhisperSettings()) {
        // If already set up for this model type, skip
        switch modelType {
        case .parakeet where parakeetModels != nil:
            setupComplete = true
            return
        case .whisper where whisperEngine != nil:
            setupComplete = true
            return
        default:
            break
        }

        isSettingUp = true
        setupProgress = "Preparing download..."
        setupError = nil

        Task {
            do {
                switch modelType {
                case .parakeet:
                    try await setupParakeet()
                case .whisper:
                    try await setupWhisper(settings: whisperSettings)
                }
                self.setupComplete = true
                self.isSettingUp = false
                self.setupProgress = "Setup complete!"
            } catch {
                self.setupError = "Model setup failed. Please check your internet connection and try again."
                self.isSettingUp = false
            }
        }
    }

    /// Reset state to allow switching models
    func resetForModelSwitch() {
        parakeetModels = nil
        whisperEngine = nil
        setupComplete = false
        setupError = nil
        isSettingUp = false
        setupProgress = ""
    }

    // MARK: - Parakeet setup

    private func setupParakeet() async throws {
        let loadedModels = try await AsrModels.downloadAndLoad(
            version: .v3,
            progressHandler: { [weak self] progress in
                Task { @MainActor in
                    self?.handleParakeetProgress(progress)
                }
            }
        )
        self.parakeetModels = loadedModels
    }

    private func handleParakeetProgress(_ progress: DownloadProgress) {
        switch progress.phase {
        case .listing:
            setupProgress = "Preparing download..."
        case .downloading:
            // ModelHub reports each model component as one operation where the download
            // phase occupies the first half of `fractionCompleted` and compilation the rest.
            let percent = Int(min(progress.fractionCompleted / 0.5, 1.0) * 100)
            setupProgress = "Downloading model (\(percent)%)..."
        case .compiling:
            setupProgress = "Compiling model..."
        }
    }

    // MARK: - Whisper setup

    private func setupWhisper(settings: WhisperSettings) async throws {
        self.setupProgress = "Downloading Whisper \(settings.modelSize.displayName)..."

        let engine = try await WhisperEngine(model: settings.modelSize.whisperKitModel)

        self.whisperEngine = engine
        self.setupProgress = "Whisper ready!"
    }
}
