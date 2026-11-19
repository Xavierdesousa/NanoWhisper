import SwiftUI
import FluidAudio

// MARK: - Engine configuration

/// The transcription settings chosen in the Model section: engine, Parakeet version and
/// Whisper options. Settings and onboarding edit a draft of it; nothing takes effect until
/// the draft is applied (see `ModelSettingsSection`).
struct EngineConfiguration: Equatable {
    var modelType: TranscriptionModelType
    var parakeetVariant: ParakeetVariant
    var whisperSettings: WhisperSettings

    /// Name of the model this configuration runs, e.g. "Parakeet Ultra" or "Whisper Small".
    var modelName: String {
        switch modelType {
        case .parakeet: return parakeetVariant.displayName
        case .whisper: return "Whisper \(whisperSettings.modelSize.displayName)"
        }
    }

    /// Approximate download size of the model this configuration runs.
    var downloadSize: String {
        switch modelType {
        case .parakeet: return parakeetVariant.sizeDescription
        case .whisper: return whisperSettings.modelSize.sizeDescription
        }
    }

    /// Whether going from `applied` to `self` loads a different model (as opposed to only
    /// changing the Whisper language or vocabulary hint, which apply instantly).
    func changesModel(from applied: EngineConfiguration) -> Bool {
        guard modelType == applied.modelType else { return true }
        switch modelType {
        case .parakeet: return parakeetVariant != applied.parakeetVariant
        case .whisper: return whisperSettings.modelSize != applied.whisperSettings.modelSize
        }
    }
}

// MARK: - Model availability on disk

/// Whether a model's files are already on this Mac, i.e. whether applying it downloads.
enum ModelAvailability: Equatable {
    case downloaded
    case notDownloaded
    /// Not checked: WhisperKit stores models under ~/Documents, which the app does not read
    /// on its own (doing so would trigger a Documents access prompt for Parakeet users).
    case unknown

    /// Resolve the availability of the model `configuration` runs.
    /// - Parameters:
    ///   - loadedParakeet: Parakeet variant currently held in memory, if any.
    ///   - loadedWhisper: Whisper size currently held in memory, if any.
    ///   - parakeetOnDisk: whether a Parakeet variant's Core ML bundle is complete on disk.
    static func resolve(
        _ configuration: EngineConfiguration,
        loadedParakeet: ParakeetVariant?,
        loadedWhisper: WhisperModelSize?,
        parakeetOnDisk: (ParakeetVariant) -> Bool
    ) -> ModelAvailability {
        switch configuration.modelType {
        case .parakeet:
            let variant = configuration.parakeetVariant
            return loadedParakeet == variant || parakeetOnDisk(variant) ? .downloaded : .notDownloaded
        case .whisper:
            return loadedWhisper == configuration.whisperSettings.modelSize ? .downloaded : .unknown
        }
    }

    /// Whether the Core ML bundle of `variant` is complete in FluidAudio's cache
    /// (~/Library/Application Support/FluidAudio, no privacy prompt). Also accepts the folder
    /// FluidAudio <= 0.12 used for v3, which `SetupManager` migrates before loading.
    static func parakeetIsOnDisk(_ variant: ParakeetVariant) -> Bool {
        let version = variant.asrModelVersion
        let directory = AsrModels.defaultCacheDirectory(for: version)
        if AsrModels.modelsExist(at: directory, version: version) { return true }
        guard variant == .v3 else { return false }
        let legacy = directory.deletingLastPathComponent()
            .appendingPathComponent(SetupManager.legacyParakeetV3FolderName, isDirectory: true)
        return AsrModels.modelsExist(at: legacy, version: .v3)
    }

    /// First launch only: hold off the automatic model download until the user picks a model
    /// in onboarding (or finishes it). A model already on disk still loads right away, and
    /// Whisper (only reachable on a first launch after `--reset-onboarding`) always does.
    static func shouldDeferSetupAtLaunch(
        isFirstLaunch: Bool,
        modelType: TranscriptionModelType,
        parakeetOnDisk: Bool
    ) -> Bool {
        isFirstLaunch && modelType == .parakeet && !parakeetOnDisk
    }
}

// MARK: - Engine state

/// Snapshot of the applied model's setup, as published by `AppState` and `SetupManager`.
struct EngineState: Equatable {
    var isReady = false
    var isSettingUp = false
    var setupComplete = false
    var progressText = ""
    var error: String?
}

/// What the Model section shows for the applied model.
enum ModelStatus: Equatable {
    case ready
    /// `fraction` is nil when the download reports no percentage (Whisper, preparation).
    case downloading(fraction: Double?)
    case compiling
    /// Files are local; the engine is being initialized.
    case loading
    case failed(String)
    /// Nothing loaded or in progress (first launch before the user chose a model).
    case notLoaded

    static func resolve(_ state: EngineState) -> ModelStatus {
        if state.isReady { return .ready }
        if let error = state.error { return .failed(error) }
        if state.isSettingUp {
            if state.progressText.contains("Compiling") { return .compiling }
            return .downloading(fraction: downloadFraction(from: state.progressText))
        }
        return state.setupComplete ? .loading : .notLoaded
    }

    /// Parse the percentage `SetupManager` writes as "Downloading model (45%)...".
    static func downloadFraction(from progressText: String) -> Double? {
        guard let range = progressText.range(of: #"\((\d{1,3})%\)"#, options: .regularExpression),
              let percent = Int(progressText[range].filter(\.isNumber)) else { return nil }
        return Double(min(percent, 100)) / 100
    }

    var isInProgress: Bool {
        switch self {
        case .downloading, .compiling, .loading: return true
        case .ready, .failed, .notLoaded: return false
        }
    }
}

// MARK: - Apply wording

/// Wording of the Model section's buttons, so the cost of an action is always stated
/// before the click: a button that downloads says so and the caption gives the size.
enum ModelActionText {
    /// Button that applies a changed draft.
    static func applyTitle(availability: ModelAvailability, changesModel: Bool) -> String {
        changesModel && availability == .notDownloaded ? "Download & Apply" : "Apply"
    }

