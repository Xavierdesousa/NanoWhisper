import AVFoundation
import FluidAudio
import os

// MARK: - Engine

/// Streaming speech-to-text engine behind a live transcription (protocol so the session
/// lifecycle can be tested without models).
protocol LiveTranscriptionEngine: Sendable {
    /// Start the job. Revisions arrive on the returned stream; it ends after the terminal
    /// revision published by `finish()`, and throws if the job fails.
    func start() async throws -> AsyncThrowingStream<LiveTranscript.Revision, any Error>
    /// Queue 16 kHz mono samples. Returns without waiting for inference.
    func append(_ samples: [Float]) async
    /// End of audio: decode what remains and publish the terminal revision.
    func finish() async throws
    /// Stop now, without a terminal revision. Safe at any time, more than once.
    func cancel() async
}

/// Live transcription on the Parakeet models already loaded for batch transcription.
///
/// Wraps FluidAudio's `SlidingWindowAsrManager`, which decodes overlapping windows of the
/// incoming audio and publishes explicit token revisions (`tokenUpdates`). Its internal
/// `AsrManager` shares the `MLModel` instances of the batch engine, as FluidAudio's own
/// parallel chunk workers do, so no model is loaded twice. One engine per recording: the
/// token stream is single-use.
struct ParakeetLiveEngine: LiveTranscriptionEngine {
    /// Window layout: a 4 s chunk per step, 1 s right context, the rest of the model's 15 s
    /// input as left context. First text after ~5 s of audio, then every 4 s.
    ///
    /// Measured against batch transcription on the same audio (English and French): every
    /// window seam is a chance for a stray sentence break ("Martin. aux notes"), and chunks of
    /// 2 s or less also freeze decodes of very short audio (a 2.4 s French clip came out as
    /// garbage). FluidAudio's default (11 s chunks) shows nothing for the first 13 s.
    static let windowConfig = SlidingWindowAsrConfig(
        chunkSeconds: 4.0,
        hypothesisChunkSeconds: 4.0,
        leftContextSeconds: 10.0,
        rightContextSeconds: 1.0,
        minContextForConfirmation: 10.0,
        confirmationThreshold: 0.85
    )

    private let models: AsrModels
    private let manager: SlidingWindowAsrManager

    init(models: AsrModels, config: SlidingWindowAsrConfig = Self.windowConfig) {
        self.models = models
        self.manager = SlidingWindowAsrManager(config: config)
    }

