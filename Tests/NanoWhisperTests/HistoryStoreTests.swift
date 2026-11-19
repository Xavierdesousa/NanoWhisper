import CryptoKit
import Foundation
import Testing
@testable import NanoWhisper

@Suite("History store")
@MainActor
final class HistoryStoreTests {
    private let directory: URL
    private var fileURL: URL { directory.appendingPathComponent("history.json") }
    private static let key = HistoryCrypto.key(fromHardwareUUID: "00000000-TEST-0000-0000-000000000001")
    private static let otherKey = HistoryCrypto.key(fromHardwareUUID: "00000000-TEST-0000-0000-000000000002")

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(key: SymmetricKey? = HistoryStoreTests.key) -> HistoryStore {
        HistoryStore(fileURL: fileURL, key: { key })
    }

    private func fileBytes() throws -> Data { try Data(contentsOf: fileURL) }

    @Test("No file: empty and available")
    func missingFile() {
        let store = store()
        #expect(store.entries.isEmpty)
        #expect(!store.isUnavailable)
    }

    @Test("Round trip: what is saved loads back, and the file holds no plain text")
    func roundTrip() throws {
        let store = store()
        let info = TranscriptionDebugInfo(audioDuration: 2.5, transcribeDuration: 0.2, rtf: 0.08)
        store.add(HistoryEntry(text: "first secret words", debugInfo: info), keepingAtMost: 10)
        store.add(HistoryEntry(text: "second secret words"), keepingAtMost: 10)

        let reloaded = self.store()
        #expect(!reloaded.isUnavailable)
        #expect(reloaded.entries.map(\.text) == ["second secret words", "first secret words"])
        #expect(reloaded.entries.map(\.id) == store.entries.map(\.id))
        #expect(reloaded.entries.last?.debugInfo?.rtf == 0.08)

        let bytes = try fileBytes()
        #expect(bytes.range(of: Data("secret".utf8)) == nil)
        #expect((try? JSONSerialization.jsonObject(with: bytes)) == nil)
    }

    @Test("Adding keeps at most the limit, newest first; trimming drops the oldest")
    func trimming() {
        let store = store()
        for i in 1...5 {
            store.add(HistoryEntry(text: "t\(i)"), keepingAtMost: 3)
        }
        #expect(store.entries.map(\.text) == ["t5", "t4", "t3"])

        store.trim(to: 2)
        #expect(store.entries.map(\.text) == ["t5", "t4"])
        #expect(self.store().entries.map(\.text) == ["t5", "t4"])

        store.trim(to: 10)
        #expect(store.entries.count == 2)
    }

    @Test("Replacing the list (History window delete and clear) is saved")
    func replace() {
        let store = store()
        store.add(HistoryEntry(text: "a"), keepingAtMost: 10)
        store.add(HistoryEntry(text: "b"), keepingAtMost: 10)
        store.replaceEntries(Array(store.entries.dropFirst()))
        #expect(self.store().entries.map(\.text) == ["a"])
        store.replaceEntries([])
        #expect(self.store().entries.isEmpty)
    }

    @Test("A file sealed with another key is unavailable, and is never overwritten")
    func wrongKey() throws {
        store(key: Self.otherKey).add(HistoryEntry(text: "from another Mac"), keepingAtMost: 10)
        let before = try fileBytes()

        let store = store()
        #expect(store.isUnavailable)
        #expect(store.entries.isEmpty)

        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        store.replaceEntries([])
        #expect(store.entries.isEmpty)
        #expect(try fileBytes() == before)
    }

    @Test("A plain-text history file is never read as a fallback")
    func plainTextIsNotRead() throws {
        let plain = try JSONEncoder().encode([HistoryEntry(text: "plain text")])
        try plain.write(to: fileURL)

        let store = store()
        #expect(store.isUnavailable)
        #expect(store.entries.isEmpty)
        #expect(try fileBytes() == plain)
    }

    @Test("No key: an existing file is unavailable; a save writes nothing")
    func noKey() throws {
        try Data("damaged".utf8).write(to: fileURL)
        #expect(store(key: nil).isUnavailable)

        try FileManager.default.removeItem(at: fileURL)
        let fresh = store(key: nil)
        #expect(!fresh.isUnavailable)
        fresh.add(HistoryEntry(text: "must not be written"), keepingAtMost: 10)
        #expect(fresh.isUnavailable)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test("Seal and open with the same key; another key or damaged data fails")
    func crypto() throws {
        let data = Data("hello".utf8)
        let sealed = try #require(HistoryCrypto.seal(data, using: Self.key))
        #expect(HistoryCrypto.open(sealed, using: Self.key) == data)
        #expect(HistoryCrypto.open(sealed, using: Self.otherKey) == nil)
        #expect(HistoryCrypto.open(Data(sealed.dropLast()), using: Self.key) == nil)
    }

    @Test("Key derivation is unchanged (a change would make existing history unreadable)")
    func pinnedKeyDerivation() {
        let bytes = Self.key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined()
        #expect(bytes == "b4202dacf30df4e6fdd51cdbf878af0e8c24918adeee2f296aa398acbd4f525a")
    }
}