    /// Caption next to the apply button, for the draft `configuration`.
    static func applyDetail(
        _ configuration: EngineConfiguration, availability: ModelAvailability, changesModel: Bool
    ) -> String {
        guard changesModel else { return "Takes effect immediately." }
        switch availability {
        case .downloaded: return "\(configuration.modelName) is already on this Mac."
        case .notDownloaded: return "Downloads \(configuration.modelName) (\(configuration.downloadSize))."
        case .unknown:
            return "Downloads \(configuration.modelName) (\(configuration.downloadSize)) unless it is already on this Mac."
        }
    }

    /// Button that starts the applied model when nothing is loaded yet.
    static func loadTitle(availability: ModelAvailability) -> String {
        availability == .downloaded ? "Load" : "Download"
    }

    /// Caption of the applied model when nothing is loaded yet.
    static func notLoadedDetail(_ configuration: EngineConfiguration, availability: ModelAvailability) -> String {
        switch availability {
        case .downloaded: return "On this Mac, not loaded"
        case .notDownloaded: return "Not downloaded · \(configuration.downloadSize)"
        case .unknown: return "Download size \(configuration.downloadSize)"
        }
    }
}

// MARK: - Settings context

/// Everything the shared settings sections read from or write to the app, as plain values,
/// bindings and actions. `AppState.settingsContext(permissions:)` builds the live one; the
/// render tests build fixed ones, so every section can be drawn without a running app.
struct SettingsContext {
    // Model
    var appliedEngine: EngineConfiguration
    var engineState: EngineState
    var availability: (EngineConfiguration) -> ModelAvailability
    /// Make a configuration the applied one (downloads it if needed).
    var applyEngine: (EngineConfiguration) -> Void
    /// Download, load or retry the applied model.
    var loadAppliedModel: () -> Void

    // Permissions
    var microphone: PermissionStatus
    var accessibility: PermissionStatus
    var requestPermission: (Permission) -> Void

    // Shortcut
    var shortcut: Shortcut
    var setShortcut: (Shortcut) -> Void

    // General
    var launchAtLogin: Binding<Bool>
    var soundEnabled: Binding<Bool>
    var pauseMediaEnabled: Binding<Bool>
    var historyEnabled: Binding<Bool>
    var historyUnavailable: Bool
    var maxHistoryCount: Binding<Int>

    var modelStatus: ModelStatus { ModelStatus.resolve(engineState) }

    func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone: return microphone
        case .accessibility: return accessibility
        }
    }
}

extension AppState {
    /// The configuration currently in effect.
    var engineConfiguration: EngineConfiguration {
        EngineConfiguration(
            modelType: selectedModelType,
            parakeetVariant: parakeetVariant,
            whisperSettings: whisperSettings
        )
    }

    var engineState: EngineState {
        EngineState(
            isReady: isEngineReady,
            isSettingUp: setupManager.isSettingUp,
            setupComplete: setupManager.setupComplete,
            progressText: setupManager.setupProgress,
            error: setupManager.setupError
        )
    }

    /// Make `configuration` the applied one. Changing only the Whisper language or
    /// vocabulary hint takes effect without reloading (and never restarts a download in
    /// progress); any other change switches models.
    func applyEngine(_ configuration: EngineConfiguration) {
        let changesModel = configuration.changesModel(from: engineConfiguration)
        whisperSettings = configuration.whisperSettings
        parakeetVariant = configuration.parakeetVariant
        if changesModel || (!isEngineReady && !setupManager.isSettingUp) {
            switchModel(to: configuration.modelType, parakeetVariant: configuration.parakeetVariant)
        }
    }

    func modelAvailability(_ configuration: EngineConfiguration) -> ModelAvailability {
        ModelAvailability.resolve(
            configuration,
            loadedParakeet: setupManager.loadedParakeetVariant,
            loadedWhisper: setupManager.loadedWhisperModelSize,
            parakeetOnDisk: ModelAvailability.parakeetIsOnDisk
        )
    }

    func settingsContext(permissions: PermissionMonitor) -> SettingsContext {
        SettingsContext(
            appliedEngine: engineConfiguration,
            engineState: engineState,
            availability: { [unowned self] in modelAvailability($0) },
            applyEngine: { [unowned self] in applyEngine($0) },
            loadAppliedModel: { [unowned self] in switchModel(to: selectedModelType) },
            microphone: permissions.microphone,
            accessibility: permissions.accessibility,
            requestPermission: { [unowned permissions] in permissions.request($0) },
            shortcut: shortcut,
            setShortcut: { [unowned self] in updateShortcut($0) },
            launchAtLogin: binding(\.launchAtLogin),
            soundEnabled: binding(\.soundEnabled),
            pauseMediaEnabled: binding(\.pauseMediaEnabled),
            historyEnabled: binding(\.historyEnabled),
            historyUnavailable: historyUnavailable,
            maxHistoryCount: binding(\.maxHistoryCount)
        )
    }

    private func binding<Value>(_ keyPath: ReferenceWritableKeyPath<AppState, Value>) -> Binding<Value> {
        Binding(get: { [unowned self] in self[keyPath: keyPath] },
                set: { [unowned self] in self[keyPath: keyPath] = $0 })
    }
}
