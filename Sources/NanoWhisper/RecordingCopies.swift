import AVFoundation
import FluidAudio
import Foundation

/// Plain copies of a recording that FluidAudio made in the temp directory for recordings over
/// about 30 s, until `Transcriber.asrConfig` stopped it, and that a crash of an earlier version
/// left there.
///
/// Their names (`fluidaudio-streaming-<UUID>.raw`) and attributes do not say which app made them,
/// and other apps use FluidAudio. Only a file whose bytes are exactly the samples of one of this
/// build's own recordings, still in the same directory, is known to be ours; the others are left
/// alone, and not even opened unless their size matches.
enum RecordingCopies {
    static func isCopyName(_ name: String) -> Bool {
        let prefix = "fluidaudio-streaming-", suffix = ".raw"
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return false }
        return UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(suffix.count))) != nil
    }

    /// Zeroes and deletes the copies of `recordings` found among `contents`.
    /// - Returns: how many were deleted.
    static func remove(of recordings: [URL], among contents: [URL]) -> Int {
        var copies = contents.filter { isCopyName($0.lastPathComponent) && OwnedFile.exists(at: $0) }
        var deleted = 0
        for recording in recordings where !copies.isEmpty && OwnedFile.exists(at: recording) {
            copies.removeAll { copy in
                guard isCopy(copy, of: recording) else { return false }
                TemporaryRecordings.securelyDelete(at: copy)
                deleted += 1
                return true
            }
        }
        return deleted
    }

    /// Shorter recordings were never copied.
    static let minimumFrames = AVAudioFramePosition(ASRConfig.default.streamingThreshold)

    /// Whether `copy` holds exactly the samples of `recording` (16 kHz mono Float32, as the
    /// recorder writes it; FluidAudio's copy of those is unchanged).
    static func isCopy(_ copy: URL, of recording: URL) -> Bool {
        guard let audio = try? AVAudioFile(forReading: recording),
              audio.processingFormat.sampleRate == RecordingWriter.outputFormat.sampleRate,
              audio.processingFormat.channelCount == 1, audio.length > minimumFrames,
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16_384),
              let file = OwnedFile.open(copy, O_RDONLY) else { return false }
        let handle = FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard file.size == audio.length * Int64(MemoryLayout<Float>.stride) else { return false }
        var remaining = audio.length
        while remaining > 0 {
            // One read can return fewer frames than asked for.
            guard (try? audio.read(into: buffer, frameCount: AVAudioFrameCount(min(remaining, 16_384)))) != nil,
                  buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else { return false }
            let expected = Data(bytes: samples, count: Int(buffer.frameLength) * MemoryLayout<Float>.stride)
            guard let bytes = try? handle.read(upToCount: expected.count), bytes == expected else { return false }
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        return true
    }
}
