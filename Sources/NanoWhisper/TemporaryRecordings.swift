import Foundation

/// The WAV files a recording writes to the temp directory until it has been transcribed.
enum TemporaryRecordings {
    /// Overwrite a file with zeros, then delete it. Best effort: on APFS (copy-on-write) and
    /// SSDs the old blocks may survive the overwrite, so this makes recovery harder but does
    /// not guarantee erasure. The file is deleted even if the overwrite fails. With another hard
    /// link to it (a copy that is not the app's) it is deleted without the overwrite.
    static func securelyDelete(at url: URL) {
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            var info = stat()
            if fstat(fileHandle.fileDescriptor, &info) == 0, info.st_nlink <= 1,
               let fileSize = try? fileHandle.seekToEnd(),
               (try? fileHandle.seek(toOffset: 0)) != nil {
                try? fileHandle.write(contentsOf: Data(count: Int(fileSize)))
            }
            try? fileHandle.close()
        }
        try? FileManager.default.removeItem(at: url)
    }

    // Recordings left by a crash are no longer deleted at launch: they are transcribed once
    // into History, or deleted when they cannot be (`InterruptedRecordings`).
}
