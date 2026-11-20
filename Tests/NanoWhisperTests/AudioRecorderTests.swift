import AVFoundation
import Foundation
import os
import Testing
@testable import NanoWhisper

/// `RecordingWriter`: conversion to 16 kHz mono and a WAV that is complete once `finish()`
/// returns (the crash of 2026-11-20 left a WAV whose header said "0 bytes of audio").
@Suite("Recording writer")
final class RecordingWriterTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url() -> URL { directory.appendingPathComponent("\(UUID().uuidString).wav") }

    /// A 440 Hz tone: `frames` frames at `sampleRate`, every channel the same.
    static func tone(frames: AVAudioFrameCount, sampleRate: Double, channels: AVAudioChannelCount) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for i in 0..<Int(frames) {
                buffer.floatChannelData![channel][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / Float(sampleRate))
            }
        }
        return buffer
    }

    /// The `data` chunk size written in the WAV header.
    static func headerDataSize(_ url: URL) throws -> UInt32 {
        let header = try Data(contentsOf: url).prefix(8192)
        let range = try #require(header.range(of: Data("data".utf8)))
        return header.subdata(in: range.upperBound..<(range.upperBound + 4))
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    @Test("48 kHz input: one second becomes 16,000 frames, and the header has the final size")
    func convertsAndFinalizes() throws {
        let url = url()
        let writer = try RecordingWriter(url: url)
        let input = Self.tone(frames: 4800, sampleRate: 48000, channels: 1)
        try writer.setInputFormat(input.format)
        for _ in 0..<10 {
            #expect(writer.append(input) != nil)
        }
        writer.finish()
        #expect(writer.isFinished)

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 16000)
        #expect(file.fileFormat.channelCount == 1)
        // The sample-rate converter's priming takes up to 240 frames (15 ms) once.
        #expect(abs(file.length - 16000) <= 256)
        #expect(file.length == writer.framesWritten)
        #expect(try Self.headerDataSize(url) == UInt32(file.length) * 4)
    }

    @Test("Stereo 44.1 kHz input is converted to 16 kHz mono")
    func convertsStereo() throws {
        let url = url()
        let writer = try RecordingWriter(url: url)
        let input = Self.tone(frames: 4410, sampleRate: 44100, channels: 2)
        try writer.setInputFormat(input.format)
        for _ in 0..<10 {
            _ = writer.append(input)
        }
        writer.finish()
        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(file.length - 16000) <= 256)
    }

    @Test("Nothing is written after finish, and finish is idempotent")
    func finishStopsWriting() throws {
        let url = url()
        let writer = try RecordingWriter(url: url)
        let input = Self.tone(frames: 4800, sampleRate: 48000, channels: 1)
        try writer.setInputFormat(input.format)
        _ = writer.append(input)
        writer.finish()
        let frames = writer.framesWritten
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int

        #expect(writer.append(input) == nil)
        writer.finish()
        #expect(writer.framesWritten == frames)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int == size)
    }

    @Test("Input format change mid-recording: a stale buffer is skipped, the new one is written to the same file")
    func inputFormatChange() throws {
        let url = url()
        let writer = try RecordingWriter(url: url)
        let before = Self.tone(frames: 4800, sampleRate: 48000, channels: 1)
        let after = Self.tone(frames: 2400, sampleRate: 24000, channels: 2)
        try writer.setInputFormat(before.format)
        _ = writer.append(before)

        try writer.setInputFormat(after.format)
        #expect(writer.append(before) == nil) // in flight from the previous input
        for _ in 0..<5 {
            #expect(writer.append(after) != nil)
        }
        writer.finish()
        let file = try AVAudioFile(forReading: url)
        // 0.1 s before the change + 0.5 s after it, minus each converter's priming.
        #expect(abs(file.length - 9600) <= 512)
    }

    @Test("Appends from another thread while finishing: the file stays readable")
    func concurrentFinish() async throws {
        let url = url()
        let writer = try RecordingWriter(url: url)
        try writer.setInputFormat(Self.tone(frames: 1, sampleRate: 48000, channels: 1).format)
        let appending = Thread {
            let input = Self.tone(frames: 4096, sampleRate: 48000, channels: 1)
            for _ in 0..<2000 {
                _ = writer.append(input)
            }
        }
        appending.start()
        try await Task.sleep(for: .milliseconds(20))
        writer.finish()
        let frames = writer.framesWritten
        let file = try AVAudioFile(forReading: url)
        #expect(file.length == frames)
        #expect(try Self.headerDataSize(url) == UInt32(frames) * 4)
    }

    @Test("Level: silence is 0, a full-scale signal is 1")
    func level() {
        #expect(AudioRecorder.level(of: []) == 0)
        #expect(AudioRecorder.level(of: [Float](repeating: 0, count: 100)) == 0)
        #expect(AudioRecorder.level(of: [Float](repeating: 1, count: 100)) == 1)
        // 0.01 RMS → boosted 0.25 → sqrt 0.5.
        // RMS 0.01 is −40 dBFS: (−40 + 55) / 40.
        #expect(abs(AudioRecorder.level(of: [Float](repeating: 0.01, count: 100)) - 0.375) < 0.0001)
        // −15 dBFS and louder is the top.
        #expect(AudioRecorder.level(of: [Float](repeating: 0.2, count: 100)) == 1)
        #expect(AudioRecorder.level(of: [Float](repeating: 0.0005, count: 100)) == 0)
    }
}

