import AppKit
import CryptoKit
import Foundation
@testable import NanoWhisper

/// Invented History entries and models for tests and renders. Never the real history: each
/// store is a temporary file sealed with a test key, and copies go to a private pasteboard.
@MainActor
enum HistoryFixtures {
    static let key = HistoryCrypto.key(fromHardwareUUID: "00000000-TEST-0000-0000-00000000H157")

    /// Saturday 21 November 2026, 11:00 in the test calendar.
    static let now: Date = {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 11, minute: 0))!
    }()

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }()

    private static func date(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private static func parakeet(_ audio: Double, _ time: Double) -> TranscriptionDebugInfo {
        TranscriptionDebugInfo(audioDuration: audio, transcribeDuration: time, rtf: time / audio, model: "Parakeet Ultra")
    }

    /// Ten invented dictations over five days, newest first (the design boards' samples).
    static let entries: [HistoryEntry] = [
        HistoryEntry(text: "Okay, before you touch any code, walk me through how the transcription queue handles two recordings in flight. I think there is a race when the second one finishes first and the paste lands in the wrong app. Read Transcriber and AppState, explain the order of events step by step, then propose the smallest fix and one test that would have caught it.",
                     date: date(daysAgo: 0, 10, 42), debugInfo: parakeet(41.6, 0.58)),
        HistoryEntry(text: "Let’s brainstorm the architecture for the sync service. Constraints: offline first, the server is the source of truth for billing only, everything else merges on the client. Give me three options with their failure modes, especially what happens when two devices edit the same note while offline.",
                     date: date(daysAgo: 0, 10, 15), debugInfo: parakeet(58.3, 0.96)),
        HistoryEntry(text: "Peux-tu reprendre le plan de migration de la base ? Je préfère qu’on le fasse en deux étapes : d’abord on ajoute les nouvelles colonnes sans rien casser et on déploie, ensuite seulement on bascule la lecture. Écris les deux migrations et la liste des vérifications à faire entre les deux.",
                     date: date(daysAgo: 0, 9, 58),
                     debugInfo: TranscriptionDebugInfo(audioDuration: 34.2, transcribeDuration: 2.91, rtf: 2.91 / 34.2,
                                                       model: "Whisper Large v3 Turbo", language: "fr", languageDetected: true)),
        HistoryEntry(text: longText, date: date(daysAgo: 1, 19, 12), debugInfo: parakeet(112.4, 1.41)),
        HistoryEntry(text: "Review this pull request like a senior engineer who will maintain it for five years. Focus on error handling and naming, skip formatting. When something is unclear, write the question you would ask the author instead of guessing.",
                     date: date(daysAgo: 1, 18, 31), debugInfo: parakeet(22.9, 0.38)),
        HistoryEntry(text: "Rename the setting to Keep the last, and disable the picker when history is off.",
                     date: date(daysAgo: 1, 16, 4), debugInfo: parakeet(6.1, 0.19)),
        HistoryEntry(text: "I want a script that renders every onboarding page in light and dark, writes the images to one folder and makes a contact sheet. It must not need the microphone and it should run in CI.",
                     date: date(daysAgo: 1, 11, 20),
                     // An entry saved before the model was stored.
                     debugInfo: TranscriptionDebugInfo(audioDuration: 47.5, transcribeDuration: 0.71, rtf: 0.71 / 47.5)),
        HistoryEntry(text: "Summarize what we decided about the recorder overlay: the position is a setting, top center by default, and dragging it is a one-off. Then list what is still open, so I can ask the designer tomorrow morning.",
                     date: date(daysAgo: 2, 22, 47), debugInfo: parakeet(29.8, 0.47)),
        HistoryEntry(text: "Draft the migration guide for version 2 of the API: what changes for existing clients, the dates, and the two endpoints that go away. Short sentences, no jargon, and nothing we can’t actually promise.",
                     date: date(daysAgo: 2, 14, 12), debugInfo: parakeet(52.0, 0.74)),
        HistoryEntry(text: "Good morning. Today we finish the menu bar handoff. Start from the approved board, list the differences with what is built, and fix them one commit at a time.",
                     date: date(daysAgo: 4, 9, 3), debugInfo: parakeet(18.4, 0.31)),
    ]

    static let longText = "Let’s plan the architecture of the export feature before anyone writes code. Here is what I want. First, exports run in the background and never block the editor: the user starts one, keeps working, and gets a notification when the file is ready. Second, every export goes through one pipeline whatever the format, so PDF, Markdown and HTML share the same steps: collect the documents, resolve the images, render, then write the file. Third, the pipeline has to be resumable, because a large workspace can take minutes and people close their laptops. I’d like you to propose the modules and their boundaries, what each one owns, and where the state lives while an export is in progress. Then tell me what could go wrong: a document edited during the export, an image that fails to download, the disk filling up. For each, say whether we retry, skip with a warning, or stop. Don’t write code yet. Give me the plan as a short document with a diagram in text, and end with the three decisions you need from me before you start. If something in my constraints contradicts itself, say so instead of picking one silently. One more thing about the formats: Markdown must stay readable as plain text, so no HTML inside it, and images go in a folder next to the file with relative links. For PDF, page breaks never split a table row or a code block, and the table of contents is generated, not written by hand. HTML is one self-contained file people can email. Assume nothing about fonts on the reader’s machine. Finally, keep the first version small: one format end to end, then the others once the pipeline holds."

    static func settings(
        isEnabled: Bool = true, keptCount: Int = HistorySettings.defaultMaxCount, debug: Bool = false
    ) -> HistorySettingsSnapshot {
        HistorySettingsSnapshot(isEnabled: isEnabled, keptCount: keptCount, showsDebugInfo: debug, shortcut: Fixtures.productionShortcut)
    }

    /// A store in a fresh temporary folder, holding `entries`.
    static func store(_ entries: [HistoryEntry] = entries, in directory: URL = temporaryDirectory()) -> HistoryStore {
        let store = HistoryStore(fileURL: directory.appendingPathComponent("history.json"), key: { key })
        if !entries.isEmpty { store.replaceEntries(entries) }
        return store
    }

    /// A store whose file was sealed with another key: unavailable.
    static func unavailableStore() -> HistoryStore {
        let directory = temporaryDirectory()
        let url = directory.appendingPathComponent("history.json")
        let other = HistoryCrypto.key(fromHardwareUUID: "00000000-TEST-0000-0000-0000000OTHER")
        HistoryStore(fileURL: url, key: { other }).replaceEntries(Array(entries.prefix(2)))
        return HistoryStore(fileURL: url, key: { key })
    }

    /// A bound history whose file was replaced by one in the older format (a backup): not read
    /// until the user says so. The folder is deleted with the returned `HistoryFolder`.
    static func olderFormatStore(enclave: FakeEnclave = FakeEnclave()) -> (folder: HistoryFolder, store: HistoryStore) {
        let folder = HistoryFolder()
        folder.writeBoundFile(enclave, Array(entries.prefix(1)))
        folder.writeOldFile()
        return (folder, folder.store(enclave))
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("NanoWhisperHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func model(
        store: HistoryStore = store(), settings: HistorySettingsSnapshot = settings(),
        pasteboard: NSPasteboard = NSPasteboard(name: NSPasteboard.Name("nanowhisper.tests.\(UUID().uuidString)"))
    ) -> HistoryWindowModel {
        let model = HistoryWindowModel(
            store: store, settings: settings, undoManager: UndoManager(), pasteboard: pasteboard,
            now: { now }, calendar: calendar
        )
        model.announce = { _ in }
        return model
    }
}
