import CryptoKit
import Foundation
import Testing
@testable import NanoWhisper

/// History settings, the one-time cleanup of a file kept while history was off, deleting
/// everything, turning history off, and entries saved before the debug info had a model.
@Suite("History settings and cleanup")
@MainActor
final class HistorySettingsTests {
    private let suite = "nanowhisper.tests.history.\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let directory = HistoryFixtures.temporaryDirectory()
    private var fileURL: URL { directory.appendingPathComponent("history.json") }

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    deinit {
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(key: SymmetricKey = HistoryFixtures.key) -> HistoryStore {
        HistoryStore(fileURL: fileURL, key: { key })
    }

    private func storeWithEntries(_ count: Int = 3) -> HistoryStore {
        let store = store()
        store.replaceEntries(Array(HistoryFixtures.entries.prefix(count)))
        return store
    }

    // MARK: - Defaults

    @Test("The kept count defaults to 25; a stored choice is kept")
    func defaultCount() {
        #expect(HistorySettings.defaultMaxCount == 25)
        #expect(HistorySettings.maxCount(in: defaults) == 25)
        defaults.set(15, forKey: HistorySettings.maxCountKey)
        #expect(HistorySettings.maxCount(in: defaults) == 15)
        defaults.set(100, forKey: HistorySettings.maxCountKey)
        #expect(HistorySettings.maxCount(in: defaults) == 100)
    }

    @Test("History is on unless turned off")
    func enabledDefault() {
        #expect(HistorySettings.isEnabled(in: defaults))
        defaults.set(false, forKey: HistorySettings.enabledKey)
        #expect(!HistorySettings.isEnabled(in: defaults))
    }

    // MARK: - One-time cleanup

    @Test("History off with a file kept from before: deleted at the first launch, once")
    func cleanupDeletesOnce() {
        defaults.set(false, forKey: HistorySettings.enabledKey)
        let store = storeWithEntries()
        #expect(store.hasFile)

        #expect(HistorySettings.runOffCleanupOnce(defaults: defaults, store: store))
        #expect(!store.hasFile)
        #expect(store.entries.isEmpty)
        #expect(defaults.bool(forKey: HistorySettings.offCleanupDoneKey))

        // A later launch never deletes anything here, even if a file is there again.
        _ = storeWithEntries(1)
        let later = self.store()
        #expect(!HistorySettings.runOffCleanupOnce(defaults: defaults, store: later))
        #expect(later.hasFile)
        #expect(later.entries.count == 1)
    }

    @Test("History on at the first launch: nothing deleted, and the cleanup is done for good")
    func cleanupWithHistoryOn() {
        let store = storeWithEntries()
        #expect(!HistorySettings.runOffCleanupOnce(defaults: defaults, store: store))
        #expect(store.entries.count == 3)
        #expect(store.hasFile)
        #expect(defaults.bool(forKey: HistorySettings.offCleanupDoneKey))

        // Turned off afterwards (the alert deletes then): the launch cleanup does not run again.
        defaults.set(false, forKey: HistorySettings.enabledKey)
        #expect(!HistorySettings.runOffCleanupOnce(defaults: defaults, store: self.store()))
    }

    @Test("History off with a file that cannot be read: deleted too")
    func cleanupUnreadableFile() {
        defaults.set(false, forKey: HistorySettings.enabledKey)
        _ = storeWithEntries()
        let unreadable = store(key: HistoryCrypto.key(fromHardwareUUID: "another Mac"))
        #expect(unreadable.isUnavailable)

        #expect(HistorySettings.runOffCleanupOnce(defaults: defaults, store: unreadable))
        #expect(!unreadable.hasFile)
        #expect(!unreadable.isUnavailable)
    }

    @Test("History off and no file: nothing to do, marked done")
    func cleanupNoFile() {
        defaults.set(false, forKey: HistorySettings.enabledKey)
        #expect(!HistorySettings.runOffCleanupOnce(defaults: defaults, store: store()))
        #expect(defaults.bool(forKey: HistorySettings.offCleanupDoneKey))
    }

    // MARK: - Delete everything

    @Test("deleteAll removes the entries and the file")
    func deleteAll() {
        let store = storeWithEntries()
        store.deleteAll()
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(self.store().entries.isEmpty)
    }

    // MARK: - Turning history off

    @Test("Turning off with dictations kept asks first; Cancel keeps everything and leaves it on")
    func turnOffCancel() {
        let store = storeWithEntries()
        var applied: [Bool] = []
        var askedCount: Int?
        HistoryTurnOff.setEnabled(false, current: true, store: store, apply: { applied.append($0) }) { count, done in
            askedCount = count
            done(false)
        }
        #expect(askedCount == 3)
        #expect(applied.isEmpty)
        #expect(store.entries.count == 3)
        #expect(store.hasFile)
    }

    @Test("Turn Off and Delete: the history is deleted, then turned off")
    func turnOffConfirm() {
        let store = storeWithEntries()
        var applied: [Bool] = []
        var entriesWhenApplied: Int?
        HistoryTurnOff.setEnabled(false, current: true, store: store, apply: {
            applied.append($0)
            entriesWhenApplied = store.entries.count
        }) { _, done in done(true) }
        #expect(applied == [false])
        #expect(entriesWhenApplied == 0)
        #expect(!store.hasFile)
        #expect(self.store().entries.isEmpty)
    }

    @Test("Turning off with nothing kept: no alert")
    func turnOffEmpty() {
        let store = store()
        var applied: [Bool] = []
        var asked = false
        HistoryTurnOff.setEnabled(false, current: true, store: store, apply: { applied.append($0) }) { _, done in
            asked = true
            done(true)
        }
        #expect(!asked)
        #expect(applied == [false])
    }

    @Test("Turning on never asks")
    func turnOn() {
        let store = storeWithEntries()
        var applied: [Bool] = []
        var asked = false
        HistoryTurnOff.setEnabled(true, current: false, store: store, apply: { applied.append($0) }) { _, done in
            asked = true
            done(true)
        }
        #expect(!asked)
        #expect(applied == [true])
        #expect(store.entries.count == 3)
    }

    @Test("The alerts' wording")
    func alertWording() {
        let turnOff = HistoryAlerts.turnOffAlert(count: 10)
        #expect(turnOff.messageText == "Turn off history and delete it?")
        #expect(turnOff.informativeText == "The 10 dictations kept on this Mac are deleted, and new ones won’t be kept. You can’t undo this.")
        #expect(turnOff.buttons.map(\.title) == ["Turn Off and Delete", "Cancel"])
        #expect(turnOff.buttons[0].hasDestructiveAction)
        #expect(HistoryAlerts.turnOffAlert(count: 1).informativeText.hasPrefix("The 1 dictation kept on this Mac is deleted"))
        #expect(HistoryAlerts.turnOffAlert(count: 0).informativeText
            == "The history on this Mac, which can’t be read right now, is deleted, and new dictations won’t be kept. You can’t undo this.")
        let clear = HistoryAlerts.clearAllAlert(count: 10)
        #expect(clear.messageText == "Delete all 10 dictations?")
        #expect(clear.buttons.map(\.title) == ["Delete All", "Cancel"])
    }

