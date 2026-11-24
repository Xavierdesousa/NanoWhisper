import Foundation
import FluidAudio
import os

// MARK: - Known model folders

/// A model folder NanoWhisper itself downloads or downloaded in a past version. This list is
/// the **only** thing `ModelStore` may delete: both caches are shared with other apps and
/// tools, so an unknown folder (or a parent directory) is never touched.
struct ModelFolder: Hashable, Sendable, Identifiable {
    enum Cache: String, Sendable, CaseIterable {
        /// FluidAudio: ~/Library/Application Support/FluidAudio/Models.
        case fluidAudio
        /// WhisperKit: ~/Documents/huggingface/models/argmaxinc/whisperkit-coreml. Reading it
        /// triggers the macOS Documents access prompt.
        case whisperKit
    }

    let cache: Cache
    /// Folder name, a literal. Never derived from user input.
    let name: String
    let displayName: String
    /// The app can no longer select it: removed automatically once the selected model is loaded.
    let isObsolete: Bool

    var id: String { "\(cache.rawValue)/\(name)" }

    static let parakeetUltra = ModelFolder(cache: .fluidAudio, name: "parakeet-ultra", displayName: "Parakeet Ultra", isObsolete: false)
    static let parakeetV3 = ModelFolder(cache: .fluidAudio, name: "parakeet-tdt-0.6b-v3", displayName: "Parakeet TDT 0.6B v3", isObsolete: false)
    /// Where FluidAudio <= 0.12 (NanoWhisper 0.0.4) kept v3. 0.0.5+ moves it to `parakeetV3`.
    static let parakeetV3Legacy = ModelFolder(cache: .fluidAudio, name: "parakeet-tdt-0.6b-v3-coreml", displayName: "Parakeet TDT 0.6B v3 (old copy from NanoWhisper 0.0.4)", isObsolete: true)

    static let whisperTiny = ModelFolder(cache: .whisperKit, name: "openai_whisper-tiny", displayName: "Whisper Tiny (no longer offered)", isObsolete: true)
    static let whisperBase = ModelFolder(cache: .whisperKit, name: "openai_whisper-base", displayName: "Whisper Base", isObsolete: false)
    static let whisperSmall = ModelFolder(cache: .whisperKit, name: "openai_whisper-small", displayName: "Whisper Small", isObsolete: false)
    static let whisperMedium = ModelFolder(cache: .whisperKit, name: "openai_whisper-medium", displayName: "Whisper Medium (no longer offered)", isObsolete: true)
    static let whisperLargeV3 = ModelFolder(cache: .whisperKit, name: "openai_whisper-large-v3", displayName: "Whisper Large v3 (no longer offered)", isObsolete: true)
    static let whisperLargeV3Turbo = ModelFolder(cache: .whisperKit, name: "openai_whisper-large-v3-v20240930_626MB", displayName: "Whisper Large v3 Turbo", isObsolete: false)

    /// Every folder NanoWhisper may delete. At a version bump, add newly obsolete names here
    /// (with `isObsolete: true`) rather than removing them.
    static let all: [ModelFolder] = [
        parakeetUltra, parakeetV3, parakeetV3Legacy,
        whisperTiny, whisperBase, whisperSmall, whisperMedium, whisperLargeV3, whisperLargeV3Turbo,
    ]

    static func parakeet(_ variant: ParakeetVariant) -> ModelFolder {
        switch variant {
        case .v3: return parakeetV3
        case .ultra: return parakeetUltra
        }
    }

    static func whisper(_ size: WhisperModelSize) -> ModelFolder {
        switch size {
        case .tiny: return whisperTiny
        case .base: return whisperBase
        case .small: return whisperSmall
        case .medium: return whisperMedium
        case .largev3: return whisperLargeV3
        case .largev3Turbo: return whisperLargeV3Turbo
        }
    }
}

/// A known model folder found on disk.
struct StoredModel: Equatable, Sendable, Identifiable {
    let folder: ModelFolder
    /// Allocated size on disk.
    let bytes: Int64
    var id: String { folder.id }
}

/// What removing models did.
struct ModelRemovalReport: Equatable, Sendable {
    var removed: [StoredModel] = []
    var failed: [ModelFolder] = []
    /// The Whisper cache could not be read (Documents access denied).
    var whisperAccessDenied = false
    /// Another process kept the models lock: nothing was looked at or removed.
    var lockBusy = false

    var freedBytes: Int64 { removed.reduce(0) { $0 + $1.bytes } }
}

// MARK: - Store

/// File operations on NanoWhisper's downloaded models: listing, sizes, removal, and the
/// inter-process lock. Roots are injectable so tests run in a temporary directory only.
struct ModelStore: Sendable {
    let fluidAudioDirectory: URL
    let whisperKitDirectory: URL

    init(fluidAudioDirectory: URL, whisperKitDirectory: URL) {
        self.fluidAudioDirectory = fluidAudioDirectory
        self.whisperKitDirectory = whisperKitDirectory
    }

