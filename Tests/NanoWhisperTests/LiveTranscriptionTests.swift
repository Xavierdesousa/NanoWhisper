import AppKit
import Foundation
import Testing
@testable import NanoWhisper

// MARK: - Transcript state

@Suite("Live transcript")
struct LiveTranscriptTests {

    @Test("An empty transcript has no text and nothing to paste")
    func empty() {
        let transcript = LiveTranscript()
        #expect(transcript.isEmpty)
        #expect(transcript.stableText.isEmpty && transcript.volatileText.isEmpty)
        #expect(transcript.finalText == nil)
    }

    @Test("The first decode is all volatile; words confirmed by the next decode become stable")
    func stableIsCommonWordPrefix() {
        var transcript = LiveTranscript()
        transcript.update(partial: "I'll be ten")
        #expect(transcript.stableText == "")
        #expect(transcript.volatileText == "I'll be ten")

        transcript.update(partial: "I'll be ten minutes late,")
        #expect(transcript.text == "I'll be ten minutes late,")
        #expect(transcript.stableText == "I'll be ten")
        #expect(transcript.volatileText == " minutes late,")

        // Punctuation is part of the word: "late," -> "late." is a change.
        transcript.update(partial: "I'll be ten minutes late. Start")
        #expect(transcript.stableText == "I'll be ten minutes")
        #expect(transcript.volatileText == " late. Start")
        #expect(transcript.stableRevisionCount == 0)
    }

    @Test("A later decode that rewrites stable words shrinks the stable part and is counted")
    func stableWordsCanChange() {
        var transcript = LiveTranscript()
        transcript.update(partial: "I'll be ten minutes")
        transcript.update(partial: "I'll be ten minutes late")
        #expect(transcript.stableText == "I'll be ten minutes")

        transcript.update(partial: "I'll be 10 minutes late, start")
        #expect(transcript.text == "I'll be 10 minutes late, start")
        #expect(transcript.stableText == "I'll be")
        #expect(transcript.volatileText == " 10 minutes late, start")
        #expect(transcript.stableRevisionCount == 1)

        // Growing again without touching stable words is not a revision.
        transcript.update(partial: "I'll be 10 minutes late, start the call")
        #expect(transcript.stableText == "I'll be 10 minutes late, start")
        #expect(transcript.stableRevisionCount == 1)
    }

    @Test("Once final, the overlay shows exactly the string that is pasted")
    func finalTextEqualsDisplayedText() throws {
        var transcript = LiveTranscript()
        transcript.update(partial: "J'aurai dix minutes")
        transcript.update(partial: "J'aurai dix minutes de retard")
        let pasted = "J'aurai 10 minutes de retard, commencez l'appel sans moi."
        transcript.finalize(pasted)

        let final = try #require(transcript.finalText)
        #expect(final == pasted)
        #expect(transcript.stableText + transcript.volatileText == pasted)
        #expect(transcript.volatileText.isEmpty)
        #expect(Array(final.unicodeScalars) == Array(pasted.unicodeScalars))

        // A late partial decode cannot change the final text.
        transcript.update(partial: "something else")
        #expect(transcript.finalText == pasted)
    }

    @Test("An empty final transcription leaves nothing to show")
    func emptyFinal() {
        var transcript = LiveTranscript()
        transcript.update(partial: "Hello")
        transcript.finalize("")
        #expect(transcript.isEmpty)
        #expect(transcript.finalText == "")
    }

    @Test("stableText + volatileText == text after every update", arguments: [1, 2, 3, 4, 5])
    func displayInvariant(seed: Int) {
        var rng = SplitMix64(seed: UInt64(seed))
        let vocabulary = ["le", "rapport,", "demain", "matin", "?", "café", "cafe\u{301}", "10h30.", "I'll", "",
                          "  ", "\n", "Ça"]
        var transcript = LiveTranscript()
        var words: [String] = []
        for _ in 0..<40 {
            // Mostly grow, sometimes rewrite a few earlier words, like successive decodes.
            if !words.isEmpty, Int.random(in: 0..<4, using: &rng) == 0 {
                let index = Int.random(in: 0..<words.count, using: &rng)
                words[index] = vocabulary.randomElement(using: &rng)!
            }
            words += (0..<Int.random(in: 0...3, using: &rng)).map { _ in vocabulary.randomElement(using: &rng)! }
            let partial = words.joined(separator: Bool.random(using: &rng) ? " " : "  ")
            transcript.update(partial: partial)
            #expect(transcript.text == partial)
            #expect(transcript.stableText + transcript.volatileText == transcript.text)
        }
        let final = words.joined(separator: " ")
        transcript.finalize(final)
        #expect(transcript.finalText == final)
        #expect(transcript.stableText + transcript.volatileText == final)
    }

