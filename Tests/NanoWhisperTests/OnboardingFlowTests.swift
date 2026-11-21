import AppKit
import Combine
import Foundation
import Testing
@testable import NanoWhisper

@Suite("Onboarding pages and navigation")
@MainActor
struct OnboardingNavigationTests {
    @Test("Welcome, setup page, Try it; Back only from Try it; only Try it captures tests")
    func pages() {
        #expect(OnboardingPage.allCases == [.welcome, .setup, .tryIt])
        #expect(OnboardingPage.welcome.next == .setup)
        #expect(OnboardingPage.setup.next == .tryIt)
        #expect(OnboardingPage.tryIt.next == nil)
        #expect(OnboardingPage.welcome.previous == nil)
        #expect(OnboardingPage.setup.previous == nil)
        #expect(OnboardingPage.tryIt.previous == .setup)
        #expect(OnboardingPage.allCases.filter(\.capturesTestTranscription) == [.tryIt])
    }

    @Test("Continue, Continue, Back, Continue: each page tells the app it appeared")
    func progression() {
        var shown: [OnboardingPage] = []
        let model = OnboardingModel(actions: .init(pageDidAppear: { shown.append($0) }))
        model.start()
        #expect(model.page == .welcome)
        model.goBack() // nothing before the welcome
        model.goForward()
        model.goForward()
        #expect(model.page == .tryIt)
        model.goForward() // Try it ends with Finish Setup, not Continue
        model.goBack()
        #expect(model.page == .setup)
        model.goBack() // the setup page has no Back
        model.goForward()
        #expect(shown == [.welcome, .setup, .tryIt, .setup, .tryIt])
    }

    @Test("Leaving a page closes the model sheet")
    func sheetClosesOnPageChange() {
        let model = OnboardingModel(page: .setup)
        model.showsModelChoice = true
        model.goForward()
        #expect(!model.showsModelChoice)
    }

    @Test("Finish Setup: off while a test listens or transcribes, and only on Try it")
    func finish() {
        var finished = 0
        let model = OnboardingModel(page: .setup, actions: .init(finish: { finished += 1 }))
        #expect(!model.finish(stage: .ready), "not from the setup page")
        model.goForward()
        #expect(!model.finish(stage: .listening))
        #expect(!model.finish(stage: .transcribing))
        #expect(finished == 0)
        for stage: TryItStage in [.ready, .result("Hi"), .microphoneMissing(.denied), .modelNotReady(.downloading(fraction: 0.4))] {
            #expect(model.finish(stage: stage))
        }
        #expect(finished == 4)
    }

    @Test("Finish → flag set, window closed, model loaded, then the menu bar handoff")
    func completionOrder() throws {
        let suite = "nanowhisper.onboarding.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var calls: [String] = []
        OnboardingCompletion.finish(
            defaults: defaults,
            closeWindow: {
                #expect(defaults.bool(forKey: AppState.onboardingCompleteKey), "completed before the window closes")
                calls.append("close")
            },
            loadModel: { calls.append("load") },
            handoff: { calls.append("handoff") }
        )
        #expect(calls == ["close", "load", "handoff"])
        #expect(defaults.bool(forKey: AppState.onboardingCompleteKey))
        // No handoff wired (tests, or before the menu bar exists): still completes.
        OnboardingCompletion.finish(defaults: defaults, closeWindow: {}, loadModel: {}, handoff: nil)
    }
}

@Suite("Setup page states")
@MainActor
struct SetupPageStateTests {
    private let ultra = EngineConfiguration(modelType: .parakeet, parakeetVariant: .ultra, whisperSettings: WhisperSettings())

    @Test("Microphone: empty circle and Allow…, a check once allowed, a warning and System Settings when denied")
    func microphone() {
        let ask = PermissionChecklistDisplay.resolve(.microphone, status: .notDetermined, historyEnabled: true)
        #expect(ask.mark == .empty)
        #expect(ask.buttonTitle == "Allow…")
        #expect(ask.caption == OnboardingText.microphoneCaption)
        #expect(!ask.isProblem)

        let granted = PermissionChecklistDisplay.resolve(.microphone, status: .granted, historyEnabled: true)
        #expect(granted.mark == .checked)
        #expect(granted.buttonTitle == nil)

        let denied = PermissionChecklistDisplay.resolve(.microphone, status: .denied, historyEnabled: true)
        #expect(denied.mark == .attention)
        #expect(denied.isProblem)
        #expect(denied.caption == "Turned off in System Settings. macOS won’t ask again.")
        #expect(denied.buttonTitle == "Open System Settings")
    }

