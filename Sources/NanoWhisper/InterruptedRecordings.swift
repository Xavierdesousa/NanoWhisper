import AVFoundation
import Foundation
import os

/// Recordings left in the temp directory by a crash of this build, and their silent recovery:
/// at the next launch each one that holds audio is transcribed once, in the background, and
/// its text goes to History with the date it was recorded (the maintainer's rule, 2026-11-20:
/// no message, no paste, "as if nothing happened").
///
/// Exactly once, even if it crashes again: a recording is renamed `….attempted.wav` before it
/// is transcribed, and an attempted recording found at launch is deleted without a retry, so a
/// file that crashes the transcription cannot loop.
enum InterruptedRecordings {
    nonisolated static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "InterruptedRecordings")

    /// Shorter recordings are not worth a transcription (a tap of the hotkey).
    static let minimumDuration: TimeInterval = 0.3
    /// Older recordings are deleted: the dictation is no longer useful.
    static let maximumAge: TimeInterval = 7 * 24 * 3600
    static let attemptedSuffix = ".attempted.wav"

    /// A recording to transcribe.
    struct Candidate: Equatable, Sendable {
        let url: URL
        /// When the recording started (the file's creation date).
        let recordedAt: Date
        let duration: TimeInterval
    }

    /// What `collect` did, for the log (counts only: file names are not private, but text is).
    struct Collection: Equatable, Sendable {
        var candidates: [Candidate] = []
        var deletedAttempted = 0
        var deletedTooShort = 0
        var deletedTooOld = 0
        var deletedUnreadable = 0
        var deletedHistoryOff = 0
        var repairedHeaders = 0
        /// Copies of the recordings left by an earlier version (`RecordingCopies`).
        var deletedCopies = 0
        /// Not files this app can have written (`OwnedFile`): left alone.
        var ignored = 0
    }

    /// At launch: this build's leftovers in `directory`. Already attempted, too short, too old
    /// or unreadable recordings are deleted (zeroed first); with history off, all are deleted.
    /// The others get their WAV header repaired if the crash left it incomplete, and are
    /// returned oldest first. Other builds' files are never touched, nor is anything that is not
    /// a file this app can have written (a link, a directory, another user's file).
    /// Before that, the copies of these recordings left by an earlier version are deleted
    /// (`RecordingCopies`).
    static func collect(
        in directory: URL = FileManager.default.temporaryDirectory,
        flavor: BuildFlavor = .current,
        historyAvailable: Bool,
        now: Date = Date()
    ) -> Collection {
        var result = Collection()
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey]
        ) else { return result }

        // First: a copy is only known by the recording it copies.
        let recordings = contents.filter { flavor.ownsTemporaryAudioFile(named: $0.lastPathComponent) }
        result.deletedCopies = RecordingCopies.remove(of: recordings, among: contents)

        for url in recordings {
            guard OwnedFile.exists(at: url) else {
                result.ignored += 1
                continue
            }
            if url.lastPathComponent.hasSuffix(attemptedSuffix) {
                TemporaryRecordings.securelyDelete(at: url)
                result.deletedAttempted += 1
                continue
            }
            if !historyAvailable {
                TemporaryRecordings.securelyDelete(at: url)
                result.deletedHistoryOff += 1
                continue
            }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let recordedAt = values?.creationDate ?? values?.contentModificationDate ?? now
            if now.timeIntervalSince(recordedAt) > maximumAge {
                TemporaryRecordings.securelyDelete(at: url)
                result.deletedTooOld += 1
                continue
            }
            switch WAVHeader.repair(at: url) {
            case .repaired: result.repairedHeaders += 1
            case .complete: break
            case .invalid:
                TemporaryRecordings.securelyDelete(at: url)
                result.deletedUnreadable += 1
                continue
            }
            guard let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else {
                TemporaryRecordings.securelyDelete(at: url)
                result.deletedUnreadable += 1
                continue
            }
            let duration = Double(file.length) / file.fileFormat.sampleRate
            guard duration >= minimumDuration else {
                TemporaryRecordings.securelyDelete(at: url)
                result.deletedTooShort += 1
                continue
            }
            result.candidates.append(Candidate(url: url, recordedAt: recordedAt, duration: duration))
        }
        result.candidates.sort { $0.recordedAt < $1.recordedAt }
        return result
    }

    /// Rename `x.wav` to `x.attempted.wav` before transcribing it, so a crash during the
    /// attempt is never retried. Returns the new location. The file is checked again, since a
    /// recording may have waited for the engine after it was collected.
    static func markAttempted(_ url: URL) throws -> URL {
        guard OwnedFile.exists(at: url) else { throw CocoaError(.fileReadUnknown) }
        let name = url.deletingPathExtension().lastPathComponent + attemptedSuffix
        let attempted = url.deletingLastPathComponent().appendingPathComponent(name)
        try FileManager.default.moveItem(at: url, to: attempted)
        return attempted
    }
}

