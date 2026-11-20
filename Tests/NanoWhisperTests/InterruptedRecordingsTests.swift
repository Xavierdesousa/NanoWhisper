import AVFoundation
import Foundation
import Testing
@testable import NanoWhisper

/// Recordings left by a crash: header repair, which ones are kept, and the silent recovery to
/// History. Temporary directories and fake transcriptions only.
@Suite("Interrupted recordings")
@MainActor
final class InterruptedRecordingsTests {
    private let directory: URL
    private let debug = BuildFlavor(bundleIdentifier: "com.moonji.nanowhisper.debug")
    private let production = BuildFlavor(bundleIdentifier: "com.moonji.nanowhisper")

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterruptedRecordingsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    /// A 16 kHz mono Float32 WAV written by `RecordingWriter`, as the recorder writes it.
    /// With `crashed`, the bytes on disk are copied while the file is still open, before its
    /// header got its sizes: what a crash leaves.
    private func recording(
        seconds: Double, flavor: BuildFlavor? = nil, crashed: Bool = false, name: String? = nil
    ) throws -> URL {
        let flavor = flavor ?? debug
        let url = directory.appendingPathComponent(name ?? flavor.temporaryAudioFileName())
        let staging = directory.appendingPathComponent("staging-\(UUID().uuidString).wav")
        let writer = try RecordingWriter(url: staging)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        try writer.setInputFormat(format)
        var remaining = Int(seconds * 48000)
        while remaining > 0 {
            let frames = min(4800, remaining)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            buffer.frameLength = AVAudioFrameCount(frames)
            for i in 0..<frames { buffer.floatChannelData![0][i] = 0.3 * sin(Float(i) * 0.05) }
            _ = writer.append(buffer)
            remaining -= frames
        }
        if crashed {
            try FileManager.default.copyItem(at: staging, to: url)
        }
        writer.finish()
        if crashed {
            try FileManager.default.removeItem(at: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: url)
        }
        return url
    }

