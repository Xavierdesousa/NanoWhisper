/// Answer of a `MediaPlaybackController` to "is media playing?".
enum MediaPlaybackState: Sendable, Equatable {
    case playing
    case notPlaying
    /// Detection failed or is not supported. Callers must not act on it.
    case unknown
}

/// The mechanism used to observe and control system media playback.
///
/// Implementations only answer the query and perform the action they are asked to perform.
/// Every pause/resume decision lives in `MediaController`, so the mechanism can be replaced
/// without touching that logic.
@MainActor
protocol MediaPlaybackController: AnyObject {
    /// Is media currently playing? Must not block the main actor.
    func playbackState() async -> MediaPlaybackState

    /// Pauses playback. Only called right after `playbackState()` answered `.playing`.
    /// Returns whether a pause was actually issued; `resume()` follows only if it was.
    func pause() async -> Bool

    /// Resumes the playback paused by a previous successful `pause()`. Called at most once
    /// per such `pause()`.
    func resume() async
}
