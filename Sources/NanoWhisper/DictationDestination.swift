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

    static func resolve(
        destination: DictationDestination, text: String, testBoxShowing: Bool
    ) -> DictationOutcome {
        switch destination {
        case .onboardingTest:
            return testBoxShowing ? .showTestResult(text) : .discard
        case .paste:
            return text.isEmpty ? .noResult : .deliver(text)
        }
    }
}
