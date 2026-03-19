import Foundation
import AVFoundation
import FluidAudio

@MainActor
class Transcriber {
    private var asrManager: AsrManager?

    struct TranscriptionResult {
        let text: String
        let debugInfo: TranscriptionDebugInfo?
    }

    func initialize(models: AsrModels) async throws {
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
    }

    func transcribe(audioURL: URL) async -> TranscriptionResult {
        guard let asrManager = asrManager else {
            return TranscriptionResult(text: "", debugInfo: nil)
        }

        let audioDuration = Self.audioDuration(url: audioURL)

        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let result = try await asrManager.transcribe(audioURL, source: .system)
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

    // MARK: - Audio Duration

    private static func audioDuration(url: URL) -> Double {
        guard let file = try? AVAudioFile(forReading: url) else { return -1 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
