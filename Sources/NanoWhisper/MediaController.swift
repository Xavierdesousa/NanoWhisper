import Foundation

/// Controls system-wide media playback via the private MediaRemote framework.
/// Checks whether media is actually playing before pausing, to avoid accidentally
/// triggering playback when nothing is queued.
@MainActor
final class MediaController {
    private var didPauseMedia = false

    private static let bundle: CFBundle? = {
        CFBundleCreate(
            kCFAllocatorDefault,
            URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL
        )
    }()

    private static let playbackRateKey = "kMRMediaRemoteNowPlayingInfoPlaybackRate"
    private static let commandPlay: UInt32 = 0
    private static let commandPause: UInt32 = 1

    private typealias GetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (UInt32, AnyObject?) -> Bool

    /// Pauses system media if something is currently playing.
    /// Tracks state so `resumeIfPaused()` can restore playback later.
    func pauseIfPlaying() async {
        guard await isMediaPlaying() else { return }
        sendCommand(Self.commandPause)
        didPauseMedia = true
    }

    /// Resumes media only if it was paused by `pauseIfPlaying()`.
    func resumeIfPaused() {
        guard didPauseMedia else { return }
        didPauseMedia = false
        sendCommand(Self.commandPlay)
    }

    // MARK: - Private

    private func isMediaPlaying() async -> Bool {
        await withCheckedContinuation { continuation in
            guard let bundle = Self.bundle,
                  let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingInfo" as CFString) else {
                continuation.resume(returning: false)
                return
            }
            let fn = unsafeBitCast(ptr, to: GetNowPlayingInfoFn.self)
            fn(DispatchQueue.main) { info in
                let rate = info[Self.playbackRateKey] as? Float ?? 0
                continuation.resume(returning: rate > 0)
            }
        }
    }

    private func sendCommand(_ command: UInt32) {
        guard let bundle = Self.bundle,
              let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else {
            return
        }
        let fn = unsafeBitCast(ptr, to: SendCommandFn.self)
        _ = fn(command, nil)
    }
}
