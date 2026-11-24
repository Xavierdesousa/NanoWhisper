import Darwin
import Foundation

// MARK: - Key storage

/// Where the history's key record is kept. A file today (`HistoryKeyFile`); kept behind this
/// protocol so that a later build can keep it in the Data Protection Keychain without a new
/// history format (docs/wiki/architecture.md, "History storage").
protocol HistoryKeyStorage {
    /// Whether a record is kept (readable or not).
    var hasRecord: Bool { get }
    /// The record kept, or `nil` when there is none. Throws when it cannot be read, which is
    /// not the same thing.
    func read() throws -> Data?
    /// Keep a record, durably. Throws `HistoryKeyError.recordExists` rather than replace one.
    func create(_ record: Data) throws
    /// Make sure the record found survives a power cut: called before a history is first sealed
    /// with a key that was already there.
    func makeDurable() throws
    /// Remove the record. Only once no history encrypted with it remains.
    /// - Returns: whether nothing is kept any more.
    func remove() -> Bool
    /// Make room for another record without losing this one: it can be put back by hand.
    func setAside() throws
}

/// The key record in a file next to the history (`history.key`, readable by the user only).
struct HistoryKeyFile: HistoryKeyStorage {
    let url: URL

    /// `history.key` next to a history file.
    init(besideHistoryAt historyURL: URL) {
        url = historyURL.deletingLastPathComponent().appendingPathComponent("history.key")
    }

    var hasRecord: Bool { FileManager.default.fileExists(atPath: url.path) }

    func read() throws -> Data? { try PrivateFile.read(url) }

    func create(_ record: Data) throws {
        PrivateFile.removeLeftovers(of: url)
        let staged = try PrivateFile.stage(record, for: url, durably: true)
        do {
            try PrivateFile.moveWithoutReplacing(staged, to: url)
        } catch {
            unlink(staged.path)
            throw error
        }
        try makeDurable()
    }

    /// The history must never reach the disk before its key.
    func makeDurable() throws {
        guard PrivateFile.syncFolder(of: url) else { throw POSIXError(.EIO) }
    }

    func remove() -> Bool {
        PrivateFile.removeLeftovers(of: url)
        TemporaryRecordings.securelyDelete(at: url)
        return !hasRecord
    }

    func setAside() throws {
        let aside = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).unused-\(UUID().uuidString)")
        try PrivateFile.moveWithoutReplacing(url, to: aside)
    }
}

// MARK: - Files

/// Files readable by the user only (mode 0600), written so that an interruption leaves either
/// the previous file or the new one.
///
/// New content is first written next to the file, as `<name>.writing-<UUID>`. Such a file left
/// by a crash is never read: it is removed at a later launch.
enum PrivateFile {
    /// The file's content, or `nil` when there is no file. Any other failure throws: a file
    /// that cannot be read is not a missing file.
    static func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    /// Replace (or create) a file with `data`, mode 0600.
    static func replace(_ url: URL, with data: Data) throws {
        let target = url.resolvingSymlinksInPath()
        let staged = try stage(data, for: target, durably: false)
        do {
            try move(staged, over: target)
        } catch {
            unlink(staged.path)
            throw error
        }
    }

    /// Write `data` next to `url`, mode 0600.
    /// - Parameter durably: flush to the disk itself (`F_FULLFSYNC`), not only to the drive.
    static func stage(_ data: Data, for url: URL, durably: Bool) throws -> URL {
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent)\(stagingInfix)\(UUID().uuidString)")
        let file = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw posixError() }
        do {
            defer { Darwin.close(file) }
            // `open` applies the umask; this does not.
            guard fchmod(file, 0o600) == 0 else { throw posixError() }
            try write(data, to: file)
            guard durably ? fullSync(file) : fsync(file) == 0 else { throw posixError() }
        } catch {
            unlink(staged.path)
            throw error
        }
        return staged
    }

    static func move(_ staged: URL, over url: URL) throws {
        guard rename(staged.path, url.path) == 0 else { throw posixError() }
    }

    /// Throws `HistoryKeyError.recordExists` when there is already a file.
    static func moveWithoutReplacing(_ staged: URL, to url: URL) throws {
        guard renamex_np(staged.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            throw errno == EEXIST ? HistoryKeyError.recordExists : posixError()
        }
    }

    /// The inode: whether a path still names the file that was written there.
    static func fileNumber(_ url: URL) -> UInt64? {
        var info = stat()
        return stat(url.path, &info) == 0 ? info.st_ino : nil
    }

    /// Flush a rename to the disk.
    static func syncFolder(of url: URL) -> Bool {
        let folder = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        guard folder >= 0 else { return false }
        defer { Darwin.close(folder) }
        return fullSync(folder)
    }

    private static let stagingInfix = ".writing-"

    /// Files left by an interrupted write of `url`: only names this type makes.
    static func leftovers(of url: URL) -> [URL] {
        let target = url.resolvingSymlinksInPath()
        let folder = target.deletingLastPathComponent()
        let prefix = target.lastPathComponent + stagingInfix
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names
            .filter { $0.hasPrefix(prefix) && UUID(uuidString: String($0.dropFirst(prefix.count))) != nil }
            .map { folder.appendingPathComponent($0) }
    }

    static func removeLeftovers(of url: URL) {
        for leftover in leftovers(of: url) { unlink(leftover.path) }
    }

    /// Create the folder readable by the user only (0700), or make an existing one so.
    static func makeFolderPrivate(_ url: URL) {
        try? FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              info.st_mode & 0o7777 != 0o700 else { return }
        chmod(url.path, 0o700)
    }

    private static func write(_ data: Data, to file: Int32) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(file, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
    }

    /// `F_FULLFSYNC`, or `fsync` on a volume that does not support it.
    private static func fullSync(_ file: Int32) -> Bool {
        fcntl(file, F_FULLFSYNC) == 0 || fsync(file) == 0
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