    @Test("Pasting: never a warning; its caption promises History only when history is on")
    func pasting() {
        let ask = PermissionChecklistDisplay.resolve(.accessibility, status: .notDetermined, historyEnabled: true)
        #expect(ask.mark == .empty)
        #expect(ask.buttonTitle == "Allow…")
        #expect(ask.caption == "Without it, text stays in History. macOS calls this Accessibility.")
        // After the system prompt, System Settings is the way left; still not a warning.
        let prompted = PermissionChecklistDisplay.resolve(.accessibility, status: .denied, historyEnabled: true)
        #expect(prompted.mark == .empty)
        #expect(prompted.buttonTitle == "Open System Settings")
        #expect(PermissionChecklistDisplay.resolve(.accessibility, status: .granted, historyEnabled: true).mark == .checked)
        let noHistory = PermissionChecklistDisplay.resolve(.accessibility, status: .notDetermined, historyEnabled: false)
        #expect(!noHistory.caption.contains("History"))
    }

    @Test("Model: the ring fills with the download, then a check")
    func modelDownloading() {
        let downloading = ModelChecklistDisplay.resolve(
            applied: ultra, state: EngineState(isSettingUp: true, progressText: "Downloading model (23%)..."),
            availability: .notDownloaded)
        #expect(downloading.mark == .progress(0.23))
        #expect(downloading.title == "Parakeet Ultra by NVIDIA")
        #expect(downloading.caption == "The speech model that runs on this Mac.")
        #expect(downloading.detail == "23% of ~630 MB")
        #expect(downloading.isDownloading)
        #expect(!downloading.isDone)

        let ready = ModelChecklistDisplay.resolve(applied: ultra, state: Fixtures.ready, availability: .downloaded)
        #expect(ready.mark == .checked)
        #expect(ready.detail == nil)
        #expect(ready.isDone)
    }

    @Test("Model already on this Mac: checked at once, even while it loads or is optimized")
    func modelOnDisk() {
        for state in [EngineState(setupComplete: true), EngineState(isSettingUp: true, progressText: "Compiling model..."),
                      EngineState(isSettingUp: true, progressText: "Preparing download...")] {
            #expect(ModelChecklistDisplay.resolve(applied: ultra, state: state, availability: .downloaded).mark == .checked)
        }
    }

    @Test("Model: working without a percentage, optimizing, not started, failed")
    func modelOtherStates() {
        let preparing = ModelChecklistDisplay.resolve(
            applied: ultra, state: EngineState(isSettingUp: true, progressText: "Preparing download..."), availability: .notDownloaded)
        #expect(preparing.mark == .busy)
        #expect(preparing.detail == "Downloading…")

        let optimizing = ModelChecklistDisplay.resolve(
            applied: ultra, state: EngineState(isSettingUp: true, progressText: "Compiling model..."), availability: .unknown)
        #expect(optimizing.mark == .busy)
        #expect(optimizing.detail == "Optimizing…")

        let notStarted = ModelChecklistDisplay.resolve(applied: ultra, state: EngineState(), availability: .notDownloaded)
        #expect(notStarted.mark == .empty)
        #expect(notStarted.detail == "~630 MB")

        let failed = ModelChecklistDisplay.resolve(
            applied: ultra, state: EngineState(error: "Model setup failed."), availability: .downloaded)
        #expect(failed.mark == .attention)
        #expect(failed.caption == "Model setup failed.")
        #expect(failed.isProblem)
        #expect(failed.offersRetry)
    }

    @Test("Model: an existing user's choice is shown as it is")
    func modelOfExistingUser() {
        var whisper = ultra
        whisper.modelType = .whisper
        whisper.whisperSettings.modelSize = .small
        #expect(ModelChecklistDisplay.resolve(applied: whisper, state: Fixtures.ready, availability: .downloaded).title
            == "Whisper Small by OpenAI")
        var v3 = ultra
        v3.parakeetVariant = .v3
        #expect(OnboardingText.modelTitle(v3) == "Parakeet TDT 0.6B v3 by NVIDIA")

