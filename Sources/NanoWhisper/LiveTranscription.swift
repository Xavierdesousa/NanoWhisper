import Foundation
import os

// MARK: - Schedule

/// When the live preview decodes. Each decode covers all the audio so far, so its duration
/// grows with the recording; spacing decodes by a multiple of that duration keeps inference
/// under `1 / durationFactor` of the time whatever the length or the engine, and decodes never
/// queue up.
struct LivePreviewSchedule: Sendable, Equatable {
    /// Audio needed after the first sound before the first decode. Measured on English and
    /// French: from 1 s the words are mostly right (the cut last word often is not, and is
    /// shown as the changing tail); at 0.5 s many decodes are one or two words or empty.
    var minimumAudio: TimeInterval = 1.0
    /// Minimum time between the starts of two decodes.
    var minimumInterval: TimeInterval = 1.0
    /// The next decode starts no sooner than this many times the last decode's duration
    /// after it started.
    var durationFactor: Double = 4
    /// A sample above this amplitude counts as the first sound (leading silence is skipped).
    var soundThreshold: Float = 0.01
    /// How often to check again while waiting for audio or for a final pass to end.
    var pollInterval: TimeInterval = 0.1

    static let `default` = LivePreviewSchedule()

    /// Seconds from the start of a decode that took `duration` seconds to the next start.
    func interval(afterDecodeLasting duration: TimeInterval) -> TimeInterval {
        max(minimumInterval, durationFactor * duration)
    }
}

// MARK: - Audio buffer

/// The recording's samples, accumulated off the audio thread.
actor LiveAudioBuffer {
    private(set) var samples: [Float] = []
    /// Index of the first sample above the sound threshold, once heard.
    private(set) var firstSoundIndex: Int?
    private let soundThreshold: Float

    init(soundThreshold: Float) {
        self.soundThreshold = soundThreshold
        samples.reserveCapacity(16_000 * 60)
    }

    func append(_ chunk: [Float]) {
        if firstSoundIndex == nil, let index = chunk.firstIndex(where: { abs($0) > soundThreshold }) {
            firstSoundIndex = samples.count + index
        }
        samples.append(contentsOf: chunk)
    }

    /// Append everything from `stream` until it ends.
    func collect(_ stream: AsyncStream<[Float]>) async {
        for await chunk in stream {
            append(chunk)
        }
    }

    /// Samples heard after the first sound (0 before any sound).
    var countAfterFirstSound: Int {
        firstSoundIndex.map { samples.count - $0 } ?? 0
    }
}

// MARK: - Session

/// Live preview of one recording.
///
/// Audio comes from the recorder through `sampleSink` (any thread, never blocks). Once
/// `schedule.minimumAudio` has been heard, the session repeatedly decodes all the audio so
/// far with the transcriber's preview decoder and shows the result. Decodes are best effort:
/// one at a time, spaced by `LivePreviewSchedule`, skipped while `canDecode()` is false (a
/// final pass is queued or running), and abandoned by `stop()`. They never produce the pasted
/// text: the caller runs the normal transcription of the recording and shows it with
/// `LiveTranscript.finalize(_:)`. If a decode fails, the session stops and clears its text.
@MainActor
final class LiveTranscriptionSession {
    nonisolated private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "LiveTranscription")

    let id = UUID()
    private(set) var transcript = LiveTranscript()
    private(set) var failure: (any Error)?
    private(set) var isStopped = false

    /// Called after every partial decode while the session runs.
    var onUpdate: ((LiveTranscript) -> Void)?
    /// Called once if a partial decode fails (not when the session is stopped).
    var onFailure: ((any Error) -> Void)?
    /// Checked before each decode; returning `false` skips it.
    var canDecode: @MainActor () -> Bool = { true }

    private let decoder: Transcriber.PreviewDecoder
    private let schedule: LivePreviewSchedule
    private let audio: LiveAudioBuffer
    private let sampleContinuation: AsyncStream<[Float]>.Continuation
    private var collectTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?

    init(decoder: Transcriber.PreviewDecoder, schedule: LivePreviewSchedule = .default) {
        self.decoder = decoder
        self.schedule = schedule
        self.audio = LiveAudioBuffer(soundThreshold: schedule.soundThreshold)
        let (samples, continuation) = AsyncStream<[Float]>.makeStream(bufferingPolicy: .unbounded)
        self.sampleContinuation = continuation
        let audio = self.audio
        collectTask = Task.detached { await audio.collect(samples) }
    }

    /// Feeds 16 kHz mono samples to the session. Callable from the audio tap: it only
    /// enqueues; samples after `stop()` are dropped.
    nonisolated var sampleSink: @Sendable ([Float]) -> Void {
        let continuation = sampleContinuation
        return { samples in continuation.yield(samples) }
    }

    func start() {
        guard decodeTask == nil, !isStopped else { return }
        decodeTask = Task { await decodeLoop() }
    }

    /// Stop decoding: the decode in flight is cancelled and its result ignored. The transcript
    /// stays as it is, for the overlay to show until the final text replaces it. Idempotent.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        sampleContinuation.finish()
        decodeTask?.cancel()
    }

    /// Wait until the decode loop and the audio collection have ended (after `stop()`).
    func waitUntilStopped() async {
        await decodeTask?.value
        await collectTask?.value
    }

    // MARK: - Private

    private func decodeLoop() async {
        let minimumSamples = Int(schedule.minimumAudio * 16_000)
        var nextStart = ContinuousClock.now
        while !Task.isCancelled {
            // Sleep until the next decode is due, or poll while waiting for audio or for a
            // final pass to end. A decode is never started while another one runs.
            let now = ContinuousClock.now
            try? await Task.sleep(for: nextStart > now ? nextStart - now : .seconds(schedule.pollInterval))
            guard !Task.isCancelled else { return }
            guard await audio.countAfterFirstSound >= minimumSamples, canDecode() else { continue }

            let samples = await audio.samples
            let start = ContinuousClock.now
            let text: String
            do {
                text = try await decoder.decode(samples)
            } catch {
                if !Task.isCancelled && !isStopped {
                    fail(error)
                }
                return
            }
            guard !Task.isCancelled, !isStopped else { return }
            transcript.update(partial: text)
            onUpdate?(transcript)

            let elapsed = start.duration(to: .now)
            nextStart = start + .seconds(schedule.interval(afterDecodeLasting: Self.seconds(elapsed)))
        }
    }

    private func fail(_ error: any Error) {
        guard failure == nil, !isStopped else { return }
        failure = error
        transcript = LiveTranscript()
        Self.logger.error("Live preview stopped: \(String(describing: error), privacy: .public)")
        stop()
        onFailure?(error)
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let (seconds, attoseconds) = duration.components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
