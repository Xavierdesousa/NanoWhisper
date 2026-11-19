import Foundation
import Testing
@testable import NanoWhisper

// MARK: - Fake mechanism

@MainActor
private final class FakePlaybackController: MediaPlaybackController {
    enum Call: Equatable { case query, pause, resume }

    /// Answer returned by `playbackState()`.
    var state: MediaPlaybackState
    private(set) var calls: [Call] = []
    /// When `true`, `playbackState()` waits until `releaseQueries()` is called.
    var holdQueries = false
    private var heldQueries: [CheckedContinuation<Void, Never>] = []

    init(state: MediaPlaybackState) {
        self.state = state
    }

    var pauseCount: Int { calls.filter { $0 == .pause }.count }
    var resumeCount: Int { calls.filter { $0 == .resume }.count }
    var heldQueryCount: Int { heldQueries.count }

    func playbackState() async -> MediaPlaybackState {
        calls.append(.query)
        if holdQueries {
            await withCheckedContinuation { heldQueries.append($0) }
        }
        return state
    }

    func pause() async { calls.append(.pause) }
    func resume() async { calls.append(.resume) }

    func releaseQueries() {
        let held = heldQueries
        heldQueries = []
        held.forEach { $0.resume() }
    }

    /// Lets background tasks run until a query is parked in `playbackState()`.
    func waitForHeldQuery() async {
        for _ in 0..<1_000 where heldQueries.isEmpty {
            await Task.yield()
        }
        #expect(!heldQueries.isEmpty, "detection never started")
    }
}

// MARK: - MediaController state machine

@Suite("MediaController")
@MainActor
struct MediaControllerTests {

    // MARK: Detection answer

    @Test("Pauses when media is playing and resumes when the session ends")
    func pausesAndResumes() async {
        let fake = FakePlaybackController(state: .playing)
        let controller = MediaController(playback: fake)

        let session = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        #expect(fake.calls == [.query, .pause])

        controller.endSession(session)
        await controller.waitUntilIdle()
        #expect(fake.calls == [.query, .pause, .resume])
    }

    @Test("Does nothing when media is not playing")
    func notPlaying() async {
        let fake = FakePlaybackController(state: .notPlaying)
        let controller = MediaController(playback: fake)

        let session = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        controller.endSession(session)
        await controller.waitUntilIdle()

        #expect(fake.calls == [.query])
    }

    @Test("Does nothing when detection answers unknown")
    func unknown() async {
        let fake = FakePlaybackController(state: .unknown)
        let controller = MediaController(playback: fake)

        let session = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        controller.endSession(session)
        await controller.waitUntilIdle()

        #expect(fake.calls == [.query])
    }

    @Test("Does not even detect when pausing media is disabled")
    func disabled() async {
        let fake = FakePlaybackController(state: .playing)
        let controller = MediaController(playback: fake)

        let session = controller.beginSession(pauseMedia: false)
        await controller.waitUntilIdle()
        controller.endSession(session)
        await controller.waitUntilIdle()

        #expect(fake.calls.isEmpty)
    }

    // MARK: Resume exactly once

    @Test("Ending a session twice resumes only once")
    func endTwice() async {
        let fake = FakePlaybackController(state: .playing)
        let controller = MediaController(playback: fake)

        let session = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        controller.endSession(session)
        controller.endSession(session)
        await controller.waitUntilIdle()
        controller.endSession(session)
        await controller.waitUntilIdle()

        #expect(fake.pauseCount == 1)
        #expect(fake.resumeCount == 1)
    }

    @Test("Each full cycle pauses and resumes once")
    func consecutiveCycles() async {
        let fake = FakePlaybackController(state: .playing)
        let controller = MediaController(playback: fake)

        for _ in 0..<2 {
            let session = controller.beginSession(pauseMedia: true)
            await controller.waitUntilIdle()
            controller.endSession(session)
            await controller.waitUntilIdle()
        }

        #expect(fake.calls == [.query, .pause, .resume, .query, .pause, .resume])
    }

    // MARK: Overlapping sessions

    @Test("Recording #2 during transcription #1: no resume until the last session ends")
    func overlapInOrder() async {
        let fake = FakePlaybackController(state: .playing)
        let controller = MediaController(playback: fake)

        let first = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        // Recording #1 stopped, transcription #1 running; recording #2 starts.
        let second = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        // Transcription #1 finishes while recording #2 is in progress.
        controller.endSession(first)
        await controller.waitUntilIdle()
        #expect(fake.resumeCount == 0)

        controller.endSession(second)
        await controller.waitUntilIdle()
        // Media we paused is not queried again, and is resumed exactly once.
        #expect(fake.calls == [.query, .pause, .resume])
    }

