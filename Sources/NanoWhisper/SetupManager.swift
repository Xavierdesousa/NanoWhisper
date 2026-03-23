import Foundation
import FluidAudio
import WhisperKit

@MainActor
class SetupManager: ObservableObject {
    @Published var isSettingUp = false
    @Published var setupProgress = ""
    @Published var setupComplete = false
    @Published var setupError: String?

    private(set) var parakeetModels: AsrModels?
    private(set) var whisperKit: WhisperKit?

    var needsSetup: Bool {
        parakeetModels == nil && whisperKit == nil
    }

    func runSetup(modelType: TranscriptionModelType, whisperSettings: WhisperSettings = WhisperSettings()) {
        // If already set up for this model type, skip
        switch modelType {
        case .parakeet where parakeetModels != nil:
            setupComplete = true
            return
        case .whisper where whisperKit != nil:
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
        whisperKit = nil
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

    private func handleParakeetProgress(_ progress: DownloadUtils.DownloadProgress) {
        switch progress.phase {
        case .listing:
            setupProgress = "Preparing download..."
        case .downloading:
            let percent = Int(progress.fractionCompleted * 100)
            setupProgress = "Downloading model (\(percent)%)..."
        case .compiling:
            setupProgress = "Compiling model..."
        }
    }

    // MARK: - Whisper setup

    private func setupWhisper(settings: WhisperSettings) async throws {
        self.setupProgress = "Downloading Whisper \(settings.modelSize.displayName)..."

        let config = WhisperKitConfig(
            model: settings.modelSize.whisperKitModel,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )

        let kit = try await WhisperKit(config)

        self.whisperKit = kit
        self.setupProgress = "Whisper ready!"
    }
}
