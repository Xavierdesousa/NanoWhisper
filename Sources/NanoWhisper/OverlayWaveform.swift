import Combine
import SwiftUI

// MARK: - Level history (pure)

/// The overlay's waveform data: the peak audio level of each 50 ms slot, for the last
/// `capacity` slots (4 s), oldest first. The capsule shows the last 26 (1.3 s); the card with
/// live text shows as many as fit its width.
///
/// `AudioRecorder` publishes one level per tap buffer (4096 frames, about 85–93 ms), so some
/// 50 ms slots receive nothing. Such a slot repeats the previous value (up to
/// `maxHeldSlots` in a row) instead of reading as silence, which would turn steady speech
/// into a dotted line.
struct LevelHistory: Equatable, Sendable {
    /// Bars of the compact capsule.
    static let barCount = 26
    /// Slots kept: enough for the widest waveform (the card's, 75 bars).
    static let capacity = 80
    static let slotDuration: TimeInterval = 0.05
    /// Empty slots in a row that repeat the previous value before the bars fall to silence.
    static let maxHeldSlots = 2

    /// Oldest first; starts full of silence, so the waveform appears at its final width.
    private(set) var values: [Float] = Array(repeating: 0, count: capacity)
    /// Peak of the levels received in the current slot, `nil` while none was received.
    private var slotPeak: Float?
    private var heldSlots = 0

    init() {}

    /// A fixed history (previews and tests): the last `capacity` values, oldest first.
    init(values: [Float]) {
        let tail = Array(values.suffix(Self.capacity))
        self.values = Array(repeating: 0, count: Self.capacity - tail.count) + tail.map(Self.clamp)
    }

    /// A level received during the current slot.
    mutating func record(_ level: Float) {
        slotPeak = max(slotPeak ?? 0, Self.clamp(level))
    }

    /// End the current slot: append its peak and drop the oldest value.
    mutating func advance() {
        let value: Float
        if let slotPeak {
            value = slotPeak
            heldSlots = 0
        } else if heldSlots < Self.maxHeldSlots {
            value = values.last ?? 0
            heldSlots += 1
        } else {
            value = 0
        }
        values.removeFirst()
        values.append(value)
        slotPeak = nil
    }

    private static func clamp(_ level: Float) -> Float {
        level.isFinite ? min(max(level, 0), 1) : 0
    }
}

// MARK: - Bar mapping (pure)

/// One bar of the waveform, as drawn.
struct WaveformBar: Equatable, Sendable {
    var height: CGFloat
    var opacity: Double
    /// Lit by the transcribing sweep (drawn in the sweep color).
    var isLit = false
}

/// How levels become bars, and the transcribing animation. Numbers from the design's
/// developer notes ("Voice note"), except silence (2026-11-20 feedback, below).
enum WaveformMetrics {
    static let barWidth: CGFloat = 2
    static let barSpacing: CGFloat = 2
    /// Distance from one bar to the next.
    static let pitch: CGFloat = barWidth + barSpacing
    static let rowHeight: CGFloat = 22
    static let maxBarHeight: CGFloat = 20
    /// Silence: a low, dim mark (2 × 1.5 pt), so the row still shows it is listening while
    /// speech, never lower than `minSpeechHeight`, stands out clearly.
    static let dotHeight: CGFloat = 1.5
    static let silenceOpacity = 0.45
    static let minSpeechHeight: CGFloat = 4
    /// Below this level a bar is silence. `AudioRecorder` sends `sqrt(min(25 × RMS, 1))`, so
    /// a quiet room (RMS 0.001–0.003, −60 to −50 dBFS) reads 0.16–0.28: 0.06 (the design's
    /// guess) drew room noise as 7 pt bars. 0.35 is RMS ≈ 0.005 (−46 dBFS); soft speech at
    /// −40 dBFS reads 0.5. Estimated from typical levels, not measured on a microphone.
    static let silenceFloor: Float = 0.35
    /// The oldest `fadeCount` bars fade in from `oldestOpacity`.
    static let fadeCount = 7
    static let oldestOpacity = 0.22
    static let fadeEndOpacity = 0.9
    static let barOpacity = 0.92

    /// Width of the capsule's waveform row (26 bars: 102 pt).
    static var rowWidth: CGFloat {
        CGFloat(LevelHistory.barCount) * pitch - barSpacing
    }

    /// Bars that fit `width`, at most the history's capacity.
    static func barCount(fitting width: CGFloat) -> Int {
        min(LevelHistory.capacity, max(1, Int((width + barSpacing) / pitch)))
    }

