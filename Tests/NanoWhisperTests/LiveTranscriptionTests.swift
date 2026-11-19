import AppKit
import FluidAudio
import Foundation
import Testing
@testable import NanoWhisper

// MARK: - Transcript state

@Suite("Live transcript")
struct LiveTranscriptTests {
    typealias Revision = LiveTranscript.Revision

    private func revision(
        _ transcript: LiveTranscript, retained: Int? = nil, stable: Int, _ pieces: [String], terminal: Bool = false
    ) -> Revision {
        Revision(
            previousCount: transcript.pieces.count,
            retainedCount: retained ?? transcript.pieces.count,
            stableCount: stable,
            pieces: pieces,
            isTerminal: terminal
        )
    }

    @Test("An empty transcript has no text and nothing to paste")
    func empty() {
        let transcript = LiveTranscript()
        #expect(transcript.text.isEmpty)
        #expect(transcript.stableText.isEmpty && transcript.volatileText.isEmpty)
        #expect(transcript.isEmpty)
        #expect(transcript.finalText == nil)
    }

    @Test("Stable tokens render in the stable part, the rest in the volatile tail")
    func stableVolatileSplit() throws {
        var transcript = LiveTranscript()
        try transcript.apply(revision(transcript, stable: 1, [" Hello", " world", "."]))
        #expect(transcript.text == "Hello world.")
        #expect(transcript.stableText == "Hello")
        #expect(transcript.volatileText == " world.")
        #expect(transcript.finalText == nil)
    }

    @Test("A revision replaces the tail after the retained tokens")
    func retainedPrefixAndReplacedTail() throws {
        var transcript = LiveTranscript()
        try transcript.apply(revision(transcript, stable: 2, [" Send", " the", " rep", "or"]))
        try transcript.apply(revision(transcript, retained: 2, stable: 3, [" report", " today"]))
        #expect(transcript.text == "Send the report today")
        #expect(transcript.stableText == "Send the report")
        #expect(transcript.volatileText == " today")
    }

