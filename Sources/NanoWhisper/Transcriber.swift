import Foundation
import AVFoundation
import FluidAudio
import WhisperKit

@MainActor
class Transcriber {
    private var asrManager: AsrManager?
    private var whisperKit: WhisperKit?
    private var whisperSettings: WhisperSettings?

    struct TranscriptionResult {
        let text: String
        let debugInfo: TranscriptionDebugInfo?
    }

    // MARK: - Initialization

    func initializeParakeet(models: AsrModels) async throws {
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
        self.whisperKit = nil
    }

    func initializeWhisper(kit: WhisperKit, settings: WhisperSettings) {
        self.whisperKit = kit
        self.whisperSettings = settings
        self.asrManager = nil
    }

    func updateWhisperSettings(_ settings: WhisperSettings) {
        self.whisperSettings = settings
    }

    // MARK: - Transcription

    func transcribe(audioURL: URL) async -> TranscriptionResult {
        if whisperKit != nil {
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
            let result = try await manager.transcribe(audioURL, source: .system)
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
        guard let kit = whisperKit else {
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

            let results = try await kit.transcribe(audioPath: audioURL.path, decodeOptions: options)
            let transcribeDuration = CFAbsoluteTimeGetCurrent() - t0
            let text = results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
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
