import Foundation

/// Every string the onboarding window shows, in one place (English only for now), so another
/// language can be added here later. Rows shared with Settings keep `SettingsText`'s wording.
enum OnboardingText {
    /// The copy names the product "NanoWhisper". System Settings lists the app under its build's
    /// display name ("NanoWhisper Debug" for the debug build), so captions that point there use it.
    static var appName: String { BuildFlavor.current.displayName }

    static let continueButton = "Continue"
    static let change = "Change…"
    /// VoiceOver values of the setup rows' circles.
    static let allowed = "Allowed"
    static let notAllowed = "Not allowed"

    // MARK: Welcome

    /// The opening scene's title (the product, in both builds) and its button.
    static let sceneTitle = "NanoWhisper"
    static let getStarted = "Get Started"
    static let headline = "Speak where you’d type."
    static let catchPhrase = "NanoWhisper turns your voice into text on this Mac and puts it where your cursor is."

    struct Fact: Equatable {
        /// An SF Symbol, or nil for the text cursor (no plain I-beam symbol exists).
        var systemImage: String?
        var title: String
        var detail: String
    }

    static let facts = [
        Fact(systemImage: "laptopcomputer", title: "On this Mac", detail: "Your voice is transcribed here. Nothing is sent to a server."),
        Fact(systemImage: "lock", title: "Private history", detail: "Encrypted, stays on this Mac."),
        Fact(systemImage: "bolt", title: "Fast", detail: "Your text arrives right after you speak."),
        Fact(systemImage: nil, title: "Pasted for you", detail: "Right where your cursor is, in any app."),
    ]

    /// Dictated by the welcome's recorder in its 4 s (`WelcomeDictation.wordsPerSecond`): a
    /// whole phrase, so the pasted text reads as one. Spoken, not written: most dictations are
    /// someone talking an agent through a plan (maintainer, 2026-11-21).
    static let welcomeSentence = "So the plan for this week is the payment flow."
    static let welcomeRecorderLabel = "Recorder, as it appears while you dictate"
    /// The welcome's recorder, once its dictation has played.
    static let replay = "Replay"
    static let stopRecording = "Stop recording"

    // MARK: Setup page

    static let setupTitle = "Set up NanoWhisper"
    static let setupSubtitle = "Allow the microphone, check the defaults, then try it."

    static let gettingReady = "Getting ready"
    static let microphone = "Microphone"
    static let required = "Required"
    static let microphoneCaption = "Used only between the two presses of your shortcut."
    static let microphoneDeniedCaption = "Turned off in System Settings. macOS won’t ask again."
    static let pasting = "Pasting into other apps"
    static let recommended = "Recommended"
    static let pastingCaption = "Without it, text stays in History. macOS calls this Accessibility."
    /// With history off nothing keeps the text, so the caption does not promise History.
    static let pastingCaptionWithoutHistory = "Without it, nothing is pasted. macOS calls this Accessibility."

    static let modelSection = "Model"
    static let modelCaption = "The speech model that runs on this Mac."
    static let optimizing = "Optimizing…"
    static let loading = "Loading…"
    static let tryAgain = "Try Again"
    static let modelDone = "On this Mac"

    /// "Parakeet Ultra by NVIDIA".
    static func modelTitle(_ configuration: EngineConfiguration) -> String {
        "\(configuration.modelName) by \(configuration.modelType.vendor)"
    }

    /// "23% of ~630 MB", or "Downloading…" without a percentage.
    static func downloadAmount(_ fraction: Double?, of size: String) -> String {
        guard let fraction else { return "Downloading…" }
        return "\(Int((fraction * 100).rounded(.down)))% of \(size)"
    }

    static let dictationSection = "Dictation"
    static let settingsSection = "Settings"

    static let footerAllowMicrophone = "Allow the microphone to dictate."
    static let footerMicrophoneNeeded = "Dictation needs the microphone."
    static let footerChangeLater = "You can change all of this later in Settings."
    static func footerKeepsDownloading(_ engine: TranscriptionModelType) -> String {
        "\(engine.displayName) keeps downloading while you go on."
    }

    static let modelChoiceDone = "Done"

    // MARK: Try it

    static let tryTitle = "Try it"
    static let tryInstructionBefore = "Press"
    static let tryInstructionAfter = ", say a sentence, then press it again to see what you said."
    static let press = "Press"
    static let toStart = "to start"
    static let or = "or"
    static let startRecording = "Start Recording"
    static let listening = "Listening…"
    static let againToStop = "again to stop"
    static let stop = "Stop"
    static let transcribing = "Transcribing on this Mac…"
    static let youSaid = "You said"
    static let transcribedHere = "Transcribed on this Mac."
    static let nothingRecognized = "Nothing was recognized. Speak a little longer, a bit closer to the microphone."
    static let back = "Back"
    static let finishSetup = "Finish Setup"

    /// Where the recorder appears, in words ("at the top of the screen").
    static func recorderPlace(_ position: RecorderPosition) -> String {
        switch position {
        case .topLeft: return "at the top left of the screen"
        case .topCenter: return "at the top of the screen"
        case .topRight: return "at the top right of the screen"
        case .bottomCenter: return "at the bottom of the screen"
        }
    }

    static func readyNote(_ position: RecorderPosition) -> String {
        "The recorder appears \(recorderPlace(position)), as it will in any app."
    }

    /// While listening. Only with live transcription (debug builds) do the words show in the
    /// recorder; otherwise it shows the waveform and the timer.
    static func listeningNote(_ position: RecorderPosition, showsWords: Bool) -> String {
        showsWords
            ? "Your words write themselves in the recorder \(recorderPlace(position))."
            : "The recorder \(recorderPlace(position)) shows your voice as you speak."
    }

    static func stillDownloading(_ modelName: String) -> String { "\(modelName) is still downloading" }
    static func optimizingModel(_ modelName: String) -> String { "Optimizing \(modelName) for this Mac…" }
    static func loadingModel(_ modelName: String) -> String { "Loading \(modelName)…" }
    static func modelFailed(_ modelName: String) -> String { "Could not set up \(modelName)" }
    static let modelNotReadyNote = "You can try it as soon as it’s ready. You can also finish now: it keeps downloading, and the menu bar icon shows when it’s ready."
    static let modelPreparingNote = "You can try it as soon as it’s ready. You can also finish now: the menu bar icon shows when it’s ready."

    static let microphoneOff = "The microphone is off"
    static var microphoneOffNote: String {
        "\(appName) can’t hear you until it’s allowed in System Settings, Privacy & Security, Microphone. This page updates by itself."
    }
    static let microphoneNotAllowed = "Allow the microphone"
    static var microphoneNotAllowedNote: String {
        "\(appName) can’t hear you until you allow the microphone. macOS asks you once. This page updates by itself."
    }
}
