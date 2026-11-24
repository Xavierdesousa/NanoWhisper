import Combine
import CryptoKit
import Foundation
import IOKit
import os

/// What History shows with "Show debug info in history". Every field is optional: entries saved
/// before a field existed decode without it (the model and language arrived in November 2026).
struct TranscriptionDebugInfo: Codable, Equatable, Sendable {
    let audioDuration: Double?
    let transcribeDuration: Double?
    let rtf: Double?
    /// The model that transcribed it, as Settings names it ("Parakeet Ultra",
    /// "Whisper Large v3 Turbo").
    var model: String?
    /// Whisper only: the language code it transcribed in ("fr").
    var language: String?
    /// Whisper only: `true` when Whisper detected `language`, `false` when Settings set it.
    var languageDetected: Bool?

    init(
        audioDuration: Double?, transcribeDuration: Double?, rtf: Double?,
        model: String? = nil, language: String? = nil, languageDetected: Bool? = nil
    ) {
        self.audioDuration = audioDuration
        self.transcribeDuration = transcribeDuration
        self.rtf = rtf
        self.model = model
        self.language = language
        self.languageDetected = languageDetected
    }

    enum CodingKeys: String, CodingKey {
        case audioDuration = "audio_duration"
        case transcribeDuration = "transcribe_duration"
        case rtf
        case model
        case language
        case languageDetected = "language_detected"
    }
}

struct HistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let text: String
    let date: Date
    var debugInfo: TranscriptionDebugInfo?

    /// - Parameter date: when it was dictated; now, except for a recording recovered after a
    ///   crash (the recording's date).
    init(id: UUID = UUID(), text: String, date: Date = Date(), debugInfo: TranscriptionDebugInfo? = nil) {
        self.id = id
        self.text = text
        self.date = date
        self.debugInfo = debugInfo
    }
}

// MARK: - Store

/// Why the history cannot be read or written. Its file is then left as it is (never overwritten,
/// never replaced by plain text).
enum HistoryUnavailableReason: Equatable, Sendable {
    /// The key cannot be used (missing, damaged, from another Mac, or not now), the file is
    /// damaged, or encryption failed.
    case unreadable
    /// The file is in the format used up to 0.1.0, although this history was already bound to
    /// this Mac: put back from a backup, or not written by the app. Read only if the user says
    /// so (`HistoryStore.useOlderFile`).
    case olderFormat
}

