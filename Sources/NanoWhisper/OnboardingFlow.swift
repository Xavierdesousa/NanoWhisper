import AppKit
import Combine
import Foundation

// MARK: - Pages

/// The onboarding pages, in one window: Welcome, the setup page, then Try it. Nothing blocks:
/// Continue is always available and Try it says what is missing, if anything.
enum OnboardingPage: Int, CaseIterable, Equatable, Sendable {
    case welcome
    case setup
    case tryIt

    /// Where Continue leads (none from Try it, whose button is Finish Setup).
    var next: OnboardingPage? { OnboardingPage(rawValue: rawValue + 1) }

    /// Where Back leads. Only Try it has a Back button (to the setup page); the setup page has
    /// none, as drawn.
    var previous: OnboardingPage? { self == .tryIt ? .setup : nil }

    /// A recording started while this page shows (with the app in front) is a test whose text
    /// shows in the window, never pasted or saved (`DictationDestination.onboardingTest`).
    var capturesTestTranscription: Bool { self == .tryIt }
}

// MARK: - Setup page: the circles on the left

/// The mark on the left of a setup row: a circle that becomes a check.
enum SetupMark: Equatable, Sendable {
    /// Not done yet.
    case empty
    case checked
    /// Needs the user (denied microphone, failed model setup).
    case attention
    /// A download with a known fraction: the ring fills.
    case progress(Double)
    /// Working without a fraction (preparing, optimizing, loading).
    case busy
}

/// One permission row of "Getting ready".
struct PermissionChecklistDisplay: Equatable {
    var mark: SetupMark
    var caption: String
    /// The caption says something is wrong (drawn in red).
    var isProblem = false
    /// "Allow…" (system request) or "Open System Settings"; nil once granted.
    var buttonTitle: String?

    /// - Parameter historyEnabled: Without Accessibility nothing is pasted; the text is only
    ///   kept when history is on, so the caption says so only then.
    static func resolve(_ permission: Permission, status: PermissionStatus, historyEnabled: Bool) -> PermissionChecklistDisplay {
        let button = Permission.actionTitle(for: status)
        switch permission {
        case .microphone:
            switch status {
            case .granted: return PermissionChecklistDisplay(mark: .checked, caption: OnboardingText.microphoneCaption)
            case .notDetermined: return PermissionChecklistDisplay(mark: .empty, caption: OnboardingText.microphoneCaption, buttonTitle: button)
            case .denied:
                return PermissionChecklistDisplay(
                    mark: .attention, caption: OnboardingText.microphoneDeniedCaption, isProblem: true, buttonTitle: button)
            }
        case .accessibility:
            let caption = historyEnabled ? OnboardingText.pastingCaption : OnboardingText.pastingCaptionWithoutHistory
            // Accessibility has no "denied" answer: after the system prompt, the way left is
            // System Settings. The circle stays empty rather than warning.
            return PermissionChecklistDisplay(mark: status.isGranted ? .checked : .empty, caption: caption, buttonTitle: button)
        }
    }
}

/// The Model row: the model in effect, its status on the left, a short status on the right.
struct ModelChecklistDisplay: Equatable {
    var mark: SetupMark
    /// "Parakeet Ultra by NVIDIA".
    var title: String
    var caption: String
    var isProblem = false
    /// Right of the title while working ("23% of ~630 MB"); hidden under the pointer, where
    /// Change… takes its place.
    var detail: String?
    /// The setup failed: Try Again retries it.
    var offersRetry = false
    /// Still downloading (the footer says it keeps going).
    var isDownloading = false

    var isDone: Bool { mark == .checked }