/// The parts of a RIFF/WAVE header that a crash leaves wrong: `AVAudioFile` writes the sizes
/// (RIFF size, `data` size, the `fact` frame count) when the file is closed, so a recording
/// interrupted by a crash says "0 bytes of audio" while its samples are in the file.
enum WAVHeader {
    enum Repair: Equatable {
        /// The sizes already match the file.
        case complete
        /// The sizes were rewritten from the file's length.
        case repaired
        /// Not a WAV file, or no `fmt ` / `data` chunk.
        case invalid
    }

    /// Rewrites the RIFF size, the `data` size (to the whole bytes after its header, in whole
    /// frames) and the `fact` frame count when they do not match the file's length.
    static func repair(at url: URL) -> Repair {
        guard let file = OwnedFile.open(url, O_RDWR) else { return .invalid }
        let handle = FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let fileLength = try? handle.seekToEnd(), fileLength >= 12,
              (try? handle.seek(toOffset: 0)) != nil,
              let riff = try? handle.read(upToCount: 12), riff.count == 12,
              riff.prefix(4) == Data("RIFF".utf8), riff.suffix(4) == Data("WAVE".utf8) else { return .invalid }

        var offset: UInt64 = 12
        var blockAlign: UInt64?
        var factSizeOffset: UInt64?
        var dataSizeOffset: UInt64?
        var dataStart: UInt64 = 0
        var declaredDataSize: UInt64 = 0
        while offset + 8 <= fileLength {
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let header = try? handle.read(upToCount: 8), header.count == 8 else { return .invalid }
            let id = String(decoding: header.prefix(4), as: UTF8.self)
            let size = UInt64(header.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            if id == "fmt " {
                guard let fmt = try? handle.read(upToCount: 14), fmt.count == 14 else { return .invalid }
                blockAlign = UInt64(fmt.subdata(in: 12..<14).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian)
            } else if id == "fact" {
                factSizeOffset = offset + 8
            } else if id == "data" {
                dataSizeOffset = offset + 4
                dataStart = offset + 8
                declaredDataSize = size
                break
            }
            offset += 8 + size + (size & 1)
        }
        guard let blockAlign, blockAlign > 0, let dataSizeOffset else { return .invalid }

        let available = fileLength - dataStart
        let dataSize = available - available % blockAlign
        let riffSize = fileLength - 8
        let declaredRIFF = UInt64(riff.subdata(in: 4..<8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
        guard declaredDataSize != dataSize || declaredRIFF != riffSize else { return .complete }
        // Only a header that undercounts is a crash's; never shrink what a file declares.
        guard declaredDataSize < dataSize || declaredDataSize > available,
              dataSize <= UInt64(UInt32.max), riffSize <= UInt64(UInt32.max) else { return .invalid }

        func write(_ value: UInt64, at position: UInt64) -> Bool {
            var little = UInt32(value).littleEndian
            return (try? handle.seek(toOffset: position)) != nil
                && (try? handle.write(contentsOf: Data(bytes: &little, count: 4))) != nil
        }
        guard write(riffSize, at: 4), write(dataSize, at: dataSizeOffset) else { return .invalid }
        if let factSizeOffset, !write(dataSize / blockAlign, at: factSizeOffset) { return .invalid }
        return .repaired
    }
}
