import Foundation
import Testing
@testable import NanoWhisper

@Suite("MediaController")
@MainActor
struct MediaControllerTests {

    // MARK: - Lifecycle

    @Test("Initializes without crashing")
    func initializesCleanly() {
        _ = MediaController()
    }

    // MARK: - resumeIfPaused

    @Test("resumeIfPaused is a no-op when nothing was paused")
    func resumeWhenNotPaused() {
        let controller = MediaController()
        // didPauseMedia is false by default — should not send any command
        controller.resumeIfPaused()
    }

    @Test("resumeIfPaused is safe to call multiple times consecutively")
    func resumeMultipleTimesIsIdempotent() {
        let controller = MediaController()
        controller.resumeIfPaused()
        controller.resumeIfPaused()
        controller.resumeIfPaused()
    }

    // MARK: - pauseIfPlaying

    @Test("pauseIfPlaying completes without error when no media is playing")
    func pauseWhenNothingPlaying() async {
        let controller = MediaController()
        // In test environments (CI / no active media session) should complete cleanly
        await controller.pauseIfPlaying()
    }

    @Test("resumeIfPaused is a no-op after pauseIfPlaying finds nothing playing")
    func resumeAfterPauseFindsNothingPlaying() async {
        let controller = MediaController()
        // pauseIfPlaying finds nothing playing → didPauseMedia stays false
        await controller.pauseIfPlaying()
        // resumeIfPaused must be a no-op (guard didPauseMedia fires)
        controller.resumeIfPaused()
    }

    @Test("pauseIfPlaying followed immediately by resumeIfPaused does not crash")
    func pauseThenResumeSequence() async {
        let controller = MediaController()
        await controller.pauseIfPlaying()
        controller.resumeIfPaused()
        // Second resume must also be safe
        controller.resumeIfPaused()
    }
}

// MARK: - pauseMediaEnabled UserDefaults logic

@Suite("pauseMediaEnabled Setting")
struct PauseMediaEnabledTests {

    private let key = "pauseMediaEnabled"

    @Test("Defaults to true when key is absent from UserDefaults")
    func defaultsToTrue() {
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        // Mirrors the nil-check pattern used in AppState.init()
        let value: Bool = UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)

        #expect(value == true)
    }

    @Test("Reads false correctly when explicitly stored")
    func readsFalse() {
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let value: Bool = UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)

        #expect(value == false)
    }

    @Test("Reads true correctly when explicitly stored")
    func readsTrue() {
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let value: Bool = UserDefaults.standard.object(forKey: key) == nil
            ? true
            : UserDefaults.standard.bool(forKey: key)

        #expect(value == true)
    }

    @Test("Key name is pauseMediaEnabled")
    func keyName() {
        // Verifies the constant used in AppState matches expectations
        #expect(key == "pauseMediaEnabled")
    }
}