    static func resolve(
        applied: EngineConfiguration, state: EngineState, availability: ModelAvailability
    ) -> ModelChecklistDisplay {
        let title = OnboardingText.modelTitle(applied)
        let caption = OnboardingText.modelCaption
        let status = ModelStatus.resolve(state)
        if case .failed(let message) = status {
            return ModelChecklistDisplay(mark: .attention, title: title, caption: message, isProblem: true, offersRetry: true)
        }
        // A migration's new model downloading while the previous one is in use.
        if status == .ready, let upgrade = state.upgrade, case .downloading(let fraction) = upgrade.status {
            return ModelChecklistDisplay(
                mark: fraction.map(SetupMark.progress) ?? .busy, title: title, caption: ModelUpgradeText.detail(upgrade),
                detail: OnboardingText.downloadAmount(fraction, of: upgrade.to.sizeDescription), isDownloading: true)
        }
        // On this Mac (loaded, or its files complete on disk): checked, even while it loads.
        if status == .ready || availability == .downloaded {
            return ModelChecklistDisplay(mark: .checked, title: title, caption: caption)
        }
        switch status {
        case .downloading(let fraction):
            return ModelChecklistDisplay(
                mark: fraction.map(SetupMark.progress) ?? .busy, title: title, caption: caption,
                detail: OnboardingText.downloadAmount(fraction, of: applied.downloadSize), isDownloading: true)
        case .compiling:
            return ModelChecklistDisplay(mark: .busy, title: title, caption: caption, detail: OnboardingText.optimizing)
        case .loading:
            return ModelChecklistDisplay(mark: .busy, title: title, caption: caption, detail: OnboardingText.loading)
        case .notLoaded:
            return ModelChecklistDisplay(mark: .empty, title: title, caption: caption, detail: applied.downloadSize)
        case .ready, .failed:
            return ModelChecklistDisplay(mark: .checked, title: title, caption: caption)
        }
    }
}

/// The line on the left of the setup page's footer.
enum SetupFooterNote {
    static func resolve(microphone: PermissionStatus, model: ModelChecklistDisplay, engine: TranscriptionModelType) -> String {
        switch microphone {
        case .notDetermined: return OnboardingText.footerAllowMicrophone
        case .denied: return OnboardingText.footerMicrophoneNeeded
        case .granted:
            return model.isDownloading ? OnboardingText.footerKeepsDownloading(engine) : OnboardingText.footerChangeLater
        }
    }
}

// MARK: - Try it

/// What the Try it page shows. The recorder itself is the real overlay, at its real place.
enum TryItStage: Equatable {
    case ready
    case listening
    case transcribing
    /// The text of the test (empty: nothing was recognized).
    case result(String)
    /// The microphone is not allowed: never asked (`.notDetermined`) or denied.
    case microphoneMissing(PermissionStatus)
    /// The model in effect is not ready yet (downloading, optimizing, loading, failed).
    case modelNotReady(ModelStatus)

    /// - Parameters:
    ///   - isRecording: a recording is in progress.
    ///   - isFinishing: the recording was stopped and still captures its last few hundred ms
    ///     (`AppState.recordingTail`): already shown as transcribing.
    ///   - transcript: the last test's text, nil before the first one.
    static func resolve(
        microphone: PermissionStatus, modelStatus: ModelStatus, isEngineReady: Bool,
        isRecording: Bool, isFinishing: Bool, isTranscribing: Bool, transcript: String?
    ) -> TryItStage {
        if isRecording { return .listening }
        if isFinishing || isTranscribing { return .transcribing }
        if !microphone.isGranted { return .microphoneMissing(microphone) }
        if !isEngineReady { return .modelNotReady(modelStatus == .ready ? .loading : modelStatus) }
        if let transcript { return .result(transcript) }
        return .ready
    }

    /// Finish Setup is off only while it listens or transcribes.
    var allowsFinish: Bool {
        switch self {
        case .listening, .transcribing: return false
        default: return true
        }
    }

    /// Whether Start Recording (and the shortcut) can start a test now.
    var canStartRecording: Bool {
        switch self {
        case .ready, .result: return true
        default: return false
        }
    }
}

// MARK: - Navigation

/// The onboarding window's state: the page shown and the model sheet. Its actions reach the app
/// through `Actions`, so the flow is tested without a running app.
@MainActor
final class OnboardingModel: ObservableObject {
    struct Actions {
        /// A page was shown (also the first one). The app starts the model download on the
        /// setup page and captures test dictations on Try it.
        var pageDidAppear: (OnboardingPage) -> Void = { _ in }
        /// Finish Setup: complete onboarding, close the window, hand over to the menu bar.
        var finish: () -> Void = {}
    }

