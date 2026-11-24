import CryptoKit
import Foundation
import Testing
@testable import NanoWhisper

/// Binding an existing history to this Mac: what happens, what a crash at each step leaves and
/// what the next launch does with it, and failures. Temporary folders, invented entries, a
/// software enclave.
@Suite("History migration")
@MainActor
struct HistoryMigrationTests {
    private let folder = HistoryFolder()
    private let enclave = FakeEnclave()
    private let entries = HistoryFixtures.entries

    private struct Interrupted: Error {}

    /// Everything is there, in the new format, and the history works.
    private func expectMigrated(
        _ folder: HistoryFolder, _ store: HistoryStore, _ expected: [HistoryEntry],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(store.entries == expected, sourceLocation: sourceLocation)
        #expect(!store.isUnavailable, sourceLocation: sourceLocation)
        #expect(folder.isBound, sourceLocation: sourceLocation)
        #expect(folder.hasKey, sourceLocation: sourceLocation)
        #expect(folder.isRecordedBound, sourceLocation: sourceLocation)
        #expect(folder.names == ["history.json", "history.key"], sourceLocation: sourceLocation)
        #expect(HistoryCrypto.open(try folder.history(), using: HistoryFolder.oldKey) == nil, sourceLocation: sourceLocation)
        let added = HistoryEntry(text: "said after")
        store.add(added, keepingAtMost: 100)
        #expect(folder.store(enclave).entries == [added] + expected, sourceLocation: sourceLocation)
    }

    @Test("An older file is bound to this Mac at launch: same entries, old bytes gone")
    func migrates() throws {
        let old = folder.writeOldFile()
        let store = folder.store(enclave)
        #expect(store.entries == entries)
        #expect(try folder.history() != old)
        try expectMigrated(folder, store, entries)
    }

    @Test("An empty history migrates too")
    func migratesEmpty() throws {
        folder.writeOldFile([])
        try expectMigrated(folder, folder.store(enclave), [])
    }

