import AppKit
import Carbon
import SwiftUI
import Testing
@testable import NanoWhisper

/// Renders the onboarding steps and Settings offscreen to PNG, with fixed fake state, to
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

    @Test("Onboarding steps")
    func onboardingSteps() throws {
        let parakeet = Fixtures.parakeetUltra
        let notLoaded = Fixtures.context(applied: parakeet, state: EngineState())

        try render(onboarding(.welcome, context: notLoaded), "onboarding-1-welcome")
        try render(onboarding(.welcome, context: notLoaded, isReplay: true), "onboarding-1-welcome-replay")
        try render(onboarding(.model, context: notLoaded), "onboarding-2-model-not-downloaded")

        let downloading = Fixtures.context(
            applied: parakeet,
            state: EngineState(isSettingUp: true, progressText: "Downloading model (42%)...")
        )
        try render(onboarding(.model, context: downloading), "onboarding-2-model-downloading")

        var whisperDraft = parakeet
        whisperDraft.modelType = .whisper
        whisperDraft.whisperSettings.modelSize = .largev3Turbo
        try render(onboarding(.model, context: Fixtures.context(applied: parakeet, state: Fixtures.ready),
                              draft: whisperDraft),
                   "onboarding-2-model-whisper-draft")
        try render(onboarding(.model, context: Fixtures.context(applied: parakeet, state: Fixtures.ready),
                              draft: whisperDraft, height: 1000),
                   "onboarding-2-model-whisper-draft-full")

        try render(onboarding(.permissions, context: Fixtures.context(
            applied: parakeet, state: Fixtures.ready, microphone: .granted, accessibility: .notDetermined
        )), "onboarding-3-permissions")
        try render(onboarding(.permissions, context: Fixtures.context(
            applied: parakeet, state: Fixtures.ready, microphone: .denied, accessibility: .denied
        )), "onboarding-3-permissions-denied")

        try render(onboarding(.shortcut, context: Fixtures.context(applied: parakeet, state: Fixtures.ready)),
                   "onboarding-4-shortcut")
        try render(onboarding(.shortcut, context: Fixtures.context(
            applied: parakeet, state: Fixtures.ready, offersLiveTranscription: false
        )), "onboarding-4-shortcut-production")

        try render(onboarding(.done, context: Fixtures.context(
            applied: parakeet, state: Fixtures.ready, microphone: .granted, accessibility: .granted
        ), transcript: "Hello, this is a test of NanoWhisper."), "onboarding-5-done")
        try render(onboarding(.done, context: Fixtures.context(
            applied: parakeet, state: EngineState(), microphone: .granted, accessibility: .notDetermined
        )), "onboarding-5-done-pending")
        try render(onboarding(.done, context: Fixtures.context(
            applied: parakeet, state: EngineState(), microphone: .granted, accessibility: .notDetermined
        ), height: 900), "onboarding-5-done-pending-full")
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

    private func onboarding(
        _ step: OnboardingStep,
        context: SettingsContext,
        draft: EngineConfiguration? = nil,
        isReplay: Bool = false,
        transcript: String? = nil,
        height: CGFloat = OnboardingContent.size.height
    ) -> some View {
        OnboardingContent(
            step: .constant(step),
            draft: .constant(draft ?? context.appliedEngine),
            context: context,
            tryIt: TryItState(
                isEngineReady: context.engineState.isReady, isRecording: false, isTranscribing: false,
                transcript: transcript, toggleRecording: {}
            ),
            isReplay: isReplay,
            onFinish: {},
            height: height
        )
    }

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
        recorderPosition: RecorderPosition = .defaultPosition
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
            launchAtLogin: .constant(false),
            soundEnabled: .constant(true),
            pauseMediaEnabled: .constant(false),
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