    @Published private(set) var page: OnboardingPage
    /// The model choice sheet (Change… on the Model row).
    @Published var showsModelChoice = false
    private let actions: Actions

    init(page: OnboardingPage = .welcome, actions: Actions = Actions()) {
        self.page = page
        self.actions = actions
    }

    /// Call once the window shows its first page.
    func start() {
        actions.pageDidAppear(page)
    }

    func goForward() {
        guard let next = page.next else { return }
        show(next)
    }

    func goBack() {
        guard let previous = page.previous else { return }
        show(previous)
    }

    /// Finish Setup. Refused while a test listens or transcribes (the button is off then).
    /// - Returns: whether onboarding finished.
    @discardableResult
    func finish(stage: TryItStage) -> Bool {
        guard page == .tryIt, stage.allowsFinish else { return false }
        actions.finish()
        return true
    }

    private func show(_ newPage: OnboardingPage) {
        showsModelChoice = false
        page = newPage
        actions.pageDidAppear(newPage)
    }
}

/// Finish Setup, in order: remember onboarding as done, close the window (the app returns to
/// the menu bar only), make sure a model loads, then let the menu bar take over (the "After
/// setup" popover under the status item).
enum OnboardingCompletion {
    @MainActor
    static func finish(
        defaults: UserDefaults, closeWindow: () -> Void, loadModel: () -> Void, handoff: (() -> Void)?
    ) {
        defaults.set(true, forKey: AppState.onboardingCompleteKey)
        closeWindow()
        loadModel()
        handoff?()
    }
}

// MARK: - Opening the window

/// What opening onboarding does. First launch, "Finish Setup…" and `--onboarding` bring an open
/// window to the front as it is; the debug build's "Open Onboarding" restarts it from the
/// opening scene (its content replaced, the window kept where it is).
enum OnboardingPresentation: Equatable {
    /// A new window, at the welcome's opening scene.
    case open
    /// The open window, as it is.
    case bringToFront
    /// The open window, its content new: the opening scene plays again from its start.
    case restart

    static func resolve(isOpen: Bool, restart: Bool) -> OnboardingPresentation {
        guard isOpen else { return .open }
        return restart ? .restart : .bringToFront
    }
}

// MARK: - Defaults for a new install

/// Settings that start on for a new install, as the setup page draws them: all four switches.
/// Existing installs keep what they had (stored or, for a value never stored, the old default).
enum NewInstallDefaults {
    static let pauseMediaKey = "pauseMediaEnabled"
    /// Set at the first launch of a new install; consumed when the setup page first shows.
    static let launchAtLoginPendingKey = "launchAtLoginDefaultPending"

    /// "Pause music and videos while recording": on for a new install (since the onboarding
    /// redesign), off for an install that ran before and never chose (the old default).
    static func pauseMedia(stored: Bool?, isExistingInstall: Bool) -> Bool {
        stored ?? !isExistingInstall
    }

    /// At launch, before anything writes a setting: resolve the pause-media setting and store
    /// it (so it does not change once the install counts as existing), and remember that a new
    /// install should open at login.
    /// - Returns: the pause-media setting.
    static func apply(isExistingInstall: Bool, to defaults: UserDefaults) -> Bool {
        let pauseMedia = pauseMedia(stored: defaults.object(forKey: pauseMediaKey) as? Bool, isExistingInstall: isExistingInstall)
        defaults.set(pauseMedia, forKey: pauseMediaKey)
        if !isExistingInstall {
            defaults.set(true, forKey: launchAtLoginPendingKey)
        }
        return pauseMedia
    }

    /// Whether "Open at login" should be turned on now (the setup page shows it on). True once
    /// per new install: the login item is registered when the user sees the switch, not at an
    /// unseen first launch.
    static func takeLaunchAtLogin(from defaults: UserDefaults) -> Bool {
        guard defaults.bool(forKey: launchAtLoginPendingKey) else { return false }
        defaults.removeObject(forKey: launchAtLoginPendingKey)
        return true
    }
}

