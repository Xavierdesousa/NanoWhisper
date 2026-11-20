import Combine
import Foundation
import Testing
@testable import NanoWhisper

@Suite("Overlay waveform")
struct OverlayWaveformTests {

    // MARK: - Ring buffer

    @Test("Starts full of silence (80 slots, 4 s): the waveform appears at its final width")
    func startsFull() {
        let history = LevelHistory()
        #expect(history.values.count == LevelHistory.capacity)
        #expect(LevelHistory.capacity == 80)
        #expect(history.values.allSatisfy { $0 == 0 })
        #expect(LevelHistory.slotDuration == 0.05)
        #expect(Double(LevelHistory.barCount) * LevelHistory.slotDuration == 1.3)
    }

    @Test("Each slot keeps the peak of its levels; the newest is last")
    func peakPerSlot() {
        var history = LevelHistory()
        history.record(0.2)
        history.record(0.7)
        history.record(0.4)
        history.advance()
        #expect(history.values.last == 0.7)
        history.record(0.1)
        history.advance()
        #expect(Array(history.values.suffix(2)) == [0.7, 0.1])
        #expect(history.values.count == LevelHistory.capacity)
    }

    @Test("The oldest value drops out after 80 slots")
    func ringBuffer() {
        var history = LevelHistory()
        for index in 0..<84 {
            history.record(Float(index) / 100)
            history.advance()
        }
        #expect(history.values.count == 80)
        #expect(history.values.first == 0.04)
        #expect(history.values.last == 0.83)
    }

    @Test("A slot without a level repeats the previous one, at most twice, then silence")
    func emptySlotsHold() {
        var history = LevelHistory()
        history.record(0.8)
        history.advance()
        history.advance()
        history.advance()
        history.advance()
        #expect(Array(history.values.suffix(4)) == [0.8, 0.8, 0.8, 0])
        // A real level resets the hold.
        history.record(0.5)
        history.advance()
        history.advance()
        #expect(Array(history.values.suffix(2)) == [0.5, 0.5])
    }

    @Test("Levels are clamped to 0…1")
    func clamping() {
        var history = LevelHistory()
        history.record(3)
        history.advance()
        #expect(history.values.last == 1)
        history.record(-1)
        history.advance()
        #expect(history.values.last == 0)
        history.record(.nan)
        history.advance()
        #expect(history.values.last == 0)
        #expect(LevelHistory(values: [2, -1]).values.suffix(2) == [1, 0])
    }

    @Test("A fixed history keeps its last 80 values, padded with silence on the left")
    func fixedHistory() {
        #expect(LevelHistory(values: [0.5]).values == Array(repeating: 0, count: 79) + [0.5])
        let long = (0..<100).map { Float($0) / 100 }
        #expect(LevelHistory(values: long).values == Array(long.suffix(80)))
    }

    // MARK: - Level to bar