/// Stands in for `AVAudioEngine`: records the calls and delivers buffers to the tap like the
/// tap queue would. No real audio input is opened.
@MainActor
final class FakeInputEngine: AudioInputEngine {
    struct Failure: Error {}

    var inputFormat: AVAudioFormat
    var isInputAvailable = true
    var configurationChangeObject: AnyObject { self }
    var startError: (any Error)?
    private(set) var calls: [String] = []
    private(set) var isRunning = false
    private var tap: AVAudioNodeTapBlock?

    init(format: AVAudioFormat) {
        inputFormat = format
    }

    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
        calls.append("installTap \(Int(format.sampleRate))")
        tap = block
    }

    func removeTap() {
        // Removing the tap of a running engine is what crashed (2026-11-20).
        calls.append(isRunning ? "removeTap WHILE RUNNING" : "removeTap")
    }

    func start() throws {
        calls.append("start")
        if let startError { throw startError }
        isRunning = true
    }

    func stop() {
        calls.append("stop")
        isRunning = false
    }

    /// A buffer from the input, also after the tap was removed (a delivery already queued).
    func deliver(_ buffer: AVAudioPCMBuffer) {
        tap?(buffer, AVAudioTime(hostTime: 0))
    }

    /// What CoreAudio does when the input hardware changes: the engine stops itself, then the
    /// notification is posted from another thread.
    func simulateConfigurationChange(to format: AVAudioFormat) {
        isRunning = false
        inputFormat = format
        DispatchQueue.global().async { [self] in
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: self)
        }
    }
}

@Suite("Audio recorder (fake input)")
@MainActor
final class AudioRecorderTests {
    private let directory: URL
    private let mono48k = RecordingWriterTests.tone(frames: 4800, sampleRate: 48000, channels: 1)
    private let stereo44k = RecordingWriterTests.tone(frames: 4410, sampleRate: 44100, channels: 2)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioRecorderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func recorder(_ engine: FakeInputEngine) -> AudioRecorder {
        AudioRecorder(makeEngine: { engine }, directory: directory)
    }

    /// Waits for the main queue to run the recorder's notification handler.
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test("Stop: the engine is stopped before the tap is removed, and the WAV is complete when returned")
    func stopOrderAndFinalizedFile() throws {
        let engine = FakeInputEngine(format: mono48k.format)
        let recorder = recorder(engine)
        let samples = OSAllocatedUnfairLock(initialState: 0)
        try recorder.startRecording(onSamples: { chunk in samples.withLock { $0 += chunk.count } })
        #expect(recorder.isRecording)
        for _ in 0..<10 {
            engine.deliver(mono48k)
        }

        let url = try #require(recorder.stopRecording())
        #expect(engine.calls == ["installTap 48000", "start", "stop", "removeTap"])
        #expect(!recorder.isRecording)
        let file = try AVAudioFile(forReading: url)
        #expect(abs(file.length - 16000) <= 256)
        #expect(try RecordingWriterTests.headerDataSize(url) == UInt32(file.length) * 4)
        #expect(samples.withLock { $0 } == Int(file.length))
    }

