import Darwin
import Foundation

/// The WAV files a recording writes to the temp directory until it has been transcribed.
enum TemporaryRecordings {
    /// How much is zeroed at a time (a long recording is hundreds of megabytes).
    static let zeroBlockSize = 256 * 1024

    /// Overwrite a file with zeros, then delete it. Best effort: on APFS (copy-on-write) and
    /// SSDs the old blocks may survive the overwrite, so this makes recovery harder but does
    /// not guarantee erasure. The file is deleted even if the overwrite fails.
    ///
    /// Only an `OwnedFile` is overwritten. Anything else at that path only loses that name: a
    /// symbolic link is removed and its target left alone, and a directory stays.
    static func securelyDelete(at url: URL) {
        if let file = OwnedFile.open(url, O_WRONLY) {
            overwriteWithZeros(file)
            close(file.descriptor)
        }
        unlink(url.path)
    }

    static func overwriteWithZeros(_ file: OwnedFile) {
        let zeros = [UInt8](repeating: 0, count: zeroBlockSize)
        var offset: off_t = 0
        while offset < file.size {
            let count = Int(min(off_t(zeroBlockSize), file.size - offset))
            let written = pwrite(file.descriptor, zeros, count, offset)
            if written < 0, errno == EINTR { continue }
            guard written > 0 else { return }
            offset += off_t(written)
        }
    }

    // Recordings left by a crash are no longer deleted at launch: they are transcribed once
    // into History, or deleted when they cannot be (`InterruptedRecordings`).
}

/// A file this app can have written: a regular file of the current user, under that only name
/// (one hard link). A symbolic link at that path is never followed.
struct OwnedFile {
    let descriptor: Int32
    let size: off_t

    /// Opens the file if it is one. The check is made on the open file, so it holds for what is
    /// then read or written. The caller closes `descriptor`.
    static func open(_ url: URL, _ accessMode: Int32) -> OwnedFile? {
        // O_NONBLOCK: do not wait for the other end of a named pipe.
        let descriptor = Darwin.open(url.path, accessMode | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        var info = stat()
        guard fstat(descriptor, &info) == 0, isOwned(info) else {
            close(descriptor)
            return nil
        }
        return OwnedFile(descriptor: descriptor, size: info.st_size)
    }

    /// Whether `url` is such a file, without opening it.
    static func exists(at url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && isOwned(info)
    }

    private static func isOwned(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFREG && info.st_uid == geteuid() && info.st_nlink == 1
    }
}
