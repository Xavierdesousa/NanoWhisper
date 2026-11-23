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

/// The dictation the welcome's recorder plays, step by step as the real recorder shows one
/// (maintainer, 2026-11-21): the recorder fades up idle at 0:00 (still capsule, no text, flat
/// waveform); `idleWait` after it has arrived it records for `recordingDuration` (0:00 → 0:04,
/// the words at `wordsPerSecond`), then on its own: Transcribing (`transcribingDuration`),
/// Pasted with the green check (`pastedDuration`), then a veil with Replay (`Phase.ended`),
/// where it stays. Stop ends the recording at once, then the same steps. Replay plays it again
/// from the start of the recording (0:00, no text). A simulation: nothing here opens the
/// microphone or pastes anything.
/// Times are seconds from the press of Get Started (the opening scene, `OpeningScene.Tweak`).
enum WelcomeDictation {
    enum Phase: Equatable, Sendable {
        /// The page arrives; the recorder waits at 0:00, paused.
        case idle
        case recording
        /// The real transcribing state: the capsule turns light, the bars sink, the sweep runs.
        case transcribing
        /// "Pasted" with the green check, and the final text.
        case pasted
        /// The pasted card under a veil with Replay. Nothing moves.
        case ended
    }

    /// When the recorder starts to fade in, idle.
    static let recorderAppears: TimeInterval = OpeningScene.Tweak.recorderAt
    /// When the recorder has faded in.
    static let entranceEnds: TimeInterval = OpeningScene.Times.recorderIn
    /// The pause between the recorder's arrival and the start of the recording (maintainer:
    /// 1 s, then 0.25 s were too long; 125 ms, 2026-11-21).
    static let idleWait: TimeInterval = OpeningScene.Tweak.recordingStartsAfter
    /// The recording starts: the capsule pulses, the timer and the waveform run.
    static var recordingStarts: TimeInterval { entranceEnds + idleWait }
    /// How long the recording runs when Stop is not pressed: long enough for the timer to show
    /// 0:04, with a short silence after the sentence, as before someone presses Stop.
    static let recordingDuration: TimeInterval = OpeningScene.Tweak.recordingLength
    /// The recording ends by itself.
    static var recordingEnds: TimeInterval { recordingStarts + recordingDuration }

    /// The pace of the speech, in words per second. The maintainer's real dictations run about
    /// 1.7–2.2 words per second (2026-11-21); at most 1.25 times that stays lively but
    /// believable (the former 29 words in 2.7 s, 10.7 words per second, read as sped up). The
    /// words and the waveform's syllables both follow it.
    static let wordsPerSecond: Double = 2.6
    /// The live text writes faster than the voice (maintainer, 2026-11-21: the waveform's pace is
    /// right, but more text must show; then the 24-word sentence over 5 s): the whole sentence is
    /// written by the end of the recording. The waveform keeps `wordsPerSecond`.
    static let textWordsPerSecond: Double = 5.0
    /// The text arrives in groups of one to three words, as the real live transcription delivers
    /// it (each re-decode settles a few words at once), not word by word (maintainer,
    /// 2026-11-21). Cycled over the sentence; a group shows when its last word has been said.
    static let groupSizes = [2, 1, 3, 2, 1, 3, 2, 2, 1, 3]
    /// The first word starts a moment after the recording, as when someone starts speaking.
    static let speechLeadIn: TimeInterval = 0.2
    static var speechStarts: TimeInterval { recordingStarts + speechLeadIn }
    /// Each word has a slot of 1 / `wordsPerSecond`: voiced for this share of it, then a short
    /// gap before the next word; a longer one after a comma or a full stop.
    static let voicedShare = 0.78
    static let voicedShareBeforePause = 0.55
    /// A word shows once it has been said (live text follows the voice): this far into its slot.
    static let wordShowsAt = 0.8

    /// Transcribing, then Pasted, as the real recorder shows them, short (maintainer: well under
    /// a second, long enough to see the sweep; the check long enough to be seen).
    static let transcribingDuration: TimeInterval = 0.8
    /// The Pasted card stays this long before the veil and Replay (maintainer, 2026-11-21: Replay
    /// came too soon; 1.5 s later than the first 0.35 s).
    static let pastedDuration: TimeInterval = 0.35 + 1.5
    /// The veil fades in over this time (at once with Reduce Motion).
    static let veilFade: TimeInterval = 0.3

    /// The newest words are shown dimmer, as the live text's tail.
    static let dimWordCount = 2

    static var words: [String] {
        OnboardingText.welcomeSentence.split(separator: " ").map(String.init)
    }

    // MARK: Steps

    /// When the recording ends: by itself, or when Stop was pressed (`stoppedAt`).
    static func recordingEnd(stoppedAt: TimeInterval?) -> TimeInterval {
        min(stoppedAt ?? .infinity, recordingEnds)
    }

    /// When the veil shows.
    static func endsAt(stoppedAt: TimeInterval?) -> TimeInterval {
        recordingEnd(stoppedAt: stoppedAt) + transcribingDuration + pastedDuration
    }

