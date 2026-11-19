import Cocoa

/// Current playback mechanism: `SystemAudioActivityDetector` to detect playback, and a simulated
/// Play/Pause media key to pause and resume.
///
/// Known limitation: the media key is a toggle. If detection is wrong, it does the opposite
/// (resumes a paused player, or launches Music.app when no app owns Now Playing).
/// To be replaced by an explicit pause / play command.
@MainActor
final class MediaKeyPlaybackController: MediaPlaybackController {
    private let detector = SystemAudioActivityDetector()
    /// Serial: two detections never run at the same time.
    private let detectionQueue = DispatchQueue(label: "com.moonji.nanowhisper.audio-detect", qos: .userInitiated)

    func playbackState() async -> MediaPlaybackState {
        let detector = self.detector
        let queue = detectionQueue
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: detector.currentState())
            }
        }
    }

    func pause() async {
        sendPlayPauseKey()
    }

    func resume() async {
        sendPlayPauseKey()
    }

    // MARK: - Media key simulation via CGEvent

    private static let keyTypePlayPause: Int32 = 16

    private func sendPlayPauseKey() {
        sendMediaKey(Self.keyTypePlayPause, keyDown: true)
        sendMediaKey(Self.keyTypePlayPause, keyDown: false)
    }

    private func sendMediaKey(_ keyType: Int32, keyDown: Bool) {
        let flags: Int32 = keyDown ? 0xa00 : 0xb00
        let data1 = Int((keyType << 16) | flags)

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }

        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
