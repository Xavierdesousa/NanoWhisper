import Foundation
import Testing
import FluidAudio
@testable import NanoWhisper

@Suite("Transcriber concurrency")
struct TranscriberConcurrencyTests {

    private actor Recorder {
        private(set) var order: [Int] = []
        private(set) var inFlight = 0
        private(set) var maxInFlight = 0

        func begin(_ id: Int) {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            order.append(id)
        }

        func end() { inFlight -= 1 }
    }

    /// Wait until `gate` has `count` queued callers.
    private func waitForPending(_ gate: SerialGate, count: Int) async {
        while await gate.pendingCount < count {
            await Task.yield()
        }
    }

    // MARK: - SerialGate

    @Test("SerialGate runs holders one at a time, in arrival order, dropping none")
    func serialGateIsFIFOAndExclusive() async {
        let gate = SerialGate()
        let recorder = Recorder()

        await gate.acquire() // hold the gate while the others queue up
        var tasks: [Task<Void, Never>] = []
        for id in 1...5 {
            tasks.append(Task {
                await gate.acquire()
                await recorder.begin(id)
                try? await Task.sleep(nanoseconds: 2_000_000) // suspend while holding
                await recorder.end()
                await gate.release()
            })
            await waitForPending(gate, count: id)
        }
        await gate.release()
        for task in tasks { await task.value }

        #expect(await recorder.order == [1, 2, 3, 4, 5])
        #expect(await recorder.maxInFlight == 1)
        #expect(await gate.pendingCount == 0)
    }

    @Test("SerialGate is reusable after it drains")
    func serialGateReusable() async {
        let gate = SerialGate()
        await gate.acquire()
        await gate.release()
        await gate.acquire()
        #expect(await gate.pendingCount == 0)
        await gate.release()
    }

    // MARK: - Stale engine initialization

    @Test("A Parakeet initialization overtaken by a newer one does not overwrite it")
    @MainActor func staleParakeetInitDiscarded() async throws {
        let transcriber = Transcriber()
        let stale = AsrManager()
        let fresh = AsrManager()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()

        let staleInit = Task { @MainActor in
            try await transcriber.installParakeet {
                startedContinuation.yield()
                for await _ in gate { break } // "loading models" until released
                return stale
            }
        }
        for await _ in started { break }

        let freshInstalled = try await transcriber.installParakeet { fresh }
        #expect(freshInstalled)

        gateContinuation.yield()
        let staleInstalled = try await staleInit.value
        #expect(!staleInstalled)
        #expect(transcriber.currentAsrManager === fresh)
    }

    @Test("A model switch discards a Parakeet initialization still in flight")
    @MainActor func switchInvalidatesPendingInit() async throws {
        let transcriber = Transcriber()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (gate, gateContinuation) = AsyncStream<Void>.makeStream()

        let pending = Task { @MainActor in
            try await transcriber.installParakeet {
                startedContinuation.yield()
                for await _ in gate { break }
                return AsrManager()
            }
        }
        for await _ in started { break }

        transcriber.invalidatePendingInitialization()
        gateContinuation.yield()

        #expect(try await pending.value == false)
        #expect(transcriber.currentAsrManager == nil)
    }

    // MARK: - Configuration snapshot

    @Test("A queued recording uses the engine and settings in effect when it was submitted")
    @MainActor func queuedRecordingKeepsSubmittedConfiguration() async throws {
        let transcriber = Transcriber()
        let oldEngine = AsrManager()
        let newEngine = AsrManager()
        var oldSettings = WhisperSettings()
        oldSettings.language = "fr"
        oldSettings.promptText = "old hint"
        var newSettings = WhisperSettings()
        newSettings.language = "de"
        newSettings.promptText = "new hint"

        #expect(try await transcriber.installParakeet { oldEngine })
        transcriber.updateWhisperSettings(oldSettings)

        let urls = (0...2).map { URL(fileURLWithPath: "/tmp/recording-\($0).wav") }
        var seen: [URL: Transcriber.Configuration] = [:]
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        transcriber.transcriptionHandler = { configuration, url in
            seen[url] = configuration
            if url == urls[0] {
                startedContinuation.yield()
                for await _ in release { break } // recording #0 is still being transcribed
            }
            return Transcriber.TranscriptionResult(text: url.lastPathComponent, debugInfo: nil)
        }

        // #0 occupies the engine.
        let first = Task { @MainActor in await transcriber.transcribe(audioURL: urls[0]) }
        for await _ in started { break }

        // #1 is submitted with the old configuration and waits in the queue.
        let second = Task { @MainActor in await transcriber.transcribe(audioURL: urls[1]) }
        while await transcriber.queuedTranscriptionCount < 1 { await Task.yield() }

        // The user switches engine and settings while #1 is queued, then records #2.
        #expect(try await transcriber.installParakeet { newEngine })
        transcriber.updateWhisperSettings(newSettings)
        let third = Task { @MainActor in await transcriber.transcribe(audioURL: urls[2]) }
        while await transcriber.queuedTranscriptionCount < 2 { await Task.yield() }

        releaseContinuation.yield()
        #expect(await first.value.text == "recording-0.wav")
        #expect(await second.value.text == "recording-1.wav")
        #expect(await third.value.text == "recording-2.wav")

        #expect(seen[urls[0]]?.asrManager === oldEngine)
        #expect(seen[urls[1]]?.asrManager === oldEngine)
        #expect(seen[urls[1]]?.whisperSettings == oldSettings)
        #expect(seen[urls[2]]?.asrManager === newEngine)
        #expect(seen[urls[2]]?.whisperSettings == newSettings)
    }

    @Test("An initialization that is not overtaken installs its engine")
    @MainActor func parakeetInitInstalls() async throws {
        let transcriber = Transcriber()
        let manager = AsrManager()
        #expect(try await transcriber.installParakeet { manager })
        #expect(transcriber.currentAsrManager === manager)
    }
}
