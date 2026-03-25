import AVFoundation

@MainActor
class SoundManager {
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    private var startBuffer: AVAudioPCMBuffer?
    private var startFormat: AVAudioFormat?
    private var stopBuffer: AVAudioPCMBuffer?
    private var stopFormat: AVAudioFormat?
    private var noResultBuffer: AVAudioPCMBuffer?
    private var noResultFormat: AVAudioFormat?

    private static let enabledKey = "soundEnabled"

    var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: Self.enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: Self.enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    init() {
        if let (buf, fmt) = loadSound(named: "start", ext: "m4a") {
            startBuffer = buf
            startFormat = fmt
        }
        if let (buf, fmt) = loadSound(named: "stop", ext: "m4a") {
            stopBuffer = buf
            stopFormat = fmt
        }
        if let (buf, fmt) = loadSound(named: "noResult", ext: "m4a") {
            noResultBuffer = buf
            noResultFormat = fmt
        }
    }

    func playStart() {
        guard isEnabled, let buffer = startBuffer else { return }
        play(buffer)
    }

    func playStop() {
        guard isEnabled, let buffer = stopBuffer else { return }
        play(buffer)
    }

    func playNoResult() {
        guard isEnabled, let buffer = noResultBuffer else { return }
        play(buffer)
    }

    // MARK: - Playback

    private func play(_ buffer: AVAudioPCMBuffer) {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: buffer.format)

        do {
            try engine.start()
        } catch {
            return
        }

        self.audioEngine = engine
        self.playerNode = player

        player.play()
        player.scheduleBuffer(buffer) { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self?.playerNode?.stop()
                self?.audioEngine?.stop()
            }
        }
    }

    // MARK: - Load audio from bundle

    private func loadSound(named name: String, ext: String = "m4a") -> (AVAudioPCMBuffer, AVAudioFormat)? {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: name, withExtension: ext) else { return nil }

        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        try? file.read(into: buffer)

        return (buffer, format)
    }
}
