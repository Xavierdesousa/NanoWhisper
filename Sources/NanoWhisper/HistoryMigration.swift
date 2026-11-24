import Darwin
import Foundation
import os

/// Re-encrypts a history file in the old format (up to 0.1.0: key derived from the hardware UUID)
/// with a key bound to this Mac.
///
/// The old file stays in place, untouched, until the new one is on disk, read back from there
/// through the enclave and compared entry by entry; it is then replaced in one rename. Every
/// failure before that leaves the old file as it was. What a crash leaves at each step, and what
/// the next launch does: docs/wiki/architecture.md, "History storage".
struct HistoryMigration {
    /// Points where a crash can happen, in order. Tests stop, fail or copy the folder there.
    enum Step: CaseIterable, Sendable {
        /// The key record is on disk; the history is the old file.
        case keyStored
        /// The new file is written next to the old one.
        case staged
        /// The new file was read back and compared.
        case verified
        /// The new file took the place of the old one.
        case replaced
        /// `recordBound` was called.
        case recorded
        /// The old file's bytes were overwritten.
        case erased
    }

    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "HistoryMigration")

    let fileURL: URL
    let keyring: HistoryKeyring
    /// Remembers that this history is bound to this Mac: the old format is refused from then on.
    let recordBound: () -> Void
    /// A key record that cannot be used makes room for a new one (the user asked for this file).
    var setsUnusableKeyAside = false
    var checkpoint: (Step) throws -> Void = { _ in }

    /// - Parameters:
    ///   - oldFile: the old file's bytes, as read.
    ///   - json: what they decrypt to. Re-encrypted as it is, so nothing is lost in decoding.
    ///   - entries: `json` decoded.
    /// - Returns: the key the history file now uses.
    func run(oldFile: Data, json: Data, entries: [HistoryEntry]) throws -> HistoryKey {
        let target = fileURL.resolvingSymlinksInPath()
        let key = try keyring.existingOrNewKey(settingUnusableAside: setsUnusableKeyAside)
        try checkpoint(.keyStored)
        let sealed = try key.seal(json)
        let staged = try PrivateFile.stage(sealed, for: target, durably: true)
        let stagedFile = PrivateFile.fileNumber(staged)
        let old: OldHistoryFile
        do {
            try checkpoint(.staged)
            try verify(staged, json: json, entries: entries)
            try checkpoint(.verified)
            old = try OldHistoryFile(at: target, expecting: oldFile)
        } catch {
            unlink(staged.path)
            throw error
        }
        defer { old.close() }
        do {
            try PrivateFile.move(staged, over: target)
        } catch {
            unlink(staged.path)
            throw error
        }
        try? checkpoint(.replaced)
        guard (try? Data(contentsOf: target)) == sealed else {
            // Not what was verified a moment ago: back to the old file, unless another process
            // wrote its own file meanwhile (that one is left alone).
            if PrivateFile.fileNumber(target) == stagedFile { try PrivateFile.replace(target, with: oldFile) }
            throw HistoryKeyError.fileChanged
        }
        // The old bytes go only once the new file cannot be lost to a power cut.
        guard PrivateFile.syncFolder(of: target) else {
            Self.logger.error("The history folder could not be flushed; the old bytes were not overwritten")
            return key
        }
        recordBound()
        try? checkpoint(.recorded)
        old.overwrite()
        try? checkpoint(.erased)
        return key
    }

    /// Read the staged file the way the next launch will: key record from its place, unwrapped
    /// by the enclave, file from the disk.
    private func verify(_ staged: URL, json: Data, entries: [HistoryEntry]) throws {
        guard let key = try keyring.existingKey() else { throw HistoryKeyError.noRecord }
        let opened = try key.open(Data(contentsOf: staged))
        guard opened == json, try JSONDecoder().decode([HistoryEntry].self, from: opened) == entries else {
            throw HistoryKeyError.cannotOpen
        }
    }
}

/// The old file, held open across the rename that replaces it, so that its bytes can be
/// overwritten once nothing points to them any more (best effort on APFS, like
/// `TemporaryRecordings.securelyDelete`).
private struct OldHistoryFile {
    private let file: Int32
    private let size: Int

    /// Throws unless the file still holds the bytes that were read.
    init(at url: URL, expecting data: Data) throws {
        file = Darwin.open(url.path, O_RDWR | O_CLOEXEC)
        guard file >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        size = data.count
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: false)
        guard let current = try? handle.readToEnd() ?? Data(), current == data else {
            Darwin.close(file)
            throw HistoryKeyError.fileChanged
        }
    }

    /// Zeros over the old bytes, unless another name still points to them: that copy is not
    /// the app's (a hard link made as a backup).
    func overwrite() {
        var info = stat()
        guard fstat(file, &info) == 0, info.st_nlink == 0 else { return }
        Data(count: size).withUnsafeBytes { _ = pwrite(file, $0.baseAddress, size, 0) }
        _ = fcntl(file, F_FULLFSYNC)
    }

    func close() { Darwin.close(file) }
}