// MARK: - Window placement

/// Where the onboarding window opens: centred on the screen, moved away from the recorder's
/// place if they would meet, so the real recorder never covers the window during Try it.
@MainActor
enum OnboardingWindowPlacement {
    /// Every page: 580 × 640 pt.
    static let size = CGSize(width: 580, height: 640)
    /// The recorder at its largest: the card with three lines of live text (380 × 106 pt).
    static var recorderSize: CGSize {
        CGSize(
            width: OverlayMetrics.cardWidth,
            height: OverlayMetrics.headerHeight + LiveTranscriptText.height(lines: LiveTranscriptText.defaultLineCount)
                + OverlayMetrics.textBottomInset
        )
    }
    /// Space kept between the recorder and the window.
    static let gap: CGFloat = 16

    /// - Parameters:
    ///   - visible: the screen's visible frame (AppKit coordinates).
    ///   - recorder: where the recorder appears (`AppState.recorderPosition`).
    static func frame(size: CGSize = size, in visible: NSRect, recorder: RecorderPosition) -> NSRect {
        var frame = NSRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded(),
            width: size.width, height: size.height
        )
        let card = recorder.initialFrame(size: recorderSize, in: visible)
        let overlapsHorizontally = frame.minX < card.maxX + gap && card.minX - gap < frame.maxX
        if overlapsHorizontally {
            switch recorder.verticalAnchor {
            case .top: frame.origin.y = min(frame.origin.y, card.minY - gap - size.height)
            case .bottom: frame.origin.y = max(frame.origin.y, card.maxY + gap)
            }
        }
        // Never outside the visible frame (a very small screen: the window wins).
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - size.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - size.width)
        return frame
    }
}

// MARK: - Welcome recorder (simulated dictation)

/// The dictation the welcome's recorder plays (the maintainer's sequence, 2026-11-21): the
/// recorder fades up idle at 0:00 (still capsule, no text, flat waveform); `idleWait` after it
/// has arrived the recording starts (the capsule pulses, the timer runs, the waveform moves, the
/// words write themselves) and runs 3 s; then everything stops and stays, paused: up to three
/// lines, the last two words dimmer, a steady caret, 0:03.
/// Times are seconds from the press of Get Started (the opening scene, `OpeningScene.Tweak`).
enum WelcomeDictation {
    /// When the recorder starts to fade in, idle.
    static let recorderAppears: TimeInterval = OpeningScene.Tweak.recorderAt
    /// When the recorder has faded in.
    static let entranceEnds: TimeInterval = OpeningScene.Times.recorderIn
    /// The pause between the recorder's arrival and the start of the recording (maintainer:
    /// 1 s, then 0.25 s were too long; 125 ms, 2026-11-21).
    static let idleWait: TimeInterval = OpeningScene.Tweak.recordingStartsAfter
    /// The recording starts: the capsule pulses, the timer and the waveform run.
    static var recordingStarts: TimeInterval { entranceEnds + idleWait }
    /// The first word, a moment after the start, as when someone starts speaking.
    static var firstWord: TimeInterval { recordingStarts + 0.15 }
    /// From the first word to the last: the whole sentence in under 3 s, to show it is fast.
    static let span: TimeInterval = OpeningScene.Tweak.dictationSpan
    /// How long the recording runs before it stops and stays.
    static let recordingDuration: TimeInterval = OpeningScene.Tweak.recordingLength
    /// The levels' sine phase: the waveform keeps the shape approved before the opening scene,
    /// when the recording started 0.745 s after the window opened (the prototype does the same).
    static let levelPhase: TimeInterval = 0.745
    /// When it stops and stays.
    static var freezeTime: TimeInterval { recordingStarts + recordingDuration }
    /// The newest words are shown dimmer, as the live text's tail.
    static let dimWordCount = 2

    static var words: [String] {
        OnboardingText.welcomeSentence.split(separator: " ").map(String.init)
    }