    @Test("The content is re-encrypted as it is: fields this version does not know are kept")
    func keepsUnknownFields() throws {
        let json = Data(#"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","text":"dictated","date":785000000.25,"later":{"a":1}}]"#.utf8)
        try #require(HistoryCrypto.seal(json, using: HistoryFolder.oldKey)).write(to: folder.historyURL)
        #expect(folder.store(enclave).entries.map(\.text) == ["dictated"])
        let key = try #require(try HistoryKeyring(enclave: enclave, storage: HistoryKeyFile(besideHistoryAt: folder.historyURL)).existingKey())
        #expect(try key.open(folder.history()) == json)
    }

    // MARK: - Crashes

    /// What is on disk when the app dies at each step.
    private func leavesOldFile(_ step: HistoryMigration.Step) -> Bool {
        switch step {
        case .keyStored, .staged, .verified: true
        case .replaced, .recorded, .erased: false
        }
    }

    @Test("A crash at any step loses nothing: the next launch has every entry and finishes the migration",
          arguments: HistoryMigration.Step.allCases)
    func crash(at step: HistoryMigration.Step) throws {
        folder.writeOldFile()
        var crashed: HistoryFolder?
        // The folder and the setting exactly as they are at that step.
        _ = folder.store(enclave) { if $0 == step { crashed = HistoryFolder(copying: self.folder) } }
        let left = try #require(crashed)

        #expect(left.hasKey)
        #expect(left.isBound == !leavesOldFile(step))
        #expect(left.isRecordedBound == (step == .recorded || step == .erased))
        #expect(left.names.contains { $0.hasPrefix("history.json.writing-") } == (step == .staged || step == .verified))

        let key = try left.key()
        let store = left.store(enclave)
        #expect(try left.key() == key) // the key already made is used, never replaced
        try expectMigrated(left, store, entries)
    }

    @Test("A crash before the key is kept: the migration starts again")
    func crashBeforeKey() throws {
        let old = folder.writeOldFile()
        // The record half written, next to its final name.
        folder.write(Data("NWHISTKEY half".utf8), named: "history.key.writing-\(UUID().uuidString)")
        #expect(try folder.history() == old)
        try expectMigrated(folder, folder.store(enclave), entries)
    }

    @Test("A crash while the new file is written: the half file is never read, and goes")
    func crashWhileWriting() throws {
        folder.writeOldFile()
        var crashed: HistoryFolder?
        _ = folder.store(enclave) { if $0 == .staged { crashed = HistoryFolder(copying: self.folder) } }
        let left = try #require(crashed)
        let staged = try #require(left.names.first { $0.hasPrefix("history.json.writing-") })
        let half = try #require(left.read(staged)).prefix(60)
        left.write(Data(half), named: staged)
        try expectMigrated(left, left.store(enclave), entries)
    }

    @Test("A crash during a later save leaves the previous history")
    func crashDuringSave() throws {
        folder.writeBoundFile(enclave)
        folder.write(Data("NWHISTORY half".utf8), named: "history.json.writing-\(UUID().uuidString)")
        try expectMigrated(folder, folder.store(enclave), entries)
    }

    // MARK: - Failures

    /// The old file is untouched, the history works with its old key, and the next launch
    /// migrates it, with what was added meanwhile.
    private func expectKeptAndRetried(
        _ old: Data, _ store: HistoryStore, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        #expect(store.entries == entries, sourceLocation: sourceLocation)
        #expect(!store.isUnavailable, sourceLocation: sourceLocation)
        #expect(try folder.history() == old, sourceLocation: sourceLocation)
        #expect(!folder.isRecordedBound, sourceLocation: sourceLocation)
        #expect(!folder.names.contains { $0.contains(".writing-") }, sourceLocation: sourceLocation)
        let added = HistoryEntry(text: "said meanwhile")
        store.add(added, keepingAtMost: 100)
        #expect(!folder.isBound, sourceLocation: sourceLocation)
        #expect(HistoryCrypto.open(try folder.history(), using: HistoryFolder.oldKey) != nil, sourceLocation: sourceLocation)
        try expectMigrated(folder, folder.store(enclave), [added] + entries, sourceLocation: sourceLocation)
    }

    @Test("A failure before the replacement keeps the old file and its key, and is tried again",
          arguments: [HistoryMigration.Step.keyStored, .staged, .verified])
    func failure(at step: HistoryMigration.Step) throws {
        let old = folder.writeOldFile()
        let store = folder.store(enclave) { if $0 == step { throw Interrupted() } }
        try expectKeptAndRetried(old, store)
    }

    @Test("The enclave makes no key")
    func enclaveRefusesToMake() throws {
        let old = folder.writeOldFile()
        enclave.update { $0.refusesToMake = true }
        let store = folder.store(enclave)
        enclave.update { $0.refusesToMake = false }
        #expect(!folder.hasKey)
        try expectKeptAndRetried(old, store)
    }

    @Test("The enclave cannot use the key it just made: the key is not kept")
    func enclaveRefusesToOpen() throws {
        let old = folder.writeOldFile()
        enclave.update { $0.refusesToOpen = true }
        let store = folder.store(enclave)
        enclave.update { $0.refusesToOpen = false }
        #expect(!folder.hasKey)
        try expectKeptAndRetried(old, store)
    }

    @Test("The enclave stops answering between the writing and the check")
    func enclaveRefusesToVerify() throws {
        let old = folder.writeOldFile()
        let store = folder.store(enclave) { if $0 == .staged { self.enclave.update { $0.refusesToOpen = true } } }
        enclave.update { $0.refusesToOpen = false }
        try expectKeptAndRetried(old, store)
    }

    @Test("The enclave does not answer: the app is not held up")
    func enclaveHangs() throws {
        let old = folder.writeOldFile()
        let gate = FakeEnclave.Gate()
        enclave.update { $0.gate = gate }
        let start = Date()
        let store = folder.store(enclave, timeout: 0.1)
        #expect(Date().timeIntervalSince(start) < 2)
        gate.open()
        enclave.update { $0.gate = nil }
        try expectKeptAndRetried(old, store)
    }

    @Test("The new file does not read back as it was written: the old one stays")
    func badReadBack() throws {
        let old = folder.writeOldFile()
        let store = folder.store(enclave) { step in
            guard step == .staged, let staged = self.folder.names.first(where: { $0.contains(".writing-") }) else { return }
            var bytes = try #require(self.folder.read(staged))
            bytes[bytes.count / 2] ^= 1
            self.folder.write(bytes, named: staged)
        }
        try expectKeptAndRetried(old, store)
    }

    @Test("A folder that cannot be written: the old file stays")
    func readOnlyFolder() throws {
        let old = folder.writeOldFile()
        chmod(folder.directory.path, 0o500)
        let store = folder.store(enclave)
        chmod(folder.directory.path, 0o700)
        try expectKeptAndRetried(old, store)
    }

    @Test("The new file is damaged once in place: the old one comes back")
    func damagedInPlace() throws {
        let old = folder.writeOldFile()
        let store = folder.store(enclave) { step in
            guard step == .replaced else { return }
            let handle = try FileHandle(forWritingTo: self.folder.historyURL)
            try handle.seek(toOffset: 40)
            try handle.write(contentsOf: Data([0, 0, 0, 0]))
            try handle.close()
        }
        try expectKeptAndRetried(old, store)
    }

    @Test("Another process wrote the history meanwhile: its file is left alone")
    func changedByAnother() throws {
        let theirs = [HistoryEntry(text: "by another instance")] + entries
        for step in [HistoryMigration.Step.verified, .replaced] {
            folder.writeOldFile()
            var written = Data()
            let store = folder.store(enclave) { if $0 == step { written = self.folder.writeOldFile(theirs) } }
            #expect(!store.isUnavailable)
            #expect(try folder.history() == written)
            #expect(!folder.isRecordedBound)
        }
        try expectMigrated(folder, folder.store(enclave), theirs)
    }

    @Test("The key kept by an interrupted migration is damaged: the history stays in the old format, the key file too")
    func damagedPendingKey() throws {
        let old = folder.writeOldFile()
        _ = folder.store(enclave) { if $0 == .keyStored { throw Interrupted() } }
        folder.write(Data("damaged".utf8), named: "history.key")
        let store = folder.store(enclave)
        #expect(store.entries == entries)
        #expect(!store.isUnavailable)
        #expect(try folder.history() == old)
        #expect(try folder.key() == Data("damaged".utf8))
        #expect(enclave.current.opened == 1) // only the check of the key when it was made
    }

    // MARK: - After the migration

    @Test("Once bound, an older file is not read, nor overwritten")
    func olderFileRefused() throws {
        folder.writeOldFile()
        _ = folder.store(enclave)
        let forged = folder.writeOldFile([HistoryEntry(text: "not dictated here")])

        // With its key file there or not.
        for keepsKey in [true, false] {
            if !keepsKey { try FileManager.default.removeItem(at: folder.keyURL) }
            let store = folder.store(enclave)
            #expect(store.unavailableReason == .olderFormat)
            #expect(store.entries.isEmpty)
            store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
            store.insert(HistoryEntry(text: "recovered"), keepingAtMost: 10)
            store.replaceEntries([])
            store.trim(to: 0)
            #expect(try folder.history() == forged)
        }
    }

    @Test("An older file that cannot be read either is just unreadable")
    func olderFileFromAnotherMac() throws {
        folder.writeOldFile()
        _ = folder.store(enclave)
        folder.writeOldFile()
        #expect(folder.store(enclave, oldKey: SymmetricKey(size: .bits256)).unavailableReason == .unreadable)
    }

    @Test("Use This History: the older file is bound to this Mac with the same key")
    func useOlderFile() throws {
        folder.writeBoundFile(enclave, [HistoryEntry(text: "before")])
        let key = try folder.key()
        folder.writeOldFile()
        let store = folder.store(enclave)
        #expect(store.unavailableReason == .olderFormat)
        #expect(store.useOlderFile())
        #expect(try folder.key() == key)
        try expectMigrated(folder, store, entries)
        #expect(!store.useOlderFile())
    }

    @Test("Use This History when it cannot be bound: nothing changes")
    func useOlderFileFails() throws {
        folder.writeBoundFile(enclave, [HistoryEntry(text: "before")])
        let old = folder.writeOldFile()
        let store = folder.store(enclave)
        enclave.update { $0.refusesToOpen = true }
        #expect(!store.useOlderFile())
        #expect(store.unavailableReason == .olderFormat)
        #expect(store.entries.isEmpty)
        #expect(try folder.history() == old)
        enclave.update { $0.refusesToOpen = false }
        #expect(store.useOlderFile())
        #expect(store.entries == entries)
    }

    @Test("Use This History after the Mac was erased: the key that cannot be used any more makes room")
    func useOlderFileWithUnusableKey() throws {
        folder.writeBoundFile(FakeEnclave()) // before
        let unusable = try folder.key()
        folder.writeOldFile()
        let store = folder.store(enclave)
        #expect(store.unavailableReason == .olderFormat)

        // Not when the enclave may only be busy.
        let gate = FakeEnclave.Gate()
        enclave.update { $0.gate = gate }
        #expect(!folder.store(enclave, timeout: 0.05).useOlderFile())
        gate.open()
        enclave.update { $0.gate = nil }
        #expect(try folder.key() == unusable)

        #expect(store.useOlderFile())
        #expect(store.entries == entries)
        #expect(try folder.key() != unusable)
        let aside = try #require(folder.names.first { $0.hasPrefix("history.key.unused-") })
        #expect(folder.read(aside) == unusable)
        #expect(folder.store(enclave).entries == entries)
    }

    @Test("A whole backup from before the migration (files and settings) migrates like the first time")
    func restoredBeforeMigration() throws {
        folder.writeOldFile()
        _ = folder.store(enclave)
        try FileManager.default.removeItem(at: folder.keyURL)
        folder.writeOldFile()
        folder.defaults.removeObject(forKey: HistorySettings.boundKey)
        try expectMigrated(folder, folder.store(enclave), entries)
    }

    @Test("A bound history put back from a backup on the same Mac is read")
    func restoredBound() throws {
        folder.writeBoundFile(enclave)
        let backup = try folder.history()
        folder.store(enclave).replaceEntries([])
        folder.write(backup, named: "history.json")
        #expect(folder.store(enclave).entries == entries)
    }

    @Test("0.1.0 leaves the bound file alone: it cannot open it, and never writes over it")
    func downgrade() throws {
        folder.writeBoundFile(enclave)
        let bound = try folder.history()
        let key = try folder.key()
        // What 0.1.0 does with the file (its HistoryStore is this one without a keyring).
        #expect(HistoryCrypto.open(bound, using: HistoryFolder.oldKey) == nil)
        let old = folder.store(nil)
        #expect(old.isUnavailable)
        old.add(HistoryEntry(text: "while downgraded"), keepingAtMost: 10)
        old.replaceEntries([])
        old.trim(to: 0)
        #expect(try folder.history() == bound)
        #expect(try folder.key() == key)
        // And back.
        #expect(folder.store(enclave).entries == entries)
    }

    @Test("Other files of the folder are never touched, even a hard link to the history")
    func otherFiles() throws {
        let others = [
            "history.json.backup-2026-11-20", "history.json.writing-notes", "history.json.writing-", "history.key.backup",
            "history.json copy",
        ]
        for name in others { folder.write(Data(name.utf8), named: name) }
        let old = folder.writeOldFile()
        let link = folder.directory.appendingPathComponent("history.json.backup-link")
        try FileManager.default.linkItem(at: folder.historyURL, to: link)

        let store = folder.store(enclave)
        #expect(folder.isBound)
        #expect(try Data(contentsOf: link) == old)
        store.add(HistoryEntry(text: "more"), keepingAtMost: 10)
        let boundLink = folder.directory.appendingPathComponent("history.json.backup-bound")
        try FileManager.default.linkItem(at: folder.historyURL, to: boundLink)
        let bound = try folder.history()
        let key = try folder.key()
        #expect(store.deleteAll())
        // Its key is set aside for the copy that needs it.
        let aside = try #require(folder.names.first { $0.hasPrefix("history.key.unused-") })
        #expect(folder.read(aside) == key)
        #expect(folder.names == Set(others + ["history.json.backup-link", "history.json.backup-bound", aside]))
        for name in others { #expect(folder.read(name) == Data(name.utf8)) }
        #expect(try Data(contentsOf: link) == old)
        #expect(try Data(contentsOf: boundLink) == bound)
    }

    @Test("A history reached through a symbolic link stays there")
    func symbolicLink() throws {
        let elsewhere = HistoryFolder()
        elsewhere.writeOldFile()
        try FileManager.default.createSymbolicLink(at: folder.historyURL, withDestinationURL: elsewhere.historyURL)
        let store = folder.store(enclave)
        #expect(store.entries == entries)
        store.add(HistoryEntry(text: "more"), keepingAtMost: 100)
        #expect(elsewhere.isBound)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder.historyURL.path) == elsewhere.historyURL.path)
        #expect(elsewhere.names == ["history.json"])
        #expect(folder.store(enclave).entries.count == entries.count + 1)
    }
}
