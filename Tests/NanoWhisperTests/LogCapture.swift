import Foundation
import OSLog
@testable import NanoWhisper

/// What this process logged, as stored in the unified log: private values read `<private>`.
enum LogCapture {
    /// The messages of `category` since `start`, once one contains `expected` (or what there is
    /// after a few seconds: entries reach the store a little late). Reading the store takes
    /// about a second, so it is done off the caller's actor.
    @concurrent
    static func messages(category: String, since start: Date, until expected: String) async throws -> [String] {
        var messages: [String] = []
        for _ in 0..<10 {
            messages = try read(category: category, since: start)
            if messages.contains(where: { $0.contains(expected) }) { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        return messages
    }

    private static func read(category: String, since start: Date) throws -> [String] {
        // Entry dates and `Date()` do not come from the same clock: some margin.
        let start = start.addingTimeInterval(-1)
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(
            format: "subsystem == %@ AND category == %@", BuildFlavor.current.logSubsystem, category
        )
        return try store.getEntries(at: store.position(date: start), matching: predicate)
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.date >= start }
            .map(\.composedMessage)
    }
}