/// The transcription history, newest first, kept in one AES-GCM encrypted file
/// (`history.json` in the build's Application Support folder). It is never written in plain
/// text: when the key cannot be used or the file cannot be decrypted, the history is
/// unavailable and nothing is read or written until the next launch.
///
/// The key is bound to this Mac by its Secure Enclave (`HistoryKey`). Without one, or until the
/// migration of an older file succeeds, the file keeps the key derived from the hardware UUID.
@MainActor
final class HistoryStore: ObservableObject {
    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "HistoryStore")

    /// How long the enclave may hold up the app (it normally answers in a few milliseconds).
    nonisolated static let enclaveTimeout: TimeInterval = 3

    @Published private(set) var entries: [HistoryEntry] = []
    /// Set when the file exists but could not be decrypted or decoded, or encryption failed.
    @Published private(set) var unavailableReason: HistoryUnavailableReason?
    var isUnavailable: Bool { unavailableReason != nil }

    /// How the file on disk is encrypted, and so how the next save is.
    private enum Protection {
        /// No file yet: the first save decides.
        case undecided
        /// Key derived from the hardware UUID (the format up to 0.1.0).
        case hardwareUUID
        /// Key bound to this Mac.
        case bound(HistoryKey)
    }

    private let fileURL: URL
    private let oldKey: () -> SymmetricKey?
    /// `nil`: never any Secure Enclave (tests and the sample window).
    private let keyring: HistoryKeyring?
    private let defaults: UserDefaults?
    private let timeout: TimeInterval
    private let migrationCheckpoint: (HistoryMigration.Step) throws -> Void
    private var protection = Protection.undecided
    /// The load whose key the enclave has not given yet.
    private var pendingLoad: UUID?

    /// `keyring`, if its enclave answers, for one operation: within `timeout` in all.
    private var availableKeyring: HistoryKeyring? {
        guard let keyring else { return nil }
        let enclave = TimeLimitedEnclave(base: keyring.enclave, deadline: Date().addingTimeInterval(timeout))
        return enclave.isAvailable ? HistoryKeyring(enclave: enclave, storage: keyring.storage) : nil
    }

    /// Whether there is no enclave: not just one that does not answer in time.
    private var hasNoEnclave: Bool {
        guard let keyring else { return true }
        return TimeLimitedEnclave(base: keyring.enclave, deadline: Date().addingTimeInterval(timeout)).availability == false
    }

    /// Loads the history at `fileURL`. A missing file is an empty, available history.
    ///
    /// - Parameters:
    ///   - key: the key derived from the hardware UUID, for the old format.
    ///   - keyring: the Secure Enclave, and where the key record is kept.
    ///   - defaults: remembers that this history was bound to this Mac.
    init(
        fileURL: URL, key: @escaping () -> SymmetricKey?, keyring: HistoryKeyring? = nil, defaults: UserDefaults? = nil,
        enclaveTimeout: TimeInterval = HistoryStore.enclaveTimeout,
        migrationCheckpoint: @escaping (HistoryMigration.Step) throws -> Void = { _ in }
    ) {
        self.fileURL = fileURL
        self.oldKey = key
        self.keyring = keyring
        self.defaults = defaults
        self.timeout = enclaveTimeout
        self.migrationCheckpoint = migrationCheckpoint
        load()
    }

    /// This build's history, on this Mac. The only place that names the real file.
    static func forThisBuild() -> HistoryStore {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = BuildFlavor.current.supportDirectory(in: appSupport)
        PrivateFile.makeFolderPrivate(folder)
        let fileURL = folder.appendingPathComponent("history.json")
        return HistoryStore(
            fileURL: fileURL, key: HistoryCrypto.machineKey,
            keyring: HistoryKeyring(enclave: MacSecureEnclave(), storage: HistoryKeyFile(besideHistoryAt: fileURL)),
            defaults: .standard
        )
    }

    /// Add a new transcription at the top, keeping at most `maxCount` entries.
    func add(_ entry: HistoryEntry, keepingAtMost maxCount: Int) {
        guard !isUnavailable else { return }
        entries = Array(([entry] + entries).prefix(max(0, maxCount)))
        save()
    }

    /// Insert an entry at its place by date (the list is newest first), keeping at most
    /// `maxCount` entries: the oldest are dropped. For a recording recovered after a crash,
    /// whose date is earlier than entries added since.
    func insert(_ entry: HistoryEntry, keepingAtMost maxCount: Int) {
        guard !isUnavailable else { return }
        var updated = entries
        let index = updated.firstIndex { $0.date < entry.date } ?? updated.count
        updated.insert(entry, at: index)
        entries = Array(updated.prefix(max(0, maxCount)))
        save()
    }

    /// Drop the oldest entries beyond `maxCount`. Writes only when something was dropped.
    func trim(to maxCount: Int) {
        guard entries.count > maxCount else { return }
        replaceEntries(Array(entries.prefix(max(0, maxCount))))
    }

    /// Replace the whole list (the History window's delete and its undo).
    func replaceEntries(_ newEntries: [HistoryEntry]) {
        guard !isUnavailable else { return }
        entries = newEntries
        save()
    }

    // MARK: Deleting

    /// Whether the history file is on disk (read or not).
    var hasFile: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Whether anything of the history is on disk: the file, what an interrupted save left, or
    /// the key record.
    var hasAnyFile: Bool { hasFile || hasLeftovers || (keyring?.storage.hasRecord ?? false) }

    private var hasLeftovers: Bool { !PrivateFile.leftovers(of: fileURL).isEmpty }

    /// Delete everything: the entries, the file itself, overwritten with zeros first
    /// (`TemporaryRecordings.securelyDelete`, best effort on APFS), then, once no history is
    /// left, its key. Used by Clear All, by turning history off, and by the one-time cleanup of a
    /// file kept while history was off. Also removes a file that could not be read: once it is
    /// gone there is nothing left to protect, so the history is available again, with a new key
    /// (a key that cannot be made makes the next save fail and mark it unavailable again).
    /// - Returns: whether everything is gone (also when there was nothing).
    @discardableResult
    func deleteAll() -> Bool {
        pendingLoad = nil
        entries = []
        PrivateFile.removeLeftovers(of: fileURL)
        if hasFile { TemporaryRecordings.securelyDelete(at: fileURL) }
        guard !hasFile, !hasLeftovers else {
            // The key stays as long as anything encrypted with it does.
            Self.logger.error("History file could not be deleted")
            return false
        }
        protection = .undecided
        unavailableReason = nil
        // No enclave (settings moved to a virtual machine, for example): the next history, if
        // any, starts like on such a Mac. Only here, where the user deleted the bound one.
        if isRecordedBound, hasNoEnclave { defaults?.removeObject(forKey: HistorySettings.boundKey) }
        return deleteKey()
    }

    /// The key of a history that is gone. A copy of that history kept in the folder by the user
    /// is not the app's: its key is then set aside, not deleted.
    private func deleteKey() -> Bool {
        guard let keyring, keyring.storage.hasRecord else { return true }
        do {
            if let record = try? keyring.record(),
               BoundHistoryFile.folder(fileURL.deletingLastPathComponent(), mayHoldFileSealedWith: record.id) {
                try keyring.storage.setAside()
                Self.logger.notice("A copy of the history may be in its folder: its key was set aside, not deleted")
            } else if !keyring.storage.remove() {
                throw HistoryKeyError.recordExists
            }
            return true
        } catch {
            Self.logger.error("History key could not be deleted: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    // MARK: Loading

    private func load() {
        let data: Data
        do {
            guard let found = try PrivateFile.read(fileURL) else { return }
            data = found
        } catch {
            // There is a file: never treat it as missing, the next save would replace it.
            Self.logger.error("History file could not be read: \(String(describing: error), privacy: .public)")
            unavailableReason = .unreadable
            return
        }
        if BoundHistoryFile.isBound(data) {
            loadBound(data)
        } else {
            loadOldFormat(data)
        }
    }

    private func loadBound(_ data: Data) {
        // Set first: whatever happens below, the file is not overwritten.
        unavailableReason = .unreadable
        guard let keyring else {
            Self.logger.error("The history is bound to a Secure Enclave and there is none; history is unavailable")
            return
        }
        let record: HistoryKeyRecord
        do {
            guard let found = try keyring.record() else { throw HistoryKeyError.noRecord }
            record = found
        } catch {
            Self.logger.error("History key could not be read; history is unavailable: \(String(describing: error), privacy: .public)")
            return
        }
        let enclave = keyring.enclave
        let loading = UUID()
        pendingLoad = loading
        let result = TimedCall.run(timeout: timeout, late: { [weak self] result in
            Task { @MainActor in self?.finishLoading(data, result, loading: loading, isLate: true) }
        }, {
            try HistoryKey(unwrapping: record, with: enclave)
        })
        if let result {
            finishLoading(data, result, loading: loading, isLate: false)
        } else {
            Self.logger.error("The Secure Enclave has not answered yet; history is unavailable until it does")
        }
    }

    private func finishLoading(_ data: Data, _ result: Result<HistoryKey, any Error>, loading: UUID, isLate: Bool) {
        guard pendingLoad == loading else { return }
        pendingLoad = nil
        do {
            let key = try result.get()
            // Late: only if the file is still the one that was read.
            if isLate, try PrivateFile.read(fileURL) != data { throw HistoryKeyError.fileChanged }
            entries = try JSONDecoder().decode([HistoryEntry].self, from: key.open(data))
            protection = .bound(key)
            unavailableReason = nil
            recordBound()
            PrivateFile.removeLeftovers(of: fileURL)
        } catch {
            // Another Mac's key, a damaged file... Never fall back to another scheme.
            Self.logger.error("History file could not be decrypted; history is unavailable: \(String(describing: error), privacy: .public)")
        }
    }

    private func loadOldFormat(_ data: Data) {
        guard let old = openOldFormat(data) else {
            // Wrong or missing key, or a damaged file. Never fall back to reading plain text.
            Self.logger.error("History file could not be decrypted; history is unavailable")
            unavailableReason = .unreadable
            return
        }
        guard !isRecordedBound else {
            Self.logger.error("The history file is in the older format although this history is bound to this Mac; not read")
            unavailableReason = .olderFormat
            return
        }
        entries = old.entries
        protection = .hardwareUUID
        PrivateFile.removeLeftovers(of: fileURL)
        migrate(data, old)
    }

    private func openOldFormat(_ data: Data) -> (json: Data, entries: [HistoryEntry])? {
        guard let key = oldKey(), let json = HistoryCrypto.open(data, using: key),
              let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: json) else { return nil }
        return (json, decoded)
    }

    /// Bind an older file to this Mac. A failure leaves it as it was, to be tried again at the
    /// next launch.
    @discardableResult
    private func migrate(
        _ data: Data, _ old: (json: Data, entries: [HistoryEntry]), settingUnusableKeyAside: Bool = false
    ) -> Bool {
        guard let keyring = availableKeyring else {
            Self.logger.notice("No Secure Enclave: the history keeps the key derived from the hardware UUID")
            return false
        }
        let migration = HistoryMigration(
            fileURL: fileURL, keyring: keyring, recordBound: { [weak self] in self?.recordBound() },
            setsUnusableKeyAside: settingUnusableKeyAside, checkpoint: migrationCheckpoint
        )
        do {
            protection = .bound(try migration.run(oldFile: data, json: old.json, entries: old.entries))
            Self.logger.notice("The history is now encrypted with a key bound to this Mac")
            return true
        } catch {
            Self.logger.error("The history could not be bound to this Mac; it keeps its key until the next launch: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// The user wants the older file (`.olderFormat`): read it and bind it to this Mac.
    /// - Returns: whether it is now the history. If not, the file is still there as it was.
    @discardableResult
    func useOlderFile() -> Bool {
        guard unavailableReason == .olderFormat,
              let data = try? PrivateFile.read(fileURL), !BoundHistoryFile.isBound(data),
              let old = openOldFormat(data), migrate(data, old, settingUnusableKeyAside: true) else { return false }
        entries = old.entries
        unavailableReason = nil
        return true
    }

    // MARK: Saving

    private func save() {
        guard let json = try? JSONEncoder().encode(entries) else { return }
        let sealed: Data
        do {
            sealed = try seal(json)
        } catch {
            // Never write plain text, nor with a key that may not be there next time.
            Self.logger.error("History could not be encrypted; nothing was written: \(String(describing: error), privacy: .public)")
            unavailableReason = .unreadable
            return
        }
        do {
            // In one rename: an interrupted save never leaves a partial (undecryptable) file.
            try PrivateFile.replace(fileURL, with: sealed)
        } catch {
            Self.logger.error("History could not be written: \(String(describing: error), privacy: .public)")
            return
        }
        if case .bound = protection { recordBound() }
    }

    private func seal(_ json: Data) throws -> Data {
        if case .undecided = protection { protection = try protectionForNewFile() }
        switch protection {
        case .bound(let key):
            try keyring?.keepRecord(of: key)
            return try key.seal(json)
        case .undecided, .hardwareUUID:
            // Another instance may have bound the file since.
            guard try !BoundHistoryFile.isBound(at: fileURL) else { throw HistoryKeyError.wouldDowngrade }
            guard let key = oldKey(), let sealed = HistoryCrypto.seal(json, using: key) else {
                throw HistoryKeyError.oldKeyUnavailable
            }
            return sealed
        }
    }

    /// No history file: a key bound to this Mac if it has a Secure Enclave.
    private func protectionForNewFile() throws -> Protection {
        guard let keyring = availableKeyring else {
            // Once bound, never back to the old key: the enclave may answer later.
            guard !isRecordedBound else { throw HistoryKeyError.noEnclave }
            Self.logger.notice("No Secure Enclave: the history uses the key derived from the hardware UUID")
            return .hardwareUUID
        }
        do {
            return .bound(try keyring.existingOrNewKey())
        } catch {
            guard !isRecordedBound else { throw error }
            Self.logger.error("No key bound to this Mac could be made; the old key is used until the next launch: \(String(describing: error), privacy: .public)")
            return .hardwareUUID
        }
    }

    // MARK: Bound to this Mac

    /// Whether this history was bound to this Mac before: the old format is then refused.
    private var isRecordedBound: Bool { defaults?.bool(forKey: HistorySettings.boundKey) ?? false }

    private func recordBound() {
        guard !isRecordedBound else { return }
        defaults?.set(true, forKey: HistorySettings.boundKey)
    }
}

// MARK: - Settings and one-time cleanup

/// History settings stored in `UserDefaults`, and the cleanup that runs once after the update
/// that made "history off" mean "nothing kept".
enum HistorySettings {
    static let enabledKey = "historyEnabled"
    static let maxCountKey = "maxHistoryCount"
    /// Set once the cleanup below has nothing left to do (the file gone, or history on).
    static let offCleanupDoneKey = "historyOffCleanupDone"
    /// Set once the history was encrypted with a key bound to this Mac: from then on a file in
    /// the older format is not read unless the user says so.
    static let boundKey = "historyBoundToThisMac"

    /// What History keeps when the user never chose (the maintainer's decision, 2026-11-21;
    /// it was 15). A stored choice is kept.
    static let defaultMaxCount = 25

    /// History is on unless the user turned it off.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledKey) == nil ? true : defaults.bool(forKey: enabledKey)
    }

    /// The stored count, or `defaultMaxCount` when none was stored.
    static func maxCount(in defaults: UserDefaults) -> Int {
        let stored = defaults.integer(forKey: maxCountKey)
        return stored > 0 ? stored : defaultMaxCount
    }

    /// Before this version, turning history off kept the file. Now it deletes it (after an
    /// alert in Settings), so at the first launch after the update an install with history off
    /// gets its old file deleted, silently. Runs once: the flag is set once nothing is left to delete, so
    /// a later launch never deletes anything here (turning history off later goes through the
    /// alert). Deletes the file even if it cannot be read: history is off, nothing in it is
    /// shown or kept.
    /// - Returns: whether a file was deleted.
    @MainActor
    @discardableResult
    static func runOffCleanupOnce(defaults: UserDefaults, store: HistoryStore) -> Bool {
        guard !defaults.bool(forKey: offCleanupDoneKey) else { return false }
        guard !isEnabled(in: defaults), store.hasAnyFile else {
            defaults.set(true, forKey: offCleanupDoneKey)
            return false
        }
        // Done only once the file is gone: a failed deletion is tried again at the next launch.
        let deleted = store.deleteAll()
        if deleted { defaults.set(true, forKey: offCleanupDoneKey) }
        return deleted
    }

    /// History was turned off but its file could not be deleted: the launch cleanup tries again.
    static func retryOffCleanup(defaults: UserDefaults) {
        defaults.removeObject(forKey: offCleanupDoneKey)
    }
}

// MARK: - Encryption

/// The history's encryption up to 0.1.0, and still on a Mac without a Secure Enclave: AES-256-GCM
/// with a key derived (HKDF-SHA256) from the Mac's hardware UUID. Files in this format are
/// migrated to a key bound to the Mac (`HistoryKey`, `HistoryMigration`).
///
/// It keeps the file alone unreadable to casual inspection. Someone with a copy of the home
/// folder can rebuild the key: the hardware UUID is in it, and the salt is in this source.
enum HistoryCrypto {
    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "HistoryCrypto")
    /// Key-derivation constant, not an identifier: changing it would make existing
    /// history unreadable. Both builds keep it; their history files live in separate folders.
    private static let salt = "com.moonji.nanowhisper.history.v1".data(using: .utf8)!

    /// The key for this Mac, or `nil` when the hardware UUID cannot be read.
    static func machineKey() -> SymmetricKey? {
        guard let uuid = hardwareUUID() else {
            logger.error("Could not read hardware UUID")
            return nil
        }
        return key(fromHardwareUUID: uuid)
    }

    static func key(fromHardwareUUID uuid: String) -> SymmetricKey {
        let ikm = SymmetricKey(data: Data(uuid.utf8))
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, outputByteCount: 32)
    }

    /// `IOPlatformUUID`: stable across reboots, unique per machine.
    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard let uuid = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String else { return nil }
        return uuid
    }

    /// Nonce, ciphertext and tag in one blob, or `nil` if sealing failed.
    static func seal(_ data: Data, using key: SymmetricKey) -> Data? {
        guard let sealedBox = try? AES.GCM.seal(data, using: key),
              let combined = sealedBox.combined else {
            logger.error("AES-GCM seal failed")
            return nil
        }
        return combined
    }

    /// The plain data, or `nil` when the blob is damaged or was sealed with another key.
    static func open(_ data: Data, using key: SymmetricKey) -> Data? {
        guard let sealedBox = try? AES.GCM.SealedBox(combined: data),
              let decrypted = try? AES.GCM.open(sealedBox, using: key) else {
            logger.error("AES-GCM open failed: damaged data or another key")
            return nil
        }
        return decrypted
    }
}
