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
    typealias Dictation = WelcomeDictation

    @Test("The pace: 2.6 words a second, at most 1.25 times the maintainer's real dictations (1.7–2.2 words/s)")
    func pace() {
        #expect(Dictation.wordsPerSecond == 2.6)
        #expect(Dictation.wordsPerSecond >= 2.5 && Dictation.wordsPerSecond <= 2.8)
        #expect(Dictation.wordsPerSecond <= 1.25 * 2.2)
        // Words show one slot apart, and the sentence, said at that pace, fits the recording.
        for index in 1..<Dictation.words.count {
            #expect(abs(Dictation.wordShows(index) - Dictation.wordShows(index - 1) - 1 / Dictation.wordsPerSecond) < 1e-9)
        }
        let spoken = Dictation.wordShows(Dictation.words.count - 1) - Dictation.recordingStarts
        #expect(Double(Dictation.words.count) / spoken >= 2.4, "about 2.5 words a second over the whole recording")
        #expect(spoken < Dictation.recordingDuration, "the last word before the end, then a short silence")
    }

    @Test("From the press: idle at 0:00, recording 0:00 → 0:04, Transcribing 0.8 s, Pasted 0.35 s, then the veil")
    func timeline() {
        // The opening scene's values: the recorder fades up from 0.25 s after the press, over
        // 0.45 s, and records 0.125 s after it has arrived (the prototype's saved Tweaks).
        #expect(Dictation.recorderAppears == 0.25)
        #expect(abs(Dictation.entranceEnds - 0.7) < 0.001)
        #expect(OpeningScene.Tweak.factsStagger == 0, "the four facts arrive together")
        let start = Dictation.recordingStarts
        #expect(abs(start - 0.825) < 0.001)
        #expect(Dictation.idleWait == 0.125, "the maintainer's pause after the recorder has arrived")
        #expect(Dictation.recordingDuration == 4.3, "about 4 s, long enough to show 0:04")
        let end = Dictation.recordingEnds
        #expect(abs(end - 5.125) < 0.001)
        #expect(Dictation.transcribingDuration == 0.8 && Dictation.pastedDuration == 0.35)
        #expect(abs(Dictation.endsAt(stoppedAt: nil) - 6.275) < 0.001)

        let phases: [(Double, Dictation.Phase)] = [
            (0, .idle), (Dictation.entranceEnds, .idle), (start - 0.001, .idle), (start, .recording), (end - 0.001, .recording),
            (end, .transcribing), (end + 0.79, .transcribing), (end + 0.8, .pasted), (end + 1.14, .pasted),
            (end + 1.151, .ended), (end + 60, .ended),
        ]
        for (time, phase) in phases {
            #expect(Dictation.phase(at: time) == phase, "at \(time)")
        }

        // The timer: 0:00 while idle, whole seconds while recording, 0:04 from 4 s, then it stays.
        for time in [0, Dictation.entranceEnds, start - 0.01, start + 0.99] {
            #expect(Dictation.elapsedSeconds(at: time) == 0)
        }
        #expect(Dictation.elapsedSeconds(at: start + 1) == 1)
        #expect(Dictation.elapsedSeconds(at: start + 3.99) == 3)
        #expect(Dictation.elapsedSeconds(at: start + 4) == 4)
        #expect(Dictation.elapsedSeconds(at: end) == 4)
        #expect(Dictation.elapsedSeconds(at: end + 30) == 4, "the timer stops with the recording")
    }

    @Test("The words: none while idle, each once said, the newest two dimmer; the pasted text is the whole phrase")
    func words() {
        let start = Dictation.recordingStarts
        #expect(OnboardingText.welcomeSentence == "So the plan for this week is the payment flow.")
        #expect(Dictation.words.count == 10)
        for time in [0, Dictation.entranceEnds, start, Dictation.speechStarts, Dictation.wordShows(0) - 0.001] {
            #expect(Dictation.wordCount(at: time) == 0)
            #expect(Dictation.text(at: time) == ("", ""))
        }
        let first = Dictation.text(at: Dictation.wordShows(0))
        #expect(first.stable == "" && first.volatile == "So")
        let third = Dictation.text(at: Dictation.wordShows(2))
        #expect(third.stable == "So" && third.volatile == " the plan")
        let counts = stride(from: start, to: Dictation.recordingEnds + 1, by: 0.02).map { Dictation.wordCount(at: $0) }
        #expect(counts == counts.sorted(), "words only ever arrive")
        #expect(Dictation.wordCount(at: Dictation.recordingEnds) == 10, "the whole phrase before the end")

        let end = Dictation.text(at: Dictation.recordingEnds)
        #expect(end.stable == "So the plan for this week is the")
        #expect(end.volatile == " payment flow.", "the last two words stay dimmer until the final text")
        #expect(Dictation.text(at: Dictation.recordingEnds + 5) == end, "nothing changes after the end")
        #expect(Dictation.finalText() == "So the plan for this week is the payment flow.")
    }

    @Test("Stop ends the recording at any moment: the words and the timer stop, then Transcribing, Pasted, the veil")
    func stopAnyTime() {
        let start = Dictation.recordingStarts
        let cases: [(stop: Double, final: String, seconds: Int)] = [
            (0.75, "", 0),                     // the recorder has arrived, not recording yet
            (start + 0.1, "", 0),              // before the first word
            (start + 1.5, "So the plan.", 1),  // cut mid-phrase: a full stop, as a transcription writes it
            (start + 3.0, "So the plan for this week is.", 3),
            (start + 4.2, "So the plan for this week is the payment flow.", 4),
        ]
        for (stop, final, seconds) in cases {
            #expect(Dictation.recordingEnd(stoppedAt: stop) == stop)
            #expect(Dictation.phase(at: stop - 0.001, stoppedAt: stop) == (stop < start ? .idle : .recording))
            #expect(Dictation.phase(at: stop, stoppedAt: stop) == .transcribing)
            #expect(Dictation.phase(at: stop + 0.8, stoppedAt: stop) == .pasted)
            #expect(Dictation.phase(at: stop + 1.16, stoppedAt: stop) == .ended)
            #expect(Dictation.finalText(stoppedAt: stop) == final, "stopped at \(stop)")
            #expect(Dictation.elapsedSeconds(at: stop + 10, stoppedAt: stop) == seconds)
            #expect(Dictation.text(at: stop + 10, stoppedAt: stop) == Dictation.text(at: stop), "the words stop with it")
        }
        // A Stop after the end changes nothing.
        #expect(Dictation.recordingEnd(stoppedAt: Dictation.recordingEnds + 1) == Dictation.recordingEnds)
    }

    @Test("The phrase fits the card's three lines")
    func sentenceFitsTheCard() {
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
        #expect(lines >= 1 && lines <= LiveTranscriptText.defaultLineCount, "\(lines) lines")
    }

    @Test("Levels follow the words: room noise around the speech, one burst per word, a bump per syllable")
    func levels() {
        let start = Dictation.recordingStarts
        #expect(Dictation.level(at: start) < WaveformMetrics.silenceFloor, "silence before the first word")
        #expect(Dictation.level(at: Dictation.recordingEnds - 0.1) < WaveformMetrics.silenceFloor, "silence before the end")
        let samples = stride(from: start, to: Dictation.recordingEnds, by: 0.005).map { Dictation.level(at: $0) }
        // One burst per word: silence → speech as many times as there are words.
        var bursts = 0
        for (a, b) in zip(samples, samples.dropFirst()) where a < WaveformMetrics.silenceFloor && b >= WaveformMetrics.silenceFloor {
            bursts += 1
        }
        #expect(bursts == Dictation.words.count)
        // Syllables: "payment" has two bumps, "flow" one; about three a second, not frantic.
        #expect(Dictation.syllableCount("payment") == 2 && Dictation.syllableCount("flow.") == 1)
        #expect(Dictation.syllableCount("So") == 1 && Dictation.syllableCount("this") == 1)
        let syllables = Dictation.words.map(Dictation.syllableCount).reduce(0, +)
        #expect(Double(syllables) / Dictation.recordingDuration < 4)
        let history = Dictation.history(until: Dictation.recordingEnds)
        let bars = WaveformMetrics.bars(for: history, count: 75)
        #expect(bars.filter { $0.height > WaveformMetrics.dotHeight }.count > 30, "the card shows speech bars")
        #expect(bars.suffix(2).allSatisfy { $0.height == WaveformMetrics.dotHeight }, "the silence before the end")
    }

    @Test("The demo plays the steps: idle, recording, Transcribing, Pasted, then the veil, its clock stopped")
    func demoSteps() {
        let demo = WelcomeRecorderDemo()
        let model = demo.viewModel
        #expect(model.state == .recording)
        #expect(model.visibleTranscript != nil, "the card shows before any word")
        #expect(!demo.canStop, "nothing to stop before Get Started")

        // Idle until the recording starts: paused, no text, 0:00, a still flat waveform.
        for time in [0.0, Dictation.entranceEnds, Dictation.recordingStarts - 0.02] {
            demo.advance(to: time)
            #expect(demo.phase == .idle)
            #expect(model.isPaused)
            #expect(model.elapsedFormatted == "0:00")
            #expect(model.visibleTranscript?.isEmpty == true)
            #expect(model.waveform.isStatic)
        }

        // Recording: the capsule pulses, the waveform moves, the words and the timer run.
        let idleRevision = model.waveform.revision
        demo.advance(to: Dictation.recordingStarts + 2.3)
        #expect(model.waveform.revision != idleRevision, "the view redraws from its timeline")
        #expect(demo.phase == .recording)
        #expect(model.state == .recording && !model.isPaused && !model.waveform.isStatic)
        #expect(model.elapsedFormatted == "0:02")
        #expect(model.visibleTranscript?.isEmpty == false)
        demo.advance(to: Dictation.recordingStarts + 4.1)
        #expect(model.elapsedFormatted == "0:04")

        // Transcribing: the real state, the live text kept, the waveform sinking and sweeping.
        demo.advance(to: Dictation.recordingEnds + 0.1)
        #expect(demo.phase == .transcribing)
        #expect(model.state == .loading)
        #expect(!model.waveform.isStatic && model.waveform.stoppedAt != nil)
        #expect(model.visibleTranscript?.volatileText == " payment flow.")

        // Pasted: the check, the final text, 0:04.
        demo.advance(to: Dictation.recordingEnds + 0.85)
        #expect(demo.phase == .pasted)
        #expect(model.state == .finished(.pasted))
        #expect(model.visibleTranscript?.finalText == "So the plan for this week is the payment flow.")
        #expect(model.elapsedFormatted == "0:04")
        #expect(!demo.showsReplay)

        // The veil with Replay; nothing changes after.
        demo.advance(to: Dictation.endsAt(stoppedAt: nil))
        #expect(demo.phase == .ended && demo.showsReplay)
        #expect(!demo.isPlaying)
        #expect(model.state == .finished(.pasted))
        demo.advance(to: Dictation.endsAt(stoppedAt: nil) + 10)
        #expect(demo.phase == .ended)
        #expect(model.elapsedFormatted == "0:04")
        #expect(!demo.canStop)
    }

    @Test("Stop forces the end at once: Transcribing, then Pasted with the words said so far, then the veil")
    func demoStop() {
        let demo = WelcomeRecorderDemo()
        demo.showStill(at: 0)  // started, as after Get Started, without its clock
        demo.advance(to: Dictation.recordingStarts + 1.5)
        #expect(demo.canStop)
        demo.stopRecording()
        #expect(demo.stoppedAt == Dictation.recordingStarts + 1.5)
        #expect(demo.phase == .transcribing)
        #expect(demo.viewModel.state == .loading)
        #expect(!demo.canStop, "once")
        demo.stopRecording()
        #expect(demo.stoppedAt == Dictation.recordingStarts + 1.5)
        demo.advance(to: Dictation.recordingStarts + 1.5 + 0.8)
        #expect(demo.phase == .pasted)
        #expect(demo.viewModel.visibleTranscript?.finalText == "So the plan.")
        #expect(demo.viewModel.elapsedFormatted == "0:01")
        demo.advance(to: Dictation.recordingStarts + 1.5 + 1.2)
        #expect(demo.phase == .ended)

        // Stop while it waits at 0:00 (Stop shows under the pointer then too).
        let early = WelcomeRecorderDemo()
        early.showStill(at: 0)
        early.advance(to: Dictation.entranceEnds)
        early.stopRecording()
        #expect(early.phase == .transcribing)
        #expect(!early.viewModel.waveform.isStatic, "the sweep runs")
        early.advance(to: Dictation.entranceEnds + 1.2)
        #expect(early.phase == .ended)
        #expect(early.viewModel.visibleTranscript?.finalText == "")
    }

    @Test("Replay restarts from zero, recording at 0:00 with no text, as many times as wanted")
    func demoReplay() {
        let demo = WelcomeRecorderDemo()
        demo.showStill(at: 0)
        demo.advance(to: Dictation.recordingStarts + 2)
        demo.stopRecording()
        demo.advance(to: Dictation.endsAt(stoppedAt: demo.stoppedAt))
        #expect(demo.phase == .ended)
        for _ in 0..<3 {
            demo.replay()
            #expect(demo.phase == .recording)
            #expect(demo.stoppedAt == nil)
            #expect(abs(demo.time - Dictation.recordingStarts) < 0.05)
            #expect(demo.viewModel.state == .recording && !demo.viewModel.isPaused)
            #expect(demo.viewModel.elapsedFormatted == "0:00")
            #expect(demo.viewModel.visibleTranscript?.isEmpty == true)
            #expect(demo.viewModel.visibleTranscript?.isFinal == false)
            #expect(demo.isPlaying, "its clock runs again")
            #expect(!demo.showsReplay)
            demo.replay()
            #expect(demo.phase == .recording, "Replay only from the veil")
            // The page goes away mid-flow: it rests on the end, its clock stopped.
            demo.stop()
            #expect(demo.phase == .ended && !demo.isPlaying)
            #expect(demo.viewModel.visibleTranscript?.finalText == "So the plan for this week is the payment flow.")
        }
    }

    @Test("Reduce Motion: nothing plays by itself; the pasted card under the veil, Replay plays it")
    func demoReduceMotion() {
        let demo = WelcomeRecorderDemo()
        demo.start(reduceMotion: true)
        #expect(demo.phase == .ended && demo.showsReplay)
        #expect(!demo.isPlaying)
        #expect(demo.viewModel.state == .finished(.pasted))
        #expect(demo.viewModel.elapsedFormatted == "0:04")
        #expect(demo.viewModel.visibleTranscript?.finalText == "So the plan for this week is the payment flow.")
        demo.start(reduceMotion: true)
        #expect(demo.phase == .ended, "starts once")
        demo.replay()
        #expect(demo.phase == .recording && demo.isPlaying)
        demo.stop()
    }

    @Test("Still moments for renders: recording with its bars, transcribing, pasted, the veil")
    func demoStill() {
        let demo = WelcomeRecorderDemo()
        demo.showStill(at: Dictation.recordingStarts + 2.5)
        #expect(demo.phase == .recording && !demo.isPlaying)
        #expect(demo.viewModel.waveform.isStatic)
        #expect(WaveformMetrics.bars(for: demo.viewModel.waveform.history, count: 75)
            .contains { $0.height > WaveformMetrics.dotHeight })
        demo.showStill(at: Dictation.recordingEnds + 0.5)
        #expect(demo.phase == .transcribing && demo.viewModel.state == .loading)
        demo.showStill(at: Dictation.recordingEnds + 0.9)
        #expect(demo.phase == .pasted && demo.viewModel.state == .finished(.pasted))
        demo.showStill(at: Dictation.endsAt(stoppedAt: nil))
        #expect(demo.showsReplay)
    }

    @Test("Wording: Replay, Stop recording; History opens from the menu bar icon (setup page and Settings › General)")
    func wording() {
        #expect(OnboardingText.replay == "Replay")
        #expect(OnboardingText.stopRecording == "Stop recording")
        #expect(SettingsText.keepHistoryCaption == "Encrypted, stays on this Mac. Open it from the menu bar icon.")
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
