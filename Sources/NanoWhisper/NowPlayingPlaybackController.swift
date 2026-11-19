/// The app that currently owns the system Now Playing session, as macOS reports it.
struct NowPlayingSession: Sendable, Equatable {
    let processIdentifier: Int32
    let bundleIdentifier: String?
    /// Track or page title. Optional: some players publish none.
    let title: String?
    let isPlaying: Bool

    /// Same app process showing the same item, whatever its playing state.
    func isSameItem(as other: NowPlayingSession) -> Bool {
        processIdentifier == other.processIdentifier
            && bundleIdentifier == other.bundleIdentifier
            && title == other.title
    }
}

/// One reading of the system Now Playing state.
enum NowPlayingReading: Sendable, Equatable {
    /// No app owns Now Playing: nothing has played since login, or the player quit.
    case noSession
    case session(NowPlayingSession)
    /// The state could not be read (helper missing, failed, timed out, unexpected output).
    case failed

    var playbackState: MediaPlaybackState {
        switch self {
        case .noSession: .notPlaying
        case .session(let session): session.isPlaying ? .playing : .notPlaying
        case .failed: .unknown
        }
    }
}

/// Explicit Now Playing commands. There is deliberately no toggle: a toggle sent on a wrong
/// guess starts playback.
enum NowPlayingCommand: Int, Sendable {
    // MediaRemote command IDs (kMRPlay, kMRPause).
    case play = 0
    case pause = 1
}

/// Reads and commands the system Now Playing session. Must not block the caller's actor.
/// Implemented by `MediaRemoteJXA`; another transport could be added behind it later.
protocol NowPlayingSource: Sendable {
    func read() async -> NowPlayingReading
    /// Sends `command` only if `session`'s app still owns Now Playing and is not already in
    /// the requested state. Returns whether the command was issued.
    @discardableResult
    func send(_ command: NowPlayingCommand, to session: NowPlayingSession) async -> Bool
}

/// `MediaPlaybackController` backed by the system Now Playing session (the media shown in
/// Control Center), which covers native players and browser tabs alike.
///
/// - Reads the state first, then pauses with an explicit pause command, never a toggle, so it
///   cannot start playback. Remembers what it paused only if the command was issued.
/// - Resumes only the item it paused: when the session is still the same app process with
///   the same title, and is still paused. Anything else (another app or tab took over,
///   the player quit, the state cannot be read) leaves playback alone.
///
/// Known limitations:
/// - Now Playing addresses one app at a time. When two sources play at once (say a video in a
///   browser and music in a player), only the one owning Now Playing, usually the last one
///   started, is paused; the other keeps playing.
/// - macOS routes a play command sent while no app owns Now Playing to Music, which it
///   launches (measured on macOS 27.2). The source re-checks the owner right before sending,
///   so this needs the player to quit within that instant.
@MainActor
final class NowPlayingPlaybackController: MediaPlaybackController {
    private let source: NowPlayingSource
    /// Session seen by the last `playbackState()`, the one `pause()` acts on.
    private var observed: NowPlayingSession?
    /// Session we paused and have not resumed yet.
    private var paused: NowPlayingSession?

    init(source: NowPlayingSource) {
        self.source = source
    }

    func playbackState() async -> MediaPlaybackState {
        let reading = await source.read()
        if case .session(let session) = reading {
            observed = session
        } else {
            observed = nil
        }
        return reading.playbackState
    }

    func pause() async {
        guard let target = observed, target.isPlaying else { return }
        // Not issued (state changed, or failure): nothing of ours to resume later.
        if await source.send(.pause, to: target) {
            paused = target
        }
    }

    func resume() async {
        guard let target = paused else { return }
        paused = nil
        let now = await source.read()
        guard Self.shouldResume(paused: target, now: now), case .session(let current) = now else { return }
        await source.send(.play, to: current)
    }

    /// Resume only when Now Playing still shows the item we paused, and it is still paused.
    nonisolated static func shouldResume(paused: NowPlayingSession, now: NowPlayingReading) -> Bool {
        guard case .session(let current) = now else { return false }
        return !current.isPlaying && current.isSameItem(as: paused)
    }
}