    static func phase(at time: TimeInterval, stoppedAt: TimeInterval? = nil) -> Phase {
        let end = recordingEnd(stoppedAt: stoppedAt)
        if time >= end + transcribingDuration + pastedDuration { return .ended }
        if time >= end + transcribingDuration { return .pasted }
        if time >= end { return .transcribing }
        return time >= recordingStarts ? .recording : .idle
    }

    // MARK: Words

    /// Words shown at `time`: whole groups (`groupSizes`), each once its last word is said.
    static func wordCount(at time: TimeInterval) -> Int {
        guard time >= speechStarts else { return 0 }
        var shown = 0
        for last in groupLastWords where wordSaid(last) <= time + 1e-9 { shown = last + 1 }
        return shown
    }

    /// When word `index` (from 0) has been said, at `textWordsPerSecond`.
    static func wordSaid(_ index: Int) -> TimeInterval {
        speechStarts + (Double(index) + wordShowsAt) / textWordsPerSecond
    }

    /// When word `index` (from 0) shows: with the rest of its group.
    static func wordShows(_ index: Int) -> TimeInterval {
        wordSaid(groupLastWords.first { $0 >= index } ?? index)
    }

    /// The index of each group's last word.
    static var groupLastWords: [Int] {
        var ends: [Int] = []
        var next = 0
        var size = 0
        while next < words.count {
            next = min(words.count, next + groupSizes[size % groupSizes.count])
            ends.append(next - 1)
            size += 1
        }
        return ends
    }

    /// The live text at `time`: the settled words, and the newest ones (dimmer) with their
    /// leading space. It stops changing when the recording ends.
    static func text(at time: TimeInterval, stoppedAt: TimeInterval? = nil) -> (stable: String, volatile: String) {
        let shown = Array(words.prefix(wordCount(at: min(time, recordingEnd(stoppedAt: stoppedAt)))))
        let settled = max(0, shown.count - dimWordCount)
        let stable = shown.prefix(settled).joined(separator: " ")
        let tail = shown.dropFirst(settled).joined(separator: " ")
        return (stable, tail.isEmpty ? "" : (stable.isEmpty ? tail : " " + tail))
    }

    /// What is "pasted": the words shown before the end (whole groups; a group not yet shown at
    /// Stop is dropped, as the live text had not settled it), as a transcription writes them (a
    /// sentence cut by Stop ends with a full stop, not a comma).
    static func finalText(stoppedAt: TimeInterval? = nil) -> String {
        var text = words.prefix(wordCount(at: recordingEnd(stoppedAt: stoppedAt))).joined(separator: " ")
        while let last = text.last, ",;:".contains(last) { text.removeLast() }
        if let last = text.last, !".!?".contains(last) { text.append(".") }
        return text
    }

    /// The timer: whole seconds since the recording started (0:00 while idle), stopped when the
    /// recording ends.
    static func elapsedSeconds(at time: TimeInterval, stoppedAt: TimeInterval? = nil) -> Int {
        let recorded = min(time, recordingEnd(stoppedAt: stoppedAt)) - recordingStarts
        return max(0, Int((recorded + 1e-9).rounded(.down)))
    }

    // MARK: Levels

    /// Room noise, below the waveform's silence floor.
    static let roomNoise: Float = 0.04

    /// A speech-like level (the `AudioRecorder` scale, 0…1) that follows the words: room noise
    /// outside them; inside a word one bump per syllable, each word a little louder or softer
    /// than the last; short gaps between words, longer after punctuation.
    static func level(at time: TimeInterval) -> Float {
        let slot = (time - speechStarts) * wordsPerSecond
        let words = self.words
        guard slot >= 0, Int(slot) < words.count else { return roomNoise }
        let index = Int(slot)
        let word = words[index]
        let voiced = endsWithPause(word) ? voicedShareBeforePause : voicedShare
        let progress = (slot - Double(index)) / voiced
        guard progress < 1 else { return roomNoise }
        let bump = abs(sin(.pi * progress * Double(syllableCount(word))))
        let loudness = 0.72 + 0.28 * abs(sin(Double(index) * 2.17 + 0.6))
        return Float(max(Double(roomNoise), min(1, loudness * (0.4 + 0.6 * bump))))
    }

    /// Groups of vowels, from 1 to 3: "payment" 2, "flow" 1.
    static func syllableCount(_ word: String) -> Int {
        var groups = 0
        var inVowel = false
        for character in word.lowercased() {
            let isVowel = "aeiouy".contains(character)
            if isVowel && !inVowel { groups += 1 }
            inVowel = isVowel
        }
        return min(3, max(1, groups))
    }

    static func endsWithPause(_ word: String) -> Bool {
        guard let last = word.last else { return false }
        return ",.;:!?".contains(last)
    }

    /// Interval between two levels, as `AudioRecorder` publishes them.
    static let levelInterval: TimeInterval = 0.02

    /// The waveform at `time`, computed the way `OverlayWaveform` builds it live from the start
    /// of the recording (envelope, normalizer, 50 ms slots): the still frames of renders.
    static func history(until time: TimeInterval) -> LevelHistory {
        var history = LevelHistory()
        var envelope = LevelEnvelope()
        var normalizer = LevelNormalizer()
        let steps = max(0, Int(((time - recordingStarts) / levelInterval).rounded()))
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