    @Test("Once final, the overlay shows exactly the string that is pasted")
    func finalTextEqualsDisplayedText() throws {
        var transcript = LiveTranscript()
        try transcript.apply(revision(transcript, stable: 1, [" J'ai", " dix", " minutes"]))
        try transcript.apply(revision(transcript, retained: 2, stable: 2, [" minutes", " de", " retard", "."]))
        try transcript.apply(revision(transcript, stable: transcript.pieces.count, [], terminal: true))

        let pasted = try #require(transcript.finalText)
        let displayed = transcript.stableText + transcript.volatileText
        #expect(displayed == pasted)
        #expect(pasted == "J'ai dix minutes de retard.")
        #expect(transcript.volatileText.isEmpty)
        // Trimmed exactly like a batch transcription.
        #expect(pasted == pasted.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test("stableText + volatileText == text after every revision", arguments: [1, 2, 3, 4, 5])
    func displayInvariant(seed: Int) throws {
        // Deterministic pseudo-random revision sequences within the engine's contract.
        var rng = SplitMix64(seed: UInt64(seed))
        let words = [" le", " rapport", ",", " demain", " matin", " ?", "é", " café", "\u{301}", " <unk>", "<unk>",
                     "\u{2581}word", " ", "\n", " 10h30", "."]
        var transcript = LiveTranscript()
        for step in 0..<40 {
            let count = transcript.pieces.count
            let retained = Int.random(in: transcript.stableCount...count, using: &rng)
            let appended = (0..<Int.random(in: 0...4, using: &rng)).map { _ in words.randomElement(using: &rng)! }
            let total = retained + appended.count
            let terminal = step == 39
            let stable = terminal ? total : Int.random(in: transcript.stableCount...max(transcript.stableCount, total), using: &rng)
            try transcript.apply(Revision(previousCount: count, retainedCount: retained, stableCount: min(stable, total),
                                          pieces: appended, isTerminal: terminal))
            #expect(transcript.stableText + transcript.volatileText == transcript.text)
        }
        #expect(transcript.finalText == transcript.stableText + transcript.volatileText)
    }

    @Test("Unknown tokens are dropped, word boundaries become spaces, whitespace is trimmed")
    func renderingMatchesBatchText() throws {
        var transcript = LiveTranscript()
        try transcript.apply(revision(transcript, stable: 0, [" ", "<unk>", "\u{2581}Bonjour", "<unk>", " Sarah", ",", " \n"]))
        #expect(transcript.text == "Bonjour Sarah,")
        #expect(transcript.volatileText == "Bonjour Sarah,")
    }

    @Test("A stable boundary inside a grapheme rounds down and keeps the invariant")
    func boundaryInsideGrapheme() throws {
        var transcript = LiveTranscript()
        // "e" + combining acute accent form one character, "é", split across two tokens.
        try transcript.apply(revision(transcript, stable: 1, [" cafe", "\u{301}"]))
        #expect(transcript.text == "caf\u{e9}" || transcript.text == "cafe\u{301}")
        #expect(transcript.stableText == "caf")
        #expect(transcript.stableText + transcript.volatileText == transcript.text)
    }

    @Test("Revisions that break the contract are rejected and leave the transcript unchanged")
    func invalidRevisions() throws {
        var transcript = LiveTranscript()
        try transcript.apply(revision(transcript, stable: 2, [" a", " b", " c"]))
        let before = transcript

        #expect(throws: LiveTranscript.RevisionError.outOfSequence(expected: 3, received: 2)) {
            try transcript.apply(Revision(previousCount: 2, retainedCount: 2, stableCount: 2, pieces: [], isTerminal: false))
        }
        // Retiring a token already declared stable.
        #expect(throws: LiveTranscript.RevisionError.invalidCounts) {
            try transcript.apply(Revision(previousCount: 3, retainedCount: 1, stableCount: 2, pieces: [" x"], isTerminal: false))
        }
        // The stable prefix shrinking.
        #expect(throws: LiveTranscript.RevisionError.invalidCounts) {
            try transcript.apply(Revision(previousCount: 3, retainedCount: 3, stableCount: 1, pieces: [], isTerminal: false))
        }
        // A terminal revision must make everything stable.
        #expect(throws: LiveTranscript.RevisionError.invalidCounts) {
            try transcript.apply(Revision(previousCount: 3, retainedCount: 3, stableCount: 2, pieces: [], isTerminal: true))
        }
        #expect(transcript == before)

        try transcript.apply(Revision(previousCount: 3, retainedCount: 3, stableCount: 3, pieces: [], isTerminal: true))
        #expect(throws: LiveTranscript.RevisionError.alreadyFinal) {
            try transcript.apply(Revision(previousCount: 3, retainedCount: 3, stableCount: 3, pieces: [], isTerminal: true))
        }
    }

    @Test("FluidAudio token updates map to revisions")
    func mapsSlidingWindowTokenUpdate() {
        let update = SlidingWindowTokenUpdate(
            tokens: [
                TokenTiming(token: " Bonjour", tokenId: 10, startTime: 0.1, endTime: 0.4, confidence: 0.9),
                TokenTiming(token: ",", tokenId: 11, startTime: 0.4, endTime: 0.5, confidence: 0.8),
            ],
            revision: SlidingWindowTokenRevision(
                jobID: UUID(), ordinal: 3, previousTokenCount: 7, retainedTokenCount: 5, stableTokenCount: 6,
                window: 0..<64_000, center: 16_000..<48_000, isTerminal: false
            )
        )
        let revision = LiveTranscript.Revision(update)
        #expect(revision == LiveTranscript.Revision(
            previousCount: 7, retainedCount: 5, stableCount: 6, pieces: [" Bonjour", ","], isTerminal: false))
    }
}

/// Small deterministic generator for the property-style test.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Session lifecycle

/// Scriptable engine: the test publishes revisions and decides how `finish()` behaves.
private actor FakeLiveEngine: LiveTranscriptionEngine {
    enum FinishBehavior: Sendable {
        /// Publish this terminal revision, then end the stream.
        case finalize(LiveTranscript.Revision)
        case fail(LiveTestError)
        /// Never finalize (until cancelled).
        case hang
    }

    private(set) var appended: [[Float]] = []
    private(set) var finishCount = 0
    private(set) var cancelCount = 0
    private(set) var isStarted = false
    private var continuation: AsyncThrowingStream<LiveTranscript.Revision, any Error>.Continuation?
    private let startError: LiveTestError?
    private var finishBehavior: FinishBehavior

    init(startError: LiveTestError? = nil, finish: FinishBehavior = .hang) {
        self.startError = startError
        self.finishBehavior = finish
    }

    func setFinish(_ behavior: FinishBehavior) { finishBehavior = behavior }

    func start() async throws -> AsyncThrowingStream<LiveTranscript.Revision, any Error> {
        if let startError { throw startError }
        let (stream, continuation) = AsyncThrowingStream<LiveTranscript.Revision, any Error>.makeStream()
        self.continuation = continuation
        isStarted = true
        return stream
    }

    func append(_ samples: [Float]) { appended.append(samples) }

    func finish() async throws {
        finishCount += 1
        switch finishBehavior {
        case .finalize(let terminal):
            continuation?.yield(terminal)
            continuation?.finish()
        case .fail(let error):
            continuation?.finish(throwing: error)
            throw error
        case .hang:
            while cancelCount == 0 { try? await Task.sleep(for: .milliseconds(2)) }
        }
    }

    func cancel() {
        cancelCount += 1
        continuation?.finish(throwing: CancellationError())
    }

    func emit(_ revision: LiveTranscript.Revision) { continuation?.yield(revision) }
    func failStream(_ error: LiveTestError) { continuation?.finish(throwing: error) }
}

