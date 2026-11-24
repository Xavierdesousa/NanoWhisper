import Foundation
import Testing
import FluidAudio
@testable import NanoWhisper

/// Every test runs in its own temporary directory (`ModelStore(root:)`); none touches the real
/// caches.
@Suite("Model store and cleanup")
struct ModelStoreTests {
    private let fm = FileManager.default

    private func makeStore() throws -> (ModelStore, URL) {
        let root = fm.temporaryDirectory.appendingPathComponent("NanoWhisperStoreTests-\(UUID().uuidString)", isDirectory: true)
        let store = ModelStore(root: root)
        try fm.createDirectory(at: store.fluidAudioDirectory, withIntermediateDirectories: true)
        try fm.createDirectory(at: store.whisperKitDirectory, withIntermediateDirectories: true)
        return (store, root)
    }

    /// A folder with one file of `bytes` bytes.
    @discardableResult
    private func makeFolder(_ name: String, in directory: URL, bytes: Int = 10_000) throws -> URL {
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        let bundle = folder.appendingPathComponent("Model.mlmodelc", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data(count: bytes).write(to: bundle.appendingPathComponent("weight.bin"))
        return folder
    }

    private func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    private func cleanup(_ root: URL) {
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ModelStore(root: root).whisperKitDirectory.path)
        try? fm.removeItem(at: root)
    }

    // MARK: - Allow-list