    // MARK: - Entries saved by older versions

    @Test("An entry saved before the model and language were stored still loads, without them")
    func decodesOldEntries() throws {
        let old = """
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"an older dictation","date":785000000,
          "debugInfo":{"audio_duration":4.5,"transcribe_duration":0.2,"rtf":0.044}},
         {"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","text":"no debug info","date":784000000}]
        """
        let sealed = try #require(HistoryCrypto.seal(Data(old.utf8), using: HistoryFixtures.key))
        try sealed.write(to: fileURL)

        let store = store()
        #expect(!store.isUnavailable)
        #expect(store.entries.map(\.text) == ["an older dictation", "no debug info"])
        let info = try #require(store.entries[0].debugInfo)
        #expect(info.rtf == 0.044)
        #expect(info.model == nil)
        #expect(info.language == nil)
        #expect(info.languageDetected == nil)
        #expect(store.entries[1].debugInfo == nil)
        // The rows an older entry can show: no Model, no Language.
        #expect(HistoryText.debugRows(info).map(\.label) == ["Audio", "Transcription", "Real-time factor"])
    }

    @Test("The model and the detected language round-trip")
    func roundTripsModelAndLanguage() throws {
        let info = TranscriptionDebugInfo(audioDuration: 34.2, transcribeDuration: 2.91, rtf: 0.085,
                                          model: "Whisper Large v3 Turbo", language: "fr", languageDetected: true)
        let store = store()
        store.add(HistoryEntry(text: "bonjour", debugInfo: info), keepingAtMost: 25)
        #expect(self.store().entries.first?.debugInfo == info)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(info)) as? [String: Any]
        #expect(json?["model"] as? String == "Whisper Large v3 Turbo")
        #expect(json?["language"] as? String == "fr")
        #expect(json?["language_detected"] as? Bool == true)
    }
}
