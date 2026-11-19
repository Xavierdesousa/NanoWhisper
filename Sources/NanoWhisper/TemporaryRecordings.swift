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

    /// Remove recordings left by a previous crash of this build. Only this build's prefix is
    /// matched, so a recording in progress in the other build survives.
    static func removeOrphans(of flavor: BuildFlavor = .current) {
        let tempDir = FileManager.default.temporaryDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: nil
        ) else { return }

        for file in contents where flavor.ownsTemporaryAudioFile(named: file.lastPathComponent) {
            securelyDelete(at: file)
        }
    }
}