    /// Both caches under `root`, laid out like the real ones (tests).
    init(root: URL) {
        self.init(
            fluidAudioDirectory: root.appendingPathComponent("FluidAudio/Models", isDirectory: true),
            whisperKitDirectory: root.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
        )
    }

    /// The real caches. Building the URLs reads nothing (no Documents prompt).
    static func live() -> ModelStore {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return ModelStore(
            fluidAudioDirectory: AsrModels.defaultCacheDirectory(for: .ultra).deletingLastPathComponent(),
            // WhisperKit's HubApi default download base (see transcription-engines.md).
            whisperKitDirectory: documents.appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
        )
    }

    nonisolated private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "ModelStore")

    func directory(of cache: ModelFolder.Cache) -> URL {
        switch cache {
        case .fluidAudio: return fluidAudioDirectory
        case .whisperKit: return whisperKitDirectory
        }
    }

    /// Location of a known folder; nil for anything not in `ModelFolder.all` or whose name is
    /// not a single plain path component.
    func url(of folder: ModelFolder) -> URL? {
        guard ModelFolder.all.contains(folder),
              !folder.name.isEmpty, !folder.name.contains("/"), !folder.name.hasPrefix(".") else { return nil }
        return directory(of: folder.cache).appendingPathComponent(folder.name, isDirectory: true)
    }

    // MARK: Lock

    /// Lock file shared with the legacy v3 cache migration and with every NanoWhisper process
    /// (production and debug share the caches). The name must not change: 0.0.5 uses it.
    static let lockFileName = ".parakeet-v3-migration.lock"

    /// How long to wait for the lock. Its holders rename or delete a few folders.
    static let lockTimeout: Duration = .seconds(10)

    /// The lock stayed taken for the whole timeout.
    struct LockTimeout: Error {}

    /// Run `body` holding an exclusive `flock` on `directory/lockFileName`, off the main actor.
    /// Waits (without blocking a thread) until the lock is free, at most `timeout`; then throws
    /// `LockTimeout` without running `body`. If the lock file cannot be opened (e.g. the
    /// directory does not exist, or the file is a symbolic link), `body` runs unlocked.
    static func withExclusiveLock<T: Sendable>(
        in directory: URL,
        timeout: Duration = lockTimeout,
        _ body: @Sendable () throws -> T
    ) async throws -> T {
        let lockPath = directory.appendingPathComponent(lockFileName).path
        // O_NONBLOCK: never wait on something that is not a regular file.
        let lock = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o644)
        guard lock >= 0 else { return try body() }
        defer {
            flock(lock, LOCK_UN)
            close(lock)
        }
        let deadline = ContinuousClock.now + timeout
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            // Not a lockable file: same as a lock file that cannot be opened.
            guard code == EWOULDBLOCK else { break }
            guard ContinuousClock.now < deadline else { throw LockTimeout() }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try body()
    }

    // MARK: Listing

    enum CacheScan: Equatable, Sendable {
        case scanned([StoredModel])
        /// The directory exists but cannot be read (macOS privacy: Documents access denied).
        case accessDenied
    }

    /// Known model folders present in `cache`, with their sizes. Unknown folders are ignored.
    func scan(_ cache: ModelFolder.Cache) -> CacheScan {
        let fm = FileManager.default
        let names: Set<String>
        do {
            names = Set(try fm.contentsOfDirectory(atPath: directory(of: cache).path))
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
                return .scanned([])
            }
            Self.logger.error("Could not list \(cache.rawValue, privacy: .public) models: \(error.localizedDescription, privacy: .public)")
            return .accessDenied
        }
        var found: [StoredModel] = []
        for folder in ModelFolder.all where folder.cache == cache && names.contains(folder.name) {
            guard let url = url(of: folder), isRealDirectory(url) else { continue }
            found.append(StoredModel(folder: folder, bytes: allocatedSize(of: url)))
        }
        return .scanned(found)
    }

    /// A directory, not a symbolic link to one.
    private func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return false }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    /// Allocated size of everything under `url` (symbolic links are not followed).
    func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    /// Whether a WhisperKit model folder holds the three Core ML bundles WhisperKit loads.
    /// Reads the Whisper cache: call it only when the user is on Whisper.
    func isWhisperModelOnDisk(_ size: WhisperModelSize) -> Bool {
        guard let url = url(of: .whisper(size)) else { return false }
        let fm = FileManager.default
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy {
            fm.fileExists(atPath: url.appendingPathComponent("\($0).mlmodelc").path)
        }
    }

    // MARK: Removal

    /// Remove one known folder. Refuses anything outside the allow-list or the cache root.
    func remove(_ folder: ModelFolder) throws {
        guard let url = url(of: folder),
              url.deletingLastPathComponent().standardizedFileURL.path
                == directory(of: folder.cache).standardizedFileURL.path else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: url)
    }

    /// Under the lock: list the known folders of `caches`, let `choose` pick among them, remove
    /// the chosen ones. Failures (and a lock that stays taken) are logged and reported, never
    /// thrown.
    func removeModels(
        in caches: Set<ModelFolder.Cache>,
        lockTimeout: Duration = ModelStore.lockTimeout,
        choose: @Sendable ([StoredModel]) -> Set<ModelFolder>
    ) async -> ModelRemovalReport {
        do {
            return try await Self.withExclusiveLock(in: fluidAudioDirectory, timeout: lockTimeout) {
                removeModelsLocked(in: caches, choose: choose)
            }
        } catch {
            Self.logger.error("No model removed: \(String(describing: error), privacy: .public)")
            return ModelRemovalReport(lockBusy: true)
        }
    }

    private func removeModelsLocked(
        in caches: Set<ModelFolder.Cache>,
        choose: ([StoredModel]) -> Set<ModelFolder>
    ) -> ModelRemovalReport {
        var report = ModelRemovalReport()
        var found: [StoredModel] = []
        for cache in ModelFolder.Cache.allCases where caches.contains(cache) {
            switch scan(cache) {
            case .scanned(let models): found += models
            case .accessDenied: if cache == .whisperKit { report.whisperAccessDenied = true }
            }
        }
        let chosen = choose(found)
        for stored in found where chosen.contains(stored.folder) {
            do {
                try remove(stored.folder)
                report.removed.append(stored)
                Self.logger.info("Removed model folder \(stored.folder.name, privacy: .public)")
            } catch {
                report.failed.append(stored.folder)
                Self.logger.error("Could not remove \(stored.folder.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        return report
    }

    /// Automatic cleanup: obsolete folders not in `keep`. The Whisper cache is included only
    /// when `includeWhisperCache` (the user is on Whisper), so Parakeet users never get the
    /// Documents prompt.
    func removeObsoleteModels(
        keeping keep: Set<ModelFolder>,
        includeWhisperCache: Bool,
        lockTimeout: Duration = ModelStore.lockTimeout
    ) async -> ModelRemovalReport {
        await removeModels(
            in: includeWhisperCache ? [.fluidAudio, .whisperKit] : [.fluidAudio], lockTimeout: lockTimeout
        ) { found in
            ModelCleanupPolicy.obsolete(in: found, keeping: keep)
        }
    }
}

// MARK: - Policy

enum ModelCleanupPolicy {
    /// Obsolete folders that may be removed automatically.
    static func obsolete(in found: [StoredModel], keeping keep: Set<ModelFolder>) -> Set<ModelFolder> {
        Set(found.map(\.folder).filter { $0.isObsolete && !keep.contains($0) })
    }

    /// Folders "Remove Unused Models…" removes: everything known except `keep`.
    static func unused(in found: [StoredModel], keeping keep: Set<ModelFolder>) -> Set<ModelFolder> {
        Set(found.map(\.folder).filter { !keep.contains($0) })
    }

    /// Folders this app must keep: the selected model, what is loaded, and the previous models
    /// of unfinished migrations (the fallback while the new model downloads).
    static func inUse(
        selected: SpeechModel,
        loaded: [SpeechModel],
        pending: PendingModelMoves
    ) -> Set<ModelFolder> {
        Set(([selected] + loaded + pending.previousModels).map(\.folder))
    }

    /// Folders the other NanoWhisper flavor (production vs debug, which share the caches) may
    /// be using, from its stored settings. Conservative: covers older versions of that app.
    /// - 0.0.4 stored no `parakeetVariant` and used the legacy v3 folder.
    /// - A pending migration means it may still be running on the previous model.
    /// Only its selected engine counts; if it later switches engine, it downloads what it needs.
    static func usedByOtherFlavor(_ defaults: UserDefaults?) -> Set<ModelFolder> {
        guard let defaults, ModelMigrations.isExistingInstall(defaults) else { return [] }
        let pending = PendingModelMoves.load(from: defaults)
        var folders: Set<ModelFolder> = []
        let engine = defaults.string(forKey: "selectedModelType").flatMap(TranscriptionModelType.init(rawValue:)) ?? .parakeet
        switch engine {
        case .parakeet:
            switch defaults.string(forKey: ParakeetVariant.defaultsKey) {
            case nil: folders = [.parakeetV3Legacy, .parakeetV3]
            case let raw?:
                if let variant = ParakeetVariant(rawValue: raw) {
                    folders = [.parakeet(variant)]
                } else {
                    folders = [.parakeetV3, .parakeetUltra]
                }
            }
        case .whisper:
            struct StoredSize: Decodable { let modelSize: String? }
            let raw = defaults.data(forKey: WhisperSettings.defaultsKey)
                .flatMap { try? JSONDecoder().decode(StoredSize.self, from: $0) }?.modelSize
            if let raw, let size = WhisperModelSize(rawValue: raw) {
                folders = [.whisper(size)]
            } else if raw == nil {
                folders = [.whisper(WhisperSettings().modelSize)]
            } else {
                folders = Set(ModelFolder.all.filter { $0.cache == .whisperKit })
            }
        }
        if let previous = pending.previousModel(for: engine) {
            folders.insert(previous.folder)
        }
        return folders
    }
}
