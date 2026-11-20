import Foundation

/// The WAV files a recording writes to the temp directory until it has been transcribed.
enum TemporaryRecordings {
    /// Overwrite a file with zeros, then delete it. Best effort: on APFS (copy-on-write) and
    /// SSDs the old blocks may survive the overwrite, so this makes recovery harder but does
    /// not guarantee erasure. The file is deleted even if the overwrite fails.
    static func securelyDelete(at url: URL) {
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            if let fileSize = try? fileHandle.seekToEnd(),
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
