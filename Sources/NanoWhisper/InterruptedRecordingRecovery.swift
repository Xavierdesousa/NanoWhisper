import Foundation

/// Transcribes the recordings found by `InterruptedRecordings.collect`, one at a time, silently,
/// and only while the app is idle (engine ready, no recording, no transcription queued), so a
/// dictation the user starts always goes first. A recovery already running when the user
/// stops a dictation finishes first (the transcriber's queue is FIFO and a transcription cannot
/// be interrupted); it is one recording, typically well under a second with Parakeet.
@MainActor
final class InterruptedRecordingRecovery {
    struct Dependencies {
        /// Engine ready, nothing recording, nothing being transcribed.
        var isIdle: () -> Bool
        /// History is on and readable (checked again before each recording).
        var historyAvailable: () -> Bool
        var transcribe: (URL) async -> Transcriber.TranscriptionResult
        /// Inserts an entry in History at its date.
        var addToHistory: (HistoryEntry) -> Void
        /// How often idleness is checked while waiting.
        var pollInterval: Duration = .seconds(1)
    }

    struct Summary: Equatable {
        var recovered = 0
        var empty = 0
        var failed = 0
        var skipped = 0
    }

    private let dependencies: Dependencies
    private(set) var isRunning = false

    init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    /// Process `candidates` (oldest first). Each file is deleted (zeroed first) whatever the
    /// outcome; it is renamed `….attempted.wav` before its transcription starts.
    @discardableResult
    func run(_ candidates: [InterruptedRecordings.Candidate]) async -> Summary {
        var summary = Summary()
        guard !candidates.isEmpty, !isRunning else { return summary }
        isRunning = true
        defer { isRunning = false }
        for candidate in candidates {
            while !dependencies.isIdle() {
                do {
                    try await Task.sleep(for: dependencies.pollInterval)
                } catch {
                    // Cancelled (quit): leave the remaining files for the next launch.
                    return summary
                }
            }
            guard dependencies.historyAvailable() else {
                TemporaryRecordings.securelyDelete(at: candidate.url)
                summary.skipped += 1
                continue
            }
            let attempted: URL
            do {
                attempted = try InterruptedRecordings.markAttempted(candidate.url)
            } catch {
                TemporaryRecordings.securelyDelete(at: candidate.url)
                summary.skipped += 1
                continue
            }
            let result = await dependencies.transcribe(attempted)
            TemporaryRecordings.securelyDelete(at: attempted)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.failure != nil {
                summary.failed += 1
            } else if text.isEmpty {
                summary.empty += 1
            } else if dependencies.historyAvailable() {
                dependencies.addToHistory(HistoryEntry(text: result.text, date: candidate.recordedAt, debugInfo: result.debugInfo))
                summary.recovered += 1
            } else {
                summary.skipped += 1
            }
        }
        InterruptedRecordings.logger.notice(
            "Interrupted recordings: \(summary.recovered, privacy: .public) recovered to History, \(summary.empty, privacy: .public) empty, \(summary.failed, privacy: .public) failed, \(summary.skipped, privacy: .public) skipped"
        )
        return summary
    }
}
