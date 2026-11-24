import CryptoKit
import Foundation
import Security
import os

// The key that encrypts the history, bound to this Mac: a random 256-bit key, kept only wrapped
// for a key of this Mac's Secure Enclave. Formats, limits and the migration of older files:
// docs/wiki/architecture.md, "History storage".

enum HistoryKeyError: Error, Equatable {
    /// There is no key record although the history needs one.
    case noRecord
    /// The key record is truncated or its checksum is wrong. Never given to the enclave.
    case damagedRecord
    /// A key record or history file written by a newer version.
    case unknownVersion
    /// A key record is already kept (`HistoryKeyStorage.create` never replaces one).
    case recordExists
    /// The record kept is not the one this key came from.
    case recordChanged
    /// The history file was not sealed with this key, or is damaged.
    case cannotOpen
    /// The file on disk is bound to a Mac: the old format must not replace it.
    case wouldDowngrade
    /// The enclave could not be used to check a new key.
    case unusableKey
    /// The enclave did not answer in time.
    case timedOut
    /// The key derived from the hardware UUID is not available, or sealing failed.
    case oldKeyUnavailable
    /// The history file on disk is not the one that was read.
    case fileChanged
    case noEnclave
}

// MARK: - Secure Enclave

/// A private key that only its Secure Enclave can use: `blob` is meaningless elsewhere.
struct HistoryEnclaveKey: Sendable {
    let blob: Data
    let publicKey: P256.KeyAgreement.PublicKey
}

/// What the history needs from the Secure Enclave. Tests use a software one.
protocol HistoryEnclave: Sendable {
    /// Whether there is a Secure Enclave that answers. `false` may be temporary.
    var isAvailable: Bool { get }
    func makeKey() throws -> HistoryEnclaveKey
    /// ECDH between the enclave's private key (from its blob) and a public key.
    func sharedSecret(blob: Data, with publicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret
}

/// This Mac's Secure Enclave, through CryptoKit: no keychain, no entitlement, no prompt. The key
/// is usable on this Mac only, once the user has logged in since startup (also while the screen
/// is locked).
///
/// Calls, `isAvailable` included, go to `ctkd` over synchronous XPC: milliseconds normally, but
/// they can wait much longer when that daemon is slow to start, so callers use `TimedCall` or
/// `TimeLimitedEnclave`. A blob
/// whose structure is damaged can trap inside CryptoKit: only pass one whose record has a valid
/// checksum (`HistoryKeyRecord`).
struct MacSecureEnclave: HistoryEnclave {
    var isAvailable: Bool { SecureEnclave.isAvailable }

    func makeKey() throws -> HistoryEnclaveKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, .privateKeyUsage, &error
        ) else {
            if let error { throw error.takeRetainedValue() }
            throw HistoryKeyError.unusableKey
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        return HistoryEnclaveKey(blob: key.dataRepresentation, publicKey: key.publicKey)
    }

    func sharedSecret(blob: Data, with publicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob)
            .sharedSecretFromKeyAgreement(with: publicKey)
    }
}

/// Runs a blocking call on another thread and waits for it at most `timeout`.
enum TimedCall {
    private enum State<T: Sendable>: Sendable {
        case running
        case finished(Result<T, any Error>)
        /// Nobody waits any more: the result goes to `late`.
        case abandoned
    }

    /// - Parameter late: receives the result, on another thread, when it came after `timeout`.
    /// - Returns: the result, or `nil` when the call is still running.
    static func run<T: Sendable>(
        timeout: TimeInterval,
        late: @escaping @Sendable (Result<T, any Error>) -> Void = { _ in },
        _ body: @escaping @Sendable () throws -> T
    ) -> Result<T, any Error>? {
        let state = OSAllocatedUnfairLock<State<T>>(initialState: .running)
        let done = DispatchSemaphore(value: 0)
        // Its own thread: a blocked call must not take one of the shared queues' threads, and
        // busy queues must not delay it.
        let thread = Thread {
            let result = Result { try body() }
            let isLate = state.withLock { current in
                if case .abandoned = current { return true }
                current = .finished(result)
                return false
            }
            if isLate { late(result) } else { done.signal() }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = done.wait(timeout: .now() + timeout)
        return state.withLock { current in
            if case .finished(let result) = current { return result }
            current = .abandoned
            return nil
        }
    }
}

/// An enclave whose calls, together, hold up the app until `deadline` at most: later ones fail
/// with `.timedOut`.
struct TimeLimitedEnclave: HistoryEnclave {
    let base: any HistoryEnclave
    let deadline: Date