    static func isSilence(_ level: Float) -> Bool { level < silenceFloor }

    /// Bar height for a level: silence below the floor, else from `minSpeechHeight` to
    /// `maxBarHeight` over the levels above the floor (exponent 0.85 lifts quiet speech).
    static func barHeight(for level: Float) -> CGFloat {
        guard !isSilence(level) else { return dotHeight }
        let span = Double((level - silenceFloor) / (1 - silenceFloor))
        return min(maxBarHeight, minSpeechHeight + (maxBarHeight - minSpeechHeight) * CGFloat(pow(span, 0.85)))
    }

    /// Opacity of bar `index` (0 = oldest shown): the history fades out on the left.
    static func opacity(at index: Int) -> Double {
        guard index < fadeCount else { return barOpacity }
        return oldestOpacity + (fadeEndOpacity - oldestOpacity) * Double(index) / Double(fadeCount)
    }

    /// The last `count` slots as bars, oldest first.
    static func bars(for history: LevelHistory, count: Int = LevelHistory.barCount) -> [WaveformBar] {
        history.values.suffix(count).enumerated().map { index, level in
            let fade = opacity(at: index)
            return isSilence(level)
                ? WaveformBar(height: dotHeight, opacity: fade * silenceOpacity / barOpacity)
                : WaveformBar(height: barHeight(for: level), opacity: fade)
        }
    }

    // MARK: Transcribing

    /// Bars sink to dots over this time when the recording stops.
    static let sinkDuration: TimeInterval = 0.25
    /// A highlight sweeps across the dots once per period while transcribing.
    static let sweepPeriod: TimeInterval = 1.2
    static let dimDotOpacity = 0.32
    private static let litHeights: [CGFloat] = [6, 5, 4, 3]

    /// Bars `elapsed` seconds after the recording stopped: the last recorded bars sink to
    /// dots, then the sweep runs (none with Reduce Motion). As many bars as `last`.
    static func transcribingBars(from last: [WaveformBar], elapsed: TimeInterval, reduceMotion: Bool) -> [WaveformBar] {
        let count = max(1, last.count)
        if reduceMotion || elapsed >= sinkDuration {
            let sweep = reduceMotion ? nil : sweepPosition(at: elapsed - sinkDuration, count: count)
            return (0..<count).map { index in sweepBar(index: index, sweep: sweep) }
        }
        // Ease-out from the recorded bars to dim dots.
        let t = max(0, elapsed) / sinkDuration
        let eased = 1 - (1 - t) * (1 - t)
        return (0..<count).map { index in
            let from = index < last.count ? last[index] : WaveformBar(height: dotHeight, opacity: dimDotOpacity)
            return WaveformBar(
                height: from.height + (dotHeight - from.height) * eased,
                opacity: from.opacity + (dimDotOpacity - from.opacity) * eased
            )
        }
    }

    /// Center of the sweep, in bar indices: from 4 bars left of a row of `count` bars to 4
    /// bars past it.
    static func sweepPosition(at time: TimeInterval, count: Int = LevelHistory.barCount) -> Double {
        let phase = time.truncatingRemainder(dividingBy: sweepPeriod) / sweepPeriod
        return max(0, phase) * Double(count + 8) - 4
    }

    static func sweepBar(index: Int, sweep: Double?) -> WaveformBar {
        if let sweep {
            let distance = abs(Double(index) - sweep)
            if distance < 4 {
                return WaveformBar(height: litHeights[Int(distance)], opacity: 1, isLit: true)
            }
        }
        return WaveformBar(height: dotHeight, opacity: dimDotOpacity)
    }
}

// MARK: - Live meter

/// Feeds the waveform while recording: collects the levels, closes a slot every 50 ms, and
/// remembers when, so the row can glide between slots. Not observable on purpose: the
/// waveform redraws from a `TimelineView`, and the rest of the overlay does not re-render
/// 20 times a second.
@MainActor
final class OverlayWaveform {
    private(set) var history = LevelHistory()
    /// When the last slot closed (the glide's origin).
    private(set) var lastAdvance = Date()
    /// When the recording stopped, and the history at that moment (the sink's origin).
    private(set) var stoppedAt: Date?
    private(set) var historyAtStop = LevelHistory()
    /// A frozen history (Settings preview): no timer, no glide.
    let isStatic: Bool

    private var timer: Timer?
    private var levelCancellable: AnyCancellable?

    init() { isStatic = false }

    init(staticHistory: LevelHistory) {
        history = staticHistory
        isStatic = true
    }