    private func setCreationDate(_ date: Date, of url: URL) throws {
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func dataSize(_ url: URL) throws -> UInt32 {
        let header = try Data(contentsOf: url).prefix(8192)
        let range = try #require(header.range(of: Data("data".utf8)))
        return header.subdata(in: range.upperBound..<(range.upperBound + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    // MARK: - Header repair

    @Test("A crash leaves a header that says 0 bytes; the repair makes the samples readable")
    func headerRepair() throws {
        let url = try recording(seconds: 2, crashed: true)
        #expect(try dataSize(url) == 0, "the crash state: sizes not written yet")
        #expect(WAVHeader.repair(at: url) == .repaired)
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16000)
        // 2 s at 16 kHz, minus what the writer still buffered (converter priming).
        #expect(file.length > 30_000 && file.length <= 32_000)
        #expect(WAVHeader.repair(at: url) == .complete, "idempotent")
    }

    @Test("A complete file is left as it is; a non-WAV file is invalid")
    func headerUntouched() throws {
        let url = try recording(seconds: 1)
        let before = try Data(contentsOf: url)
        #expect(WAVHeader.repair(at: url) == .complete)
        #expect(try Data(contentsOf: url) == before)
        let text = directory.appendingPathComponent(debug.temporaryAudioFileName())
        try Data("not a wav".utf8).write(to: text)
        #expect(WAVHeader.repair(at: text) == .invalid)
    }

    // MARK: - Collect

    @Test("Kept: this build's crashed recordings with audio, repaired, oldest first")
    func collectKeeps() throws {
        let newer = try recording(seconds: 1.5, crashed: true)
        let older = try recording(seconds: 2, crashed: true)
        try setCreationDate(Date(timeIntervalSinceNow: -3600), of: older)
        let result = InterruptedRecordings.collect(in: directory, flavor: debug, historyAvailable: true)
        // By name: the directory listing resolves /var to /private/var.
        #expect(result.candidates.map(\.url.lastPathComponent) == [older, newer].map(\.lastPathComponent))
        #expect(result.repairedHeaders == 2)
        #expect(abs((result.candidates.first?.duration ?? 0) - 2) < 0.05)
    }

    @Test("Deleted: too short, too old, unreadable, already attempted; another build's files untouched")
    func collectDeletes() throws {
        let short = try recording(seconds: 0.1, crashed: true)
        let empty = try recording(seconds: 0, crashed: true)
        let old = try recording(seconds: 1, crashed: true)
        try setCreationDate(Date(timeIntervalSinceNow: -8 * 24 * 3600), of: old)
        let garbage = directory.appendingPathComponent(debug.temporaryAudioFileName())
        try Data(repeating: 7, count: 5000).write(to: garbage)
        let attempted = try recording(seconds: 2, name: "nanowhisper-debug_\(UUID().uuidString).attempted.wav")
        let other = try recording(seconds: 2, flavor: production, crashed: true)
        let unrelated = directory.appendingPathComponent("notes.wav")
        try Data("x".utf8).write(to: unrelated)

        let result = InterruptedRecordings.collect(in: directory, flavor: debug, historyAvailable: true)
        #expect(result.candidates.isEmpty)
        for url in [short, empty, old, garbage, attempted] {
            #expect(!exists(url), "\(url.lastPathComponent) deleted")
        }
        #expect(result.deletedAttempted == 1)
        #expect(result.deletedTooOld == 1)
        #expect(result.deletedTooShort + result.deletedUnreadable == 3)
        #expect(exists(other), "the production build's recording is not ours")
        #expect(try dataSize(other) == 0, "and is not even repaired")
        #expect(exists(unrelated))
    }

    @Test("History off: every recording is deleted without a transcription")
    func collectHistoryOff() throws {
        let url = try recording(seconds: 2, crashed: true)
        let result = InterruptedRecordings.collect(in: directory, flavor: debug, historyAvailable: false)
        #expect(result.candidates.isEmpty)
        #expect(result.deletedHistoryOff == 1)
        #expect(!exists(url))
    }

    // MARK: - Recovery

    private func recovery(
        idle: @escaping () -> Bool = { true },
        history: @escaping () -> Bool = { true },
        transcribe: @escaping (URL) async -> Transcriber.TranscriptionResult,
        added: @escaping (HistoryEntry) -> Void
    ) -> InterruptedRecordingRecovery {
        InterruptedRecordingRecovery(.init(
            isIdle: idle, historyAvailable: history, transcribe: transcribe, addToHistory: added,
            pollInterval: .milliseconds(10)
        ))
    }

    @Test("Each recording is transcribed once, as an attempted file, and deleted; the text goes to History at its date")
    func recoversToHistory() async throws {
        let url = try recording(seconds: 1.5, crashed: true)
        let date = Date(timeIntervalSinceNow: -600)
        try setCreationDate(date, of: url)
        let candidates = InterruptedRecordings.collect(in: directory, flavor: debug, historyAvailable: true).candidates
        var transcribed: [URL] = []
        var entries: [HistoryEntry] = []
        let summary = await recovery(transcribe: { url in
            transcribed.append(url)
            return .init(text: "Recovered words", debugInfo: nil)
        }, added: { entries.append($0) }).run(candidates)

        #expect(summary == .init(recovered: 1))
        #expect(transcribed.count == 1)
        #expect(transcribed.first?.lastPathComponent.hasSuffix(".attempted.wav") == true, "marked before the attempt")
        let attempted = try #require(transcribed.first)
        #expect(!exists(url) && !exists(attempted))
        #expect(entries.map(\.text) == ["Recovered words"])
        #expect(abs((entries.first?.date.timeIntervalSince(date)) ?? 99) < 1)
    }

    @Test("A crash during the attempt: the next launch deletes the file without a retry")
    func crashDuringAttemptIsNotRetried() async throws {
        let url = try recording(seconds: 1.5, crashed: true)
        let candidates = InterruptedRecordings.collect(in: directory, flavor: debug, historyAvailable: true).candidates
        // The attempt starts (renamed), then "crashes": the transcription never returns.
        let attempted = try InterruptedRecordings.markAttempted(try #require(candidates.first).url)
        #expect(!exists(url) && exists(attempted))

        let nextLaunch = InterruptedRecordings.collect(in: directory, flavor: debug, historyAvailable: true)
        #expect(nextLaunch.candidates.isEmpty)
        #expect(nextLaunch.deletedAttempted == 1)
        #expect(!exists(attempted))
    }

    @Test("Empty text or a failed transcription: nothing in History, the file is deleted anyway")
    func emptyOrFailed() async throws {
        _ = try recording(seconds: 1, crashed: true)
        _ = try recording(seconds: 1, crashed: true)
        let candidates = InterruptedRecordings.collect(in: directory, flavor: debug, historyAvailable: true).candidates
        var calls = 0
        var entries: [HistoryEntry] = []
        let summary = await recovery(transcribe: { _ in
            calls += 1
            return calls == 1 ? .init(text: "  ", debugInfo: nil) : .failed(.engineError)
        }, added: { entries.append($0) }).run(candidates)
        #expect(summary == .init(empty: 1, failed: 1))
        #expect(entries.isEmpty)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("nanowhisper-debug_") }
        #expect(left.isEmpty)
    }

    @Test("History turned off before the recovery ran: deleted without a transcription")
    func historyTurnedOff() async throws {
        _ = try recording(seconds: 1, crashed: true)
        let candidates = InterruptedRecordings.collect(in: directory, flavor: debug, historyAvailable: true).candidates
        var calls = 0
        // The engine never gets ready: the file is still deleted, without waiting.
        let summary = await recovery(idle: { false }, history: { false }, transcribe: { _ in
            calls += 1
            return .init(text: "x", debugInfo: nil)
        }, added: { _ in }).run(candidates)
        #expect(calls == 0)
        #expect(summary == .init(skipped: 1))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasPrefix("nanowhisper-debug_") }.isEmpty)
    }

    @Test("The user's dictation goes first: no recovery starts while the app is busy")
    func userDictationFirst() async throws {
        _ = try recording(seconds: 1, crashed: true)
        let candidates = InterruptedRecordings.collect(in: directory, flavor: debug, historyAvailable: true).candidates
        let transcriber = Transcriber()
        var order: [String] = []
        var releaseUser: CheckedContinuation<Void, Never>?
        transcriber.transcriptionHandler = { _, url in
            if url.lastPathComponent == "user.wav" {
                await withCheckedContinuation { releaseUser = $0 }
                order.append("user")
            } else {
                order.append("recovery")
            }
            return .init(text: "words", debugInfo: nil)
        }
        // A dictation is being transcribed when the recovery is ready to start.
        let user = Task { await transcriber.transcribe(audioURL: self.directory.appendingPathComponent("user.wav")) }
        while releaseUser == nil { await Task.yield() }
        let recovery = recovery(
            idle: { transcriber.pendingTranscriptions == 0 },
            transcribe: { await transcriber.transcribe(audioURL: $0) },
            added: { _ in }
        )
        let recovering = Task { await recovery.run(candidates) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(order.isEmpty, "the recovery waits while the user's transcription is pending")
        releaseUser?.resume()
        _ = await user.value
        let summary = await recovering.value
        #expect(order == ["user", "recovery"])
        #expect(summary.recovered == 1)
    }

    // MARK: - History insertion

    @Test("History: a recovered entry goes to its place by date, newest first")
    func historyInsertion() throws {
        let fileURL = directory.appendingPathComponent("history.json")
        let store = HistoryStore(fileURL: fileURL, key: { HistoryCrypto.key(fromHardwareUUID: "00000000-TEST-0000-0000-00000000000C") })
        let now = Date()
        store.add(HistoryEntry(text: "old", date: now.addingTimeInterval(-3600)), keepingAtMost: 10)
        store.add(HistoryEntry(text: "new", date: now), keepingAtMost: 10)
        store.insert(HistoryEntry(text: "recovered", date: now.addingTimeInterval(-600)), keepingAtMost: 10)
        #expect(store.entries.map(\.text) == ["new", "recovered", "old"])
        store.insert(HistoryEntry(text: "oldest", date: now.addingTimeInterval(-7200)), keepingAtMost: 10)
        #expect(store.entries.map(\.text) == ["new", "recovered", "old", "oldest"])
        // Full history: the oldest entry is the one dropped.
        store.insert(HistoryEntry(text: "middle", date: now.addingTimeInterval(-60)), keepingAtMost: 4)
        #expect(store.entries.map(\.text) == ["new", "middle", "recovered", "old"])
    }
}
