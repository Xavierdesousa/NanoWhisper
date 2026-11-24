import AVFoundation
import FluidAudio
import Foundation
import Testing
@testable import NanoWhisper

@Suite("Parakeet configuration")
struct ParakeetConfigurationTests {
    @Test("FluidAudio's defaults, except that it never copies a recording to disk")
    func inMemory() {
        let config = Transcriber.asrConfig, defaults = ASRConfig.default
        #expect(!config.streamingEnabled)
        #expect(defaults.streamingEnabled, "what the setting is for")
        #expect(config.sampleRate == defaults.sampleRate)
        #expect(config.encoderHiddenSize == defaults.encoderHiddenSize)
        #expect(config.parallelChunkConcurrency == defaults.parallelChunkConcurrency)
        #expect(config.melChunkContextOverride == defaults.melChunkContextOverride)
        #expect(config.dualDecodeArbitration == defaults.dualDecodeArbitration)
        #expect(config.seamGapRepair == defaults.seamGapRepair)
        #expect(config.seamGapRepairMinGapSeconds == defaults.seamGapRepairMinGapSeconds)
        #expect(config.seamTimingRealignment == defaults.seamTimingRealignment)
        #expect(String(describing: config.tdtConfig) == String(describing: defaults.tdtConfig))
    }
}

/// With the real model, a clone of the installed one, on synthesised speech:
///
///     cp -cR ~/Library/Application\ Support/FluidAudio/Models/parakeet-ultra <dir>/
///     NANOWHISPER_PARAKEET_ULTRA=<dir>/parakeet-ultra swift test --filter RecordingCopyTests
///
/// Lists the names in the temp directory while it transcribes: another app transcribing a long
/// file with FluidAudio at that moment makes it fail.
@Suite("RecordingCopy", .serialized, .enabled(if: ProcessInfo.processInfo.environment["NANOWHISPER_PARAKEET_ULTRA"] != nil))
@MainActor
final class RecordingCopyTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingCopyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Over 30 s of speech, written as the recorder writes it.
    private func speech() throws -> URL {
        let aiff = directory.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        let sentences = (1...12).map {
            "Sentence number \($0): the meeting about the budget starts at \($0 + 1) thirty in the main room."
        }
        say.arguments = ["-o", aiff.path, sentences.joined(separator: " ")]
        try say.run()
        say.waitUntilExit()
        let file = try AVAudioFile(forReading: aiff)
        let wav = directory.appendingPathComponent("nanowhisper-debug_speech.wav")
        let writer = try RecordingWriter(url: wav)
        try writer.setInputFormat(file.processingFormat)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
        while file.framePosition < file.length {
            try file.read(into: buffer)
            _ = writer.append(buffer)
        }
        writer.finish()
        try #require(writer.framesWritten > ASRConfig.default.streamingThreshold)
        return wav
    }

    /// The copies that appeared in the temp directory while `work` ran.
    private func copies<T>(during work: () async throws -> T) async throws -> (T, Set<String>) {
        let names: @Sendable () -> Set<String> = {
            let all = try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)
            return Set((all ?? []).filter(RecordingCopies.isCopyName))
        }
        let before = names()
        let watcher = Task.detached {
            var seen: Set<String> = []
            while !Task.isCancelled {
                seen.formUnion(names())
                usleep(1000)
            }
            return seen
        }
        let result = try await work()
        watcher.cancel()
        return (result, await watcher.value.subtracting(before))
    }

    @Test("Same text as FluidAudio's defaults, and no copy: dictation, upgraded engine and live preview")
    func noCopy() async throws {
        let model = URL(fileURLWithPath: ProcessInfo.processInfo.environment["NANOWHISPER_PARAKEET_ULTRA"]!)
        let models = try await AsrModels.load(from: model, version: .ultra)
        let wav = try speech()

        let reference = AsrManager(config: .default)
        try await reference.loadModels(models)
        let (expected, referenceCopies) = try await copies {
            var state = TdtDecoderState.make(decoderLayers: await reference.decoderLayerCount)
            return try await reference.transcribe(wav, decoderState: &state).text
        }
        #expect(referenceCopies.count == 1, "the watcher sees the copy the defaults make")
        #expect(expected.count > 300)

        let transcriber = Transcriber()
        #expect(try await transcriber.initializeParakeet(models: models, variant: .ultra))
        let (text, made) = try await copies { await transcriber.transcribe(audioURL: wav).text }
        #expect(text == expected && made.isEmpty)

        let prepared = try await transcriber.prepareParakeet(models: models, variant: .ultra)
        #expect(transcriber.installPrepared(prepared))
        let (upgraded, madeByUpgraded) = try await copies { await transcriber.transcribe(audioURL: wav).text }
        #expect(upgraded == expected && madeByUpgraded.isEmpty)

        let samples = try AudioConverter().resampleAudioFile(wav)
        let decoder = try #require(transcriber.makePreviewDecoder())
        let (preview, madeByPreview) = try await copies { try await decoder.decode(samples).text }
        #expect(preview == expected && madeByPreview.isEmpty)
    }
}