        // A migration's new model downloading while the previous one is in use.
        var upgrading = Fixtures.ready
        upgrading.upgrade = ModelUpgrade(from: .parakeet(.v3), to: .parakeet(.ultra), status: .downloading(fraction: 0.42))
        let display = ModelChecklistDisplay.resolve(applied: ultra, state: upgrading, availability: .notDownloaded)
        #expect(display.mark == .progress(0.42))
        #expect(display.caption == "Parakeet TDT 0.6B v3 stays in use until it is ready.")
    }

    @Test("Footer: what is missing first, then the download, then Settings")
    func footer() {
        let downloading = ModelChecklistDisplay.resolve(
            applied: ultra, state: EngineState(isSettingUp: true, progressText: "Downloading model (61%)..."),
            availability: .notDownloaded)
        let ready = ModelChecklistDisplay.resolve(applied: ultra, state: Fixtures.ready, availability: .downloaded)
        #expect(SetupFooterNote.resolve(microphone: .notDetermined, model: downloading, engine: .parakeet) == "Allow the microphone to dictate.")
        #expect(SetupFooterNote.resolve(microphone: .denied, model: ready, engine: .parakeet) == "Dictation needs the microphone.")
        #expect(SetupFooterNote.resolve(microphone: .granted, model: downloading, engine: .parakeet) == "Parakeet keeps downloading while you go on.")
        #expect(SetupFooterNote.resolve(microphone: .granted, model: ready, engine: .parakeet) == "You can change all of this later in Settings.")
    }
}

@Suite("Try it states")
struct TryItStageTests {
    private func stage(
        microphone: PermissionStatus = .granted, model: ModelStatus = .ready, ready: Bool = true,
        recording: Bool = false, finishing: Bool = false, transcribing: Bool = false, transcript: String? = nil
    ) -> TryItStage {
        TryItStage.resolve(
            microphone: microphone, modelStatus: model, isEngineReady: ready, isRecording: recording,
            isFinishing: finishing, isTranscribing: transcribing, transcript: transcript)
    }

    @Test("Ready, listening, transcribing (from the stop on), the result")
    func mainPath() {
        #expect(stage() == .ready)
        #expect(stage(recording: true) == .listening)
        #expect(stage(finishing: true) == .transcribing, "the 300 ms tail after the stop already reads as transcribing")
        #expect(stage(transcribing: true) == .transcribing)
        #expect(stage(transcript: "Let’s meet on Thursday.") == .result("Let’s meet on Thursday."))
        #expect(stage(transcript: "") == .result(""))
    }

    @Test("What is missing: the microphone first, then the model")
    func missing() {
        #expect(stage(microphone: .denied, ready: false) == .microphoneMissing(.denied))
        #expect(stage(microphone: .notDetermined) == .microphoneMissing(.notDetermined))
        #expect(stage(model: .downloading(fraction: 0.64), ready: false) == .modelNotReady(.downloading(fraction: 0.64)))
        #expect(stage(model: .compiling, ready: false) == .modelNotReady(.compiling))
        #expect(stage(model: .failed("x"), ready: false) == .modelNotReady(.failed("x")))
        // A recording in progress wins over everything (a test started before a change).
        #expect(stage(microphone: .denied, ready: false, recording: true) == .listening)
    }

    @Test("Finish Setup is off only while it listens or transcribes; a test starts from ready or a result")
    func buttons() {
        let all: [TryItStage] = [.ready, .listening, .transcribing, .result("a"), .microphoneMissing(.denied), .modelNotReady(.loading)]
        #expect(all.filter { !$0.allowsFinish } == [.listening, .transcribing])
        #expect(all.filter(\.canStartRecording) == [.ready, .result("a")])
    }
}

@Suite("New-install defaults", .serialized)
struct NewInstallDefaultsTests {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "nanowhisper.defaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    @Test("Pause media: on for a new install, off for an older install that never chose, stored value wins")
    func pauseMedia() {
        #expect(NewInstallDefaults.pauseMedia(stored: nil, isExistingInstall: false))
        #expect(!NewInstallDefaults.pauseMedia(stored: nil, isExistingInstall: true))
        #expect(NewInstallDefaults.pauseMedia(stored: true, isExistingInstall: true))
        #expect(!NewInstallDefaults.pauseMedia(stored: false, isExistingInstall: false))
    }

    @Test("A new install stores pause media on, so it stays on once the install counts as existing")
    func newInstallIsStored() throws {
        try withDefaults { defaults in
            #expect(!ModelMigrations.isExistingInstall(defaults))
            #expect(NewInstallDefaults.apply(isExistingInstall: false, to: defaults))
            #expect(defaults.object(forKey: NewInstallDefaults.pauseMediaKey) as? Bool == true)
            // Next launch: the install now counts as existing; the stored value is kept.
            #expect(NewInstallDefaults.apply(isExistingInstall: true, to: defaults))
        }
    }

