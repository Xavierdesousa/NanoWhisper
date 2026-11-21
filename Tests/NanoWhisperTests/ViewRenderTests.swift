import AppKit
import Carbon
import SwiftUI
import Testing
@testable import NanoWhisper

/// Renders the onboarding pages and Settings offscreen to PNG, with fixed fake state, to
/// check layout without running the app or granting screen recording. Opt-in:
///
///     NANOWHISPER_RENDER_DIR=/tmp/renders swift test --filter ViewRender
@Suite("ViewRender", .enabled(if: ProcessInfo.processInfo.environment["NANOWHISPER_RENDER_DIR"] != nil))
@MainActor
struct ViewRenderTests {
    private let outputDirectory = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["NANOWHISPER_RENDER_DIR"] ?? NSTemporaryDirectory()
    )

    // MARK: - Onboarding

    @Test("Onboarding pages and states, light and dark")
    func onboardingPages() throws {
        let ultra = Fixtures.parakeetUltra
        let downloading = { (percent: Int) in EngineState(isSettingUp: true, progressText: "Downloading model (\(percent)%)...") }
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            try renderOnboarding("onboarding-1-welcome\(suffix)", page: .welcome,
                                 context: Fixtures.onboardingContext(), dark: dark)

            // Setup page: first arrival (nothing allowed, the download started), everything done,
            // and the pointer over the model with the microphone denied and the shortcut changing.
            try renderOnboarding("onboarding-2-setup-first-arrival\(suffix)", page: .setup,
                                 context: Fixtures.onboardingContext(state: downloading(23)), dark: dark)
            try renderOnboarding("onboarding-2-setup-done\(suffix)", page: .setup,
                                 context: Fixtures.onboardingContext(microphone: .granted, accessibility: .granted),
                                 dark: dark)
            try renderOnboarding("onboarding-2-setup-denied-pointer-shortcut\(suffix)", page: .setup,
                                 context: Fixtures.onboardingContext(state: downloading(61), microphone: .denied, accessibility: .granted),
                                 dark: dark, revealsModelChange: true, recordsShortcut: true)

            // Try it.
            let granted = Fixtures.onboardingContext(microphone: .granted, accessibility: .granted)
            for (name, stage) in [
                ("ready", TryItStage.ready), ("listening", .listening), ("transcribing", .transcribing),
                ("result", .result("Let’s meet on Thursday at ten and go through the launch checklist together.")),
                ("downloading", .modelNotReady(.downloading(fraction: 0.64))),
                ("microphone-denied", .microphoneMissing(.denied)),
            ] {
                try renderOnboarding("onboarding-3-try-\(name)\(suffix)", page: .tryIt, context: granted,
                                     tryIt: Fixtures.tryIt(stage), dark: dark)
            }

            try render(ModelChoiceSheet(draft: .constant(ultra), context: granted, onDone: {})
                .background(OnboardingPalette.window),
                       "onboarding-2-model-choice-sheet\(suffix)", appearance: dark ? .darkAqua : .aqua)
        }

        // States drawn in light only.
        try renderOnboarding("onboarding-2-setup-preparing", page: .setup, context: Fixtures.onboardingContext(
            state: EngineState(isSettingUp: true, progressText: "Preparing download..."), microphone: .granted), dark: false)
        try renderOnboarding("onboarding-2-setup-model-failed", page: .setup, context: Fixtures.onboardingContext(
            state: EngineState(error: "Model setup failed. Please check your internet connection and try again."),
            microphone: .granted, accessibility: .granted), dark: false)
        var whisper = ultra
        whisper.modelType = .whisper
        whisper.whisperSettings.modelSize = .small
        try renderOnboarding("onboarding-2-setup-existing-user-whisper-history-off", page: .setup, context: Fixtures.onboardingContext(
            applied: whisper, microphone: .granted, accessibility: .denied, switchesOn: false, historyEnabled: false), dark: true)
        let granted = Fixtures.onboardingContext(microphone: .granted, accessibility: .granted)
        for (name, stage, live) in [
            ("listening-live-words", TryItStage.listening, true),
            ("nothing-recognized", .result(""), false),
            ("optimizing", .modelNotReady(.compiling), false),
            ("model-failed", .modelNotReady(.failed("Model setup failed. Please check your internet connection and try again.")), false),
            ("microphone-not-asked", .microphoneMissing(.notDetermined), false),
        ] {
            var inputs = Fixtures.tryIt(stage)
            inputs.showsLiveWords = live
            try renderOnboarding("onboarding-3-try-\(name)", page: .tryIt, context: granted, tryIt: inputs, dark: false)
        }
        var bottom = Fixtures.tryIt(.ready)
        bottom.recorderPosition = .bottomCenter
        try renderOnboarding("onboarding-3-try-ready-recorder-bottom", page: .tryIt, context: granted, tryIt: bottom, dark: true)
    }

    /// The real onboarding window (title bar, size, background) around fixture pages, never
    /// shown: controls draw in their inactive look. Reduce Motion is set so every entrance shows
    /// its end (the welcome's recorder rests on its frozen frame).
    private func renderOnboarding(
        _ name: String, page: OnboardingPage, context: SettingsContext, tryIt: TryItInputs? = nil, dark: Bool,
        revealsModelChange: Bool = false, recordsShortcut: Bool = false
    ) throws {
        _ = NSApplication.shared
        let demo = WelcomeRecorderDemo()
        demo.showFrozen()
        let content = OnboardingContent(
            model: OnboardingModel(page: page), demo: demo, context: context,
            tryIt: tryIt ?? Fixtures.tryIt(.ready), appIcon: Fixtures.appIcon,
            modelChoice: { AnyView(EmptyView()) },
            revealsModelChange: revealsModelChange, recordsShortcut: recordsShortcut
        )
        .environment(\._accessibilityReduceMotion, true)
        let window = OnboardingWindowController.makeWindow(content: content)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try write(rep, name)
        window.close()
    }

    // MARK: - Settings window (toolbar panes)

    @Test("Settings panes, light and dark")
    func settingsPanes() throws {
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            let base = SettingsFixture()
            try renderSettings(.general, "settings-general\(suffix)", base, dark: dark)
            try renderSettings(.engine, "settings-engine\(suffix)", base, dark: dark)
            try renderSettings(.recorder, "settings-recorder-debug\(suffix)", base, dark: dark)
            var permissions = base
            permissions.microphone = .granted
            permissions.accessibility = dark ? .granted : .denied
            try renderSettings(.permissions, "settings-permissions\(suffix)", permissions, dark: dark)
            var advanced = base
            advanced.updates = dark ? Fixtures.updates(.available(version: "0.0.7")) : Fixtures.updates(.upToDate(lastChecked: Fixtures.checkDate))
            try renderSettings(.advanced, "settings-advanced\(suffix)", advanced, dark: dark)
        }
    }

    @Test("Settings: Engine pane states, builds, update states")
    func settingsStates() throws {
        let parakeet = Fixtures.parakeetUltra
        var whisperTurbo = parakeet
        whisperTurbo.modelType = .whisper
        whisperTurbo.whisperSettings = WhisperSettings(modelSize: .largev3Turbo, language: nil, promptText: "")

        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            var upgrading = SettingsFixture()
            upgrading.state.upgrade = ModelUpgrade(from: .parakeet(.v3), to: .parakeet(.ultra), status: .downloading(fraction: 0.42))
            try renderSettings(.engine, "settings-engine-upgrading\(suffix)", upgrading, dark: dark)
        }

        var downloading = SettingsFixture()
        downloading.state = EngineState(isSettingUp: true, progressText: "Downloading model (42%)...")
        try renderSettings(.engine, "settings-engine-downloading", downloading)

        var pending = SettingsFixture()
        pending.draft = whisperTurbo
        try renderSettings(.engine, "settings-engine-pending", pending)
        try renderSettings(.engine, "settings-engine-pending-dark", pending, dark: true)
        var pendingDownload = SettingsFixture()
        pendingDownload.draft = parakeet
        pendingDownload.draft?.parakeetVariant = .v3
        try renderSettings(.engine, "settings-engine-pending-download", pendingDownload)

        var failed = SettingsFixture()
        failed.state = EngineState(error: "Model setup failed. Please check your internet connection and try again.")
        try renderSettings(.engine, "settings-engine-failed", failed)

        var startFailed = SettingsFixture()
        startFailed.state = EngineState(setupComplete: true, initializationError: AppState.engineStartFailedMessage)
        try renderSettings(.engine, "settings-engine-start-failed", startFailed)

        var notLoaded = SettingsFixture()
        notLoaded.state = EngineState()
        try renderSettings(.engine, "settings-engine-not-downloaded", notLoaded)

        var whisper = SettingsFixture(applied: whisperTurbo)
        try renderSettings(.engine, "settings-engine-whisper", whisper)
        whisper.applied.whisperSettings.language = "fr"
        whisper.applied.whisperSettings.promptText = "NanoWhisper, Parakeet"
        whisper.draft = whisper.applied
        try renderSettings(.engine, "settings-engine-whisper-french", whisper, dark: true)

        var revealed = SettingsFixture()
        revealed.showsModelPicker = true
        try renderSettings(.engine, "settings-engine-version-revealed", revealed)

        var deferred = SettingsFixture()
        deferred.state.upgrade = ModelUpgrade(from: .parakeet(.v3), to: .parakeet(.ultra), status: .deferred)
        try renderSettings(.engine, "settings-engine-upgrade-deferred", deferred)

        var debug = SettingsFixture()
        debug.updates = Fixtures.updates(.disabled, appName: "NanoWhisper Debug")
        try renderSettings(.advanced, "settings-advanced-debug", debug)
        var updating = SettingsFixture()
        updating.updates = Fixtures.updates(.downloading(version: "0.0.7", progress: 0.3))
        try renderSettings(.advanced, "settings-advanced-downloading", updating)
        var checking = SettingsFixture()
        checking.updates = Fixtures.updates(.checking)
        checking.updates.error = nil
        try renderSettings(.advanced, "settings-advanced-checking", checking)

        var production = SettingsFixture()
        production.offersLiveTranscription = false
        try renderSettings(.recorder, "settings-recorder-release", production)
        production.recorderPosition = .topRight
        try renderSettings(.recorder, "settings-recorder-release-top-right-dark", production, dark: true)

        try renderSettings(.permissions, "settings-permissions-not-asked", SettingsFixture())
        var historyOff = SettingsFixture()
        historyOff.historyEnabled = false
        try renderSettings(.general, "settings-general-history-off", historyOff)
        var customShortcut = SettingsFixture()
        customShortcut.shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_Y), modifiers: UInt32(optionKey | cmdKey))
        try renderSettings(.general, "settings-general-custom-shortcut", customShortcut, dark: true)
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            try render(SettingsPaneForm {
                Section("Shortcut") {
                    ShortcutRecorderRow(shortcut: Fixtures.productionShortcut, onChange: { _ in }, isRecording: true)
                }
            }, "settings-general-shortcut-recording\(suffix)", appearance: appearance)
        }
    }

    @Test("Remove Unused Models sheet, light and dark")
    func unusedModelsSheet() throws {
        for (suffix, appearance) in [("", NSAppearance.Name.aqua), ("-dark", .darkAqua)] {
            try render(UnusedModelsSheet(preview: Fixtures.samplePreview, onCancel: {}, onRemove: {}),
                       "settings-remove-unused-sheet\(suffix)", appearance: appearance)
        }
        var denied = Fixtures.samplePreview
        denied.removable = []
        denied.keptForOtherFlavor = []
        denied.whisperAccessDenied = true
        try render(UnusedModelsSheet(preview: denied, onCancel: {}, onRemove: {}), "settings-remove-unused-sheet-empty-denied")
    }

    // MARK: - Menu bar menu

    @Test("Menu bar menu in every state")
    func menuStates() throws {
        let states = MenuFixtures.all
        for (name, state) in states {
            try render(MenuPreview(lines: MenuContent.lines(for: state), shortcut: MenuFixtures.shortcut), "menu-\(name)")
        }
        for name in ["ready", "setup-unfinished-downloading", "upgrade-downloading", "engine-failed"] {
            let state = try #require(states.first { $0.0 == name }?.1)
            try render(MenuPreview(lines: MenuContent.lines(for: state), shortcut: MenuFixtures.shortcut),
                       "menu-\(name)-dark", appearance: .darkAqua)
        }
    }

    // MARK: - End of onboarding (menu bar handoff)

    @Test("Handoff popover content, light and dark")
    func handoffPopover() throws {
        let downloading = EngineState(isSettingUp: true, progressText: "Downloading model (48%)...")
        let cases: [(String, MenuBarHandoff.Popover, EngineState)] = [
            ("setup-done", .setupDone, Fixtures.ready),
            ("setup-done-downloading", .setupDone, downloading),
            ("model-ready", .modelReady, Fixtures.ready),
        ]
        for (name, popover, engine) in cases {
            let message = try #require(HandoffMessage.make(
                popover, appName: "NanoWhisper", modelName: "Parakeet Ultra", engine: engine,
                shortcut: MenuFixtures.shortcut, recorderPosition: .topCenter
            ))
            let preview = HandoffPopoverPreview(message: message)
            try render(preview, "handoff-\(name)")
            try render(preview, "handoff-\(name)-dark", appearance: .darkAqua)
        }
    }

    // MARK: - Settings helpers

    /// The real Settings window (toolbar, title, size) around fixture panes, captured with its
    /// title bar.
    private func renderSettings(
        _ pane: SettingsPane, _ name: String, _ fixture: SettingsFixture, dark: Bool = false,
        panes: [SettingsPane] = SettingsPane.allCases
    ) throws {
        _ = NSApplication.shared
        let suite = "nanowhisper.render.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(pane.rawValue, forKey: SettingsPane.defaultsKey)

        let tabs = SettingsWindowController.makeTabs(panes: panes, selectedFrom: defaults) { fixture.view(for: $0) }
        let window = SettingsWindowController.makeWindow(tabs: tabs)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        tabs.fitWindowToSelectedPane()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try write(rep, name)
        window.close()
    }

    // MARK: - Helpers

    private func render<V: View>(_ view: V, _ name: String, appearance: NSAppearance.Name = .aqua) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()

        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        try write(rep, name)
        window.close()
    }

    private func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}