    var isAvailable: Bool { availability ?? false }

    /// `nil`: no answer in time.
    var availability: Bool? {
        let base = base
        return try? run { base.isAvailable }
    }

    func makeKey() throws -> HistoryEnclaveKey {
        let base = base
        return try run { try base.makeKey() }
    }

    func sharedSecret(blob: Data, with publicKey: P256.KeyAgreement.PublicKey) throws -> SharedSecret {
        let base = base
        return try run { try base.sharedSecret(blob: blob, with: publicKey) }
    }

    private func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) throws -> T {
        let left = deadline.timeIntervalSinceNow
        guard left > 0, let result = TimedCall.run(timeout: left, body) else { throw HistoryKeyError.timedOut }
        return try result.get()
    }
}

// MARK: - Key record

/// What is kept of the history's key: the enclave key's blob, and the history key wrapped for it.
///
///     "NWHISTKEY" | version (1) | key id (16) | blob length (2, big endian) | enclave key blob
///     | ephemeral public key (64) | wrapped key (12 nonce + 32 + 16 tag) | SHA-256 of all before
///
/// The wrapping key is HKDF-SHA256 of an ephemeral ECDH (P-256) with the enclave key; what
/// comes before the wrapped key is authenticated with it. The checksum is there to never give a
/// damaged blob to the enclave, not for secrecy or authenticity.
struct HistoryKeyRecord: Equatable, Sendable {
    static let magic = Data("NWHISTKEY".utf8)
    static let version: UInt8 = 1
    static let idLength = 16
    private static let ephemeralLength = 64
    private static let wrappedLength = 12 + 32 + 16
    private static let checksumLength = 32
    private static let fixedStart = magic.count + 1 + idLength + 2
    private static let fixedEnd = ephemeralLength + wrappedLength + checksumLength

    let bytes: Data
    let id: Data
    let enclaveBlob: Data
    let ephemeralKey: Data
    let wrappedKey: Data
    /// Everything before the wrapped key, authenticated with it.
    let authenticated: Data

    /// A record read back. Throws when it is not exactly what was written.
    init(bytes: Data) throws {
        let bytes = Data(bytes) // indices from 0
        guard bytes.starts(with: Self.magic), bytes.count > Self.magic.count else { throw HistoryKeyError.damagedRecord }
        guard bytes[Self.magic.count] == Self.version else { throw HistoryKeyError.unknownVersion }
        guard bytes.count > Self.fixedStart + Self.fixedEnd else { throw HistoryKeyError.damagedRecord }
        let checksum = bytes.suffix(Self.checksumLength)
        guard Data(SHA256.hash(data: bytes.dropLast(Self.checksumLength))) == Data(checksum) else {
            throw HistoryKeyError.damagedRecord
        }
        let blobLength = Int(bytes[Self.fixedStart - 2]) << 8 | Int(bytes[Self.fixedStart - 1])
        guard blobLength > 0, bytes.count == Self.fixedStart + blobLength + Self.fixedEnd else {
            throw HistoryKeyError.damagedRecord
        }
        let blobEnd = Self.fixedStart + blobLength
        let ephemeralEnd = blobEnd + Self.ephemeralLength
        self.bytes = bytes
        id = Data(bytes[(Self.magic.count + 1)..<(Self.magic.count + 1 + Self.idLength)])
        enclaveBlob = Data(bytes[Self.fixedStart..<blobEnd])
        ephemeralKey = Data(bytes[blobEnd..<ephemeralEnd])
        wrappedKey = Data(bytes[ephemeralEnd..<(ephemeralEnd + Self.wrappedLength)])
        authenticated = Data(bytes[..<ephemeralEnd])
    }