    @Test("An existing install keeps its choice, and the old default when it never chose")
    func existingInstall() throws {
        try withDefaults { defaults in
            #expect(!NewInstallDefaults.apply(isExistingInstall: true, to: defaults))
            #expect(!NewInstallDefaults.takeLaunchAtLogin(from: defaults), "existing installs keep their login item setting")
        }
        try withDefaults { defaults in
            defaults.set(true, forKey: NewInstallDefaults.pauseMediaKey)
            #expect(NewInstallDefaults.apply(isExistingInstall: true, to: defaults))
        }
    }

    @Test("Open at login: turned on once for a new install, when the setup page shows it")
    func launchAtLogin() throws {
        try withDefaults { defaults in
            _ = NewInstallDefaults.apply(isExistingInstall: false, to: defaults)
            // A second launch before the setup page (the install now counts as existing).
            _ = NewInstallDefaults.apply(isExistingInstall: true, to: defaults)
            #expect(NewInstallDefaults.takeLaunchAtLogin(from: defaults))
            #expect(!NewInstallDefaults.takeLaunchAtLogin(from: defaults), "only once: turning it off sticks")
        }
    }
}

@Suite("Onboarding window placement")
@MainActor
struct OnboardingWindowPlacementTests {
    private let size = OnboardingWindowPlacement.size

    @Test("1440 × 900: a little below the centre, clear of the recorder's card at Top Center")
    func smallScreen() {
        // Menu bar 24 pt, with and without a 70 pt Dock.
        for visible in [NSRect(x: 0, y: 0, width: 1440, height: 876), NSRect(x: 0, y: 70, width: 1440, height: 806)] {
            let frame = OnboardingWindowPlacement.frame(in: visible, recorder: .topCenter)
            #expect(frame.size == size)
            #expect(frame.midY < visible.midY, "below the centre")
            #expect(frame.midX == visible.midX)
            let card = RecorderPosition.topCenter.initialFrame(size: NSSize(width: 380, height: 106), in: visible)
            #expect(card.minY - frame.maxY >= OnboardingWindowPlacement.gap)
            #expect(visible.contains(frame))
        }
    }

    @Test("A 13-inch Air (1470 × 956, menu bar 37): centred, already clear of the card")
    func largerScreen() {
        let visible = NSRect(x: 0, y: 0, width: 1470, height: 919)
        let frame = OnboardingWindowPlacement.frame(in: visible, recorder: .topCenter)
        #expect(abs(frame.midY - visible.midY) <= 0.5)
    }

    @Test("Other recorder positions: moved only when the card would meet the window")
    func otherPositions() {
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 876)
        let centred = NSRect(x: 430, y: 118, width: size.width, height: size.height)
        // The corners are far from a centred window on a 1440 pt wide screen.
        #expect(OnboardingWindowPlacement.frame(in: visible, recorder: .topLeft) == centred)
        #expect(OnboardingWindowPlacement.frame(in: visible, recorder: .topRight) == centred)
        // Bottom Center pushes it up instead.
        let frame = OnboardingWindowPlacement.frame(in: visible, recorder: .bottomCenter)
        let card = RecorderPosition.bottomCenter.initialFrame(size: NSSize(width: 380, height: 106), in: visible)
        #expect(frame.minY - card.maxY >= OnboardingWindowPlacement.gap)
    }

    @Test("A screen too small to clear the card: the window stays inside the visible frame")
    func tinyScreen() {
        let visible = NSRect(x: 0, y: 40, width: 1024, height: 700)
        let frame = OnboardingWindowPlacement.frame(in: visible, recorder: .topCenter)
        #expect(visible.contains(frame))
        #expect(frame.minY == visible.minY)
    }
}

