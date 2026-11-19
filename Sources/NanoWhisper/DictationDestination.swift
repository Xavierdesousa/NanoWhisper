import Foundation

/// Where a dictation's text goes. Decided when the recording starts and kept until its
/// transcription finishes, whatever happens to onboarding in between.
enum DictationDestination: Equatable {
    /// The normal path: saved to history and pasted into the frontmost app.
    case paste
    /// A "Try it" test from onboarding's last step: shown there, never pasted or saved.
    case onboardingTest

    /// A recording is a test when it starts while onboarding's last step is showing and
    /// NanoWhisper is the active app (the onboarding window is in front). A recording
    /// started while another app is in front is a normal dictation.
    static func atStart(testBoxShowing: Bool, appIsActive: Bool) -> DictationDestination {
        testBoxShowing && appIsActive ? .onboardingTest : .paste
    }
}

/// Why a recording produced no text although something may have been said. Distinct from an
/// empty result (the engine ran and recognized nothing).
enum TranscriptionFailure: Error, Equatable, Sendable {
    /// No engine was installed when the recording was submitted.
    case noEngine
    /// The engine threw; the underlying error is logged by `Transcriber`.
    case engineError

    /// The line shown in the menu.
    var message: String {
        switch self {
        case .noEngine: return "Transcription failed: no model is loaded."
        case .engineError: return "Transcription failed. Try again."
        }
    }
}

/// What to do with a finished transcription.
enum DictationOutcome: Equatable {
    /// Show it in the Try-it box (may be empty: "Nothing was recognized").
    case showTestResult(String)
    /// A test whose box is gone (onboarding closed or left the last step): drop it.
    case discard
    /// Normal dictation with no text: report "Empty transcription".
    case noResult
    /// Normal dictation: save to history and paste.
    case deliver(String)
    /// The engine failed: report the error (menu line), never as "Empty transcription".
    case failed(TranscriptionFailure)

    static func resolve(
        destination: DictationDestination, text: String, failure: TranscriptionFailure? = nil,
        testBoxShowing: Bool
    ) -> DictationOutcome {
        switch destination {
        case .onboardingTest:
            guard testBoxShowing else { return .discard }
            if let failure { return .failed(failure) }
            return .showTestResult(text)
        case .paste:
            if let failure { return .failed(failure) }
            return text.isEmpty ? .noResult : .deliver(text)
        }
    }
}