    @Test("A buffer delivered after stop writes nothing")
    func lateBufferIgnored() throws {
        let engine = FakeInputEngine(format: mono48k.format)
        let recorder = recorder(engine)
        try recorder.startRecording()
        engine.deliver(mono48k)
        let url = try #require(recorder.stopRecording())
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        engine.deliver(mono48k)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int == size)
    }

    @Test("Input change mid-recording: recording goes on with the new format in the same file")
    func inputChangeContinues() async throws {
        let engine = FakeInputEngine(format: mono48k.format)
        let recorder = recorder(engine)
        var lost = false
        recorder.onInputLost = { lost = true }
        try recorder.startRecording()
        for _ in 0..<5 {
            engine.deliver(mono48k)
        }

        engine.simulateConfigurationChange(to: stereo44k.format)
        await waitUntil { engine.calls.count >= 6 }
        #expect(engine.calls == [
            "installTap 48000", "start", "stop", "removeTap", "installTap 44100", "start",
        ])
        engine.deliver(mono48k) // queued before the change: skipped
        for _ in 0..<5 {
            engine.deliver(stereo44k)
        }
        let url = try #require(recorder.stopRecording())
        #expect(!lost)
        #expect(!engine.calls.contains("removeTap WHILE RUNNING"))
        let file = try AVAudioFile(forReading: url)
        // 0.5 s before + 0.5 s after, minus each converter's priming.
        #expect(abs(file.length - 16000) <= 512)
    }

    @Test("Input change and the engine cannot restart: the file is finalized and onInputLost is called")
    func inputChangeFails() async throws {
        let engine = FakeInputEngine(format: mono48k.format)
        let recorder = recorder(engine)
        var lost = false
        recorder.onInputLost = { lost = true }
        try recorder.startRecording()
        for _ in 0..<5 {
            engine.deliver(mono48k)
        }
        engine.startError = FakeInputEngine.Failure()
        engine.simulateConfigurationChange(to: stereo44k.format)
        await waitUntil { lost }
        #expect(lost)

        // What AppState does on onInputLost.
        let url = try #require(recorder.stopRecording())
        let file = try AVAudioFile(forReading: url)
        #expect(abs(file.length - 8000) <= 256)
        #expect(try RecordingWriterTests.headerDataSize(url) == UInt32(file.length) * 4)
        #expect(!engine.calls.contains("removeTap WHILE RUNNING"))
    }

    @Test("Input unplugged mid-recording: no tap on a missing input, file finalized, onInputLost")
    func inputUnplugged() async throws {
        let engine = FakeInputEngine(format: mono48k.format)
        let recorder = recorder(engine)
        var lost = false
        recorder.onInputLost = { lost = true }
        try recorder.startRecording()
        engine.deliver(mono48k)
        engine.isInputAvailable = false
        engine.simulateConfigurationChange(to: mono48k.format)
        await waitUntil { lost }
        #expect(lost)
        #expect(engine.calls.filter { $0.hasPrefix("installTap") }.count == 1)
        let url = try #require(recorder.stopRecording())
        #expect(try AVAudioFile(forReading: url).length > 0)
    }

    @Test("No input at start: noInput is thrown and no file is left behind")
    func noInputAtStart() throws {
        let engine = FakeInputEngine(format: mono48k.format)
        engine.isInputAvailable = false
        let recorder = recorder(engine)
        #expect(throws: AudioRecorder.RecorderError.self) { try recorder.startRecording() }
        #expect(engine.calls.isEmpty || !engine.calls.contains { $0.hasPrefix("installTap") })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("The engine fails to start: the error is thrown and no file is left behind")
    func startFailure() throws {
        let engine = FakeInputEngine(format: mono48k.format)
        engine.startError = FakeInputEngine.Failure()
        let recorder = recorder(engine)
        #expect(throws: FakeInputEngine.Failure.self) { try recorder.startRecording() }
        #expect(!recorder.isRecording)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(recorder.stopRecording() == nil)
    }
}

