/// Pauses system media while the user dictates and resumes it afterwards.
///
/// All pause/resume decisions live here; observing and controlling playback is delegated
/// to a `MediaPlaybackController`.
///
/// A session spans one recording and its transcription. Rules:
/// - Media is paused only when the controller answers `.playing`; `.unknown` means do nothing.
/// - Only media we paused is resumed, and exactly once.
/// - Sessions may overlap (a recording starts while the previous transcription is still
///   running). Media is never resumed while a session is open; it is resumed once, when the
///   last open session ends.
/// - A session beginning while the previous resume is still being sent detects only once it
///   has landed, so media resumed a moment ago is seen as playing and paused again.
/// - Detection runs in the background: `beginSession` returns immediately.
@MainActor
final class MediaController {
    /// Opaque handle returned by `beginSession`, to pass back to `endSession`.
    struct Session: Hashable, Sendable {
        fileprivate let id: UInt64
    }

    private let playback: MediaPlaybackController
    private var openSessions: Set<UInt64> = []
    private var nextSessionID: UInt64 = 0
    /// `true` while media is paused because of us and not yet resumed.
    private var didPause = false
    /// The in-flight "detect, then pause if playing" task, if any.
    private var pauseCheck: Task<Void, Never>?
    /// The in-flight `playback.resume()` call, if any. Only that call, not the whole resume
    /// task: the resume task itself waits for `pauseCheck`.
    private var resumeCall: Task<Void, Never>?
    /// Every in-flight task, so tests can wait for them.
    private var inFlight: [UInt64: Task<Void, Never>] = [:]
    private var nextTaskID: UInt64 = 0

    init(playback: MediaPlaybackController) {
        self.playback = playback
    }

    // MARK: - Public API

    /// Opens a session. When `pauseMedia` is `true`, starts a background check that pauses
    /// media if it is playing. Returns immediately.
    func beginSession(pauseMedia: Bool) -> Session {
        let session = Session(id: nextSessionID)
        nextSessionID &+= 1
        openSessions.insert(session.id)

        // Already paused by us, or a check is already in flight: nothing more to do.
        if pauseMedia, !didPause, pauseCheck == nil {
            pauseCheck = spawn { [self] in
                await pauseIfPlaying()
                pauseCheck = nil
            }
        }
        return session
    }

    /// Closes a session. When it was the last open one, resumes media if we paused it.
    /// Ending a session twice, or one that was never opened, does nothing.
    func endSession(_ session: Session) {
        guard openSessions.remove(session.id) != nil, openSessions.isEmpty else { return }
        spawn { [self] in await resumeIfNoSessionOpen() }
    }

    /// Waits until no detection, pause or resume is in flight.
    func waitUntilIdle() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    // MARK: - State machine

    private func pauseIfPlaying() async {
        // The previous session's resume may still be on its way: until it has landed, the
        // media reads as paused, and music would then start over this recording. No new
        // resume call can start while this check runs, so one wait is enough.
        if let call = resumeCall {
            await call.value
        }
        let state = await playback.playbackState()
        // Every session may have ended while we were detecting: a pause now would never be undone.
        guard state == .playing, !openSessions.isEmpty, !didPause else { return }
        // Owned only if a pause was actually issued: otherwise there is nothing to resume.
        if await playback.pause() {
            didPause = true
        }
    }

    private func resumeIfNoSessionOpen() async {
        // A check still in flight may pause; wait for it so that pause is undone too.
        while let check = pauseCheck {
            await check.value
        }
        // A new session may have started meanwhile: it now owns the paused state.
        guard openSessions.isEmpty, didPause else { return }
        didPause = false
        let call = Task { @MainActor [playback] in await playback.resume() }
        resumeCall = call
        await call.value
        if resumeCall == call {
            resumeCall = nil
        }
    }

    @discardableResult
    private func spawn(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = nextTaskID
        nextTaskID &+= 1
        let task = Task { @MainActor [self] in
            await body()
            inFlight[id] = nil
        }
        inFlight[id] = task
        return task
    }
}