enum LiveTestError: Error, Equatable { case boom }

@MainActor
@Suite("Live transcription session")
struct LiveTranscriptionSessionTests {
    /// Poll until `condition` holds (fails the test after ~2 s).
    private func waitUntil(_ what: String, _ condition: () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting until \(what)")
    }

    private func started(_ engine: FakeLiveEngine) -> LiveTranscriptionSession {
        let session = LiveTranscriptionSession(engine: engine)
        session.start()
        return session
    }

    @Test("Samples reach the engine in order; finish returns the finalized transcript")
    func finalizesWithTheStreamedText() async throws {
        let engine = FakeLiveEngine()
        let session = started(engine)
        var updates: [String] = []
        session.onUpdate = { updates.append($0.text) }

        await waitUntil("the engine started") { await engine.isStarted }
        session.sampleSink([0.1, 0.2])
        session.sampleSink([0.3])
        await engine.emit(.init(previousCount: 0, retainedCount: 0, stableCount: 1, pieces: [" Hello", " wor"], isTerminal: false))
        await waitUntil("the first revision is shown") { session.transcript.text == "Hello wor" }

        await engine.setFinish(.finalize(.init(previousCount: 2, retainedCount: 1, stableCount: 3,
                                               pieces: [" world", "."], isTerminal: true)))
        let final = await session.finish()

        #expect(final?.finalText == "Hello world.")
        #expect(final?.stableText == "Hello world.")
        #expect(updates == ["Hello wor", "Hello world."])
        #expect(await engine.appended == [[0.1, 0.2], [0.3]])
        #expect(await engine.finishCount == 1)
        #expect(await engine.cancelCount == 0)
        #expect(session.failure == nil)
    }

    @Test("An engine error while recording clears the text, stops the engine and falls back")
    func engineFailureFallsBack() async {
        let engine = FakeLiveEngine()
        let session = started(engine)
        var failures = 0
        session.onFailure = { _ in failures += 1 }

        await waitUntil("the engine started") { await engine.isStarted }
        await engine.emit(.init(previousCount: 0, retainedCount: 0, stableCount: 0, pieces: [" Hi"], isTerminal: false))
        await waitUntil("text is shown") { !session.transcript.isEmpty }
        await engine.failStream(.boom)
        await waitUntil("the failure is reported") { failures == 1 }

        #expect(session.transcript.isEmpty)
        session.sampleSink([0.5]) // dropped: the session is over
        #expect(await session.finish() == nil)
        await session.waitUntilStopped()
        #expect(await engine.cancelCount == 1)
        #expect(await engine.appended.isEmpty)
        #expect(failures == 1)
    }

    @Test("A revision out of sequence fails the session")
    func brokenRevisionSequenceFallsBack() async {
        let engine = FakeLiveEngine()
        let session = started(engine)
        await waitUntil("the engine started") { await engine.isStarted }
        await engine.emit(.init(previousCount: 5, retainedCount: 0, stableCount: 0, pieces: [" x"], isTerminal: false))
        await waitUntil("the failure is recorded") { session.failure != nil }
        #expect(session.failure as? LiveTranscript.RevisionError == .outOfSequence(expected: 0, received: 5))
        #expect(await session.finish() == nil)
    }

    @Test("A failure while finalizing falls back")
    func finishFailureFallsBack() async {
        let engine = FakeLiveEngine(finish: .fail(.boom))
        let session = started(engine)
        await waitUntil("the engine started") { await engine.isStarted }
        await engine.emit(.init(previousCount: 0, retainedCount: 0, stableCount: 1, pieces: [" Hi"], isTerminal: false))
        await waitUntil("text is shown") { !session.transcript.isEmpty }
        #expect(await session.finish() == nil)
        #expect(session.failure as? LiveTestError == .boom)
    }

