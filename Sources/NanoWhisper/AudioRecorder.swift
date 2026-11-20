import AVFoundation
import Combine
import os

/// The parts of `AVAudioEngine` the recorder uses. A seam for tests, which drive the recorder
/// with a fake engine instead of the real microphone.
@MainActor
protocol AudioInputEngine: AnyObject {
    /// The format the tap must use (it changes after a configuration change).
    var inputFormat: AVAudioFormat { get }
    /// Whether an input device with at least one channel is there (checked before installing
    /// a tap: a tap in a format the input cannot deliver raises an Objective-C exception).
    var isInputAvailable: Bool { get }
    /// The object of this engine's `AVAudioEngineConfigurationChange` notifications.
    var configurationChangeObject: AnyObject { get }
    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock)
    func removeTap()
    func start() throws
    func stop()
}

/// The real input: the default input device through `AVAudioEngine.inputNode`.
@MainActor
final class SystemAudioInputEngine: AudioInputEngine {
    private let engine = AVAudioEngine()

    var inputFormat: AVAudioFormat { engine.inputNode.outputFormat(forBus: 0) }
    var configurationChangeObject: AnyObject { engine }

    /// The hardware side of the input node (input scope), not its output format.
    var isInputAvailable: Bool {
        let hardware = engine.inputNode.inputFormat(forBus: 0)
        return hardware.sampleRate > 0 && hardware.channelCount > 0
    }

    func installTap(bufferSize: AVAudioFrameCount, format: AVAudioFormat, block: @escaping AVAudioNodeTapBlock) {
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format, block: block)
    }

    func removeTap() { engine.inputNode.removeTap(onBus: 0) }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}

/// Records the default input to a 16 kHz mono Float32 WAV in the temp directory (see
/// `RecordingWriter`), one engine per recording.
///
/// Stop order matters. `removeTap(onBus:)` on a running `AVAudioEngine` makes it clear the
/// HAL output unit's input callback while CoreAudio's IO thread may be about to call it; the
/// IO thread then jumps to a null pointer (crash of 2026-11-20, reproduced in a harness; see
/// the wiki's architecture page, "Stopping the recorder"). `stopRecording()` therefore stops
/// the engine first: `AVAudioEngine.stop()` returns once the IO thread has stopped, and only
/// then are the tap removed and the file closed.
@MainActor
final class AudioRecorder {
    nonisolated private static let logger = Logger(
        subsystem: BuildFlavor.current.logSubsystem, category: "AudioRecorder"
    )

    /// Current audio level (0.0 – 1.0), sent from the recording tap's thread.
    let audioLevelSubject = PassthroughSubject<Float, Never>()

    /// Called when the input changed during a recording (another device, sample rate or
    /// channel count) and recording could not continue on the new input. The audio recorded
    /// so far is kept and finalized; the caller should stop the recording.
    var onInputLost: (() -> Void)?

    private struct Recording {
        let engine: any AudioInputEngine
        let writer: RecordingWriter
        let onSamples: (@Sendable ([Float]) -> Void)?
        let configurationObserver: any NSObjectProtocol
    }

    private let makeEngine: () -> any AudioInputEngine
    private let directory: URL
    private var recording: Recording?

    var isRecording: Bool { recording != nil }

    /// - Parameters:
    ///   - makeEngine: a new engine for each recording (tests pass a fake).
    ///   - directory: where the WAV is written.
    init(
        makeEngine: @escaping () -> any AudioInputEngine = { SystemAudioInputEngine() },
        directory: URL = FileManager.default.temporaryDirectory
    ) {
        self.makeEngine = makeEngine
        self.directory = directory
    }

