import Combine
import Foundation
import Testing
@testable import NanoWhisper

@Suite("Overlay waveform")
struct OverlayWaveformTests {

    // MARK: - Ring buffer

    @Test("Starts with 26 slots of silence: the waveform appears at its final width")
    func startsFull() {
        let history = LevelHistory()
        #expect(history.values.count == 26)
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
        #expect(history.values.count == 26)
    }

    @Test("The oldest value drops out after 26 slots")
    func ringBuffer() {
        var history = LevelHistory()
        for index in 0..<30 {
            history.record(Float(index) / 100)
            history.advance()
        }
        #expect(history.values.count == 26)
        #expect(history.values.first == 0.04)
        #expect(history.values.last == 0.29)
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

    @Test("A fixed history keeps its last 26 values, padded with silence on the left")
    func fixedHistory() {
        #expect(LevelHistory(values: [0.5]).values == Array(repeating: 0, count: 25) + [0.5])
        let long = (0..<40).map { Float($0) / 40 }
        #expect(LevelHistory(values: long).values == Array(long.suffix(26)))
    }

    // MARK: - Level to bar

    @Test("Bar height: a 2 pt dot below 0.06, else 3 + 17 × level^0.85, at most 20 pt")
    func barHeights() {
        #expect(WaveformMetrics.barHeight(for: 0) == 2)
        #expect(WaveformMetrics.barHeight(for: 0.059) == 2)
        #expect(abs(WaveformMetrics.barHeight(for: 0.06) - (3 + 17 * pow(0.06, 0.85))) < 1e-6)
        #expect(abs(WaveformMetrics.barHeight(for: 0.5) - (3 + 17 * pow(0.5, 0.85))) < 1e-6)
        #expect(WaveformMetrics.barHeight(for: 1) == 20)
        // Monotonic over speech levels.
        let heights = stride(from: Float(0.06), through: 1, by: 0.01).map(WaveformMetrics.barHeight(for:))
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 <= $1 })
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
        #expect(bars.first?.height == 2)
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
        #expect(mid.filter { !$0.isLit }.allSatisfy { $0.height == 2 && $0.opacity == 0.32 })
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
            #expect(bars.allSatisfy { $0.height == 2 && !$0.isLit })
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
        #expect(waveform.history.values.contains(0.9))
        #expect(waveform.barsAtStop.count == 26)
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
