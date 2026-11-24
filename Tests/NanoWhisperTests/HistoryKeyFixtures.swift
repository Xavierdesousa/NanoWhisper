import CryptoKit
import Foundation
import os
@testable import NanoWhisper

/// A software stand-in for a Secure Enclave: each instance is one Mac. Its blobs are sealed with
/// a key only that instance has, so another instance cannot use them.
final class FakeEnclave: HistoryEnclave {
    struct Refused: Error {}

    struct State: Sendable {
        var isAvailable = true
        var refusesToMake = false
        var refusesToOpen = false
        var made = 0
        var opened = 0
        /// Calls to `sharedSecret` that have answered.
        var answered = 0
        /// Calls wait for this before they answer.
        var gate: Gate?
    }

    /// Closed until `open()`.
    final class Gate: Sendable {
        private let semaphore = DispatchSemaphore(value: 0)
        func open() { semaphore.signal() }
        func pass() {
            semaphore.wait()
            semaphore.signal()
        }
    }

    private let device = SymmetricKey(size: .bits256)
    private let state = OSAllocatedUnfairLock(initialState: State())

    var current: State { state.withLock { $0 } }
    func update(_ change: @Sendable (inout State) -> Void) { state.withLock { change(&$0) } }

    var isAvailable: Bool {
        current.gate?.pass()
        return current.isAvailable
    }

    func makeKey() throws -> HistoryEnclaveKey {
        update { $0.made += 1 }
        current.gate?.pass()
        guard current.isAvailable, !current.refusesToMake else { throw Refused() }
        let key = P256.KeyAgreement.PrivateKey()
        let blob = try AES.GCM.seal(key.rawRepresentation, using: device).combined!
        return HistoryEnclaveKey(blob: blob, publicKey: key.publicKey)
    }

    func sharedSecret(blob: Data, with publicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        update { $0.opened += 1 }
        defer { update { $0.answered += 1 } }
        current.gate?.pass()
        guard current.isAvailable, !current.refusesToOpen else { throw Refused() }
        let raw = try AES.GCM.open(AES.GCM.SealedBox(combined: blob), using: device)
        return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw).sharedSecretFromKeyAgreement(with: publicKey)
    }
}

/// A key record kept in memory: what a later build would keep in the keychain.
final class MemoryKeyStorage: HistoryKeyStorage {
    var record: Data?
    var refusesToRemove = false
    private(set) var aside: [Data] = []

    init(record: Data? = nil) { self.record = record }

    var hasRecord: Bool { record != nil }
    func read() throws -> Data? { record }
    func create(_ record: Data) throws {
        guard self.record == nil else { throw HistoryKeyError.recordExists }
        self.record = record
    }
    func makeDurable() throws {}
    func remove() -> Bool {
        if !refusesToRemove { record = nil }
        return record == nil
    }
    func setAside() throws {
        if let record { aside.append(record) }
        record = nil
    }
}

/// A history folder in a temporary directory, with invented entries: never the real one.
@MainActor
final class HistoryFolder {
    nonisolated static let oldKey = HistoryCrypto.key(fromHardwareUUID: "00000000-TEST-0000-0000-0000000000E0")

    let directory: URL
    let defaults: UserDefaults
    nonisolated let suite: String

    init(copying source: HistoryFolder? = nil) {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoWhisperHistoryKeyTests-\(UUID().uuidString)", isDirectory: true)
        suite = "nanowhisper.tests.historykey.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        if let source {
            try! FileManager.default.copyItem(at: source.directory, to: directory)
            isRecordedBound = source.isRecordedBound
        } else {
            try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
        _ = chmod(directory.path, 0o700)
        try? FileManager.default.removeItem(at: directory)
    }

    var historyURL: URL { directory.appendingPathComponent("history.json") }
    var keyURL: URL { directory.appendingPathComponent("history.key") }

    var isRecordedBound: Bool {
        get { defaults.bool(forKey: HistorySettings.boundKey) }
        set { defaults.set(newValue, forKey: HistorySettings.boundKey) }
    }

    func store(
        _ enclave: FakeEnclave?, storage: (any HistoryKeyStorage)? = nil, oldKey: SymmetricKey? = HistoryFolder.oldKey,
        timeout: TimeInterval = 5, checkpoint: @escaping (HistoryMigration.Step) throws -> Void = { _ in }
    ) -> HistoryStore {
        let keyring = enclave.map {
            HistoryKeyring(enclave: $0, storage: storage ?? HistoryKeyFile(besideHistoryAt: historyURL))
        }
        return HistoryStore(
            fileURL: historyURL, key: { oldKey }, keyring: keyring, defaults: defaults,
            enclaveTimeout: timeout, migrationCheckpoint: checkpoint
        )
    }

    func history() throws -> Data { try Data(contentsOf: historyURL) }
    func key() throws -> Data { try Data(contentsOf: keyURL) }
    var hasHistory: Bool { FileManager.default.fileExists(atPath: historyURL.path) }
    var hasKey: Bool { FileManager.default.fileExists(atPath: keyURL.path) }
    var isBound: Bool { (try? BoundHistoryFile.isBound(at: historyURL)) ?? false }
    var names: Set<String> { Set((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []) }

    func write(_ data: Data, named name: String) { try! data.write(to: directory.appendingPathComponent(name)) }
    func read(_ name: String) -> Data? { try? Data(contentsOf: directory.appendingPathComponent(name)) }

    func mode(_ url: URL) -> Int {
        var info = stat()
        return lstat(url.path, &info) == 0 ? Int(info.st_mode & 0o7777) : -1
    }

    /// A history file as 0.1.0 writes it.
    @discardableResult
    func writeOldFile(_ entries: [HistoryEntry] = HistoryFixtures.entries) -> Data {
        let sealed = HistoryCrypto.seal(try! JSONEncoder().encode(entries), using: Self.oldKey)!
        try! sealed.write(to: historyURL, options: .atomic)
        return sealed
    }

    /// A bound history, as a launch on `enclave` leaves it.
    func writeBoundFile(_ enclave: FakeEnclave, _ entries: [HistoryEntry] = HistoryFixtures.entries) {
        store(enclave).replaceEntries(entries)
    }
}
