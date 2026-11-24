import Testing
@testable import NanoWhisper

/// Menu bar menu: which lines each app state produces (`MenuContent.lines(for:)`).
@Suite("Menu content")
struct MenuContentTests {
    private static func state(_ change: (inout MenuState) -> Void = { _ in }) -> MenuState {
        var state = MenuState(
            appName: "NanoWhisper", debugHeader: nil, setupUnfinished: false,
            microphoneGranted: true, accessibilityGranted: true,
            engine: EngineState(isReady: true, setupComplete: true, progressText: "Setup complete!"),
            modelName: "Parakeet Ultra", modelSize: "~630 MB",
            isRecording: false, isTranscribing: false, lastError: nil,
            update: .upToDate(lastChecked: nil)
        )
        change(&state)
        return state
    }

    private func lines(_ change: (inout MenuState) -> Void = { _ in }) -> [MenuLine] {
        MenuContent.lines(for: Self.state(change))
    }

    @Test("Ready: as drawn on the board")
    func ready() {
        #expect(lines() == [
            .action(.toggleDictation, title: "Start Dictation", showsShortcut: true),
            .status("Parakeet Ultra is ready"),
            .separator,
            .action(.showHistory, title: "History…"),
            .action(.showSettings, title: "Settings…", keyEquivalent: ","),
            .separator,
            .action(.quit, title: "Quit NanoWhisper", keyEquivalent: "q"),
        ])
    }

    @Test("Setup not finished, downloading: Finish Setup with its reason, Start disabled, a bar")
    func setupUnfinishedDownloading() {
        let result = lines {
            $0.setupUnfinished = true
            $0.microphoneGranted = false
            $0.engine = EngineState(isSettingUp: true, progressText: "Downloading model (64%)...")
        }
        #expect(Array(result.prefix(4)) == [
            .action(.finishSetup, title: "Finish Setup…", detail: "Microphone is off"),
            .separator,
            .action(.toggleDictation, title: "Start Dictation", isEnabled: false, showsShortcut: true),
            .progress("Downloading Parakeet Ultra, 64%", fraction: 0.64),
        ])
    }

    @Test("Finish Setup reason: microphone first, then accessibility, else none")
    func setupReason() {
        #expect(MenuContent.setupReason(Self.state { $0.microphoneGranted = false; $0.accessibilityGranted = false }) == "Microphone is off")
        #expect(MenuContent.setupReason(Self.state { $0.accessibilityGranted = false }) == "Accessibility is off")
        #expect(MenuContent.setupReason(Self.state()) == nil)
        #expect(!lines().contains { if case .action(.finishSetup, _, _, _, _, _) = $0 { return true }; return false })
    }

    @Test("Download without a percentage, optimizing, loading")
    func progressStates() {
        #expect(MenuContent.modelLines(Self.state {
            $0.modelName = "Whisper Small"
            $0.engine = EngineState(isSettingUp: true, progressText: "Downloading Whisper Small...")
        }) == [.progress("Downloading Whisper Small…", fraction: nil)])
        #expect(MenuContent.modelLines(Self.state {
            $0.engine = EngineState(isSettingUp: true, progressText: "Compiling model...")
        }) == [.status("Optimizing Parakeet Ultra for this Mac…")])
        #expect(MenuContent.modelLines(Self.state { $0.engine = EngineState(setupComplete: true) })
            == [.status("Loading Parakeet Ultra…")])
    }

    @Test("First launch before the download: Download offers the model and its size")
    func notDownloaded() {
        #expect(MenuContent.modelLines(Self.state { $0.engine = EngineState() }) == [
            .status("Parakeet Ultra is not downloaded"),
            .action(.downloadModel, title: "Download Parakeet Ultra (~630 MB)"),
        ])
    }

    @Test("Setup failed and engine failed: the error and Retry")
    func failures() {
        #expect(MenuContent.modelLines(Self.state { $0.engine = EngineState(error: "No network.") }) == [
            .status("Could not set up Parakeet Ultra", tone: .failure),
            .status("No network."),
            .action(.retrySetup, title: "Retry"),
        ])
        #expect(MenuContent.modelLines(Self.state {
            $0.engine = EngineState(setupComplete: true, initializationError: "Could not start.")
        }) == [
            .status("Parakeet Ultra could not start", tone: .failure),
            .status("Could not start."),
            .action(.retrySetup, title: "Retry"),
        ])
    }

    @Test("Recording: Stop Dictation; transcribing: Start stays available")
    func recordingAndTranscribing() {
        let recording = lines { $0.isRecording = true }
        #expect(recording[0] == .action(.toggleDictation, title: "Stop Dictation", showsShortcut: true))
        #expect(recording[1] == .status("Recording…", tone: .recording))
        let transcribing = lines { $0.isTranscribing = true }
        #expect(transcribing[0] == .action(.toggleDictation, title: "Start Dictation", showsShortcut: true))
        #expect(transcribing[1] == .status("Transcribing…"))
    }

    @Test("Migration switchover: the previous model is in use, the new one downloads")
    func upgrade() {
        let downloading = MenuContent.modelLines(Self.state {
            $0.engine.upgrade = ModelUpgrade(from: .parakeet(.v3), to: .parakeet(.ultra), status: .downloading(fraction: 0.42))
        })
        #expect(downloading == [
            .status("Parakeet TDT 0.6B v3 is ready"),
            .progress("Downloading Parakeet Ultra, 42%", fraction: 0.42),
        ])
        // A failed or offline background download shows nothing alarming.
        let deferred = MenuContent.modelLines(Self.state {
            $0.engine.upgrade = ModelUpgrade(from: .parakeet(.v3), to: .parakeet(.ultra), status: .deferred)
        })
        #expect(deferred == [.status("Parakeet TDT 0.6B v3 is ready")])
    }

    @Test("Last error, update available and downloading, History always enabled, debug header")
    func otherLines() {
        #expect(lines { $0.lastError = "Empty transcription" }.contains(.status("Empty transcription", tone: .failure)))
        #expect(lines { $0.update = .available(version: "0.0.7") }
            .contains(.action(.installUpdate, title: "Install Update 0.0.7 and Relaunch")))
        let failure = MenuLine.status("Could not finish the update: see Settings › Advanced", tone: .failure)
        #expect(!lines { $0.update = .available(version: "0.0.7") }.contains(failure))
        #expect(lines { $0.update = .available(version: "0.0.7"); $0.updateFailed = true }.contains(failure))
        #expect(!lines { $0.updateFailed = true }.contains(failure))
        #expect(lines { $0.update = .downloading(version: "0.0.7", progress: 0.3) }
            .contains(.progress("Downloading update 0.0.7…", fraction: 0.3)))
        #expect(lines { $0.update = .disabled }.allSatisfy {
            if case .action(.installUpdate, _, _, _, _, _) = $0 { return false }; return true
        })
        #expect(lines().contains(.action(.showHistory, title: "History…")))
        let debug = lines { $0.appName = "NanoWhisper Debug"; $0.debugHeader = "v0.0.6 · abc1234" }
        #expect(Array(debug.prefix(2)) == [.header(title: "NanoWhisper Debug", detail: "v0.0.6 · abc1234"), .separator])
        #expect(debug.last == .action(.quit, title: "Quit NanoWhisper Debug", keyEquivalent: "q"))
    }
}
