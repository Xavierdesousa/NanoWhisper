import AppKit
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

    // MARK: - Settings

    @Test("Settings in both engine modes")
    func settings() throws {
        let parakeet = Fixtures.parakeetUltra
        var whisper = parakeet
        whisper.modelType = .whisper
        whisper.whisperSettings = WhisperSettings(modelSize: .small, language: nil, promptText: "")

        for (name, applied) in [("parakeet", parakeet), ("whisper", whisper)] {
            let context = Fixtures.context(
                applied: applied, state: Fixtures.ready, microphone: .granted, accessibility: .denied
            )
            for (suffix, height) in [("", SettingsForm.size.height), ("-full", 1500.0)] {
                try render(
                    SettingsForm(
                        context: context, draft: .constant(applied), autoUpdater: AutoUpdater.shared,
                        debugMode: .constant(false), showOnboarding: {}
                    )
                    .frame(width: SettingsForm.size.width, height: height),
                    "settings-\(name)\(suffix)"
                )
            }
        }

        var draft = parakeet
        draft.parakeetVariant = .v3
        try render(
            SettingsForm(
                context: Fixtures.context(applied: parakeet, state: Fixtures.ready),
                draft: .constant(draft), autoUpdater: AutoUpdater.shared,
                debugMode: .constant(false), showOnboarding: {}
            )
            .frame(width: SettingsForm.size.width, height: SettingsForm.size.height),
            "settings-parakeet-pending-change"
        )
    }

    @Test("Settings: migration upgrade status and the Downloaded Models section")
    func settingsModelStorage() throws {
        let parakeet = Fixtures.parakeetUltra
        func form(_ state: EngineState, height: CGFloat = 520) -> some View {
            SettingsForm(
                context: Fixtures.context(applied: parakeet, state: state), draft: .constant(parakeet),
                autoUpdater: AutoUpdater.shared, debugMode: .constant(false), showOnboarding: {}
            )
            .frame(width: SettingsForm.size.width, height: height)
        }
        var upgrading = Fixtures.ready
        upgrading.upgrade = ModelUpgrade(from: .parakeet(.v3), to: .parakeet(.ultra), status: .downloading(fraction: 0.42))
        try render(form(upgrading), "settings-model-upgrading")
        var deferred = Fixtures.ready
        deferred.upgrade = ModelUpgrade(from: .parakeet(.v3), to: .parakeet(.ultra), status: .deferred)
        try render(form(deferred), "settings-model-upgrade-deferred")
        try render(form(Fixtures.ready, height: 760), "settings-model-storage-enabled")

        try render(UnusedModelsSheet(preview: Fixtures.samplePreview, onCancel: {}, onRemove: {}), "settings-remove-unused-sheet")
        var denied = Fixtures.samplePreview
        denied.removable = []
        denied.keptForOtherFlavor = []
        denied.whisperAccessDenied = true
        try render(UnusedModelsSheet(preview: denied, onCancel: {}, onRemove: {}), "settings-remove-unused-sheet-empty-denied")
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

    private func render<V: View>(_ view: V, _ name: String) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        hosting.layoutSubtreeIfNeeded()

        let rep = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
        window.close()
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
        offersLiveTranscription: Bool = true
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
            microphone: microphone,
            accessibility: accessibility,
            requestPermission: { _ in },
            shortcut: .default,
            setShortcut: { _ in },
            launchAtLogin: .constant(false),
            soundEnabled: .constant(true),
            pauseMediaEnabled: .constant(false),
            liveTranscriptionEnabled: liveTranscriptionEnabled,
            offersLiveTranscription: offersLiveTranscription,
            historyEnabled: .constant(true),
            historyUnavailable: false,
            maxHistoryCount: .constant(15),
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
