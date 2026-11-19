import Foundation
import Testing
import FluidAudio
@testable import NanoWhisper

/// "The engine failed" is reported as an error, distinct from "nothing was said".
@Suite("Transcription failure")
struct TranscriptionFailureTests {

    @Test("An engine that throws yields a failure, not an empty transcription")
    @MainActor func engineErrorIsAFailure() async throws {
        let transcriber = Transcriber()
        // Installed but never loaded: its transcribe throws.
        #expect(try await transcriber.installParakeet { AsrManager() })
        let result = await transcriber.transcribe(
            audioURL: URL(fileURLWithPath: "/nonexistent/nanowhisper-test.wav")
        )
        #expect(result.text.isEmpty)
        #expect(result.failure == .engineError)
    }

    @Test("No engine installed yields a failure")
    @MainActor func noEngineIsAFailure() async {
        let result = await Transcriber().transcribe(audioURL: URL(fileURLWithPath: "/tmp/none.wav"))
        #expect(result.failure == .noEngine)
    }

    @Test("A normal result carries no failure")
    func normalResult() {
        #expect(Transcriber.TranscriptionResult(text: "", debugInfo: nil).failure == nil)
    }

    @Test("A failed dictation is reported as a failure, never as \"Empty transcription\"")
    func pasteOutcome() {
        #expect(DictationOutcome.resolve(
            destination: .paste, text: "", failure: .engineError, testBoxShowing: false) == .failed(.engineError))
        #expect(DictationOutcome.resolve(
            destination: .paste, text: "", failure: .noEngine, testBoxShowing: true) == .failed(.noEngine))
        // Nothing said: unchanged.
        #expect(DictationOutcome.resolve(destination: .paste, text: "", failure: nil, testBoxShowing: false) == .noResult)
    }

    @Test("A failed test is reported while its box shows, and dropped once onboarding moved on")
    func testOutcome() {
        #expect(DictationOutcome.resolve(
            destination: .onboardingTest, text: "", failure: .engineError, testBoxShowing: true) == .failed(.engineError))
        #expect(DictationOutcome.resolve(
            destination: .onboardingTest, text: "", failure: .engineError, testBoxShowing: false) == .discard)
    }

    @Test("Failure messages are distinct from the empty-result message")
    func messages() {
        for failure in [TranscriptionFailure.noEngine, .engineError] {
            #expect(failure.message.hasPrefix("Transcription failed"))
            #expect(failure.message != "Empty transcription")
        }
    }
}
