import Foundation

/// The WAV files a recording writes to the temp directory until it has been transcribed.
enum TemporaryRecordings {
    /// Overwrite a file with zeros before deleting it, so the audio cannot be recovered from
    /// the freed blocks.
    static func securelyDelete(at url: URL) {
        if let fileHandle = try? FileHandle(forWritingTo: url) {
            let fileSize = fileHandle.seekToEndOfFile()
            fileHandle.seek(toFileOffset: 0)
            let zeroData = Data(count: Int(fileSize))
            fileHandle.write(zeroData)
            fileHandle.closeFile()
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
