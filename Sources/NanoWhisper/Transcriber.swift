import Foundation
import AVFoundation
import FluidAudio
import WhisperKit

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
        await gate.acquire()
        do {
            let text = try await transcribeNow(audioPath: audioPath, options: options, prompt: prompt)
            await gate.release()
            return text
        } catch {
            await gate.release()
            throw error
        }
    }

    /// Must only run while holding `gate`.
    private func transcribeNow(audioPath: String, options: DecodingOptions, prompt: String?) async throws -> String {
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
        let results = try await kit.transcribe(audioPath: audioPath, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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
    }

    // MARK: - Initialization

    /// Load Parakeet models into a new `AsrManager` and install it.
    /// - Returns: `false` when a newer initialization (or a model switch) superseded this one
    ///   while the models were loading; the result is then discarded and nothing changes.
    func initializeParakeet(models: AsrModels) async throws -> Bool {
        try await installParakeet {
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            return manager
        }
    }

    /// Install the manager produced by `load` unless a newer initialization started meanwhile.
    func installParakeet(_ load: () async throws -> AsrManager) async throws -> Bool {
        engineGeneration += 1
        let generation = engineGeneration
        let manager = try await load()
        guard generation == engineGeneration else { return false }
        asrManager = manager
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
    }

    /// Discard any initialization still in flight (called when the user switches models).
    func invalidatePendingInitialization() {
        engineGeneration += 1
    }

    func updateWhisperSettings(_ settings: WhisperSettings) {
        self.whisperSettings = settings
    }

    // MARK: - Transcription

    /// Transcribe one recording. Calls are queued and run one at a time, in order: a new
    /// recording can finish while the previous one is still being transcribed.
    ///
    /// - Parakeet: `AsrManager` is an actor, so overlapping calls would be data-race free and
    ///   each has its own `TdtDecoderState`, but they would interleave at every `await` and
    ///   share the manager's progress session and MLMultiArray cache.
    /// - Whisper: `WhisperEngine` also serializes internally (it owns the non-Sendable kit).
    /// Queuing here keeps the debug timings free of waiting time.
    func transcribe(audioURL: URL) async -> TranscriptionResult {
        await transcriptionGate.acquire()
        let result: TranscriptionResult
        if whisperEngine != nil {
            result = await transcribeWithWhisper(audioURL: audioURL)
        } else if asrManager != nil {
            result = await transcribeWithParakeet(audioURL: audioURL)
        } else {
            result = TranscriptionResult(text: "", debugInfo: nil)
        }
        await transcriptionGate.release()
        return result
    }

    // MARK: - Parakeet

    private func transcribeWithParakeet(audioURL: URL) async -> TranscriptionResult {
        guard let manager = asrManager else {
            return TranscriptionResult(text: "", debugInfo: nil)
        }
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
            return TranscriptionResult(text: "", debugInfo: nil)
        }
    }

    // MARK: - Whisper

    private func transcribeWithWhisper(audioURL: URL) async -> TranscriptionResult {
        guard let engine = whisperEngine else {
            return TranscriptionResult(text: "", debugInfo: nil)
        }
        let audioDuration = Self.audioDuration(url: audioURL)
        let t0 = CFAbsoluteTimeGetCurrent()

        do {
            var options = DecodingOptions()
            if let lang = whisperSettings?.language {
                options.language = lang
                options.detectLanguage = false
            } else {
                options.detectLanguage = true
            }

            // The vocabulary hint is tokenized by the engine (it owns the tokenizer).
            let text = try await engine.transcribe(
                audioPath: audioURL.path,
                options: options,
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
            return TranscriptionResult(text: "", debugInfo: nil)
        }
    }

    // MARK: - Audio Duration

    private static func audioDuration(url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return -1 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
