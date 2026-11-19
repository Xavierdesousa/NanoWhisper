import AppKit

extension LiveTranscriptionSupport {
    static func isAvailable(for configuration: EngineConfiguration) -> Bool {
        isAvailable(modelType: configuration.modelType, whisperModelSize: configuration.whisperSettings.modelSize)
    }
}

/// Live transcription (beta): while recording, the overlay shows repeated decodes of the audio
/// so far; when the recording stops, it is transcribed exactly as with live transcription
/// off, and the overlay shows that final text, which is the text pasted.
extension AppState {
    static let liveTranscriptionKey = "liveTranscriptionEnabled"

    /// Start the live preview of a recording that is about to begin.
    /// - Returns: the session to feed with the recording's samples, or `nil` when live
    ///   transcription is off or no engine is installed.
    func beginLiveTranscription() -> LiveTranscriptionSession? {
        cancelLiveTranscription()
        guard liveTranscriptionEnabled,
              LiveTranscriptionSupport.isAvailable(for: engineConfiguration),
              let decoder = transcriber.makePreviewDecoder()
        else { return nil }

        let session = LiveTranscriptionSession(decoder: decoder)
        let id = session.id
        let transcriber = self.transcriber
        // Never compete with a final pass (a previous recording still being transcribed).
        session.canDecode = { transcriber.pendingTranscriptions == 0 }
        session.onUpdate = { [weak self] transcript in
            self?.recordingOverlay.updateTranscript(transcript, for: id)
        }
        session.onFailure = { [weak self] _ in
            // Only the preview stops; the recording and its transcription are unaffected.
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

    /// Stop the live preview of the current recording, if any, and remove its text.
    func cancelLiveTranscription() {
        guard let session = liveSession else { return }
        liveSession = nil
        session.stop()
        recordingOverlay.updateTranscript(nil, for: session.id)
    }

    /// Show a recording's final transcription in its live preview: the exact string delivered
    /// (pasted and saved, or shown in onboarding's Try-it box for a test).
    func showFinalLiveText(_ text: String, for session: LiveTranscriptionSession?) {
        guard let session, session.failure == nil else { return }
        var transcript = session.transcript
        transcript.finalize(text)
        recordingOverlay.updateTranscript(transcript, for: session.id)
    }

    /// Stop the live preview when the app quits (nothing must keep decoding during teardown).
    func observeTerminationForLiveTranscription() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelLiveTranscription()
            }
        }
    }
}