    @Test("Overlapping sessions ending in reverse order resume once, at the last end")
    func overlapReverseOrder() async {
        let fake = FakePlaybackController(state: .playing)
        let controller = MediaController(playback: fake)

        let first = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        let second = controller.beginSession(pauseMedia: true)
        controller.endSession(second)
        await controller.waitUntilIdle()
        #expect(fake.resumeCount == 0)

        controller.endSession(first)
        await controller.waitUntilIdle()
        #expect(fake.calls == [.query, .pause, .resume])
    }

    @Test("A session starting right after the last one ended takes over the paused state")
    func sessionStartsBeforeResumeRuns() async {
        let fake = FakePlaybackController(state: .playing)
        let controller = MediaController(playback: fake)

        let first = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        controller.endSession(first)
        // Starts before the scheduled resume had a chance to run.
        let second = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        #expect(fake.resumeCount == 0)

        controller.endSession(second)
        await controller.waitUntilIdle()
        #expect(fake.calls == [.query, .pause, .resume])
    }

    @Test("Media started during an open session is paused by the next one and resumed once")
    func mediaStartsBetweenSessions() async {
        let fake = FakePlaybackController(state: .notPlaying)
        let controller = MediaController(playback: fake)

        let first = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        fake.state = .playing
        let second = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        #expect(fake.calls == [.query, .query, .pause])

        controller.endSession(first)
        await controller.waitUntilIdle()
        #expect(fake.resumeCount == 0)

        controller.endSession(second)
        await controller.waitUntilIdle()
        #expect(fake.calls == [.query, .query, .pause, .resume])
    }

    // MARK: Detection in flight

    @Test("A session that begins while detection runs reuses it")
    func detectionInFlightIsShared() async {
        let fake = FakePlaybackController(state: .playing)
        fake.holdQueries = true
        let controller = MediaController(playback: fake)

        let first = controller.beginSession(pauseMedia: true)
        await fake.waitForHeldQuery()
        let second = controller.beginSession(pauseMedia: true)
        fake.releaseQueries()
        await controller.waitUntilIdle()
        #expect(fake.calls == [.query, .pause])

        controller.endSession(first)
        controller.endSession(second)
        await controller.waitUntilIdle()
        #expect(fake.calls == [.query, .pause, .resume])
    }

    @Test("Detection finishing after every session ended does not pause")
    func detectionFinishesAfterSessionEnded() async {
        let fake = FakePlaybackController(state: .playing)
        fake.holdQueries = true
        let controller = MediaController(playback: fake)

        let session = controller.beginSession(pauseMedia: true)
        await fake.waitForHeldQuery()
        controller.endSession(session)
        fake.releaseQueries()
        await controller.waitUntilIdle()

        #expect(fake.calls == [.query])
    }

    // MARK: startRecording failure path

    @Test("Failed recording start resumes media paused by its session")
    func failedStartRestores() async {
        let fake = FakePlaybackController(state: .playing)
        let controller = MediaController(playback: fake)

        let session = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        controller.endSession(session) // microphone failed
        await controller.waitUntilIdle()

        #expect(fake.calls == [.query, .pause, .resume])
    }

    @Test("Failed recording start during detection neither pauses nor resumes")
    func failedStartDuringDetection() async {
        let fake = FakePlaybackController(state: .playing)
        fake.holdQueries = true
        let controller = MediaController(playback: fake)

        let session = controller.beginSession(pauseMedia: true)
        controller.endSession(session) // microphone failed, synchronously after beginSession
        await fake.waitForHeldQuery()
        fake.releaseQueries()
        await controller.waitUntilIdle()

        #expect(fake.pauseCount == 0)
        #expect(fake.resumeCount == 0)
    }

    @Test("Failed recording start while a transcription runs leaves media paused for it")
    func failedStartWhileTranscribing() async {
        let fake = FakePlaybackController(state: .playing)
        let controller = MediaController(playback: fake)

        let transcribing = controller.beginSession(pauseMedia: true)
        await controller.waitUntilIdle()
        let failed = controller.beginSession(pauseMedia: true)
        controller.endSession(failed)
        await controller.waitUntilIdle()
        #expect(fake.resumeCount == 0)

        controller.endSession(transcribing)
        await controller.waitUntilIdle()
        #expect(fake.calls == [.query, .pause, .resume])
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