    @Test("Bar height: a 1.5 pt mark below 0.15 (−49 dBFS), else 4 to 20 pt, linear above it")
    func barHeights() {
        #expect(WaveformMetrics.barHeight(for: 0) == 1.5)
        // A quiet room (−52 dBFS reads 0.075) is silence, not a bar.
        #expect(WaveformMetrics.barHeight(for: 0.075) == 1.5)
        #expect(WaveformMetrics.barHeight(for: 0.149) == 1.5)
        #expect(WaveformMetrics.barHeight(for: 0.15) == 4)
        #expect(abs(WaveformMetrics.barHeight(for: 0.575) - 12) < 1e-4)
        #expect(WaveformMetrics.barHeight(for: 1) == 20)
        let heights = stride(from: Float(0.15), through: 1, by: 0.01).map(WaveformMetrics.barHeight(for:))
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test("Normalizer: the loudest recent speech reaches the top, softer speech is clearly lower")
    func normalizer() {
        var normalizer = LevelNormalizer()
        // Loud speech at −20 dBFS (0.875) sets the reference and reaches the top.
        #expect(abs(normalizer.normalize(0.875) - 1) < 1e-5)
        // Soft speech right after (−40 dBFS, 0.375) is well under half the height.
        let soft = normalizer.normalize(0.375)
        #expect(soft > WaveformMetrics.silenceFloor && soft < 0.35)
        // Silence passes through unchanged.
        #expect(normalizer.normalize(0.05) == 0.05)
        // A quiet room alone is not amplified: the reference never drops below the minimum.
        var quiet = LevelNormalizer()
        for _ in 0..<2000 { _ = quiet.normalize(0.2) }
        #expect(quiet.peak == LevelNormalizer.minimumPeak)
        #expect(quiet.normalize(0.2) < 0.2)
    }

    @Test("Envelope: rises over a few levels instead of jumping, falls more slowly")
    func envelope() {
        var envelope = LevelEnvelope()
        let rise = (0..<4).map { _ in envelope.follow(1) }
        #expect(rise[0] < 0.6)                     // no jump to the top on the first 20 ms
        #expect(rise[3] > 0.9)                     // there after ~80 ms
        let fall = (0..<4).map { _ in envelope.follow(0) }
        #expect(fall[0] > 0.8)                     // a 20 ms gap barely dips
        #expect(fall[3] > 0.5)                     // still speech after 80 ms of silence
        #expect(envelope.follow(.nan) < fall[3])   // invalid levels count as silence
    }

    @Test("Silence and speech are clearly different: the quietest speech bar is over 2.5 times a silence mark, which is dimmer")
    func silenceVersusSpeech() {
        let bars = WaveformMetrics.bars(for: LevelHistory(values: Array(repeating: 0.1, count: 13) + Array(repeating: 0.36, count: 13)))
        let silence = bars[10], speech = bars[20]
        #expect(speech.height / silence.height > 2.5)
        #expect(silence.opacity < 0.5 && speech.opacity > 0.9)
    }

    @Test("Opacity: the oldest 7 bars ramp from 0.22, the rest are 0.92")
    func opacities() {
        #expect(WaveformMetrics.opacity(at: 0) == 0.22)
        #expect(abs(WaveformMetrics.opacity(at: 6) - (0.22 + 0.68 * 6 / 7)) < 1e-9)
        #expect(WaveformMetrics.opacity(at: 7) == 0.92)
        #expect(WaveformMetrics.opacity(at: 25) == 0.92)
        let ramp = (0..<7).map(WaveformMetrics.opacity(at:))
        #expect(zip(ramp, ramp.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("Row: 26 bars of 2 pt, 2 pt apart, 102 pt wide")
    func rowGeometry() {
        #expect(WaveformMetrics.rowWidth == 102)
        let bars = WaveformMetrics.bars(for: LevelHistory(values: [1]))
        #expect(bars.count == 26)
        #expect(bars.last?.height == 20)
        #expect(bars.first?.height == 1.5)
    }

    @Test("The card's waveform: as many bars as fit its width, from the same history")
    func cardRow() {
        #expect(WaveformMetrics.barCount(fitting: 102) == 26)
        #expect(WaveformMetrics.barCount(fitting: 298) == 75)
        #expect(WaveformMetrics.barCount(fitting: 10_000) == LevelHistory.capacity)
        let history = LevelHistory(values: (0..<80).map { Float($0) / 80 })
        let wide = WaveformMetrics.bars(for: history, count: 75)
        #expect(wide.count == 75)
        // The newest bars are the same in both rows; only the fade moves with the left edge.
        #expect(wide.suffix(10).map(\.height) == WaveformMetrics.bars(for: history).suffix(10).map(\.height))
        #expect(wide.first?.opacity ?? 1 < 0.25)
    }

    // MARK: - Transcribing

    @Test("At stop the bars sink to dim dots in 0.25 s, then the sweep runs")
    func sinkThenSweep() {
        let last = WaveformMetrics.bars(for: LevelHistory(values: Array(repeating: 1, count: 26)))
        let start = WaveformMetrics.transcribingBars(from: last, elapsed: 0, reduceMotion: false)
        #expect(start.map(\.height) == last.map(\.height))
        let half = WaveformMetrics.transcribingBars(from: last, elapsed: 0.125, reduceMotion: false)
        #expect(half.allSatisfy { $0.height < 20 && $0.height > 2 })
        let sunk = WaveformMetrics.transcribingBars(from: last, elapsed: 0.25, reduceMotion: false)
        #expect(sunk.allSatisfy { $0.height <= 6 })
        // Mid-period the sweep lights 7 bars around its center, highest in the middle.
        let mid = WaveformMetrics.transcribingBars(from: last, elapsed: 0.25 + 0.6, reduceMotion: false)
        let lit = mid.enumerated().filter { $0.element.isLit }
        #expect(lit.count == 7)
        #expect(lit.map(\.element.height).max() == 6)
        #expect(mid.filter { !$0.isLit }.allSatisfy { $0.height == 1.5 && $0.opacity == 0.32 })
        // A wider row keeps its bar count.
        let wide = WaveformMetrics.bars(for: LevelHistory(values: Array(repeating: 1, count: 80)), count: 75)
        #expect(WaveformMetrics.transcribingBars(from: wide, elapsed: 0.9, reduceMotion: false).count == 75)
    }

    @Test("The sweep crosses the row once every 1.2 s")
    func sweepPeriod() {
        #expect(WaveformMetrics.sweepPosition(at: 0) == -4)
        #expect(abs(WaveformMetrics.sweepPosition(at: 0.6) - 13) < 1e-9)
        #expect(abs(WaveformMetrics.sweepPosition(at: 1.2) - WaveformMetrics.sweepPosition(at: 0)) < 1e-9)
    }

    @Test("Reduce Motion: dots at once, no sweep")
    func reduceMotion() {
        let last = WaveformMetrics.bars(for: LevelHistory(values: Array(repeating: 1, count: 26)))
        for elapsed in [0, 0.1, 0.9, 5] as [TimeInterval] {
            let bars = WaveformMetrics.transcribingBars(from: last, elapsed: elapsed, reduceMotion: true)
            #expect(bars.allSatisfy { $0.height == 1.5 && !$0.isLit })
        }
    }

    // MARK: - Meter

    @Test("The meter samples the published levels into 50 ms slots")
    @MainActor func meterSamples() async throws {
        let waveform = OverlayWaveform()
        let levels = PassthroughSubject<Float, Never>()
        waveform.start(levels: levels)
        for _ in 0..<6 {
            levels.send(0.9)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        waveform.markStopped()
        // Through the envelope and the normalizer: steady loud speech reaches the top.
        #expect(waveform.history.values.contains { $0 > 0.8 })
        #expect(waveform.barsAtStop().count == 26)
        #expect(waveform.barsAtStop(count: 75).count == 75)
        #expect(waveform.stoppedAt != nil)
        #expect(waveform.glideProgress(at: Date()) == 0, "no glide once stopped")
    }

    @Test("A static waveform never changes")
    @MainActor func staticWaveform() {
        let history = LevelHistory(values: [0.5, 0.7])
        let waveform = OverlayWaveform(staticHistory: history)
        waveform.start(levels: PassthroughSubject<Float, Never>())
        waveform.markStopped()
        #expect(waveform.history == history)
        #expect(waveform.stoppedAt == nil)
    }
}

@Suite("Overlay result")
struct OverlayResultTests {
    @Test("Each dictation outcome maps to what the overlay shows")
    func mapping() {
        #expect(OverlayResult(.deliver("Hello")) == .pasted)
        #expect(OverlayResult(.showTestResult("Hello")) == .done)
        #expect(OverlayResult(.showTestResult("")) == .noSpeech)
        #expect(OverlayResult(.discard) == .done)
        #expect(OverlayResult(.noResult) == .noSpeech)
        #expect(OverlayResult(.failed(.engineError)) == .failed)
        #expect(OverlayResult(.failed(.noEngine)) == .failed)
    }

    @Test("Titles and kinds")
    func titles() {
        #expect(OverlayResult.pasted.title == "Pasted")
        #expect(OverlayResult.noSpeech.title == "No speech detected")
        #expect(OverlayResult.pasted.isSuccess && OverlayResult.done.isSuccess)
        #expect(!OverlayResult.noSpeech.isSuccess && !OverlayResult.noAudio.isSuccess && !OverlayResult.failed.isSuccess)
    }
}
