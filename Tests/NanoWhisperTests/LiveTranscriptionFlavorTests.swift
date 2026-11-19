import SwiftUI
import Testing
@testable import NanoWhisper

/// Live transcription (beta) is offered only in the debug build.
@Suite("Live transcription by build flavor")
struct LiveTranscriptionFlavorTests {
    private static let parakeet = EngineConfiguration(
        modelType: .parakeet, parakeetVariant: .ultra, whisperSettings: WhisperSettings()
    )

    @Test("Only the debug build supports it")
    func flag() {
        #expect(BuildFlavor.debug.supportsLiveTranscription)
        #expect(!BuildFlavor.production.supportsLiveTranscription)
    }

    @Test("Stored on + production: no live session")
    func productionForcesOff() {
        #expect(!LiveTranscriptionSupport.startsSession(
            enabled: true, flavor: .production, configuration: Self.parakeet))
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

    @Test("Stored on + production: the General section has no live toggle", arguments: [false, true])
    @MainActor
    func toggleVisibility(offered: Bool) {
        var stored = true
        let storedOn = Fixtures.context(
            applied: Self.parakeet, state: Fixtures.ready,
            liveTranscriptionEnabled: Binding(get: { stored }, set: { stored = $0 }),
            offersLiveTranscription: offered
        )

        // The view tree the section builds, as text (offscreen hosting views expose no
        // accessibility tree without an assistive client, so the tree is inspected directly).
        var tree = ""
        dump(GeneralSettingsSection(context: storedOn).body, to: &tree)
        // Positive control: another toggle of the section is found.
        #expect(tree.contains("\"Sound feedback\""))
        #expect(tree.contains("\"\(GeneralSettingsSection.liveTranscriptionLabel)\"") == offered)
        #expect(stored, "showing or hiding the toggle must not change the stored value")
    }
}
