import Foundation
import FluidAudio

@MainActor
class SetupManager: ObservableObject {
    @Published var isSettingUp = false
    @Published var setupProgress = ""
    @Published var setupComplete = false
    @Published var setupError: String?

    private(set) var models: AsrModels?

    var needsSetup: Bool {
        models == nil
    }

    func runSetup() {
        guard models == nil else {
            setupComplete = true
            return
        }

        isSettingUp = true
        setupProgress = "Preparing download..."
        setupError = nil

        Task {
            do {
                let loadedModels = try await AsrModels.downloadAndLoad(
                    version: .v3,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor in
                            self?.handleProgress(progress)
                        }
                    }
                )
                self.models = loadedModels
                self.setupComplete = true
                self.isSettingUp = false
                self.setupProgress = "Setup complete!"
            } catch {
                self.setupError = "Model setup failed. Please check your internet connection and try again."
                self.isSettingUp = false
            }
        }
    }

    private func handleProgress(_ progress: DownloadUtils.DownloadProgress) {
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
}
