import Foundation
import os

// MARK: - Schedule

/// When and what the live preview decodes. Each decode covers all the audio so far (up to
/// `fullDecodeLimit`, then a window: see `LivePreviewWindow`); spacing decodes by a multiple
/// of the last decode's duration keeps inference under `1 / durationFactor` of the time
/// whatever the engine, and decodes never queue up.
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

    /// Recordings up to this long are decoded whole for each preview. Past it, decoding all of
    /// it costs more and more (Parakeet: ~30 % of a core at 30 s, a full core past 2.5 min,
    /// because long audio is decoded on parallel workers), so the preview decodes a window.
    var fullDecodeLimit: TimeInterval = 30
    /// Most audio a windowed preview decode covers (15 s is one Parakeet model window).
    var windowLimit: TimeInterval = 15
    /// Audio the window keeps after its start moves forward.
    var windowKeep: TimeInterval = 8
    /// Audio decoded before the window's text starts, for acoustic context only.
    var windowContext: TimeInterval = 1

    static let `default` = LivePreviewSchedule()

    /// Seconds from the start of a decode that took `duration` seconds to the next start.
    func interval(afterDecodeLasting duration: TimeInterval) -> TimeInterval {
        max(minimumInterval, durationFactor * duration)
    }
}

// MARK: - Window

/// What the preview of a long recording decodes.
///
/// Up to `fullDecodeLimit`, every decode covers the whole recording and its text is shown as
/// is. Past it, the text before a boundary is frozen (taken from the last decode, as shown)
/// and only the audio after it is decoded, with `windowContext` before it for context. When
/// that window would exceed `windowLimit`, the boundary moves forward to a gap between two
/// decoded pieces, preferring the longest pause, so the window keeps at least `windowKeep`.
/// A piece of a window decode belongs to the window when its midpoint is after the boundary,
/// so the words around the join are neither repeated nor dropped (decoders place a word a few
/// tens of milliseconds differently from one decode to the next).
///
/// Display only: the pasted text is always the normal transcription of the whole recording.
struct LivePreviewWindow: Sendable {
    let schedule: LivePreviewSchedule
    /// Text before `boundary`, no longer decoded.
    private(set) var frozenText = ""
    /// Seconds into the recording where the window's text starts (0 while decoding it all).
    private(set) var boundary: Double = 0
    /// Pieces of the last decode at or after `boundary`, in recording time.
    private(set) var pieces: [Transcriber.TimedText] = []
    private(set) var isWindowed = false

    init(schedule: LivePreviewSchedule) {
        self.schedule = schedule
    }

    /// Seconds into the recording where the next decode starts, for a recording `duration`
    /// seconds long. Moves the boundary forward when the window has grown too long.
    mutating func decodeStart(forDuration duration: Double) -> Double {
        if !isWindowed {
            guard duration > schedule.fullDecodeLimit else { return 0 }
            isWindowed = true
            advance(duration)
        } else if duration - max(0, boundary - schedule.windowContext) > schedule.windowLimit {
            advance(duration)
        }
        return max(0, boundary - schedule.windowContext)
    }

    /// The text to show for `result`, a decode of the audio from `start` seconds on.
    mutating func text(for result: Transcriber.PreviewResult, decodedFrom start: Double) -> String {
        let decoded = result.pieces.map { Transcriber.TimedText(text: $0.text, start: $0.start + start, end: $0.end + start) }
        guard isWindowed else {
            pieces = decoded
            return result.text
        }
        pieces = decoded.filter { ($0.start + $0.end) / 2 >= boundary }
        let windowText = pieces.map(\.text).joined(separator: " ")
        return [frozenText, windowText].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Freeze the last decode's text up to a new boundary.
    private mutating func advance(_ duration: Double) {
        let latest = duration - schedule.windowKeep
        guard !pieces.isEmpty else {
            // Nothing decoded after the boundary (silence so far): just move it.
            boundary = max(boundary, latest)
            return
        }
        // Leave the window room to grow for a few decodes before it moves again.
        let earliest = duration - schedule.windowLimit + schedule.windowContext + 3

        // Candidate boundaries: in the gap before each piece, and just after the last one.
        // `frozen` pieces before it get frozen; `gap` is the silence the boundary sits in.
        var candidates: [(frozen: Int, position: Double, gap: Double)] = []
        var previousEnd = boundary
        for (index, piece) in pieces.enumerated() {
            candidates.append((index, (previousEnd + piece.start) / 2, piece.start - previousEnd))
            previousEnd = piece.end
        }
        candidates.append((pieces.count, previousEnd + min(0.3, max(0, duration - previousEnd) / 2), duration - previousEnd))
        candidates = candidates.filter { $0.position > boundary && $0.position <= latest }

        // In the target range the longest pause wins; otherwise the latest boundary before it.
        // None (one piece spans the whole window): the window keeps growing for now.
        let inRange = candidates.filter { $0.position >= earliest }
        guard let cut = inRange.max(by: { $0.gap < $1.gap }) ?? candidates.last else { return }

        let frozen = pieces.prefix(cut.frozen).map(\.text).joined(separator: " ")
        frozenText = [frozenText, frozen].filter { !$0.isEmpty }.joined(separator: " ")
        boundary = cut.position
        pieces.removeFirst(cut.frozen)
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

    /// A copy of the samples from `index` on.
    func samples(from index: Int) -> [Float] {
        Array(samples[min(max(0, index), samples.count)...])
    }
}

// MARK: - Session

/// Live preview of one recording.
///
/// Audio comes from the recorder through `sampleSink` (any thread, never blocks). Once
/// `schedule.minimumAudio` has been heard, the session repeatedly decodes the audio so far
/// (all of it, or a window once the recording is long: `LivePreviewWindow`) with the
/// transcriber's preview decoder and shows the result. Decodes are best effort:
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
    private var window: LivePreviewWindow
    private let sampleContinuation: AsyncStream<[Float]>.Continuation
    private var collectTask: Task<Void, Never>?
    private var decodeTask: Task<Void, Never>?

    init(decoder: Transcriber.PreviewDecoder, schedule: LivePreviewSchedule = .default) {
        self.decoder = decoder
        self.schedule = schedule
        self.audio = LiveAudioBuffer(soundThreshold: schedule.soundThreshold)
        self.window = LivePreviewWindow(schedule: schedule)
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

            let duration = Double(await audio.samples.count) / 16_000
            let decodedFrom = window.decodeStart(forDuration: duration)
            let samples = await audio.samples(from: Int(decodedFrom * 16_000))
            let start = ContinuousClock.now
            let result: Transcriber.PreviewResult
            do {
                result = try await decoder.decode(samples)
            } catch {
                if !Task.isCancelled && !isStopped {
                    fail(error)
                }
                return
            }
            guard !Task.isCancelled, !isStopped else { return }
            transcript.update(partial: window.text(for: result, decodedFrom: decodedFrom))
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
