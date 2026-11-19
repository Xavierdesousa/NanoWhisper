import Foundation
import AVFoundation
import FluidAudio
import WhisperKit
import os

// MARK: - Serial gate

/// FIFO async mutex. Actors are reentrant: while one call awaits, another call on the same
/// actor can start. Wrapping work in `acquire()` / `release()` makes calls strictly serial,
/// in arrival order, without dropping any.
actor SerialGate {
    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Callers currently queued behind the holder.
    var pendingCount: Int { waiters.count }

    func acquire() async {
        guard isBusy else {
            isBusy = true
            return
        }
        // Ownership is handed over directly by `release()`, so `isBusy` stays true.
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Whisper engine

/// Owns a `WhisperKit` instance inside its own isolation domain.
///
/// `WhisperKit` is a non-Sendable class, so it must never cross actor boundaries.
/// The kit is created inside this actor and every call into it happens here;
/// only Sendable values (strings, `DecodingOptions`) go in or out.
/// Transcriptions are serialized by `gate`: the actor alone would let a second call
/// interleave with the first at every `await` inside WhisperKit.
actor WhisperEngine {
    private let kit: WhisperKit
    private let gate = SerialGate()

    /// Download (if needed), prewarm and load the given WhisperKit model variant.
    init(model: String) async throws {
        let config = WhisperKitConfig(
            model: model,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )
        kit = try await WhisperKit(config)
    }

    /// Transcribe an audio file and return the joined, trimmed text.
    /// - Parameter prompt: optional vocabulary hint, passed to the decoder as Whisper's
    ///   previous-context prompt (`<|startofprev|>` + tokens) to bias spelling of names and terms.
    func transcribe(audioPath: String, options: DecodingOptions, prompt: String? = nil) async throws -> String {
        try await transcribe(.path(audioPath), options: options, prompt: prompt).text
    }

    /// Transcribe 16 kHz mono samples (live preview of a recording in progress), like
    /// `transcribe(audioPath:options:prompt:)`, with the timed segments. Stops early when the
    /// calling task is cancelled.
    func transcribePreview(audioArray: [Float], options: DecodingOptions, prompt: String? = nil) async throws -> Transcriber.PreviewResult {
        let (text, pieces) = try await transcribe(.samples(audioArray), options: options, prompt: prompt)
        return Transcriber.PreviewResult(text: text, pieces: pieces)
    }

    private enum Audio {
        case path(String)
        case samples([Float])
    }

    private func transcribe(
        _ audio: Audio, options: DecodingOptions, prompt: String?
    ) async throws -> (text: String, pieces: [Transcriber.TimedText]) {
        await gate.acquire()
        do {
            let result = try await transcribeNow(audio, options: options, prompt: prompt)
            await gate.release()
            return result
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Must only run while holding `gate`.
    private func transcribeNow(
        _ audio: Audio, options: DecodingOptions, prompt: String?
    ) async throws -> (text: String, pieces: [Transcriber.TimedText]) {
        var options = options
        if let prompt, let tokenizer = kit.tokenizer,
           let tokens = Self.promptTokens(
               for: prompt,
               encode: { tokenizer.encode(text: $0) },
               specialTokenBegin: tokenizer.specialTokens.specialTokenBegin
           ) {
            options.promptTokens = tokens
            options.usePrefillPrompt = true
        }
        let results: [TranscriptionResult]
        switch audio {
        case .path(let path):
            results = try await kit.transcribe(audioPath: path, decodeOptions: options)
        case .samples(let samples):
            results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        }
        let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = results.flatMap(\.segments).compactMap { segment -> Transcriber.TimedText? in
            let text = Self.plainText(segment.text)
            guard !text.isEmpty else { return nil }
            return Transcriber.TimedText(text: text, start: Double(segment.start), end: Double(segment.end))
        }
        return (text, pieces)
    }

    /// Segment text without Whisper's special tokens (`<|0.00|>`, `<|en|>`…).
    nonisolated static func plainText(_ text: String) -> String {
        text.replacingOccurrences(of: "<\\|[^|]*\\|>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Encode a vocabulary hint the way WhisperKit's own CLI does: a leading space (Whisper's
    /// BPE treats words as space-prefixed), then drop every special token (ids at or above
    /// `specialTokenBegin`), which must not appear inside the prompt.
    /// - Returns: `nil` when the hint is blank or encodes to nothing usable.
    nonisolated static func promptTokens(
        for prompt: String,
        encode: (String) -> [Int],
        specialTokenBegin: Int
    ) -> [Int]? {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tokens = encode(" " + trimmed).filter { $0 < specialTokenBegin }
        return tokens.isEmpty ? nil : tokens
    }
}

// MARK: - Transcriber

@MainActor
class Transcriber {
    private var asrManager: AsrManager?
    private var whisperEngine: WhisperEngine?
    private var whisperSettings: WhisperSettings?
    /// Models behind `asrManager` (for live previews), when installed by `initializeParakeet`.
    private var parakeetModels: AsrModels?

    /// Recordings submitted to `transcribe(audioURL:)` and not finished (queued or running).
    /// Live previews pause while it is non-zero, so they never compete with a final pass.
    private(set) var pendingTranscriptions = 0

    /// Bumped by every initialization and by `invalidatePendingInitialization()`. An async
    /// initialization only installs its engine if no newer one started while it was loading.
    private var engineGeneration = 0
    /// Queues transcriptions (see `transcribe(audioURL:)`).
    private let transcriptionGate = SerialGate()

    /// Engine currently installed (exposed for tests).
    var currentAsrManager: AsrManager? { asrManager }

    struct TranscriptionResult {
        let text: String
        let debugInfo: TranscriptionDebugInfo?
        /// Set when no text could be produced because the engine failed (`text` is then
        /// empty). `nil` with empty text means the engine ran and recognized nothing.
        var failure: TranscriptionFailure? = nil

        static func failed(_ failure: TranscriptionFailure) -> TranscriptionResult {
            TranscriptionResult(text: "", debugInfo: nil, failure: failure)
        }
    }

    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "Transcriber")

    /// Log an engine error (never the audio or any text) and turn it into a failed result.
    private static func failedResult(_ engineName: String, _ error: any Error) -> TranscriptionResult {
        logger.error("\(engineName, privacy: .public) transcription failed: \(String(describing: error), privacy: .public)")
        return .failed(.engineError)
    }

    // MARK: - Initialization

    /// Load Parakeet models into a new `AsrManager` and install it.
    /// - Returns: `false` when a newer initialization (or a model switch) superseded this one
    ///   while the models were loading; the result is then discarded and nothing changes.
    func initializeParakeet(models: AsrModels) async throws -> Bool {
        let installed = try await installParakeet {
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
        if installed {
            parakeetModels = models
        }
        return installed
    }

    /// Install the manager produced by `load` unless a newer initialization started meanwhile.
    func installParakeet(_ load: () async throws -> AsrManager) async throws -> Bool {
        engineGeneration += 1
        let generation = engineGeneration
        let manager = try await load()
        guard generation == engineGeneration else { return false }
        asrManager = manager
        parakeetModels = nil
        whisperEngine = nil
        return true
    }

    /// Install a loaded Whisper engine. Synchronous, so it cannot be overtaken itself, but it
    /// bumps the generation so a Parakeet initialization still in flight is discarded.
    func initializeWhisper(engine: WhisperEngine, settings: WhisperSettings) {
        engineGeneration += 1
        self.whisperEngine = engine
        self.whisperSettings = settings
        self.asrManager = nil
        self.parakeetModels = nil
    }

    /// Discard any initialization still in flight (called when the user switches models).
    func invalidatePendingInitialization() {
        engineGeneration += 1
    }

    func updateWhisperSettings(_ settings: WhisperSettings) {
        self.whisperSettings = settings
    }

    // MARK: - Transcription

    /// Engine and settings a recording is transcribed with, captured when it is submitted.
    struct Configuration: Sendable {
        enum Engine: Sendable {
            case none
            case parakeet(AsrManager)
            case whisper(WhisperEngine)
        }

        let engine: Engine
        let whisperSettings: WhisperSettings?

        var asrManager: AsrManager? {
            if case .parakeet(let manager) = engine { return manager }
            return nil
        }
    }

    /// Engine and settings currently installed.
    var currentConfiguration: Configuration {
        let engine: Configuration.Engine
        if let whisperEngine {
            engine = .whisper(whisperEngine)
        } else if let asrManager {
            engine = .parakeet(asrManager)
        } else {
            engine = .none
        }
        return Configuration(engine: engine, whisperSettings: whisperSettings)
    }

    /// Test seam: replaces the actual inference for a queued recording.
    var transcriptionHandler: ((Configuration, URL) async -> TranscriptionResult)?

    /// Transcribe one recording.
    ///
    /// Contract:
    /// - The recording is transcribed with the engine and settings in effect **when this method
    ///   is called** (captured before any suspension), even if the model, language or vocabulary
    ///   hint changes while it waits in the queue. A queued recording keeps its engine alive
    ///   until it has been transcribed.
    /// - Calls are queued and run one at a time, in submission order; none is dropped. A new
    ///   recording can finish while the previous one is still being transcribed.
    ///   - Parakeet: `AsrManager` is an actor, so overlapping calls would be data-race free and
    ///     each has its own `TdtDecoderState`, but they would interleave at every `await` and
    ///     share the manager's progress session and MLMultiArray cache.
    ///   - Whisper: `WhisperEngine` also serializes internally (it owns the non-Sendable kit).
    /// - Debug timings start once the recording leaves the queue.
    func transcribe(audioURL: URL) async -> TranscriptionResult {
        let configuration = currentConfiguration
        pendingTranscriptions += 1
        defer { pendingTranscriptions -= 1 }
        await transcriptionGate.acquire()
        let result: TranscriptionResult
        if let transcriptionHandler {
            result = await transcriptionHandler(configuration, audioURL)
        } else {
            result = await transcribe(audioURL: audioURL, with: configuration)
        }
        await transcriptionGate.release()
        return result
    }

    /// Recordings waiting behind the one being transcribed (exposed for tests).
    var queuedTranscriptionCount: Int {
        get async { await transcriptionGate.pendingCount }
    }

    private func transcribe(audioURL: URL, with configuration: Configuration) async -> TranscriptionResult {
        switch configuration.engine {
        case .whisper(let engine):
            return await transcribeWithWhisper(engine: engine, settings: configuration.whisperSettings, audioURL: audioURL)
        case .parakeet(let manager):
            return await transcribeWithParakeet(manager: manager, audioURL: audioURL)
        case .none:
            Self.logger.error("Transcription requested with no engine installed")
            return .failed(.noEngine)
        }
    }

    // MARK: - Parakeet

    private func transcribeWithParakeet(manager: AsrManager, audioURL: URL) async -> TranscriptionResult {
        let audioDuration = Self.audioDuration(url: audioURL)

        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            // Each recording is an independent utterance: start from a fresh decoder state.
            var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
            let result = try await manager.transcribe(audioURL, decoderState: &decoderState)
            let transcribeDuration = CFAbsoluteTimeGetCurrent() - t0
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let rtf = audioDuration > 0 ? transcribeDuration / audioDuration : nil

            let debugInfo = TranscriptionDebugInfo(
                audioDuration: audioDuration,
                transcribeDuration: transcribeDuration,
                rtf: rtf
            )
            return TranscriptionResult(text: text, debugInfo: debugInfo)
        } catch {
            return Self.failedResult("Parakeet", error)
        }
    }

    // MARK: - Whisper

    private func transcribeWithWhisper(
        engine: WhisperEngine,
        settings whisperSettings: WhisperSettings?,
        audioURL: URL
    ) async -> TranscriptionResult {
        let audioDuration = Self.audioDuration(url: audioURL)
        let t0 = CFAbsoluteTimeGetCurrent()

        do {
            // The vocabulary hint is tokenized by the engine (it owns the tokenizer).
            let text = try await engine.transcribe(
                audioPath: audioURL.path,
                options: Self.decodingOptions(for: whisperSettings),
                prompt: whisperSettings?.promptText
            )
            let transcribeDuration = CFAbsoluteTimeGetCurrent() - t0
            let rtf = audioDuration > 0 ? transcribeDuration / audioDuration : nil

            let debugInfo = TranscriptionDebugInfo(
                audioDuration: audioDuration,
                transcribeDuration: transcribeDuration,
                rtf: rtf
            )
            return TranscriptionResult(text: text, debugInfo: debugInfo)
        } catch {
            return Self.failedResult("Whisper", error)
        }
    }

    nonisolated static func decodingOptions(for settings: WhisperSettings?) -> DecodingOptions {
        var options = DecodingOptions()
        if let lang = settings?.language {
            options.language = lang
            options.detectLanguage = false
        } else {
            options.detectLanguage = true
        }
        return options
    }

    // MARK: - Live preview

    /// A stretch of text with its time span in seconds.
    struct TimedText: Sendable, Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    /// A preview decode: the text, and the same text in timed pieces (words for Parakeet,
    /// segments for Whisper; times from the start of the decoded audio).
    struct PreviewResult: Sendable, Equatable {
        var text: String
        var pieces: [TimedText]
    }

    /// Decodes audio of a recording in progress for the live preview.
    struct PreviewDecoder: Sendable {
        let decode: @Sendable ([Float]) async throws -> PreviewResult
    }

    /// Words of a Parakeet transcription with their times. A token whose text starts with a
    /// space starts a word; punctuation and word continuations attach to the previous word.
    nonisolated static func words(from timings: [TokenTiming]) -> [TimedText] {
        var words: [TimedText] = []
        for timing in timings {
            let piece = timing.token
            if piece.hasPrefix(" ") || words.isEmpty {
                words.append(TimedText(text: piece.trimmingCharacters(in: .whitespaces),
                                       start: timing.startTime, end: timing.endTime))
            } else {
                words[words.count - 1].text += piece
                words[words.count - 1].end = timing.endTime
            }
        }
        return words.filter { !$0.text.isEmpty }
    }

    /// A decoder for live previews of the next recording, on a snapshot of the engine and
    /// settings installed now (those its final pass uses too, unless the model is switched
    /// meanwhile, which cancels the preview). `nil` without an engine.
    ///
    /// Previews never go through the transcription queue: they are best effort, and the live
    /// session pauses them while `pendingTranscriptions > 0`.
    /// - Parakeet: a separate `AsrManager` on the same Core ML models (as FluidAudio's own
    ///   parallel chunk workers do), so a preview never interleaves with a final pass on the
    ///   batch manager's actor. Same configuration and call as the final pass.
    /// - Whisper: the same `WhisperEngine` (it owns the kit); a cancelled preview releases it
    ///   at WhisperKit's next cancellation check.
    func makePreviewDecoder() -> PreviewDecoder? {
        switch currentConfiguration.engine {
        case .parakeet:
            guard let models = parakeetModels else { return nil }
            let manager = AsrManager(config: .default, models: models)
            return PreviewDecoder { samples in
                var decoderState = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                let result = try await manager.transcribe(samples, decoderState: &decoderState)
                return PreviewResult(
                    text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    pieces: Self.words(from: result.tokenTimings ?? [])
                )
            }
        case .whisper(let engine):
            let settings = whisperSettings
            let options = Self.decodingOptions(for: settings)
            return PreviewDecoder { samples in
                try await engine.transcribePreview(audioArray: samples, options: options, prompt: settings?.promptText)
            }
        case .none:
            return nil
        }
    }

    // MARK: - Audio Duration

    private static func audioDuration(url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return -1 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
