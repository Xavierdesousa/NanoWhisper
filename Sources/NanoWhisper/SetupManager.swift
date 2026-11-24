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

/// A model loaded by `SetupManager`, ready to hand to the `Transcriber`.
enum LoadedModel: Sendable {
    case parakeet(AsrModels)
    case whisper(WhisperEngine)
}

@MainActor
class SetupManager: ObservableObject {
    @Published var isSettingUp = false
    @Published var setupProgress = ""
    @Published var setupComplete = false
    @Published var setupError: String?
    /// Background download of a migration target while the previous model is in use.
    @Published private(set) var upgrade: ModelUpgrade?

    private(set) var parakeetModels: AsrModels?
    private(set) var whisperEngine: WhisperEngine?

    /// Variant held in `parakeetModels`, if any. During a switchover it is the previous
    /// variant until the selected one is loaded.
    private(set) var loadedParakeetVariant: ParakeetVariant?
    /// Size held in `whisperEngine`, if any.
    private(set) var loadedWhisperModelSize: WhisperModelSize?

    /// Called when a background upgrade has loaded the selected model (it replaced the
    /// previous one in `parakeetModels` / `whisperEngine`); the app installs it in the
    /// transcriber at a safe moment.
    var onUpgradeLoaded: (() -> Void)?

    let store: ModelStore

    /// Incremented on every new setup or reset so results and progress from a
    /// superseded download (e.g. the user switched models mid-download) are dropped.
    private var setupGeneration = 0
    private var setupTask: Task<Void, Never>?

    init(store: ModelStore = .live()) {
        self.store = store
    }

    var needsSetup: Bool {
        parakeetModels == nil && whisperEngine == nil
    }

    /// Models currently held (the previous one during a switchover, then the selected one).
    var loadedModels: [SpeechModel] {
        [loadedParakeetVariant.map(SpeechModel.parakeet), loadedWhisperModelSize.map(SpeechModel.whisper)]
            .compactMap { $0 }
    }

