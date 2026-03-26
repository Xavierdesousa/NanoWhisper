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
    func pauseWhenNothingPlaying() {
        let controller = MediaController()
        // In test environments (CI / no active media session) should complete cleanly
        controller.pauseIfPlaying()
    }

    @Test("resumeIfPaused is a no-op after pauseIfPlaying finds nothing playing")
    func resumeAfterPauseFindsNothingPlaying() {
        let controller = MediaController()
        // pauseIfPlaying finds nothing playing → didPauseMedia stays false
        controller.pauseIfPlaying()
        // resumeIfPaused must be a no-op (guard didPauseMedia fires)
        controller.resumeIfPaused()
    }

    @Test("pauseIfPlaying followed immediately by resumeIfPaused does not crash")
    func pauseThenResumeSequence() {
        let controller = MediaController()
        controller.pauseIfPlaying()
        controller.resumeIfPaused()
        // Second resume must also be safe
        controller.resumeIfPaused()
    }
}

// MARK: - pauseMediaEnabled UserDefaults logic

@Suite("pauseMediaEnabled Setting", .serialized)
@MainActor
struct PauseMediaEnabledTests {

    private let key = "pauseMediaEnabled"

    @Test("Defaults to false when key is absent from UserDefaults")
    func defaultsToFalse() {
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(UserDefaults.standard.bool(forKey: key) == false)
    }

    @Test("Reads false correctly when explicitly stored")
    func readsFalse() {
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(UserDefaults.standard.bool(forKey: key) == false)
    }

    @Test("Reads true correctly when explicitly stored")
    func readsTrue() {
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        #expect(UserDefaults.standard.bool(forKey: key) == true)
    }
}
