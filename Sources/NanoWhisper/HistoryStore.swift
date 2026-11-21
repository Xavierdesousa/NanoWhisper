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

/// The transcription history, newest first, kept in one AES-GCM encrypted file
/// (`history.json` in the build's Application Support folder). It is never written in plain
/// text: when the key cannot be derived or the file cannot be decrypted, the history is
/// unavailable and nothing is read or written until the next launch.
@MainActor
final class HistoryStore: ObservableObject {
    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "HistoryStore")

    @Published private(set) var entries: [HistoryEntry] = []
    /// The file exists but could not be decrypted or decoded, or encryption failed. The file
    /// is then left as it is (never overwritten, never replaced by plain text).
    @Published private(set) var isUnavailable = false

    private let fileURL: URL
    private let key: () -> SymmetricKey?

    /// Loads the history at `fileURL`. A missing file is an empty, available history.
    init(fileURL: URL = HistoryStore.defaultFileURL(), key: @escaping () -> SymmetricKey? = HistoryCrypto.machineKey) {
        self.fileURL = fileURL
        self.key = key
        load()
    }

    /// `history.json` in this build's Application Support folder (created if needed).
    nonisolated static func defaultFileURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = BuildFlavor.current.supportDirectory(in: appSupport)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
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

    /// Whether the history file is on disk (read or not).
    var hasFile: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// Delete everything: the entries, and the file itself, overwritten with zeros first
    /// (`TemporaryRecordings.securelyDelete`, best effort on APFS). Used by Clear All, by
    /// turning history off, and by the one-time cleanup of a file kept while history was off.
    /// Also removes a file that could not be read: once it is gone there is nothing left to
    /// protect, so the history is available again (a missing key makes the next save fail
    /// and mark it unavailable again).
    /// - Returns: whether the file is gone (also when there was none).
    @discardableResult
    func deleteAll() -> Bool {
        entries = []
        guard hasFile else { return true }
        TemporaryRecordings.securelyDelete(at: fileURL)
        guard !hasFile else {
            Self.logger.error("History file could not be deleted")
            return false
        }
        isUnavailable = false
        return true
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        if let key = key(),
           let json = HistoryCrypto.open(data, using: key),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: json) {
            entries = decoded
        } else {
            // Wrong or missing key, or a damaged file. Never fall back to reading plain text.
            Self.logger.error("History file could not be decrypted; history is unavailable")
            isUnavailable = true
        }
    }

    private func save() {
        guard let json = try? JSONEncoder().encode(entries) else { return }
        guard let key = key(), let sealed = HistoryCrypto.seal(json, using: key) else {
            // Never write plain text.
            Self.logger.error("History could not be encrypted; nothing was written")
            isUnavailable = true
            return
        }
        do {
            // Atomic: an interrupted save never leaves a partial (undecryptable) file.
            try sealed.write(to: fileURL, options: .atomic)
        } catch {
            Self.logger.error("History could not be written: \(String(describing: error), privacy: .public)")
        }
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
        guard !isEnabled(in: defaults), store.hasFile else {
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

/// AES-256-GCM with a key derived (HKDF-SHA256) from the Mac's hardware UUID.
///
/// This keeps the file unreadable at rest and to casual inspection (a copied file, a backup,
/// another Mac). It does not protect against other software running under the same user
/// account: the hardware UUID is readable by any process, and the salt is in this source.
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