    /// Load the selected model.
    /// - Parameter previousModel: the model a pending migration moved this engine away from.
    ///   If it is on disk and the selected one is not, it is used while the selected one
    ///   downloads in the background (`SwitchoverPlan`).
    func runSetup(
        modelType: TranscriptionModelType,
        parakeetVariant: ParakeetVariant,
        whisperSettings: WhisperSettings = WhisperSettings(),
        previousModel: SpeechModel? = nil
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
        upgrade = nil

        let selected: SpeechModel = modelType == .parakeet
            ? .parakeet(parakeetVariant) : .whisper(whisperSettings.modelSize)
        let plan = SwitchoverPlan.resolve(selected: selected, previous: previousModel, isOnDisk: isOnDisk)

        setupTask = Task {
            do {
                try await ModelSwitchover.run(
                    plan,
                    load: { model, role in try await self.load(model, role: role, generation: generation) },
                    onReady: { loaded, model in
                        guard generation == self.setupGeneration else { return false }
                        self.hold(loaded, as: model)
                        self.setupComplete = true
                        self.isSettingUp = false
                        self.setupProgress = "Setup complete!"
                        return true
                    },
                    onUpgradeStarted: { from, to in
                        guard generation == self.setupGeneration else { return }
                        self.upgrade = ModelUpgrade(from: from, to: to, status: .downloading(fraction: nil))
                    },
                    onUpgraded: { loaded, model in
                        guard generation == self.setupGeneration else { return }
                        self.hold(loaded, as: model)
                        self.upgrade = nil
                        self.onUpgradeLoaded?()
                    },
                    onUpgradeFailed: { error in
                        guard generation == self.setupGeneration else { return }
                        Self.logger.error("Background model download failed; keeping the previous model: \(error.localizedDescription, privacy: .public)")
                        self.upgrade?.status = .deferred
                    }
                )
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
        upgrade = nil
    }

    private func hold(_ loaded: LoadedModel, as model: SpeechModel) {
        switch (loaded, model) {
        case (.parakeet(let models), .parakeet(let variant)):
            parakeetModels = models
            loadedParakeetVariant = variant
        case (.whisper(let engine), .whisper(let size)):
            whisperEngine = engine
            loadedWhisperModelSize = size
        default:
            assertionFailure("Loaded model does not match \(model)")
        }
    }

    /// Whether a model's files are complete on disk. Whisper reads ~/Documents: only reached
    /// from `SwitchoverPlan.resolve` while setting up Whisper with a pending migration.
    private func isOnDisk(_ model: SpeechModel) -> Bool {
        switch model {
        case .parakeet(let variant): return ModelAvailability.parakeetIsOnDisk(variant)
        case .whisper(let size): return store.isWhisperModelOnDisk(size)
        }
    }

    private func load(_ model: SpeechModel, role: ModelLoadRole, generation: Int) async throws -> LoadedModel {
        switch model {
        case .parakeet(let variant):
            return .parakeet(try await loadParakeet(variant, role: role, generation: generation))
        case .whisper(let size):
            if role == .selected {
                setupProgress = "Compiling model..."
            }
            // The previous model is loaded from its folder only: never download it again.
            return .whisper(try await WhisperEngine(size, localOnly: role == .previous) { [weak self] phase in
                guard role == .selected else { return }
                Task { @MainActor in
                    guard let self, generation == self.setupGeneration else { return }
                    switch phase {
                    case .downloading: self.setupProgress = "Downloading Whisper \(size.displayName)..."
                    case .loading: self.setupProgress = "Compiling model..."
                    }
                }
            })
        }
    }

    // MARK: - Parakeet setup

    nonisolated private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "SetupManager")

    /// Folder FluidAudio <= 0.12 used for Parakeet v3. FluidAudio 0.18 looks for the same
    /// files in `parakeet-tdt-0.6b-v3` instead, so without this an update would re-download v3.
    nonisolated static let legacyParakeetV3FolderName = ModelFolder.parakeetV3Legacy.name

    /// Result of `migrateLegacyParakeetV3Cache(currentDirectory:)`.
    enum LegacyCacheMigration: Equatable {
        /// No legacy folder: nothing to do.
        case notNeeded
        /// The legacy folder was moved to the current location.
        case moved
        /// The current location held an incomplete download; it was replaced by the legacy folder.
        case replacedIncomplete
        /// The current location already held a complete cache; the legacy folder was deleted.
        case removedDuplicate
        /// The move failed; leftovers were cleaned up best effort and v3 downloads normally.
        case failed
        /// Another process kept the models lock: nothing was touched, v3 downloads normally if
        /// it is missing.
        case lockBusy
    }

    /// Move a Parakeet v3 cache downloaded by FluidAudio <= 0.12 to the folder FluidAudio 0.18
    /// uses, so the update does not re-download ~480 MB and nothing is left at the old path.
    ///
    /// - Current folder missing: the legacy folder is moved in.
    /// - Current folder complete (`AsrModels.modelsExist(at:version:)`, the load-ready check
    ///   FluidAudio's own `download` uses: every required `.mlmodelc` has `coremldata.bin` and
    ///   no `*.partial` file, and the vocabulary is present): the legacy folder is deleted.
    /// - Current folder incomplete (e.g. an interrupted download): it is removed and the legacy
    ///   folder is moved in, rather than throwing away the complete legacy weights.
    ///
    /// The download then only fetches the files that changed (the ~12 MB JointDecisionv3 model).
    /// Never throws: on any failure the app falls back to a normal download. A failed move
    /// never leaves a partial folder at the current location; the legacy folder is removed
    /// too, best effort. Runs off the main actor.
    /// Production and debug builds share this cache and can launch together, so the whole
    /// check-and-move holds the models lock (`ModelStore.withExclusiveLock`, which also keeps
    /// two setups of this process apart): otherwise the process that loses the rename would
    /// delete the winner's moved folder in its failure path. If the lock file cannot be opened,
    /// it migrates unlocked; if the lock stays taken, it does not migrate.
    @discardableResult
    nonisolated static func migrateLegacyParakeetV3Cache(
        currentDirectory: URL = AsrModels.defaultCacheDirectory(for: .v3),
        lockTimeout: Duration = ModelStore.lockTimeout
    ) async -> LegacyCacheMigration {
        do {
            return try await ModelStore.withExclusiveLock(
                in: currentDirectory.deletingLastPathComponent(), timeout: lockTimeout
            ) {
                migrateLegacyParakeetV3CacheLocked(currentDirectory: currentDirectory)
            }
        } catch {
            logger.error("Legacy Parakeet v3 cache not migrated: \(String(describing: error), privacy: .public)")
            return .lockBusy
        }
    }

    nonisolated private static func migrateLegacyParakeetV3CacheLocked(currentDirectory: URL) -> LegacyCacheMigration {
        let fm = FileManager.default
        let legacyDirectory = currentDirectory.deletingLastPathComponent()
            .appendingPathComponent(legacyParakeetV3FolderName, isDirectory: true)
        guard legacyDirectory.standardizedFileURL != currentDirectory.standardizedFileURL,
              fm.fileExists(atPath: legacyDirectory.path) else { return .notNeeded }

        var replacingIncomplete = false
        if fm.fileExists(atPath: currentDirectory.path) {
            if AsrModels.modelsExist(at: currentDirectory, version: .v3) {
                do {
                    try fm.removeItem(at: legacyDirectory)
                    logger.info("Removed legacy Parakeet v3 cache (already migrated)")
                } catch {
                    logger.error("Could not remove legacy Parakeet v3 cache: \(error.localizedDescription, privacy: .public)")
                }
                return .removedDuplicate
            }
            replacingIncomplete = true
            logger.info("Current Parakeet v3 cache is incomplete; replacing it with the legacy cache")
        }

        do {
            if replacingIncomplete {
                try fm.removeItem(at: currentDirectory)
            }
            try fm.createDirectory(
                at: currentDirectory.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            // Same parent directory, so this is an atomic rename.
            try fm.moveItem(at: legacyDirectory, to: currentDirectory)
            logger.info("Moved legacy Parakeet v3 cache to \(currentDirectory.path, privacy: .public)")
            return replacingIncomplete ? .replacedIncomplete : .moved
        } catch {
            logger.error("Could not move legacy Parakeet v3 cache: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: currentDirectory)
            try? fm.removeItem(at: legacyDirectory)
            return .failed
        }
    }

    private func loadParakeet(_ variant: ParakeetVariant, role: ModelLoadRole, generation: Int) async throws -> AsrModels {
        // The legacy folder only matters to v3. For Ultra it is an obsolete folder that the
        // automatic cleanup removes (moving it would only create a v3 copy nobody selected).
        if variant == .v3 {
            await Self.migrateLegacyParakeetV3Cache()
        }
        return try await ParakeetModelFiles.load(variant) { [weak self] progress in
            Task { @MainActor in
                guard let self, generation == self.setupGeneration else { return }
                self.handleParakeetProgress(progress, role: role)
            }
        }
    }

    private func handleParakeetProgress(_ progress: DownloadProgress, role: ModelLoadRole) {
        if role == .upgrade {
            guard upgrade != nil else { return }
            switch progress.phase {
            case .downloading: upgrade?.status = .downloading(fraction: progress.fractionCompleted)
            case .listing, .compiling: upgrade?.status = .downloading(fraction: nil)
            }
            return
        }
        switch progress.phase {
        case .listing:
            setupProgress = "Preparing download..."
        case .downloading:
            setupProgress = "Downloading model (\(Int(progress.fractionCompleted * 100))%)..."
        case .compiling:
            setupProgress = "Compiling model..."
        }
    }
}