    @Test("The allow-list is explicit and matches the folders FluidAudio and WhisperKit use")
    func allowList() {
        #expect(ModelFolder.all.map(\.name) == [
            "parakeet-ultra", "parakeet-tdt-0.6b-v3", "parakeet-tdt-0.6b-v3-coreml",
            "openai_whisper-tiny", "openai_whisper-base", "openai_whisper-small", "openai_whisper-medium",
            "openai_whisper-large-v3", "openai_whisper-large-v3-v20240930_626MB",
        ])
        for variant in ParakeetVariant.allCases {
            let folder = ModelFolder.parakeet(variant)
            #expect(folder.name == AsrModels.defaultCacheDirectory(for: variant.asrModelVersion).lastPathComponent)
            #expect(!folder.isObsolete)
        }
        for size in WhisperModelSize.allCases {
            let folder = ModelFolder.whisper(size)
            #expect(folder.name == size.whisperKitModel)
            #expect(folder.isObsolete == !size.isSelectable)
        }
        #expect(ModelFolder.parakeetV3Legacy.isObsolete)
        #expect(SetupManager.legacyParakeetV3FolderName == "parakeet-tdt-0.6b-v3-coreml")
        #expect(Set(ModelFolder.all.filter(\.isObsolete).map(\.name)) == [
            "parakeet-tdt-0.6b-v3-coreml", "openai_whisper-tiny", "openai_whisper-medium", "openai_whisper-large-v3",
        ])
    }

    @Test("url(of:) refuses folders outside the allow-list")
    func urlRefusesUnknown() throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let unknown = ModelFolder(cache: .fluidAudio, name: "silero-vad-coreml", displayName: "VAD", isObsolete: true)
        let traversal = ModelFolder(cache: .fluidAudio, name: "../Models", displayName: "x", isObsolete: true)
        #expect(store.url(of: unknown) == nil)
        #expect(store.url(of: traversal) == nil)
        try makeFolder("silero-vad-coreml", in: store.fluidAudioDirectory)
        #expect(throws: (any Error).self) { try store.remove(unknown) }
        #expect(exists(store.fluidAudioDirectory.appendingPathComponent("silero-vad-coreml")))
    }

    // MARK: - Scan and sizes

    @Test("Scan lists only known folders, with allocated sizes; unknown folders and files are ignored")
    func scanKnownOnly() throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        try makeFolder("parakeet-ultra", in: store.fluidAudioDirectory, bytes: 300_000)
        try makeFolder("parakeet-tdt-0.6b-v3", in: store.fluidAudioDirectory, bytes: 100_000)
        try makeFolder("silero-vad-coreml", in: store.fluidAudioDirectory)
        try Data("x".utf8).write(to: store.fluidAudioDirectory.appendingPathComponent(ModelStore.lockFileName))

        guard case .scanned(let found) = store.scan(.fluidAudio) else { Issue.record("not scanned"); return }
        #expect(Set(found.map(\.folder)) == [.parakeetUltra, .parakeetV3])
        let ultra = try #require(found.first { $0.folder == .parakeetUltra })
        let v3 = try #require(found.first { $0.folder == .parakeetV3 })
        #expect(ultra.bytes >= 300_000)
        #expect(v3.bytes >= 100_000 && v3.bytes < ultra.bytes)
    }

    @Test("Missing cache directory scans as empty")
    func scanMissing() {
        let store = ModelStore(root: fm.temporaryDirectory.appendingPathComponent("absent-\(UUID().uuidString)"))
        #expect(store.scan(.whisperKit) == .scanned([]))
    }

    @Test("A symbolic link with a known name is not followed or listed")
    func symlinkSkipped() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let target = try makeFolder("elsewhere", in: root)
        try fm.createSymbolicLink(at: store.whisperKitDirectory.appendingPathComponent("openai_whisper-medium"),
                                  withDestinationURL: target)
        #expect(store.scan(.whisperKit) == .scanned([]))
        _ = await store.removeObsoleteModels(keeping: [], includeWhisperCache: true)
        #expect(exists(target.appendingPathComponent("Model.mlmodelc/weight.bin")))
    }

    @Test("Documents access denied: reported, nothing removed, Parakeet side still cleaned")
    func accessDenied() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        try makeFolder("openai_whisper-medium", in: store.whisperKitDirectory)
        let legacy = try makeFolder("parakeet-tdt-0.6b-v3-coreml", in: store.fluidAudioDirectory)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.whisperKitDirectory.path)

        #expect(store.scan(.whisperKit) == .accessDenied)
        let report = await store.removeObsoleteModels(keeping: [], includeWhisperCache: true)
        #expect(report.whisperAccessDenied)
        #expect(report.removed.map(\.folder) == [.parakeetV3Legacy])
        #expect(!exists(legacy))

        let preview = store.unusedModelsPreview(keepingInUse: [], otherFlavor: [], otherFlavorName: "Other")
        #expect(preview.whisperAccessDenied)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.whisperKitDirectory.path)
        #expect(exists(store.whisperKitDirectory.appendingPathComponent("openai_whisper-medium")))
    }

    @Test("Whisper on-disk check needs the three Core ML bundles")
    func whisperOnDisk() throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let folder = store.whisperKitDirectory.appendingPathComponent("openai_whisper-medium")
        for bundle in ["MelSpectrogram", "AudioEncoder"] {
            try fm.createDirectory(at: folder.appendingPathComponent("\(bundle).mlmodelc"), withIntermediateDirectories: true)
        }
        #expect(!store.isWhisperModelOnDisk(.medium))
        try fm.createDirectory(at: folder.appendingPathComponent("TextDecoder.mlmodelc"), withIntermediateDirectories: true)
        #expect(store.isWhisperModelOnDisk(.medium))
        #expect(!store.isWhisperModelOnDisk(.largev3Turbo))
    }

    // MARK: - Automatic cleanup

    @Test("Automatic cleanup removes obsolete folders only, never selectable or kept ones, never parents")
    func automaticCleanup() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let fluid = store.fluidAudioDirectory, whisper = store.whisperKitDirectory
        let legacy = try makeFolder("parakeet-tdt-0.6b-v3-coreml", in: fluid)
        let v3 = try makeFolder("parakeet-tdt-0.6b-v3", in: fluid)
        let ultra = try makeFolder("parakeet-ultra", in: fluid)
        let vad = try makeFolder("silero-vad-coreml", in: fluid)
        let medium = try makeFolder("openai_whisper-medium", in: whisper)
        let tiny = try makeFolder("openai_whisper-tiny", in: whisper)
        let large = try makeFolder("openai_whisper-large-v3", in: whisper)
        let base = try makeFolder("openai_whisper-base", in: whisper)
        let other = try makeFolder("openai_whisper-large-v2", in: whisper)

        // On Whisper Large v3 Turbo; Tiny is the other flavor's model.
        let report = await store.removeObsoleteModels(keeping: [.whisperLargeV3Turbo, .whisperTiny], includeWhisperCache: true)
        #expect(Set(report.removed.map(\.folder)) == [.parakeetV3Legacy, .whisperMedium, .whisperLargeV3])
        #expect(report.freedBytes > 0)
        for gone in [legacy, medium, large] { #expect(!exists(gone)) }
        for kept in [v3, ultra, vad, tiny, base, other, fluid, whisper] { #expect(exists(kept)) }
    }

    @Test("Parakeet users: the Whisper cache is not read at all")
    func whisperCacheUntouchedForParakeet() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let medium = try makeFolder("openai_whisper-medium", in: store.whisperKitDirectory)
        // Unreadable: any read would be reported as access denied.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.whisperKitDirectory.path)
        let report = await store.removeObsoleteModels(keeping: [.parakeetUltra], includeWhisperCache: false)
        #expect(!report.whisperAccessDenied)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.whisperKitDirectory.path)
        #expect(exists(medium))
    }

    @Test("The obsolete model of a pending replacement is kept until the replacement is loaded")
    func pendingReplacementKept() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let medium = try makeFolder("openai_whisper-medium", in: store.whisperKitDirectory)
        var pending = PendingModelMoves(parakeet: nil, whisper: .medium)
        var keep = ModelCleanupPolicy.inUse(selected: .whisper(.largev3Turbo), loaded: [.whisper(.medium)], pending: pending)
        _ = await store.removeObsoleteModels(keeping: keep, includeWhisperCache: true)
        #expect(exists(medium))

        // Turbo loaded: the move is finished.
        pending.clear(.whisper)
        keep = ModelCleanupPolicy.inUse(selected: .whisper(.largev3Turbo), loaded: [.whisper(.largev3Turbo)], pending: pending)
        _ = await store.removeObsoleteModels(keeping: keep, includeWhisperCache: true)
        #expect(!exists(medium))
    }

    @Test("Parakeet v3 is never removed automatically after the migration (still selectable)")
    func v3NotAutoRemoved() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let v3 = try makeFolder("parakeet-tdt-0.6b-v3", in: store.fluidAudioDirectory)
        let keep = ModelCleanupPolicy.inUse(selected: .parakeet(.ultra), loaded: [.parakeet(.ultra)], pending: PendingModelMoves())
        _ = await store.removeObsoleteModels(keeping: keep, includeWhisperCache: false)
        #expect(exists(v3))
    }

    @Test("Cleanup takes the shared lock: it waits while another process holds it")
    func cleanupWaitsForLock() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let legacy = try makeFolder("parakeet-tdt-0.6b-v3-coreml", in: store.fluidAudioDirectory)

        // Another process (a separate open file description) holds the migration lock.
        let lockPath = store.fluidAudioDirectory.appendingPathComponent(".parakeet-v3-migration.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        #expect(fd >= 0)
        flock(fd, LOCK_EX)

        let cleanup = Task.detached { await store.removeObsoleteModels(keeping: [], includeWhisperCache: false) }
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(exists(legacy)) // blocked on the lock

        flock(fd, LOCK_UN)
        close(fd)
        let report = await cleanup.value
        #expect(report.removed.map(\.folder) == [.parakeetV3Legacy])
        #expect(!exists(legacy))
    }

    @Test("Cleanup gives up when the lock stays taken: nothing is removed, and it says so")
    func cleanupLockTimeout() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let legacy = try makeFolder("parakeet-tdt-0.6b-v3-coreml", in: store.fluidAudioDirectory)
        let fd = open(store.fluidAudioDirectory.appendingPathComponent(ModelStore.lockFileName).path, O_CREAT | O_RDWR, 0o644)
        #expect(fd >= 0)
        flock(fd, LOCK_EX)
        defer { close(fd) }

        let report = await store.removeObsoleteModels(
            keeping: [], includeWhisperCache: true, lockTimeout: .milliseconds(150)
        )
        #expect(report == ModelRemovalReport(lockBusy: true))
        #expect(exists(legacy))
        #expect(ModelStorageText.result(report)
            == "Nothing was removed. Another copy of NanoWhisper is using the models folder. Try again later.")
    }

    @Test("Waiting for the lock leaves the main actor free")
    @MainActor
    func lockWaitOffMainActor() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let fd = open(store.fluidAudioDirectory.appendingPathComponent(ModelStore.lockFileName).path, O_CREAT | O_RDWR, 0o644)
        #expect(fd >= 0)
        flock(fd, LOCK_EX)
        defer { close(fd) }

        let directory = store.fluidAudioDirectory
        let waiting = Task { @MainActor in
            try await ModelStore.withExclusiveLock(in: directory, timeout: .seconds(30)) { pthread_main_np() != 0 }
        }
        // The main actor keeps running while the lock is awaited, and can release it.
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)) }
        flock(fd, LOCK_UN)
        #expect(try await waiting.value == false) // and the body itself runs off the main thread
    }

    @Test("The lock: exclusive, released afterwards (also on error), immediate when free")
    func lockBasics() async throws {
        struct Failure: Error {}
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let directory = store.fluidAudioDirectory
        let path = directory.appendingPathComponent(ModelStore.lockFileName).path
        let isTaken: @Sendable () -> Bool = {
            let fd = open(path, O_RDWR)
            defer { close(fd) }
            return flock(fd, LOCK_EX | LOCK_NB) != 0
        }
        // Free: a zero timeout is enough.
        #expect(try await ModelStore.withExclusiveLock(in: directory, timeout: .zero) { isTaken() })
        #expect(!isTaken())
        await #expect(throws: Failure.self) {
            try await ModelStore.withExclusiveLock(in: directory, timeout: .zero) { throw Failure() }
        }
        #expect(!isTaken())
        // Taken: not run.
        let fd = open(path, O_RDWR)
        flock(fd, LOCK_EX)
        defer { close(fd) }
        await #expect(throws: ModelStore.LockTimeout.self) {
            try await ModelStore.withExclusiveLock(in: directory, timeout: .milliseconds(120)) { Issue.record("ran") }
        }
    }

    @Test("A symbolic link in place of the lock file is not followed")
    func lockSymlink() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let target = root.appendingPathComponent("elsewhere")
        try fm.createSymbolicLink(
            at: store.fluidAudioDirectory.appendingPathComponent(ModelStore.lockFileName), withDestinationURL: target
        )
        // As with a lock file that cannot be opened: runs unlocked.
        #expect(try await ModelStore.withExclusiveLock(in: store.fluidAudioDirectory, timeout: .zero) { true })
        #expect(!exists(target))
    }

    @Test("A pipe in place of the lock file does not block")
    func lockPipe() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        #expect(mkfifo(store.fluidAudioDirectory.appendingPathComponent(ModelStore.lockFileName).path, 0o644) == 0)
        #expect(try await ModelStore.withExclusiveLock(in: store.fluidAudioDirectory, timeout: .zero) { true })
    }

    @Test("A folder that cannot be removed is reported and does not stop the others")
    func removalFailureReported() async throws {
        let (store, root) = try makeStore()
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.fluidAudioDirectory.path)
            cleanup(root)
        }
        try makeFolder("parakeet-tdt-0.6b-v3-coreml", in: store.fluidAudioDirectory)
        let medium = try makeFolder("openai_whisper-medium", in: store.whisperKitDirectory)
        // The lock file exists (as it does once any process used it), so the locked path runs.
        let lockPath = store.fluidAudioDirectory.appendingPathComponent(ModelStore.lockFileName).path
        #expect(fm.createFile(atPath: lockPath, contents: nil))
        // Read-only parent: the Parakeet removal fails.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.fluidAudioDirectory.path)
        let report = await store.removeObsoleteModels(keeping: [], includeWhisperCache: true)
        #expect(report.failed == [.parakeetV3Legacy])
        #expect(report.removed.map(\.folder) == [.whisperMedium])
        #expect(!exists(medium))
    }

    // MARK: - Remove Unused Models…

    @Test("Preview: everything known except in use and the other flavor's; sizes and total")
    func unusedPreview() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        try makeFolder("parakeet-ultra", in: store.fluidAudioDirectory, bytes: 30_000)
        try makeFolder("parakeet-tdt-0.6b-v3", in: store.fluidAudioDirectory, bytes: 20_000)
        try makeFolder("openai_whisper-base", in: store.whisperKitDirectory, bytes: 10_000)
        try makeFolder("openai_whisper-small", in: store.whisperKitDirectory, bytes: 15_000)
        try makeFolder("silero-vad-coreml", in: store.fluidAudioDirectory)

        let preview = store.unusedModelsPreview(keepingInUse: [.parakeetUltra], otherFlavor: [.whisperSmall], otherFlavorName: "NanoWhisper")
        #expect(Set(preview.removable.map(\.folder)) == [.parakeetV3, .whisperBase])
        #expect(preview.keptInUse.map(\.folder) == [.parakeetUltra])
        #expect(preview.keptForOtherFlavor.map(\.folder) == [.whisperSmall])
        #expect(preview.totalBytes == preview.removable.reduce(0) { $0 + $1.bytes })
        #expect(preview.totalBytes >= 30_000)

        let report = await store.removeUnusedModels(preview, keeping: [.parakeetUltra, .whisperSmall])
        #expect(Set(report.removed.map(\.folder)) == [.parakeetV3, .whisperBase])
        #expect(report.freedBytes == preview.totalBytes)
        guard case .scanned(let left) = store.scan(.fluidAudio) else { Issue.record("not scanned"); return }
        #expect(left.map(\.folder) == [.parakeetUltra])
        #expect(exists(store.fluidAudioDirectory.appendingPathComponent("silero-vad-coreml")))
    }

    @Test("Confirmed removal never deletes the model in use, even if it was in the preview")
    func unusedRemovalRechecksKeep() async throws {
        let (store, root) = try makeStore()
        defer { cleanup(root) }
        let ultra = try makeFolder("parakeet-ultra", in: store.fluidAudioDirectory)
        let preview = store.unusedModelsPreview(keepingInUse: [], otherFlavor: [], otherFlavorName: "x")
        #expect(preview.removable.map(\.folder) == [.parakeetUltra])
        // The user switched to Ultra before confirming.
        let report = await store.removeUnusedModels(preview, keeping: [.parakeetUltra])
        #expect(report.removed.isEmpty)
        #expect(exists(ultra))
        #expect(ModelStorageText.result(report) == "Nothing was removed.")
    }

    @Test("Result wording")
    func resultText() {
        let report = ModelRemovalReport(
            removed: [StoredModel(folder: .parakeetV3, bytes: 473_000_000), StoredModel(folder: .whisperBase, bytes: 140_000_000)],
            failed: [.whisperSmall], whisperAccessDenied: false
        )
        let text = ModelStorageText.result(report)
        #expect(text.hasPrefix("Removed 2 models and freed "))
        #expect(text.contains("Could not remove Whisper Small."))
    }

    // MARK: - Production / debug sharing

    private func otherDefaults(_ values: [String: Any]) -> UserDefaults {
        let suite = "NanoWhisperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        for (key, value) in values { defaults.set(value, forKey: key) }
        return defaults
    }

    @Test("Models the other flavor may use, from its stored settings")
    func otherFlavorProtection() throws {
        let whisper: (String) -> Data = { Data(#"{"modelSize":"\#($0)","promptText":""}"#.utf8) }
        #expect(ModelCleanupPolicy.usedByOtherFlavor(nil) == [])
        #expect(ModelCleanupPolicy.usedByOtherFlavor(otherDefaults([:])) == [])
        // 0.0.4: no parakeetVariant key, uses the legacy folder.
        #expect(ModelCleanupPolicy.usedByOtherFlavor(otherDefaults(["onboardingComplete": true]))
                == [.parakeetV3Legacy, .parakeetV3])
        // 0.0.5 on v3, or Ultra.
        #expect(ModelCleanupPolicy.usedByOtherFlavor(otherDefaults(["parakeetVariant": "v3"])) == [.parakeetV3])
        #expect(ModelCleanupPolicy.usedByOtherFlavor(otherDefaults(["parakeetVariant": "ultra"])) == [.parakeetUltra])
        // Mid-migration: may still run on v3.
        let pending = try JSONEncoder().encode(PendingModelMoves(parakeet: .v3, whisper: nil))
        #expect(ModelCleanupPolicy.usedByOtherFlavor(otherDefaults(["parakeetVariant": "ultra", "pendingModelMoves": pending]))
                == [.parakeetUltra, .parakeetV3])
        // Whisper, including a 0.0.4 Medium the other app still uses.
        #expect(ModelCleanupPolicy.usedByOtherFlavor(otherDefaults(["selectedModelType": "whisper", "whisperSettings": whisper("medium")]))
                == [.whisperMedium])
        #expect(ModelCleanupPolicy.usedByOtherFlavor(otherDefaults(["selectedModelType": "whisper"])) == [.whisperBase])
        // Unknown value: keep every Whisper folder.
        #expect(ModelCleanupPolicy.usedByOtherFlavor(otherDefaults(["selectedModelType": "whisper", "whisperSettings": whisper("huge")])).count == 6)
    }

    @Test("In use: selected, loaded and pending previous models")
    func inUse() {
        let keep = ModelCleanupPolicy.inUse(
            selected: .parakeet(.ultra), loaded: [.parakeet(.v3)], pending: PendingModelMoves(parakeet: .v3, whisper: .tiny)
        )
        #expect(keep == [.parakeetUltra, .parakeetV3, .whisperTiny])
    }
}