    @Test("Words are separated by any whitespace; punctuation stays attached")
    func wordRanges() {
        let text = " Bonjour  Sarah,\nça va ?"
        let words = LiveTranscript.wordRanges(in: text).map { String(text[$0]) }
        #expect(words == ["Bonjour", "Sarah,", "ça", "va", "?"])
        #expect(LiveTranscript.wordRanges(in: "").isEmpty)
        #expect(LiveTranscript.wordRanges(in: "   ").isEmpty)
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

// MARK: - Schedule

@Suite("Live preview schedule")
struct LivePreviewScheduleTests {
    @Test("Decodes are spaced by max(minimum interval, factor × last decode duration)")
    func spacing() {
        let schedule = LivePreviewSchedule.default
        #expect(schedule.minimumAudio == 1.0)
        #expect(schedule.interval(afterDecodeLasting: 0.05) == 1.0)
        #expect(schedule.interval(afterDecodeLasting: 0.25) == 1.0)
        #expect(schedule.interval(afterDecodeLasting: 1.2) == 4.8)
        // Duty cycle (decode time / spacing) stays at or under 1 / factor.
        for duration in [0.01, 0.3, 2.0, 10.0] {
            #expect(duration / schedule.interval(afterDecodeLasting: duration) <= 0.25)
        }
    }
}

// MARK: - Session

/// Records what the session asks the decoder to do.
private actor DecodeProbe {
    private(set) var sampleCounts: [Int] = []
    private(set) var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var cancelled = 0

    func begin(_ count: Int) {
        sampleCounts.append(count)
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
    }

    func end(cancelled wasCancelled: Bool) {
        inFlight -= 1
        if wasCancelled { cancelled += 1 }
    }
}

private enum LiveTestError: Error { case boom }

@MainActor
private final class PendingFlag {
    var isPending = true
}

@MainActor
@Suite("Live transcription session")
struct LiveTranscriptionSessionTests {
    /// Fast schedule: 0.1 s of sound before the first decode, decodes at least 10 ms apart.
    private let schedule = LivePreviewSchedule(
        minimumAudio: 0.1, minimumInterval: 0.01, durationFactor: 4, soundThreshold: 0.01, pollInterval: 0.002)
    private let sound = [Float](repeating: 0.2, count: 800) // 50 ms
    private let silence = [Float](repeating: 0, count: 800)

    /// Poll until `condition` holds (records an issue after ~2 s).
    private func waitUntil(_ what: String, _ condition: () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Timed out waiting until \(what)")
    }

    /// A decoder that returns "w1 … wN" for N = number of 50 ms chunks heard, after `delay`.
    private func countingDecoder(_ probe: DecodeProbe, delay: Duration = .milliseconds(3)) -> Transcriber.PreviewDecoder {
        Transcriber.PreviewDecoder { samples in
            await probe.begin(samples.count)
            do {
                try await Task.sleep(for: delay)
            } catch {
                await probe.end(cancelled: true)
                throw error
            }
            await probe.end(cancelled: false)
            return (1...max(1, samples.count / 800)).map { "w\($0)" }.joined(separator: " ")
        }
    }

    @Test("Nothing is decoded before enough sound; leading silence does not count")
    func waitsForSound() async {
        let probe = DecodeProbe()
        let session = LiveTranscriptionSession(decoder: countingDecoder(probe), schedule: schedule)
        session.start()
        for _ in 0..<6 { session.sampleSink(silence) } // 0.3 s of silence
        session.sampleSink(sound)                       // 0.05 s of sound
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await probe.sampleCounts.isEmpty)

        session.sampleSink(sound)                       // 0.1 s of sound
        await waitUntil("a first decode") { await !probe.sampleCounts.isEmpty }
        // The decode covers all the audio, leading silence included.
        #expect(await probe.sampleCounts.first == 8 * 800)
        session.stop()
        await session.waitUntilStopped()
    }

    @Test("Each decode covers all the audio so far, one at a time, and updates the transcript")
    func decodesGrowingBuffer() async {
        let probe = DecodeProbe()
        let session = LiveTranscriptionSession(decoder: countingDecoder(probe), schedule: schedule)
        var updates: [String] = []
        session.onUpdate = { updates.append($0.text) }
        session.start()
        for _ in 0..<10 {
            session.sampleSink(sound)
            try? await Task.sleep(for: .milliseconds(15))
        }
        await waitUntil("a decode of all 10 chunks") { await probe.sampleCounts.last == 10 * 800 }
        await waitUntil("its update") { session.transcript.text.hasSuffix("w10") }
        session.stop()
        await session.waitUntilStopped()

        let counts = await probe.sampleCounts
        #expect(counts.count >= 2)
        #expect(counts == counts.sorted())
        #expect(await probe.maxInFlight == 1)
        #expect(updates.last == (1...10).map { "w\($0)" }.joined(separator: " "))
        #expect(session.transcript.stableText.hasPrefix("w1"))
    }

    @Test("Decodes are skipped while a final pass is pending, and resume after")
    func pausesForFinalPass() async {
        let probe = DecodeProbe()
        let session = LiveTranscriptionSession(decoder: countingDecoder(probe), schedule: schedule)
        let finalPass = PendingFlag()
        session.canDecode = { !finalPass.isPending }
        session.start()
        for _ in 0..<4 { session.sampleSink(sound) }
        try? await Task.sleep(for: .milliseconds(60))
        #expect(await probe.sampleCounts.isEmpty)

        finalPass.isPending = false
        await waitUntil("a decode") { await !probe.sampleCounts.isEmpty }
        session.stop()
        await session.waitUntilStopped()
    }

    @Test("Stopping abandons the decode in flight and ignores its result")
    func stopAbandonsDecode() async {
        let probe = DecodeProbe()
        let session = LiveTranscriptionSession(decoder: countingDecoder(probe, delay: .seconds(5)), schedule: schedule)
        var updates = 0
        session.onUpdate = { _ in updates += 1 }
        session.start()
        for _ in 0..<3 { session.sampleSink(sound) }
        await waitUntil("a decode in flight") { await probe.inFlight == 1 }

        session.stop()
        session.stop() // idempotent
        session.sampleSink(sound) // dropped
        await session.waitUntilStopped()

        #expect(await probe.cancelled == 1)
        #expect(await probe.inFlight == 0)
        #expect(updates == 0)
        #expect(session.transcript.isEmpty)
        #expect(session.failure == nil)
    }

    @Test("A failed decode stops the preview and clears its text; nothing else is decoded")
    func failureStopsPreview() async {
        let probe = DecodeProbe()
        var calls = 0
        let decoder = Transcriber.PreviewDecoder { samples in
            await probe.begin(samples.count)
            await probe.end(cancelled: false)
            if samples.count > 3 * 800 { throw LiveTestError.boom }
            return "Hello there"
        }
        let session = LiveTranscriptionSession(decoder: decoder, schedule: schedule)
        var failures = 0
        session.onFailure = { _ in failures += 1 }
        session.onUpdate = { _ in calls += 1 }
        session.start()
        for _ in 0..<3 { session.sampleSink(sound) }
        await waitUntil("text is shown") { !session.transcript.isEmpty }
        session.sampleSink(sound)
        await waitUntil("the failure") { failures == 1 }

        let decodes = await probe.sampleCounts.count
        try? await Task.sleep(for: .milliseconds(40))
        #expect(await probe.sampleCounts.count == decodes)
        #expect(session.transcript.isEmpty)
        #expect(session.isStopped)
        #expect(session.failure is LiveTestError)
        #expect(failures == 1)
        await session.waitUntilStopped()
    }

    @Test("Each recording starts from an empty transcript; a stopped one cannot leak into it")
    func noStaleTextBetweenRecordings() async {
        let firstProbe = DecodeProbe()
        let first = LiveTranscriptionSession(decoder: countingDecoder(firstProbe), schedule: schedule)
        first.start()
        for _ in 0..<3 { first.sampleSink(sound) }
        await waitUntil("the first session shows text") { !first.transcript.isEmpty }
        first.stop()

        let second = LiveTranscriptionSession(decoder: countingDecoder(DecodeProbe()), schedule: schedule)
        second.start()
        #expect(second.transcript.isEmpty)
        #expect(second.id != first.id)
        first.sampleSink(sound)
        await first.waitUntilStopped()
        #expect(second.transcript.isEmpty)
        second.stop()
        await second.waitUntilStopped()
    }
}

// MARK: - Transcriber and final passes

@MainActor
@Suite("Transcriber and live previews")
struct TranscriberPreviewTests {
    @Test("Final passes are counted while queued or running, so previews can pause for them")
    func countsPendingTranscriptions() async {
        let transcriber = Transcriber()
        let (started, startedContinuation) = AsyncStream<Void>.makeStream()
        let (release, releaseContinuation) = AsyncStream<Void>.makeStream()
        transcriber.transcriptionHandler = { _, _ in
            startedContinuation.yield()
            for await _ in release { break }
            return Transcriber.TranscriptionResult(text: "done", debugInfo: nil)
        }
        #expect(transcriber.pendingTranscriptions == 0)
        let first = Task { @MainActor in await transcriber.transcribe(audioURL: URL(fileURLWithPath: "/tmp/a.wav")) }
        for await _ in started { break }
        let second = Task { @MainActor in await transcriber.transcribe(audioURL: URL(fileURLWithPath: "/tmp/b.wav")) }
        while await transcriber.queuedTranscriptionCount < 1 { await Task.yield() }
        #expect(transcriber.pendingTranscriptions == 2)

        releaseContinuation.yield()
        _ = await first.value
        for await _ in started { break }
        releaseContinuation.yield()
        _ = await second.value
        #expect(transcriber.pendingTranscriptions == 0)
    }

    @Test("Without an installed engine there is no live preview")
    func noEngineNoPreview() {
        #expect(Transcriber().makePreviewDecoder() == nil)
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