    func start() async throws -> AsyncThrowingStream<LiveTranscript.Revision, any Error> {
        try await manager.loadModels(models)
        // The token stream must be subscribed before any audio is accepted.
        let updates = await manager.tokenUpdates
        try await manager.startStreaming(source: .microphone)

        let (revisions, continuation) = AsyncThrowingStream<LiveTranscript.Revision, any Error>.makeStream()
        let forwarder = Task {
            do {
                for try await update in updates {
                    continuation.yield(LiveTranscript.Revision(update))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in forwarder.cancel() }
        return revisions
    }

    func append(_ samples: [Float]) async {
        guard let buffer = Self.makeBuffer(samples) else { return }
        await manager.streamAudio(buffer)
    }

    func finish() async throws {
        _ = try await manager.finish()
    }

    func cancel() async {
        await manager.cancel()
    }

    private static func makeBuffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}

extension LiveTranscript.Revision {
    init(_ update: SlidingWindowTokenUpdate) {
        self.init(
            previousCount: update.revision.previousTokenCount,
            retainedCount: update.revision.retainedTokenCount,
            stableCount: update.revision.stableTokenCount,
            pieces: update.tokens.map(\.token),
            isTerminal: update.revision.isTerminal
        )
    }
}

// MARK: - Session

enum LiveTranscriptionError: Error, Equatable {
    /// The engine's revision stream ended without the terminal revision.
    case incomplete
    /// The engine did not finalize in time after the recording stopped.
    case timedOut
}

/// Live transcription of one recording.
///
/// Audio comes from the recorder through `sampleSink` (any thread, never blocks), is fed to
/// the engine off the audio thread, and every revision updates `transcript` on the main
/// actor. `finish()` ends the audio and returns the finalized transcript, whose `text` is
/// what the app pastes. Any failure (engine error, broken revision sequence, timeout) stops
/// the engine, clears the transcript, reports through `onFailure` and makes `finish()`
/// return `nil`, so the caller falls back to the batch transcription of the recording.
@MainActor
final class LiveTranscriptionSession {
    nonisolated private static let logger = Logger(subsystem: "com.moonji.nanowhisper", category: "LiveTranscription")

    let id = UUID()
    private(set) var transcript = LiveTranscript()
    private(set) var failure: (any Error)?
    private(set) var isCancelled = false

    /// Called on every transcript change while the session is live.
    var onUpdate: ((LiveTranscript) -> Void)?
    /// Called once if the session fails (not when it is cancelled).
    var onFailure: ((any Error) -> Void)?

    private let engine: any LiveTranscriptionEngine
    private let samples: AsyncStream<[Float]>
    private let sampleContinuation: AsyncStream<[Float]>.Continuation
    private var runTask: Task<Void, Never>?
    private var engineCancellation: Task<Void, Never>?

    init(engine: any LiveTranscriptionEngine) {
        self.engine = engine
        (samples, sampleContinuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
    }

    /// Feeds 16 kHz mono samples to the session. Callable from the audio tap: it only
    /// enqueues; samples after `finish()`, `cancel()` or a failure are dropped.
    nonisolated var sampleSink: @Sendable ([Float]) -> Void {
        let continuation = sampleContinuation
        return { samples in continuation.yield(samples) }
    }

    func start() {
        guard runTask == nil, !isCancelled else { return }
        runTask = Task { await run() }
    }

    /// End the audio and wait for the engine to finalize the transcript.
    /// - Returns: the final transcript, or `nil` (the caller then transcribes the recording in
    ///   batch) if the session failed, was cancelled, did not finalize within `timeout`, or had
    ///   shown no text by the end of the audio. In that last case (a recording shorter than
    ///   the first live window) there is no shown text to stay consistent with, and the batch
    ///   pass is faster and more accurate than flushing the stream; the engine is cancelled.
    func finish(timeout: Duration = .seconds(5)) async -> LiveTranscript? {
        sampleContinuation.finish()
        guard let runTask, !isCancelled, failure == nil else { return nil }
        guard !transcript.isEmpty else {
            cancel()
            return nil
        }
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.fail(LiveTranscriptionError.timedOut)
        }
        await runTask.value
        timer.cancel()
        guard failure == nil, !isCancelled, transcript.isFinal else { return nil }
        return transcript
    }

    /// Stop the session and its engine; nothing is reported afterwards.
    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        stopEngine()
    }

    /// Wait until the run loop and any engine cancellation have completed.
    func waitUntilStopped() async {
        await runTask?.value
        await engineCancellation?.value
    }

    // MARK: - Private

    private func run() async {
        let engine = self.engine
        let samples = self.samples
        do {
            let revisions = try await engine.start()
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await chunk in samples {
                        await engine.append(chunk)
                    }
                    try Task.checkCancellation()
                    try await engine.finish()
                }
                group.addTask {
                    try await self.consume(revisions)
                }
                // The first error ends the group, which cancels the other child (unlike
                // `waitForAll()`, which would keep feeding audio until the recording stops).
                for try await _ in group {}
            }
            if !transcript.isFinal && !isCancelled {
                fail(LiveTranscriptionError.incomplete)
            }
        } catch {
            fail(error)
        }
    }

    private func consume(_ revisions: AsyncThrowingStream<LiveTranscript.Revision, any Error>) async throws {
        for try await revision in revisions {
            guard !isCancelled, failure == nil else { return }
            try transcript.apply(revision)
            onUpdate?(transcript)
        }
    }

    private func fail(_ error: any Error) {
        guard !isCancelled, failure == nil else { return }
        failure = error
        transcript = LiveTranscript()
        Self.logger.error("Live transcription failed: \(String(describing: error), privacy: .public)")
        stopEngine()
        onFailure?(error)
    }

    private func stopEngine() {
        sampleContinuation.finish()
        runTask?.cancel()
        guard engineCancellation == nil else { return }
        let engine = self.engine
        engineCancellation = Task { await engine.cancel() }
    }
}
