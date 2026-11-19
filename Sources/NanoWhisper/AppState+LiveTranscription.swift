import AVFoundation
import AppKit
import os

/// Live transcription (beta): the overlay shows the transcript while the user speaks, and
/// the text pasted at the end is that same transcript, finalized by the streaming engine.
/// When live transcription is off, unavailable (Whisper) or fails, recordings go through the
/// batch transcription exactly as before.
extension AppState {
    static let liveTranscriptionKey = "liveTranscriptionEnabled"

    nonisolated private static var liveLogger: Logger {
        Logger(subsystem: BuildFlavor.current.logSubsystem, category: "LiveTranscription")
    }

    /// Start live transcription for a recording that is about to begin.
    /// - Returns: the session to feed with the recording's samples, or `nil` when live
    ///   transcription is off or the selected engine does not support it.
    func beginLiveTranscription() -> LiveTranscriptionSession? {
        cancelLiveTranscription()
        guard liveTranscriptionEnabled,
              selectedModelType == .parakeet,
              let models = setupManager.parakeetModels,
              setupManager.loadedParakeetVariant == parakeetVariant
        else { return nil }

        let session = LiveTranscriptionSession(engine: ParakeetLiveEngine(models: models))
        let id = session.id
        session.onUpdate = { [weak self] transcript in
            self?.recordingOverlay.updateTranscript(transcript, for: id)
        }
        session.onFailure = { [weak self] _ in
            // The recording goes on; it is transcribed in batch when it stops.
            guard let self else { return }
            self.recordingOverlay.updateTranscript(nil, for: id)
            if self.liveSession?.id == id {
                self.liveSession = nil
            }
        }
        session.start()
        liveSession = session
        return session
    }

    /// Stop the live transcription of the current recording, if any, and remove its text.
    func cancelLiveTranscription() {
        guard let session = liveSession else { return }
        liveSession = nil
        session.cancel()
        recordingOverlay.updateTranscript(nil, for: session.id)
    }

    /// Text of a finished recording.
    ///
    /// With a live session: its finalized transcript, shown in the overlay as the exact string
    /// returned (and then pasted). If the session failed, timed out, or had shown no text yet
    /// (see `LiveTranscriptionSession.finish`), the overlay drops the live text and the
    /// recording is transcribed in batch, as without live.
    func transcribeRecording(at audioURL: URL, live: LiveTranscriptionSession?) async -> Transcriber.TranscriptionResult {
        if let live {
            let start = CFAbsoluteTimeGetCurrent()
            if let transcript = await live.finish(), let text = transcript.finalText, !text.isEmpty {
                recordingOverlay.updateTranscript(transcript, for: live.id)
                let finishDuration = CFAbsoluteTimeGetCurrent() - start
                let audioDuration = Self.recordingDuration(audioURL)
                return Transcriber.TranscriptionResult(
                    text: text,
                    debugInfo: TranscriptionDebugInfo(
                        audioDuration: audioDuration,
                        transcribeDuration: finishDuration,
                        rtf: audioDuration.map { $0 > 0 ? finishDuration / $0 : nil } ?? nil
                    )
                )
            }
            Self.liveLogger.info("No live transcript; transcribing the recording in batch")
            recordingOverlay.updateTranscript(nil, for: live.id)
        }
        return await transcriber.transcribe(audioURL: audioURL)
    }

    /// Stop live transcription when the app quits (nothing must keep decoding during teardown).
    func observeTerminationForLiveTranscription() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelLiveTranscription()
            }
        }
    }

    private static func recordingDuration(_ url: URL) -> Double? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