    @Test("An engine that does not start falls back")
    func startFailureFallsBack() async {
        let engine = FakeLiveEngine(startError: .boom)
        let session = started(engine)
        await waitUntil("the failure is recorded") { session.failure != nil }
        #expect(await session.finish() == nil)
    }

    @Test("An engine that does not finalize in time is cancelled and falls back")
    func finishTimesOut() async {
        let engine = FakeLiveEngine(finish: .hang)
        let session = started(engine)
        await waitUntil("the engine started") { await engine.isStarted }
        await engine.emit(.init(previousCount: 0, retainedCount: 0, stableCount: 0, pieces: [" Hi"], isTerminal: false))
        await waitUntil("text is shown") { !session.transcript.isEmpty }

        #expect(await session.finish(timeout: .milliseconds(50)) == nil)
        #expect(session.failure as? LiveTranscriptionError == .timedOut)
        await session.waitUntilStopped()
        #expect(await engine.cancelCount == 1)
    }

    @Test("A recording that ended before any text was shown is not flushed: batch transcribes it")
    func nothingShownFallsBackWithoutFlushing() async {
        let engine = FakeLiveEngine(finish: .finalize(.init(previousCount: 0, retainedCount: 0, stableCount: 1,
                                                           pieces: [" late"], isTerminal: true)))
        let session = started(engine)
        await waitUntil("the engine started") { await engine.isStarted }
        session.sampleSink([0.1])

        #expect(await session.finish() == nil)
        await session.waitUntilStopped()
        #expect(await engine.finishCount == 0)
        #expect(await engine.cancelCount == 1)
        #expect(session.failure == nil)
    }

    @Test("Cancelling stops the engine and ignores anything it publishes afterwards")
    func cancelStopsEverything() async {
        let engine = FakeLiveEngine()
        let session = started(engine)
        var updates = 0
        var failures = 0
        session.onUpdate = { _ in updates += 1 }
        session.onFailure = { _ in failures += 1 }
        await waitUntil("the engine started") { await engine.isStarted }

        session.cancel()
        session.cancel() // idempotent
        await engine.emit(.init(previousCount: 0, retainedCount: 0, stableCount: 0, pieces: [" late"], isTerminal: false))
        session.sampleSink([0.1])
        await session.waitUntilStopped()

        #expect(await session.finish() == nil)
        #expect(await engine.cancelCount == 1)
        #expect(await engine.appended.isEmpty)
        #expect(updates == 0 && failures == 0)
        #expect(session.transcript.isEmpty)
    }

    @Test("Each recording starts from an empty transcript; a previous session cannot leak into it")
    func noStaleTextBetweenRecordings() async {
        let first = FakeLiveEngine()
        let firstSession = started(first)
        await waitUntil("the first engine started") { await first.isStarted }
        await first.emit(.init(previousCount: 0, retainedCount: 0, stableCount: 1, pieces: [" first"], isTerminal: false))
        await waitUntil("the first text is shown") { !firstSession.transcript.isEmpty }
        firstSession.cancel()

        let second = FakeLiveEngine()
        let secondSession = started(second)
        #expect(secondSession.transcript.isEmpty)
        #expect(secondSession.id != firstSession.id)
        await first.emit(.init(previousCount: 1, retainedCount: 1, stableCount: 2, pieces: [" stale"], isTerminal: false))
        await waitUntil("the second engine started") { await second.isStarted }
        #expect(secondSession.transcript.isEmpty)
        secondSession.cancel()
        await firstSession.waitUntilStopped()
        await secondSession.waitUntilStopped()
    }
}

// MARK: - Overlay geometry

@Suite("Recording overlay frame")
struct RecordingOverlayFrameTests {
    @Test("Growing for the transcript keeps the top edge and the horizontal center")
    @MainActor func keepsTopCenter() {
        let current = NSRect(x: 694, y: 860, width: 123, height: 40)
        let frame = RecordingOverlayController.frame(
            fitting: NSSize(width: 384, height: 82), from: current, within: NSRect(x: 0, y: 0, width: 1512, height: 912))
        #expect(frame.maxY == current.maxY)
        #expect(abs(frame.midX - current.midX) <= 0.5)
        #expect(frame.size == NSSize(width: 384, height: 82))
    }

    @Test("The grown overlay stays inside its screen")
    @MainActor func staysOnScreen() {
        // Dragged to the bottom-right corner of a secondary screen placed left of the main one.
        let visible = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
        let current = NSRect(x: -140, y: 10, width: 123, height: 40)
        let frame = RecordingOverlayController.frame(fitting: NSSize(width: 384, height: 82), from: current, within: visible)
        #expect(visible.contains(frame))
    }
}
