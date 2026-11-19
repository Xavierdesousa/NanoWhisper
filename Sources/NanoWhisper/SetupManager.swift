import Foundation
import FluidAudio
import os

extension ParakeetVariant {
    /// FluidAudio model version for this variant.
    var asrModelVersion: AsrModelVersion {
        switch self {
        case .v3: return .v3
        case .ultra: return .ultra
        }
    }
}

@MainActor
class SetupManager: ObservableObject {
    @Published var isSettingUp = false
    @Published var setupProgress = ""
    @Published var setupComplete = false
    @Published var setupError: String?

    private(set) var parakeetModels: AsrModels?
    private(set) var whisperEngine: WhisperEngine?

    /// Variant held in `parakeetModels`, if any.
    private(set) var loadedParakeetVariant: ParakeetVariant?
    /// Size held in `whisperEngine`, if any.
    private(set) var loadedWhisperModelSize: WhisperModelSize?

    /// Incremented on every new setup or reset so results and progress from a
    /// superseded download (e.g. the user switched models mid-download) are dropped.
    private var setupGeneration = 0
    private var setupTask: Task<Void, Never>?

    var needsSetup: Bool {
        parakeetModels == nil && whisperEngine == nil
    }

    func runSetup(
        modelType: TranscriptionModelType,
        parakeetVariant: ParakeetVariant,
        whisperSettings: WhisperSettings = WhisperSettings()
    ) {
        // If the requested model is already loaded, skip
        switch modelType {
        case .parakeet where parakeetModels != nil && loadedParakeetVariant == parakeetVariant:
            setupComplete = true
            return
        case .whisper where whisperEngine != nil && loadedWhisperModelSize == whisperSettings.modelSize:
            setupComplete = true
            return
        default:
            break
        }

        setupTask?.cancel()
        setupGeneration += 1
        let generation = setupGeneration

        isSettingUp = true
        setupProgress = "Preparing download..."
        setupError = nil

        setupTask = Task {
            do {
                switch modelType {
                case .parakeet:
                    let models = try await loadParakeet(parakeetVariant, generation: generation)
                    guard generation == setupGeneration else { return }
                    parakeetModels = models
                    loadedParakeetVariant = parakeetVariant
                case .whisper:
                    setupProgress = "Downloading Whisper \(whisperSettings.modelSize.displayName)..."
                    let engine = try await WhisperEngine(model: whisperSettings.modelSize.whisperKitModel)
                    guard generation == setupGeneration else { return }
                    whisperEngine = engine
                    loadedWhisperModelSize = whisperSettings.modelSize
                }
                setupComplete = true
                isSettingUp = false
                setupProgress = "Setup complete!"
            } catch {
                guard generation == setupGeneration else { return }
                setupError = "Model setup failed. Please check your internet connection and try again."
                isSettingUp = false
            }
        }
    }

    /// Reset state to allow switching models
    func resetForModelSwitch() {
        setupTask?.cancel()
        setupTask = nil
        setupGeneration += 1
        parakeetModels = nil
        loadedParakeetVariant = nil
        whisperEngine = nil
        loadedWhisperModelSize = nil
        setupComplete = false
        setupError = nil
        isSettingUp = false
        setupProgress = ""
    }

    // MARK: - Parakeet setup

    nonisolated private static let logger = Logger(subsystem: "com.moonji.nanowhisper", category: "SetupManager")

    /// Folder FluidAudio <= 0.12 used for Parakeet v3. FluidAudio 0.18 looks for the same
    /// files in `parakeet-tdt-0.6b-v3` instead, so without this an update would re-download v3.
    nonisolated static let legacyParakeetV3FolderName = "parakeet-tdt-0.6b-v3-coreml"

    /// Reuse a Parakeet v3 cache downloaded by FluidAudio <= 0.12.
    ///
    /// When the current v3 folder is missing and the legacy one exists, the legacy folder is
    /// copied (APFS clones the files, so no extra disk space is used) to the current location;
    /// FluidAudio then only fetches the files that changed (the ~13 MB JointDecisionv3 model).
    /// The legacy folder is left in place because other apps may share FluidAudio's cache.
    /// - Returns: `true` when a legacy cache was adopted.
    @discardableResult
    nonisolated static func adoptLegacyParakeetV3Cache(
        currentDirectory: URL = AsrModels.defaultCacheDirectory(for: .v3)
    ) -> Bool {
        let fm = FileManager.default
        let legacyDirectory = currentDirectory.deletingLastPathComponent()
            .appendingPathComponent(legacyParakeetV3FolderName, isDirectory: true)
        guard legacyDirectory.standardizedFileURL != currentDirectory.standardizedFileURL,
              !fm.fileExists(atPath: currentDirectory.path),
              fm.fileExists(atPath: legacyDirectory.path) else { return false }
        do {
            try fm.copyItem(at: legacyDirectory, to: currentDirectory)
            logger.info("Adopted legacy Parakeet v3 cache from \(legacyDirectory.path, privacy: .public)")
            return true
        } catch {
            // Not fatal: FluidAudio downloads the model instead. Drop any partial copy.
            logger.error("Could not adopt legacy Parakeet v3 cache: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: currentDirectory)
            return false
        }
    }

    private func loadParakeet(_ variant: ParakeetVariant, generation: Int) async throws -> AsrModels {
        if variant == .v3 {
            _ = await Task.detached(priority: .userInitiated) {
                Self.adoptLegacyParakeetV3Cache()
            }.value
        }
        return try await AsrModels.downloadAndLoad(
            version: variant.asrModelVersion,
            progressHandler: { [weak self] progress in
                Task { @MainActor in
                    guard let self, generation == self.setupGeneration else { return }
                    self.handleParakeetProgress(progress)
                }
            }
        )
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
}