    /// - Parameter onSamples: receives a copy of every 16 kHz mono chunk written to the file
    ///   (live transcription). Called on the tap's thread; it must only enqueue.
    func startRecording(onSamples: (@Sendable ([Float]) -> Void)? = nil) throws {
        // Not expected (AppState stops before starting again); never leave a file behind.
        if let previous = stopRecording() {
            TemporaryRecordings.securelyDelete(at: previous)
        }
        let url = directory.appendingPathComponent(BuildFlavor.current.temporaryAudioFileName())
        let writer = try RecordingWriter(url: url)
        let engine = makeEngine()
        do {
            try installTap(on: engine, writer: writer, onSamples: onSamples)
            try engine.start()
        } catch {
            engine.stop()
            engine.removeTap()
            writer.finish()
            TemporaryRecordings.securelyDelete(at: url)
            throw error
        }

        // Posted on an AVAudioEngine thread. The handler only schedules the recovery: with
        // `queue: .main` the posting thread would wait for it, while the recovery calls back
        // into the engine (stop, start).
        let engineID = ObjectIdentifier(engine)
        let observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine.configurationChangeObject, queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.inputConfigurationChanged(engineID: engineID)
            }
        }
        recording = Recording(
            engine: engine, writer: writer, onSamples: onSamples, configurationObserver: observer
        )
    }

    /// Stops recording and returns the finalized WAV, or nil when nothing was recording.
    func stopRecording() -> URL? {
        guard let recording else { return nil }
        self.recording = nil
        NotificationCenter.default.removeObserver(recording.configurationObserver)
        // Stop first (see the type's comment): the IO thread is stopped when this returns.
        recording.engine.stop()
        recording.engine.removeTap()
        // Closes the file: the WAV header gets its final sizes. A tap block still in flight
        // finds the writer finished and writes nothing.
        recording.writer.finish()
        return recording.writer.url
    }

    /// The engine stopped itself because the input hardware changed (another default device,
    /// a Bluetooth headset connecting, a new sample rate). Continue on the new input, in the
    /// same file; if that is not possible, keep what was recorded and report it.
    private func inputConfigurationChanged(engineID: ObjectIdentifier) {
        guard let recording, ObjectIdentifier(recording.engine) == engineID else { return }
        let engine = recording.engine
        // The engine is already stopped by now; stopping again is harmless and keeps the
        // order safe if it is not.
        engine.stop()
        engine.removeTap()
        do {
            try installTap(on: engine, writer: recording.writer, onSamples: recording.onSamples)
            try engine.start()
            Self.logger.notice("Input changed during a recording; continuing on the new input")
        } catch {
            Self.logger.error("Input changed during a recording and could not restart: \(String(describing: error), privacy: .public)")
            engine.stop()
            engine.removeTap()
            recording.writer.finish()
            onInputLost?()
        }
    }

    private func installTap(
        on engine: any AudioInputEngine,
        writer: RecordingWriter,
        onSamples: (@Sendable ([Float]) -> Void)?
    ) throws {
        let format = engine.inputFormat
        guard engine.isInputAvailable, format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.noInput
        }
        try writer.setInputFormat(format)
        let block = Self.tapBlock(writer: writer, levels: audioLevelSubject, onSamples: onSamples)
        engine.installTap(bufferSize: 4096, format: format, block: block)
    }

    /// The tap block runs on AVAudioEngine's tap queue. It is made in a nonisolated function:
    /// formed inside this `@MainActor` class it would inherit main-actor isolation and trap in
    /// Swift 6's runtime isolation check when called off the main thread.
    nonisolated private static func tapBlock(
        writer: RecordingWriter,
        levels: PassthroughSubject<Float, Never>,
        onSamples: (@Sendable ([Float]) -> Void)?
    ) -> AVAudioNodeTapBlock {
        { buffer, _ in
            guard let converted = writer.append(buffer),
                  let channelData = converted.floatChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(converted.frameLength)))
            onSamples?(samples)
            levels.send(level(of: samples))
        }
    }

    /// RMS, boosted and square-rooted so quiet speech is still visible in the waveform.
    nonisolated static func level(of samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples {
            sum += sample * sample
        }
        let rms = (sum / Float(samples.count)).squareRoot()
        return min(rms * 25.0, 1.0).squareRoot()
    }

    enum RecorderError: Error, LocalizedError {
        case converterError
        case noInput

        var errorDescription: String? {
            switch self {
            case .converterError: return "Could not create audio converter"
            case .noInput: return "No audio input available"
            }
        }
    }
}

/// Converts input buffers to 16 kHz mono Float32 and writes them to a WAV file.
///
/// `append(_:)` runs on the tap's queue; `setInputFormat(_:)` and `finish()` on the main
/// actor. One lock guards the file and the converter, so once `finish()` returns nothing
/// more is written and the file is closed (its header holds the final sizes).
final class RecordingWriter: Sendable {
    /// What the transcription engines read: 16 kHz mono Float32.
    static let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false
    )!

    private struct State {
        var file: AVAudioFile?
        var converter: AVAudioConverter?
        var frames: AVAudioFramePosition = 0
    }

    let url: URL
    /// The file and converter are not Sendable; they are only touched with the lock held.
    private let state: OSAllocatedUnfairLock<State>

    init(url: URL) throws {
        self.url = url
        let file = try AVAudioFile(forWriting: url, settings: Self.outputFormat.settings)
        state = OSAllocatedUnfairLock(uncheckedState: State(file: file))
    }

    /// 16 kHz frames written so far.
    var framesWritten: AVAudioFramePosition {
        state.withLockUnchecked { $0.frames }
    }

    var isFinished: Bool {
        state.withLockUnchecked { $0.file == nil }
    }

    /// Converter for the input's format; called again when the input changes mid-recording.
    func setInputFormat(_ format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: format, to: Self.outputFormat) else {
            throw AudioRecorder.RecorderError.converterError
        }
        state.withLockUnchecked { $0.converter = converter }
    }

    /// Converts and writes one input buffer. Returns the converted samples, or nil when
    /// nothing was written (finished, a buffer in a previous input format, conversion error).
    func append(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        state.withLockUnchecked { state in
            guard let file = state.file, let converter = state.converter, buffer.frameLength > 0,
                  buffer.format.sampleRate == converter.inputFormat.sampleRate,
                  buffer.format.channelCount == converter.inputFormat.channelCount,
                  let converted = Self.convert(buffer, with: converter) else { return nil }
            do {
                try file.write(from: converted)
            } catch {
                return nil
            }
            state.frames += AVAudioFramePosition(converted.frameLength)
            return converted
        }
    }

    /// Closes the file. Idempotent; waits for an `append` in progress.
    func finish() {
        state.withLockUnchecked { state in
            guard let file = state.file else { return }
            if #available(macOS 15.0, *) {
                file.close()
            }
            // Before macOS 15 the file is closed when released, which is here: the state
            // held the only reference.
            state.file = nil
            state.converter = nil
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up))
        guard capacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }
        var error: NSError?
        var consumed = false
        converter.convert(to: converted, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard error == nil, converted.frameLength > 0 else { return nil }
        return converted
    }
}
