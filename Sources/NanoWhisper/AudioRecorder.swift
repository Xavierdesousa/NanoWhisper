import AVFoundation
import Combine
import os

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private let audioFileLock = NSLock()
    private var outputURL: URL?

    /// Current audio level (0.0 – 1.0), updated from the recording tap.
    let audioLevelSubject = PassthroughSubject<Float, Never>()

    func startRecording() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Target: 16kHz mono WAV (standard for ASR)
        guard let recordingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw RecorderError.formatError
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanowhisper_\(UUID().uuidString).wav")
        outputURL = url

        audioFile = try AVAudioFile(forWriting: url, settings: recordingFormat.settings)

        // Install converter if sample rates differ
        guard let converter = AVAudioConverter(from: inputFormat, to: recordingFormat) else {
            throw RecorderError.converterError
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }

            let frameCount = AVAudioFrameCount(
                Double(buffer.frameLength) * recordingFormat.sampleRate / inputFormat.sampleRate
            )
            guard frameCount > 0 else { return }

            guard let convertedBuffer = AVAudioPCMBuffer(
                pcmFormat: recordingFormat,
                frameCapacity: frameCount
            ) else { return }

            var error: NSError?
            var consumed = false
            converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                if consumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error == nil && convertedBuffer.frameLength > 0 {
                self.audioFileLock.lock()
                try? self.audioFile?.write(from: convertedBuffer)
                self.audioFileLock.unlock()

                // Compute RMS level for the visualizer
                if let channelData = convertedBuffer.floatChannelData?[0] {
                    let frames = Int(convertedBuffer.frameLength)
                    var sum: Float = 0
                    for i in 0..<frames {
                        let sample = channelData[i]
                        sum += sample * sample
                    }
                    let rms = sqrt(sum / Float(max(frames, 1)))
                    // Boost and apply sqrt curve so quiet speech is still visible
                    let boosted = min(rms * 25.0, 1.0)
                    let level = sqrt(boosted)
                    self.audioLevelSubject.send(level)
                }
            }
        }

        try engine.start()
        audioEngine = engine
    }

    func stopRecording() -> URL? {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioFileLock.lock()
        audioFile = nil
        audioFileLock.unlock()
        return outputURL
    }

    enum RecorderError: Error, LocalizedError {
        case formatError
        case converterError

        var errorDescription: String? {
            switch self {
            case .formatError: return "Could not create audio format"
            case .converterError: return "Could not create audio converter"
            }
        }
    }
}
