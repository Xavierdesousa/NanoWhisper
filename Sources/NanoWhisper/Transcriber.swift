import Foundation
import AVFoundation
import FluidAudio
import WhisperKit

// MARK: - Whisper engine

/// Owns a `WhisperKit` instance inside its own isolation domain.
///
/// `WhisperKit` is a non-Sendable class, so it must never cross actor boundaries.
/// The kit is created inside this actor and every call into it happens here;
/// only Sendable values (strings, `DecodingOptions`) go in or out.
actor WhisperEngine {
    private let kit: WhisperKit

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
    func transcribe(audioPath: String, options: DecodingOptions) async throws -> String {
        let results = try await kit.transcribe(audioPath: audioPath, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Transcriber

@MainActor
class Transcriber {
    private var asrManager: AsrManager?
    private var whisperEngine: WhisperEngine?
    private var whisperSettings: WhisperSettings?

    struct TranscriptionResult {
        let text: String
        let debugInfo: TranscriptionDebugInfo?
    }

    // MARK: - Initialization

    func initializeParakeet(models: AsrModels) async throws {
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asrManager = manager
        self.whisperEngine = nil
    }

    func initializeWhisper(engine: WhisperEngine, settings: WhisperSettings) {
        self.whisperEngine = engine
        self.whisperSettings = settings
        self.asrManager = nil
    }

    func updateWhisperSettings(_ settings: WhisperSettings) {
        self.whisperSettings = settings
    }

    // MARK: - Transcription

    func transcribe(audioURL: URL) async -> TranscriptionResult {
        if whisperEngine != nil {
            return await transcribeWithWhisper(audioURL: audioURL)
        } else if asrManager != nil {
            return await transcribeWithParakeet(audioURL: audioURL)
        }
        return TranscriptionResult(text: "", debugInfo: nil)
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

            // Apply prompt text as vocabulary hint
            if let prompt = whisperSettings?.promptText, !prompt.isEmpty {
                options.usePrefillPrompt = true
            }

            let text = try await engine.transcribe(audioPath: audioURL.path, options: options)
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