@Suite("Welcome recorder")
@MainActor
struct WelcomeRecorderTests {
    @Test("From the press: idle at 0:00 once the recorder has arrived, recording 125 ms later for 3 s, then stopped at 0:03")
    func timeline() {
        // The opening scene's values: the recorder fades up from 0.25 s after the press, over
        // 0.45 s, and records 0.125 s after it has arrived (the prototype's saved Tweaks).
        #expect(WelcomeDictation.recorderAppears == 0.25)
        #expect(abs(WelcomeDictation.entranceEnds - 0.7) < 0.001)
        #expect(OpeningScene.Tweak.factsStagger == 0, "the four facts arrive together")
        let start = WelcomeDictation.recordingStarts
        #expect(abs(start - 0.825) < 0.001)
        #expect(abs(start - WelcomeDictation.entranceEnds - WelcomeDictation.idleWait) < 0.001)
        #expect(WelcomeDictation.idleWait == 0.125, "the maintainer's pause after the recorder has arrived")
        let duration = WelcomeDictation.freezeTime - start
        #expect(abs(duration - 3) < 0.001, "the dictation lasts 3 s, quick on purpose")

        // Idle: no text, 0:00.
        for time in [0.0, WelcomeDictation.recorderAppears, WelcomeDictation.entranceEnds, start - 0.01] {
            #expect(WelcomeDictation.wordCount(at: time) == 0)
            #expect(WelcomeDictation.text(at: time) == ("", ""))
            #expect(WelcomeDictation.elapsedSeconds(at: time) == 0)
        }
        #expect(WelcomeDictation.level(at: start - 0.5) < WaveformMetrics.silenceFloor)

        // Recording: the words arrive, the timer runs.
        let words = WelcomeDictation.words
        #expect(words.count == 29)
        #expect(WelcomeDictation.wordCount(at: WelcomeDictation.firstWord) == 1)
        let one = WelcomeDictation.text(at: WelcomeDictation.firstWord)
        #expect(one.stable == "" && one.volatile == "So")
        #expect(WelcomeDictation.elapsedSeconds(at: start + 0.99) == 0)
        #expect(WelcomeDictation.elapsedSeconds(at: start + 1.0) == 1)
        #expect(WelcomeDictation.elapsedSeconds(at: start + 2.2) == 2)
        let counts = stride(from: WelcomeDictation.firstWord, to: WelcomeDictation.freezeTime, by: 0.05)
            .map(WelcomeDictation.wordCount(at:))
        #expect(counts == counts.sorted(), "words only ever arrive")
        #expect(WelcomeDictation.wordCount(at: WelcomeDictation.firstWord + WelcomeDictation.span) == words.count,
                "the last word arrives before the freeze")
        #expect(WelcomeDictation.firstWord + WelcomeDictation.span < WelcomeDictation.freezeTime)