    /// A new record, wrapping `dataKey` for `enclaveKey`.
    init(wrapping dataKey: SymmetricKey, for enclaveKey: HistoryEnclaveKey) throws {
        guard let blobLength = UInt16(exactly: enclaveKey.blob.count), blobLength > 0 else { throw HistoryKeyError.unusableKey }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ephemeralRaw = ephemeral.publicKey.rawRepresentation
        var head = Self.magic
        head.append(Self.version)
        head.append(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }) // a random id
        head.append(UInt8(blobLength >> 8))
        head.append(UInt8(blobLength & 0xff))
        head.append(enclaveKey.blob)
        head.append(ephemeralRaw)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
        let box = try AES.GCM.seal(
            dataKey.withUnsafeBytes { Data($0) },
            using: Self.wrappingKey(secret, ephemeralKey: ephemeralRaw), authenticating: head
        )
        guard let wrapped = box.combined else { throw HistoryKeyError.unusableKey }
        let body = head + wrapped
        try self.init(bytes: body + Data(SHA256.hash(data: body)))
    }

    /// The history key, unwrapped by the enclave that made it.
    func unwrap(with enclave: any HistoryEnclave) throws -> SymmetricKey {
        let publicKey = try P256.KeyAgreement.PublicKey(rawRepresentation: ephemeralKey)
        let secret = try enclave.sharedSecret(blob: enclaveBlob, with: publicKey)
        let plain = try AES.GCM.open(
            AES.GCM.SealedBox(combined: wrappedKey),
            using: Self.wrappingKey(secret, ephemeralKey: ephemeralKey), authenticating: authenticated
        )
        guard plain.count == 32 else { throw HistoryKeyError.damagedRecord }
        return SymmetricKey(data: plain)
    }

    private static func wrappingKey(_ secret: SharedSecret, ephemeralKey: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: ephemeralKey,
            sharedInfo: Data("com.moonji.nanowhisper.history.key.v1".utf8), outputByteCount: 32
        )
    }
}

// MARK: - Key

/// The history's key, unwrapped, with the record it came from. Kept in memory while the app runs:
/// the enclave is needed once per launch.
struct HistoryKey: Sendable {
    let record: HistoryKeyRecord
    private let dataKey: SymmetricKey

    /// The key of a record kept earlier.
    init(unwrapping record: HistoryKeyRecord, with enclave: any HistoryEnclave) throws {
        self.record = record
        dataKey = try record.unwrap(with: enclave)
    }

    /// A new random key, checked by unwrapping it the way the next launch will.
    init(newIn enclave: any HistoryEnclave) throws {
        let dataKey = SymmetricKey(size: .bits256)
        let record = try HistoryKeyRecord(wrapping: dataKey, for: enclave.makeKey())
        guard try record.unwrap(with: enclave) == dataKey else { throw HistoryKeyError.unusableKey }
        self.record = record
        self.dataKey = dataKey
    }

    /// A history file: header, then AES-256-GCM (nonce, ciphertext, tag). The header is
    /// authenticated.
    func seal(_ json: Data) throws -> Data {
        let header = BoundHistoryFile.header(keyID: record.id)
        guard let combined = try AES.GCM.seal(json, using: dataKey, authenticating: header).combined else {
            throw HistoryKeyError.cannotOpen
        }
        return header + combined
    }

    func open(_ file: Data) throws -> Data {
        let parts = try BoundHistoryFile.parse(file)
        // Another key: after a deletion and a restore, for example. Said before trying.
        guard parts.keyID == record.id else { throw HistoryKeyError.cannotOpen }
        do {
            return try AES.GCM.open(AES.GCM.SealedBox(combined: parts.sealed), using: dataKey, authenticating: parts.header)
        } catch {
            throw HistoryKeyError.cannotOpen
        }
    }
}