@MainActor
enum Fixtures {
    static let parakeetUltra = EngineConfiguration(
        modelType: .parakeet, parakeetVariant: .ultra, whisperSettings: WhisperSettings()
    )
    static let ready = EngineState(isReady: true, setupComplete: true, progressText: "Setup complete!")

    static func context(
        applied: EngineConfiguration,
        state: EngineState,
        microphone: PermissionStatus = .notDetermined,
        accessibility: PermissionStatus = .notDetermined,
        liveTranscriptionEnabled: Binding<Bool> = .constant(false),
        offersLiveTranscription: Bool = true,
        shortcut: Shortcut = .default,
        historyEnabled: Bool = true,
        recorderPosition: RecorderPosition = .defaultPosition,
        launchAtLogin: Bool = false,
        pauseMediaEnabled: Bool = false
    ) -> SettingsContext {
        SettingsContext(
            appliedEngine: applied,
            engineState: state,
            availability: { config in
                ModelAvailability.resolve(
                    config,
                    loadedParakeet: state.isReady && applied.modelType == .parakeet ? applied.parakeetVariant : nil,
                    loadedWhisper: state.isReady && applied.modelType == .whisper ? applied.whisperSettings.modelSize : nil,
                    parakeetOnDisk: { _ in false }
                )
            },
            applyEngine: { _ in },
            loadAppliedModel: {},
            setWhisperOptions: { _, _ in },
            microphone: microphone,
            accessibility: accessibility,
            requestPermission: { _ in },
            shortcut: shortcut,
            setShortcut: { _ in },
            launchAtLogin: .constant(launchAtLogin),
            soundEnabled: .constant(true),
            pauseMediaEnabled: .constant(pauseMediaEnabled),
            liveTranscriptionEnabled: liveTranscriptionEnabled,
            offersLiveTranscription: offersLiveTranscription,
            historyEnabled: .constant(historyEnabled),
            historyUnavailable: false,
            maxHistoryCount: .constant(15),
            recorderPosition: .constant(recorderPosition),
            storage: ModelStorageContext(
                unavailableReason: ModelStorageContext.unavailableReason(state),
                preview: { samplePreview },
                remove: { _ in ModelRemovalReport() }
            )
        )
    }