    /// The bars shown at stop, for a row of `count` bars.
    func barsAtStop(count: Int = LevelHistory.barCount) -> [WaveformBar] {
        WaveformMetrics.bars(for: historyAtStop, count: count)
    }

    /// Start a recording: empty history, a slot every 50 ms, levels from `publisher`.
    func start(levels publisher: some Publisher<Float, Never>) {
        guard !isStatic else { return }
        stop()
        history = LevelHistory()
        stoppedAt = nil
        historyAtStop = LevelHistory()
        lastAdvance = Date()
        levelCancellable = publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                MainActor.assumeIsolated { self?.history.record(level) }
            }
        let timer = Timer(timeInterval: LevelHistory.slotDuration, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.history.advance()
                self.lastAdvance = Date()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// The recording stopped: freeze the bars as they are, for the sink to dots.
    func markStopped(at date: Date = Date()) {
        guard !isStatic else { return }
        historyAtStop = history
        stop()
        stoppedAt = date
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        levelCancellable?.cancel()
        levelCancellable = nil
    }

    /// Fraction of the current slot elapsed at `date`, 0…1: how far the row has glided.
    func glideProgress(at date: Date) -> CGFloat {
        guard !isStatic, timer != nil else { return 0 }
        return CGFloat(min(1, max(0, date.timeIntervalSince(lastAdvance) / LevelHistory.slotDuration)))
    }
}

// MARK: - View

/// The waveform: one `Canvas` in a `TimelineView`. While recording, a new bar enters on the
/// right every 50 ms and the row glides left between slots; with Reduce Motion it updates in
/// place at 10 Hz. While transcribing, the bars sink to dots and a highlight sweeps across
/// them (dots only with Reduce Motion). 26 bars in the capsule; with `fillsWidth`, as many as
/// fit the width it is given, right-aligned.
struct OverlayWaveformView: View {
    let waveform: OverlayWaveform
    let isTranscribing: Bool
    var fillsWidth = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if waveform.isStatic {
                canvas(at: Date())
            } else {
                TimelineView(.animation(minimumInterval: reduceMotion ? 0.1 : nil)) { context in
                    canvas(at: context.date)
                }
            }
        }
        .frame(width: fillsWidth ? nil : WaveformMetrics.rowWidth, height: WaveformMetrics.rowHeight)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .clipped()
        .accessibilityHidden(true)
    }

    private func canvas(at date: Date) -> some View {
        Canvas { graphics, size in
            let count = fillsWidth ? WaveformMetrics.barCount(fitting: size.width) : LevelHistory.barCount
            let frame = Self.frame(waveform: waveform, isTranscribing: isTranscribing, count: count,
                                   date: date, reduceMotion: reduceMotion)
            Self.draw(frame.bars, offset: frame.offset, in: &graphics, size: size)
        }
    }

    private static func frame(
        waveform: OverlayWaveform, isTranscribing: Bool, count: Int, date: Date, reduceMotion: Bool
    ) -> (bars: [WaveformBar], offset: CGFloat) {
        if isTranscribing {
            let elapsed = waveform.stoppedAt.map { date.timeIntervalSince($0) } ?? WaveformMetrics.sinkDuration
            let bars = WaveformMetrics.transcribingBars(
                from: waveform.barsAtStop(count: count), elapsed: elapsed, reduceMotion: reduceMotion)
            return (bars, 0)
        }
        let progress = reduceMotion ? 0 : waveform.glideProgress(at: date)
        return (WaveformMetrics.bars(for: waveform.history, count: count), -WaveformMetrics.pitch * progress)
    }

    private static let litColor = Color(red: 0xE9 / 255, green: 0xC4 / 255, blue: 0xFE / 255)

    private static func draw(_ bars: [WaveformBar], offset: CGFloat, in graphics: inout GraphicsContext, size: CGSize) {
        let width = WaveformMetrics.barWidth
        // Right-aligned: the newest bar ends at the trailing edge.
        let rowWidth = CGFloat(bars.count) * WaveformMetrics.pitch - WaveformMetrics.barSpacing
        let origin = size.width - rowWidth
        for (index, bar) in bars.enumerated() {
            let x = origin + CGFloat(index) * WaveformMetrics.pitch + offset
            let rect = CGRect(x: x, y: (size.height - bar.height) / 2, width: width, height: bar.height)
            let path = Path(roundedRect: rect, cornerRadius: min(width, bar.height) / 2)
            graphics.fill(path, with: .color((bar.isLit ? litColor : .white).opacity(bar.opacity)))
        }
    }
}