    /// Words shown at `time`: the first at `firstWord`, the last `span` later.
    static func wordCount(at time: TimeInterval) -> Int {
        guard time >= firstWord else { return 0 }
        let step = span / Double(max(1, words.count - 1))
        return min(words.count, Int(((time - firstWord) / step).rounded(.down)) + 1)
    }

    /// The text at `time`: the settled words, and the newest ones (dimmer) with their leading space.
    static func text(at time: TimeInterval) -> (stable: String, volatile: String) {
        let shown = Array(words.prefix(wordCount(at: time)))
        let settled = max(0, shown.count - dimWordCount)
        let stable = shown.prefix(settled).joined(separator: " ")
        let tail = shown.dropFirst(settled).joined(separator: " ")
        return (stable, tail.isEmpty ? "" : (stable.isEmpty ? tail : " " + tail))
    }

    /// The timer: whole seconds since the recording started (0:00 while idle), stopped at the freeze.
    static func elapsedSeconds(at time: TimeInterval) -> Int {
        max(0, Int((min(time, freezeTime) - recordingStarts).rounded(.down)))
    }

    /// A speech-like level (the `AudioRecorder` scale, 0…1): room noise until just before the
    /// first word, then syllables with short pauses.
    static func level(at time: TimeInterval) -> Float {
        guard time >= firstWord - 0.08 else { return 0.04 }
        // Faster than real speech, matching the quick sentence (2026-11-21).
        let phase = time - recordingStarts + levelPhase
        let pause = sin(phase * 3.7 + 0.5) > 0.85 ? 0.0 : 1.0
        let syllable = abs(sin(phase * 12.3 + 0.3)) * (0.45 + 0.55 * abs(sin(phase * 2.6 + 1.2)))
        return Float(max(0.04, pause * min(1, 0.25 + 0.75 * syllable)))
    }

    /// Interval between two levels, as `AudioRecorder` publishes them.
    static let levelInterval: TimeInterval = 0.02

    /// The waveform at the freeze, computed the way `OverlayWaveform` builds it live from the
    /// start of the recording (envelope, normalizer, 50 ms slots): what Reduce Motion shows at once.
    static func frozenHistory() -> LevelHistory {
        var history = LevelHistory()
        var envelope = LevelEnvelope()
        var normalizer = LevelNormalizer()
        let steps = Int(((freezeTime - recordingStarts) / levelInterval).rounded())
        let perSlot = Int((LevelHistory.slotDuration / levelInterval).rounded(.up))
        for step in 0..<steps {
            let time = recordingStarts + Double(step) * levelInterval
            history.record(normalizer.normalize(envelope.follow(level(at: time))))
            if step % perSlot == perSlot - 1 { history.advance() }
        }
        return history
    }
}

// MARK: - Launch arguments

/// Command-line switches for testing onboarding (`open -a NanoWhisper --args --onboarding`).
struct LaunchOptions: Equatable {
    /// `--onboarding`: show onboarding at launch even if it was completed. Settings are kept.
    var showOnboarding = false
    /// `--reset-onboarding`: clear only the "onboarding completed" flag, so onboarding shows
    /// at this launch and every launch until it is finished again.
    var resetOnboarding = false

    static let showOnboardingArgument = "--onboarding"
    static let resetOnboardingArgument = "--reset-onboarding"

    init(showOnboarding: Bool = false, resetOnboarding: Bool = false) {
        self.showOnboarding = showOnboarding
        self.resetOnboarding = resetOnboarding
    }

    /// Unknown arguments (including the `-Key value` pairs macOS and Xcode pass) are ignored.
    init(arguments: [String]) {
        let args = Set(arguments.dropFirst())
        showOnboarding = args.contains(Self.showOnboardingArgument)
        resetOnboarding = args.contains(Self.resetOnboardingArgument)
    }

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    /// Whether onboarding opens at launch.
    func showsOnboardingAtLaunch(onboardingComplete: Bool) -> Bool {
        !onboardingComplete || showOnboarding || resetOnboarding
    }
}
