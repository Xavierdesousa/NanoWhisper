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

    /// Result of `migrateLegacyParakeetV3Cache(currentDirectory:)`.
    enum LegacyCacheMigration: Equatable {
        /// No legacy folder: nothing to do.
        case notNeeded
        /// The legacy folder was moved to the current location.
        case moved
        /// The current location already existed; the legacy folder was deleted.
        case removedDuplicate
        /// The move failed; both folders were cleaned up so FluidAudio downloads normally.
        case failed
    }

    /// Move a Parakeet v3 cache downloaded by FluidAudio <= 0.12 to the folder FluidAudio 0.18
    /// uses, so the update does not re-download ~480 MB and nothing is left at the old path.
    ///
    /// FluidAudio then only fetches the files that changed (the ~12 MB JointDecisionv3 model).
    /// Never throws: on any failure the app falls back to a normal download. A failed move
    /// never leaves a partial folder at the current location (which would make FluidAudio
    /// treat the cache as present); the legacy folder is removed too, best effort.
    /// Synchronous and called on the main actor, so two setups cannot race on it.
    @discardableResult
    nonisolated static func migrateLegacyParakeetV3Cache(
        currentDirectory: URL = AsrModels.defaultCacheDirectory(for: .v3)
    ) -> LegacyCacheMigration {
        let fm = FileManager.default
        let legacyDirectory = currentDirectory.deletingLastPathComponent()
            .appendingPathComponent(legacyParakeetV3FolderName, isDirectory: true)
        guard legacyDirectory.standardizedFileURL != currentDirectory.standardizedFileURL,
              fm.fileExists(atPath: legacyDirectory.path) else { return .notNeeded }

        if fm.fileExists(atPath: currentDirectory.path) {
            do {
                try fm.removeItem(at: legacyDirectory)
                logger.info("Removed legacy Parakeet v3 cache (already migrated)")
            } catch {
                logger.error("Could not remove legacy Parakeet v3 cache: \(error.localizedDescription, privacy: .public)")
            }
            return .removedDuplicate
        }

        do {
            try fm.createDirectory(
                at: currentDirectory.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Same parent directory, so this is an atomic rename.
            try fm.moveItem(at: legacyDirectory, to: currentDirectory)
            logger.info("Moved legacy Parakeet v3 cache to \(currentDirectory.path, privacy: .public)")
            return .moved
        } catch {
            logger.error("Could not move legacy Parakeet v3 cache: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: currentDirectory)
            try? fm.removeItem(at: legacyDirectory)
            return .failed
        }
    }

    private func loadParakeet(_ variant: ParakeetVariant, generation: Int) async throws -> AsrModels {
        // Run for either variant so the old folder never lingers; a moved v3 cache stays usable.
        Self.migrateLegacyParakeetV3Cache()
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
