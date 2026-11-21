import AppKit
import CryptoKit
import os

/// Debug builds only: `--history-sample` opens the History window alone, with invented
/// dictations, to try it (or show it) without the real history. Nothing else starts: no menu
/// bar item, no shortcut, no model, no `AppState`, so the real history file is never read.
/// The invented entries live in a temporary folder under a random key; Copy goes to a private
/// pasteboard (`pasteboardName`), never the clipboard. The app quits when the window closes.
@MainActor
enum HistorySample {
    static let launchArgument = "--history-sample"
    static let pasteboardName = NSPasteboard.Name("com.moonji.nanowhisper.debug.history-sample")
    static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "HistorySample")

    static func isRequestedAtLaunch(arguments: [String], flavor: BuildFlavor) -> Bool {
        flavor.isDebug && arguments.dropFirst().contains(launchArgument)
    }

    /// What the window keeps alive.
    final class Session: NSObject, NSWindowDelegate {
        let window: HistoryWindow
        let directory: URL

        init(window: HistoryWindow, directory: URL) {
            self.window = window
            self.directory = directory
            super.init()
        }

        func windowWillClose(_ notification: Notification) {
            try? FileManager.default.removeItem(at: directory)
            NSApp.terminate(nil)
        }
    }

    static func show() -> Session {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoWhisperHistorySample-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = SymmetricKey(size: .bits256)
        let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), key: { key })
        store.replaceEntries(entries(now: Date()))
        let model = HistoryWindowModel(
            store: store,
            settings: HistorySettingsSnapshot(isEnabled: true, keptCount: HistorySettings.defaultMaxCount,
                                              showsDebugInfo: true, shortcut: .default),
            pasteboard: NSPasteboard(name: pasteboardName)
        )
        let window = HistoryWindow(model: model)
        let session = Session(window: window, directory: directory)
        window.delegate = session
        window.onRefresh = { window in
            // Invented content only: safe to log, for checks from outside the app.
            logger.notice("refresh: \(window.subtitle, privacy: .public); focus \(String(describing: window.keyFocus), privacy: .public); key \(window.isKeyWindow, privacy: .public)")
        }
        centerOnCurrentScreen(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return session
    }

    private static func entries(now: Date) -> [HistoryEntry] {
        let texts = [
            "Okay, before you touch any code, walk me through how the transcription queue handles two recordings in flight.",
            "Let’s brainstorm the architecture for the sync service. Offline first; the server owns billing only.",
            "Peux-tu reprendre le plan de migration de la base ? En deux étapes, sans rien casser.",
            "Good morning. Today we finish the menu bar handoff, one commit at a time.",
        ]
        return texts.enumerated().map { index, text in
            HistoryEntry(
                text: text, date: now.addingTimeInterval(TimeInterval(-index * 3_600)),
                debugInfo: TranscriptionDebugInfo(audioDuration: 12, transcribeDuration: 0.2, rtf: 0.2 / 12, model: "Parakeet Ultra")
            )
        }
    }
}