/// The history file bound to this Mac, format 2: `"NWHISTORY" | version (2) | key id (16) |
/// AES-GCM`. Format 1, up to 0.1.0, is the bare AES-GCM box under the key derived from the
/// hardware UUID (`HistoryCrypto`): no header.
enum BoundHistoryFile {
    static let magic = Data("NWHISTORY".utf8)
    static let version: UInt8 = 2
    private static let headerLength = magic.count + 1 + HistoryKeyRecord.idLength

    static func header(keyID: Data) -> Data { magic + Data([version]) + keyID }

    /// Whether this is a file bound to a Mac (of any version), not the old format.
    static func isBound(_ file: Data) -> Bool { file.starts(with: magic) }

    /// Throws when there is a file and it cannot be read.
    static func isBound(at url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return isBound(try start(of: url))
    }

    /// Whether a folder holds a file sealed with this key (a copy the user made of the history),
    /// or could: something in it cannot be read.
    static func folder(_ folder: URL, mayHoldFileSealedWith keyID: Data) -> Bool {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return true }
        return names.contains { name in
            let url = folder.appendingPathComponent(name)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes?[.type] as? FileAttributeType == .typeRegular else { return false }
            guard let start = try? start(of: url) else { return true }
            return isBound(start) && start.count == headerLength && Data(start.suffix(HistoryKeyRecord.idLength)) == keyID
        }
    }

    private static func start(of url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: headerLength) ?? Data()
    }

    static func parse(_ file: Data) throws -> (keyID: Data, header: Data, sealed: Data) {
        let file = Data(file) // indices from 0
        guard isBound(file), file.count > headerLength else { throw HistoryKeyError.cannotOpen }
        guard file[magic.count] == version else { throw HistoryKeyError.unknownVersion }
        let header = Data(file[..<headerLength])
        return (Data(header.suffix(HistoryKeyRecord.idLength)), header, Data(file[headerLength...]))
    }
}

// MARK: - Keyring

/// The enclave, and where the key record is kept.
struct HistoryKeyring {
    let enclave: any HistoryEnclave
    let storage: any HistoryKeyStorage

    /// The record kept, or `nil` when there is none.
    func record() throws -> HistoryKeyRecord? {
        try storage.read().map { try HistoryKeyRecord(bytes: $0) }
    }

    /// The key kept, or `nil` when there is none. Throws when there is one that cannot be used:
    /// it is never replaced here (the failure may be temporary).
    func existingKey() throws -> HistoryKey? {
        try record().map { try HistoryKey(unwrapping: $0, with: enclave) }
    }

    /// The key kept, or a new one, durably kept before it is returned.
    /// - Parameter settingUnusableAside: a record that cannot be used makes room for a new one.
    func existingOrNewKey(settingUnusableAside: Bool = false) throws -> HistoryKey {
        let record = try storage.read()
        var existing: HistoryKey?
        do {
            existing = try existingKey()
        } catch {
            if !settingUnusableAside || error as? HistoryKeyError == .timedOut || error as? HistoryKeyError == .unknownVersion {
                throw error
            }
        }
        if let existing {
            // It may come from an interrupted launch.
            try storage.makeDurable()
            return existing
        }
        let key = try HistoryKey(newIn: enclave)
        if let record {
            // Only the one that could not be used.
            guard try storage.read() == record else { throw HistoryKeyError.recordChanged }
            try storage.setAside()
        }
        do {
            try storage.create(key.record.bytes)
        } catch HistoryKeyError.recordExists {
            // Another instance was faster: one key for both.
            guard let existing = try existingKey() else { throw HistoryKeyError.recordExists }
            return existing
        }
        return key
    }

    /// Called before every save: nothing is ever sealed with a key whose record is not kept. A
    /// record that went missing while the app runs is put back; another one stops the save.
    func keepRecord(of key: HistoryKey) throws {
        guard let stored = try storage.read() else {
            try storage.create(key.record.bytes)
            return
        }
        guard stored == key.record.bytes else { throw HistoryKeyError.recordChanged }
    }
}
