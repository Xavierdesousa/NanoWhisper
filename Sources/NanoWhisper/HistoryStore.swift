import Combine
import CryptoKit
import Foundation
import IOKit
import os

struct TranscriptionDebugInfo: Codable {
    let audioDuration: Double?
    let transcribeDuration: Double?
    let rtf: Double?

    enum CodingKeys: String, CodingKey {
        case audioDuration = "audio_duration"
        case transcribeDuration = "transcribe_duration"
        case rtf
    }
}

struct HistoryEntry: Codable, Identifiable {
    let id: UUID
    let text: String
    let date: Date
    var debugInfo: TranscriptionDebugInfo?

    init(text: String, debugInfo: TranscriptionDebugInfo? = nil) {
        self.id = UUID()
        self.text = text
        self.date = Date()
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

    /// Drop the oldest entries beyond `maxCount`. Writes only when something was dropped.
    func trim(to maxCount: Int) {
        guard entries.count > maxCount else { return }
        replaceEntries(Array(entries.prefix(max(0, maxCount))))
    }

    /// Replace the whole list (the History window's delete and clear).
    func replaceEntries(_ newEntries: [HistoryEntry]) {
        guard !isUnavailable else { return }
        entries = newEntries
        save()
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
            try sealed.write(to: fileURL)
        } catch {
            Self.logger.error("History could not be written: \(String(describing: error), privacy: .public)")
        }
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
