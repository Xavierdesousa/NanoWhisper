import SwiftUI
import Testing
@testable import NanoWhisper

/// Live transcription (beta) is offered in both builds, off by default.
@Suite("Live transcription by build flavor")
struct LiveTranscriptionFlavorTests {
    private static let parakeet = EngineConfiguration(
        modelType: .parakeet, parakeetVariant: .ultra, whisperSettings: WhisperSettings()
    )

    @Test("Both builds offer it (beta since 0.1.0)")
    func flag() {
        #expect(BuildFlavor.debug.supportsLiveTranscription)
        #expect(BuildFlavor.production.supportsLiveTranscription)
    }

    @Test("Production: the stored setting decides, and it is off by default")
    @MainActor
    func productionFollowsTheSetting() {
        #expect(LiveTranscriptionSupport.startsSession(
            enabled: true, flavor: .production, configuration: Self.parakeet))
        #expect(!LiveTranscriptionSupport.startsSession(
            enabled: false, flavor: .production, configuration: Self.parakeet))
        let defaults = UserDefaults(suiteName: "nanowhisper.tests.live.\(UUID().uuidString)")!
        #expect(!defaults.bool(forKey: AppState.liveTranscriptionKey), "nothing stored: off")
    }

    @Test("Debug: the stored setting and the engine decide, as before")
    func debugUnchanged() {
        #expect(LiveTranscriptionSupport.startsSession(enabled: true, flavor: .debug, configuration: Self.parakeet))
        #expect(!LiveTranscriptionSupport.startsSession(enabled: false, flavor: .debug, configuration: Self.parakeet))
        var turbo = Self.parakeet
        turbo.modelType = .whisper
        turbo.whisperSettings.modelSize = .largev3Turbo
        #expect(!LiveTranscriptionSupport.startsSession(enabled: true, flavor: .debug, configuration: turbo))
    }

    @Test("The Recorder pane shows the live toggle only when the build offers it", arguments: [false, true])
    @MainActor
    func toggleVisibility(offered: Bool) {
        var stored = true
        let storedOn = Fixtures.context(
            applied: Self.parakeet, state: Fixtures.ready,
            liveTranscriptionEnabled: Binding(get: { stored }, set: { stored = $0 }),
            offersLiveTranscription: offered
        )

        // The view tree the pane builds, as text (offscreen hosting views expose no
        // accessibility tree without an assistive client, so the tree is inspected directly).
        var tree = ""
        dump(RecorderPane(context: storedOn).body, to: &tree)
        // Positive control: the position section's title is found.
        #expect(tree.contains("\"Recorder position\""))
        #expect(tree.contains("\"\(RecorderPane.liveTranscriptionLabel)\"") == offered)
        #expect(stored, "showing or hiding the toggle must not change the stored value")
    }
}