        // Stopped: the whole sentence, the last two words dimmer, the timer stays at 0:03.
        let end = WelcomeDictation.freezeTime
        let frozen = WelcomeDictation.text(at: end)
        #expect(frozen.stable == "So the plan for this week is the payment flow, then the mobile release. Let’s split it in two: first the API, then the checkout screens, and")
        #expect(frozen.volatile == " we’ll see", "the last two words stay dimmer")
        #expect(WelcomeDictation.elapsedSeconds(at: end) == 3)
        #expect(WelcomeDictation.elapsedSeconds(at: end + 30) == 3, "the timer stops at the freeze")
    }

    @Test("The sentence fills up to three lines of the card, not more")
    func sentenceFitsThreeLines() {
        let width = OverlayMetrics.cardWidth - 2 * OverlayMetrics.textInset
        let font = NSFont.systemFont(ofSize: LiveTranscriptText.fontSize)
        let caret = Caret.leadingGap + Caret.size.width + Caret.glowPadding
        let text = NSAttributedString(string: OnboardingText.welcomeSentence, attributes: [.font: font, .kern: -0.05])
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width - caret, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        var lines = 0
        layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(for: container)) { _, _, _, _, _ in lines += 1 }
        #expect(lines == LiveTranscriptText.defaultLineCount, "three lines: \(lines)")
    }

    @Test("Levels: room noise before the first word, speech after, in the shape approved before the scene")
    func levels() {
        let first = WelcomeDictation.firstWord
        #expect(WelcomeDictation.level(at: first - 0.2) < WaveformMetrics.silenceFloor)
        // The same levels as when the recording started 0.745 s after the window opened.
        for since in stride(from: 0.2, to: 2.9, by: 0.13) {
            let then = since + 0.745
            let pause = sin(then * 3.7 + 0.5) > 0.85 ? 0.0 : 1.0
            let syllable = abs(sin(then * 12.3 + 0.3)) * (0.45 + 0.55 * abs(sin(then * 2.6 + 1.2)))
            let expected = Float(max(0.04, pause * min(1, 0.25 + 0.75 * syllable)))
            #expect(abs(WelcomeDictation.level(at: WelcomeDictation.recordingStarts + since) - expected) < 1e-5)
        }
        let speech = stride(from: first + 0.1, to: WelcomeDictation.freezeTime, by: 0.02).map { WelcomeDictation.level(at: $0) }
        #expect(speech.filter { $0 > 0.5 }.count > speech.count / 3)
        let history = WelcomeDictation.frozenHistory()
        let bars = WaveformMetrics.bars(for: history, count: 75)
        #expect(bars.filter { $0.height > WaveformMetrics.dotHeight }.count > 40, "the frozen card shows speech bars")
    }

    @Test("The demo: idle and paused at 0:00, then recording, then frozen and paused at 0:03")
    func demoPhases() {
        let demo = WelcomeRecorderDemo()
        let model = demo.viewModel
        #expect(model.state == .recording)
        #expect(model.visibleTranscript != nil, "the card shows before any word")

        // Idle until the recording starts: paused (still capsule, steady caret), no text,
        // 0:00, a still flat waveform.
        for time in [0.0, WelcomeDictation.entranceEnds, WelcomeDictation.recordingStarts - 0.02] {
            demo.advance(to: time)
            #expect(demo.phase == .idle)
            #expect(model.isPaused)
            #expect(model.elapsedFormatted == "0:00")
            #expect(model.visibleTranscript?.isEmpty == true)
            #expect(model.waveform.isStatic)
            #expect(WaveformMetrics.bars(for: model.waveform.history, count: 30)
                .allSatisfy { $0.height == WaveformMetrics.dotHeight })
        }

        // Recording: the capsule pulses, the waveform moves, the words and the timer run. The
        // waveform's revision changes, so the view redraws from its timeline.
        let idleRevision = model.waveform.revision
        demo.advance(to: WelcomeDictation.recordingStarts + 2.3)
        #expect(model.waveform.revision != idleRevision)
        #expect(demo.phase == .recording)
        #expect(!model.isPaused)
        #expect(!model.waveform.isStatic)
        #expect(model.elapsedFormatted == "0:02")
        #expect(model.visibleTranscript?.isEmpty == false)

        // Frozen: everything stops, paused again.
        demo.advance(to: WelcomeDictation.freezeTime)
        #expect(demo.isFrozen)
        #expect(model.isPaused)
        #expect(model.waveform.isStatic)
        #expect(model.elapsedFormatted == "0:03")
        #expect(model.visibleTranscript?.volatileText == " we’ll see")
        demo.advance(to: WelcomeDictation.freezeTime + 10)
        #expect(model.elapsedFormatted == "0:03", "nothing moves after the freeze")
        demo.stop()
    }

    @Test("Reduce Motion: the frozen, paused frame at once")
    func demoReduceMotion() {
        let demo = WelcomeRecorderDemo()
        demo.start(reduceMotion: true)
        #expect(demo.isFrozen)
        #expect(demo.viewModel.isPaused)
        #expect(demo.viewModel.elapsedFormatted == "0:03")
        #expect(demo.viewModel.visibleTranscript?.volatileText == " we’ll see")
        #expect(demo.viewModel.waveform.isStatic)
        let bars = WaveformMetrics.bars(for: demo.viewModel.waveform.history, count: 75)
        #expect(bars.filter { $0.height > WaveformMetrics.dotHeight }.count > 40, "the bars of the dictation, computed")
    }

    @Test("A live recording is never paused; the Settings preview waveform never starts")
    func pausedOnlyForTheWelcome() {
        #expect(!RecordingOverlayViewModel().isPaused)
        let preview = OverlayWaveform(staticHistory: LevelHistory())
        preview.start(levels: PassthroughSubject<Float, Never>())
        #expect(preview.isStatic, "a preview stays still")
        let welcome = OverlayWaveform()
        welcome.freeze(with: LevelHistory())
        welcome.start(levels: PassthroughSubject<Float, Never>())
        #expect(!welcome.isStatic, "a frozen waveform starts again")
        welcome.stop()
    }

    @Test("The live overlay stays compact until there is text")
    func emptyCardOnlyWhenAsked() {
        let model = RecordingOverlayViewModel()
        model.transcript = LiveTranscript()
        #expect(model.visibleTranscript == nil)
        model.showsCardWhileEmpty = true
        #expect(model.visibleTranscript != nil)
    }
}