    /// Onboarding's setup page as a new install sees it: ⌥Space, the four switches on.
    static func onboardingContext(
        applied: EngineConfiguration = parakeetUltra,
        state: EngineState = ready,
        microphone: PermissionStatus = .notDetermined,
        accessibility: PermissionStatus = .notDetermined,
        switchesOn: Bool = true,
        historyEnabled: Bool = true
    ) -> SettingsContext {
        context(
            applied: applied, state: state, microphone: microphone, accessibility: accessibility,
            shortcut: productionShortcut, historyEnabled: historyEnabled,
            launchAtLogin: switchesOn, pauseMediaEnabled: switchesOn
        )
    }

    static func tryIt(_ stage: TryItStage) -> TryItInputs {
        TryItInputs(
            stage: stage, shortcut: productionShortcut, recorderPosition: .defaultPosition,
            showsLiveWords: false, model: parakeetUltra
        )
    }

    /// The app icon from `Resources/` (a test process has no app bundle).
    static let appIcon: NSImage = {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources")
        return NSImage(contentsOf: resources.appendingPathComponent("AppIcon.png")) ?? NSImage()
    }()

    static let samplePreview = UnusedModelsPreview(
        removable: [
            StoredModel(folder: .parakeetV3, bytes: 473_000_000),
            StoredModel(folder: .whisperLargeV3Turbo, bytes: 598_000_000),
        ],
        keptInUse: [StoredModel(folder: .parakeetUltra, bytes: 603_000_000)],
        keptForOtherFlavor: [StoredModel(folder: .whisperBase, bytes: 140_000_000)],
        otherFlavorName: "NanoWhisper",
        whisperAccessDenied: false
    )
}
