import CryptoKit
import Foundation
import Testing
@testable import NanoWhisper

/// The key bound to this Mac: formats, the store with a (software) Secure Enclave, a key that is
/// missing, damaged or from another Mac, deleting, file modes.
@Suite("History key")
@MainActor
struct HistoryKeyTests {
    private let folder = HistoryFolder()
    private let enclave = FakeEnclave()
    private let entries = HistoryFixtures.entries

    private var keyFile: HistoryKeyFile { HistoryKeyFile(besideHistoryAt: folder.historyURL) }

    // MARK: - Formats

    @Test("Key record: round trip, its exact layout, a random key and id each time")
    func recordRoundTrip() throws {
        let key = try HistoryKey(newIn: enclave)
        let bytes = key.record.bytes
        let blob = key.record.enclaveBlob
        try #require(bytes.count > 28)
        #expect(bytes.prefix(9) == Data("NWHISTKEY".utf8))
        #expect(bytes[9] == 1)
        #expect(Data(bytes[10..<26]) == key.record.id)
        #expect(Int(bytes[26]) << 8 | Int(bytes[27]) == blob.count)
        #expect(bytes.count == 28 + blob.count + 64 + 60 + 32)
        #expect(Data(bytes.suffix(32)) == Data(SHA256.hash(data: bytes.dropLast(32))))
        #expect(try HistoryKeyRecord(bytes: bytes) == key.record)

        let again = try HistoryKey(unwrapping: HistoryKeyRecord(bytes: bytes), with: enclave)
        #expect(try again.open(key.seal(Data("text".utf8))) == Data("text".utf8))
        let other = try HistoryKey(newIn: enclave)
        #expect(other.record.id != key.record.id)
        #expect(throws: HistoryKeyError.cannotOpen) { try other.open(key.seal(Data("text".utf8))) }
    }

    @Test("A damaged key record is refused before the enclave sees it, whatever the byte")
    func damagedRecord() throws {
        let bytes = try HistoryKey(newIn: enclave).record.bytes
        for index in bytes.indices {
            var damaged = bytes
            damaged[index] ^= 0x01
            #expect(throws: HistoryKeyError.self) { try HistoryKeyRecord(bytes: damaged) }
        }
        for count in [0, 1, 9, 10, 28, 100, bytes.count - 1] {
            #expect(throws: HistoryKeyError.self) { try HistoryKeyRecord(bytes: bytes.prefix(count)) }
        }
        #expect(throws: HistoryKeyError.self) { try HistoryKeyRecord(bytes: bytes + Data([0])) }
    }

    @Test("A forged record with a valid checksum does not unwrap")
    func forgedRecord() throws {
        let bytes = try HistoryKey(newIn: enclave).record.bytes
        // Any byte but the magic, the version and the blob's length.
        for index in Array(10..<26) + Array(28..<(bytes.count - 32)) {
            var body = Data(bytes.dropLast(32))
            body[index] ^= 0x01
            let forged = body + Data(SHA256.hash(data: body))
            #expect(throws: (any Error).self) {
                try HistoryKey(unwrapping: HistoryKeyRecord(bytes: forged), with: enclave)
            }
        }
    }

    @Test("History file: its exact layout; a damaged one is refused, whatever the byte")
    func historyFile() throws {
        let key = try HistoryKey(newIn: enclave)
        let json = Data("[]".utf8)
        let file = try key.seal(json)
        try #require(file.count > 26)
        #expect(file.prefix(9) == Data("NWHISTORY".utf8))
        #expect(file[9] == 2)
        #expect(Data(file[10..<26]) == key.record.id)
        #expect(file.count == 26 + 12 + json.count + 16)
        #expect(try key.open(file) == json)
        for index in file.indices {
            var damaged = file
            damaged[index] ^= 0x01
            #expect(throws: HistoryKeyError.self) { try key.open(damaged) }
        }
        #expect(throws: HistoryKeyError.self) { try key.open(file.prefix(26)) }
        #expect(!BoundHistoryFile.isBound(Data("NWHIST".utf8)))
    }

    @Test("Files of a newer version are left alone", arguments: ["history.json", "history.key"])
    func newerVersion(name: String) throws {
        folder.writeBoundFile(enclave)
        var bytes = try #require(folder.read(name))
        bytes[9] += 1
        folder.write(bytes, named: name)
        let both = try [folder.history(), folder.key()]
        let store = folder.store(enclave)
        #expect(store.isUnavailable)
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        #expect(try [folder.history(), folder.key()] == both)
    }

    // MARK: - A new history

    @Test("With an enclave: nothing on disk until the first dictation, then a bound history and its key")
    func newHistory() throws {
        let store = folder.store(enclave)
        #expect(!store.isUnavailable)
        #expect(folder.names.isEmpty)
        store.replaceEntries(entries)
        #expect(folder.names == ["history.json", "history.key"])
        #expect(folder.isBound)
        #expect(folder.isRecordedBound)
        #expect(try folder.history().range(of: Data("queue".utf8)) == nil)
        #expect(folder.store(enclave).entries == entries)
    }

    @Test("A crash between the key and the first history: the key is used")
    func crashBeforeFirstHistory() throws {
        let key = try HistoryKeyring(enclave: enclave, storage: keyFile).existingOrNewKey()
        #expect(folder.names == ["history.key"])
        let store = folder.store(enclave)
        #expect(!store.isUnavailable)
        store.add(HistoryEntry(text: "first"), keepingAtMost: 10)
        #expect(try folder.key() == key.record.bytes)
        #expect(folder.store(enclave).entries.map(\.text) == ["first"])
    }

    @Test("A crash between the first history and the setting: the next launch sets it")
    func crashBeforeRecording() throws {
        folder.writeBoundFile(enclave)
        folder.isRecordedBound = false
        #expect(folder.store(enclave).entries == entries)
        #expect(folder.isRecordedBound)
    }

    @Test("No key can be made: the old key for now, bound at the next launch")
    func noKeyYet() throws {
        enclave.update { $0.refusesToMake = true }
        let store = folder.store(enclave)
        store.add(HistoryEntry(text: "first"), keepingAtMost: 10)
        #expect(!store.isUnavailable)
        #expect(!folder.isBound)
        enclave.update { $0.refusesToMake = false }
        #expect(folder.store(enclave).entries.map(\.text) == ["first"])
        #expect(folder.isBound)
    }

    @Test("No key can be made after a bound history was deleted: nothing is written with the old key")
    func noKeyOnceBound() throws {
        folder.writeBoundFile(enclave)
        let store = folder.store(enclave)
        #expect(store.deleteAll())
        enclave.update { $0.refusesToMake = true }
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        #expect(store.isUnavailable)
        #expect(folder.names.isEmpty)
    }

    @Test("The enclave does not answer when a bound history is started again: nothing is written with the old key",
          arguments: [true, false])
    func noAnswerOnceBound(hangs: Bool) throws {
        folder.writeBoundFile(enclave)
        let store = folder.store(enclave, timeout: 0.1)
        #expect(store.deleteAll())
        let gate = FakeEnclave.Gate()
        enclave.update { $0.gate = hangs ? gate : nil; $0.isAvailable = hangs }
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        #expect(store.isUnavailable)
        #expect(folder.names.isEmpty)
        #expect(folder.isRecordedBound)
        gate.open()
        enclave.update { $0.gate = nil; $0.isAvailable = true }
        let next = folder.store(enclave)
        next.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        #expect(folder.isBound)
    }

    // MARK: - No Secure Enclave

    @Test("No Secure Enclave: the old format keeps working, without a key file")
    func noEnclave() throws {
        enclave.update { $0.isAvailable = false }
        folder.writeOldFile()
        let store = folder.store(enclave)
        #expect(store.entries == entries)
        let added = HistoryEntry(text: "more")
        store.add(added, keepingAtMost: 100)
        #expect(folder.names == ["history.json"])
        #expect(!folder.isBound)
        #expect(!folder.isRecordedBound)
        #expect(enclave.current.made == 0)
        #expect(folder.store(enclave).entries == [added] + entries)
        // It gets one (a backup of a virtual machine put back on a Mac with the same UUID…).
        enclave.update { $0.isAvailable = true }
        #expect(folder.store(enclave).entries == [added] + entries)
        #expect(folder.isBound)
    }

    @Test("A bound history without a Secure Enclave is unavailable, never downgraded")
    func noEnclaveOnceBound() throws {
        folder.writeBoundFile(enclave)
        let bound = try folder.history()
        enclave.update { $0.isAvailable = false }
        let store = folder.store(enclave)
        #expect(store.unavailableReason == .unreadable)
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        store.replaceEntries([])
        #expect(try folder.history() == bound)
        #expect(folder.isRecordedBound)

        // Deleted by the user: a new history, which can only use the old key here.
        #expect(store.deleteAll())
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        #expect(!store.isUnavailable)
        #expect(folder.store(enclave).entries.map(\.text) == ["new"])
    }

    @Test("An instance still on the old key does not replace a history bound since")
    func oldInstanceDoesNotDowngrade() throws {
        folder.writeOldFile()
        enclave.update { $0.refusesToMake = true }
        let late = folder.store(enclave)
        enclave.update { $0.refusesToMake = false }
        _ = folder.store(enclave)
        let bound = try folder.history()
        late.add(HistoryEntry(text: "from the other instance"), keepingAtMost: 100)
        #expect(late.isUnavailable)
        #expect(try folder.history() == bound)
    }

    @Test("A file that cannot be read any more is not replaced by one in the old format")
    func unreadableWhileRunning() throws {
        enclave.update { $0.isAvailable = false }
        folder.writeOldFile()
        let store = folder.store(enclave)
        let old = try folder.history()
        chmod(folder.historyURL.path, 0)
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        #expect(store.isUnavailable)
        chmod(folder.historyURL.path, 0o600)
        #expect(try folder.history() == old)
    }

    // MARK: - Key missing, damaged, from another Mac

    /// The history is unavailable, and whatever the app does the files stay as they are.
    private func expectUnavailableAndUntouched(
        _ enclave: FakeEnclave?, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let history = try folder.history()
        let key = try? folder.key()
        let names = folder.names
        let store = folder.store(enclave)
        #expect(store.unavailableReason == .unreadable, sourceLocation: sourceLocation)
        #expect(store.entries.isEmpty, sourceLocation: sourceLocation)
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        store.insert(HistoryEntry(text: "recovered"), keepingAtMost: 10)
        store.replaceEntries([])
        store.trim(to: 0)
        #expect(!store.useOlderFile(), sourceLocation: sourceLocation)
        #expect(try folder.history() == history, sourceLocation: sourceLocation)
        #expect((try? folder.key()) == key, sourceLocation: sourceLocation)
        #expect(folder.names == names, sourceLocation: sourceLocation)
    }

    @Test("Key file missing")
    func missingKey() throws {
        folder.writeBoundFile(enclave)
        try FileManager.default.removeItem(at: folder.keyURL)
        try expectUnavailableAndUntouched(enclave)
        #expect(!folder.hasKey)
    }

    @Test("Key file damaged: the enclave is not even asked")
    func damagedKey() throws {
        folder.writeBoundFile(enclave)
        let key = try folder.key()
        let opened = enclave.current.opened
        for damaged in [Data(), Data("damaged".utf8), key.dropLast(), key + Data([0])] {
            folder.write(Data(damaged), named: "history.key")
            try expectUnavailableAndUntouched(enclave)
        }
        #expect(enclave.current.opened == opened)
        folder.write(key, named: "history.key")
        #expect(folder.store(enclave).entries == entries)
    }

    @Test("Files copied to another Mac cannot be read there, even with the same hardware UUID")
    func anotherMac() throws {
        folder.writeBoundFile(enclave)
        try expectUnavailableAndUntouched(FakeEnclave())
        #expect(folder.store(enclave).entries == entries)
    }

    @Test("The key of another history")
    func anotherKey() throws {
        folder.writeBoundFile(enclave)
        let other = HistoryFolder()
        other.writeBoundFile(enclave)
        folder.write(try other.key(), named: "history.key")
        try expectUnavailableAndUntouched(enclave)
    }

    @Test("The enclave refuses for now: unavailable, readable again at a later launch")
    func enclaveRefuses() throws {
        folder.writeBoundFile(enclave)
        enclave.update { $0.refusesToOpen = true }
        try expectUnavailableAndUntouched(enclave)
        enclave.update { $0.refusesToOpen = false }
        #expect(folder.store(enclave).entries == entries)
    }

    @Test("A history file that cannot be read is not a missing one: it is not overwritten")
    func unreadableFile() throws {
        folder.writeBoundFile(enclave)
        let bound = try folder.history()
        chmod(folder.historyURL.path, 0)
        let store = folder.store(enclave)
        #expect(store.isUnavailable)
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        chmod(folder.historyURL.path, 0o600)
        #expect(try folder.history() == bound)
    }

    @Test("The enclave answers late: the history appears then, and nothing was written meanwhile")
    func lateEnclave() async throws {
        folder.writeBoundFile(enclave)
        let bound = try folder.history()
        let gate = FakeEnclave.Gate()
        enclave.update { $0.gate = gate }
        let store = folder.store(enclave, timeout: 0.05)
        #expect(store.isUnavailable)
        store.add(HistoryEntry(text: "too early"), keepingAtMost: 10)
        #expect(try folder.history() == bound)
        gate.open()
        for _ in 0..<200 where store.isUnavailable { try await Task.sleep(for: .milliseconds(10)) }
        #expect(store.entries == entries)
        store.add(HistoryEntry(text: "now"), keepingAtMost: 100)
        enclave.update { $0.gate = nil }
        #expect(folder.store(enclave).entries.count == entries.count + 1)
    }

    @Test("Deleted while the enclave was still silent: its late answer brings nothing back")
    func lateEnclaveAfterDeletion() async throws {
        folder.writeBoundFile(enclave)
        let gate = FakeEnclave.Gate()
        enclave.update { $0.gate = gate }
        let store = folder.store(enclave, timeout: 0.05)
        #expect(store.deleteAll())
        let answered = enclave.current.answered
        gate.open()
        for _ in 0..<200 where enclave.current.answered == answered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(enclave.current.answered > answered)
        try await Task.sleep(for: .milliseconds(100)) // its answer reaches the main actor
        #expect(store.entries.isEmpty)
        #expect(!store.isUnavailable)
        #expect(folder.names.isEmpty)
    }

    // MARK: - While the app runs

    @Test("The enclave is used once per launch: saving works while it refuses (screen locked)")
    func unwrappedOnce() throws {
        folder.writeBoundFile(enclave)
        let store = folder.store(enclave)
        let opened = enclave.current.opened
        enclave.update { $0.refusesToOpen = true; $0.refusesToMake = true }
        let added = [HistoryEntry(text: "locked 1"), HistoryEntry(text: "locked 2")]
        for entry in added { store.add(entry, keepingAtMost: 100) }
        #expect(!store.isUnavailable)
        #expect(enclave.current.opened == opened)
        enclave.update { $0.refusesToOpen = false }
        #expect(folder.store(enclave).entries == added.reversed() + entries)
    }

    @Test("The key file disappears while the app runs: it is put back before the next save")
    func keyPutBack() throws {
        folder.writeBoundFile(enclave)
        let key = try folder.key()
        let store = folder.store(enclave)
        try FileManager.default.removeItem(at: folder.keyURL)
        store.add(HistoryEntry(text: "more"), keepingAtMost: 100)
        #expect(try folder.key() == key)
        #expect(folder.mode(folder.keyURL) == 0o600)
        #expect(folder.store(enclave).entries.count == entries.count + 1)
    }

    @Test("Another key appears while the app runs: nothing is sealed with a key that is not kept")
    func keyReplaced() throws {
        folder.writeBoundFile(enclave)
        let store = folder.store(enclave)
        let history = try folder.history()
        let other = HistoryFolder()
        other.writeBoundFile(enclave)
        let otherKey = try other.key()
        folder.write(otherKey, named: "history.key")
        store.add(HistoryEntry(text: "more"), keepingAtMost: 100)
        #expect(store.isUnavailable)
        #expect(try folder.history() == history)
        #expect(try folder.key() == otherKey)
    }

    @Test("Two instances make one key")
    func oneKey() throws {
        let first = folder.store(enclave)
        let second = folder.store(enclave)
        first.add(HistoryEntry(text: "first"), keepingAtMost: 10)
        let key = try folder.key()
        second.add(HistoryEntry(text: "second"), keepingAtMost: 10)
        #expect(try folder.key() == key)
        #expect(!folder.store(enclave).isUnavailable)
        #expect(throws: HistoryKeyError.recordExists) { try keyFile.create(Data("another".utf8)) }
        #expect(try folder.key() == key)
        #expect(folder.names == ["history.json", "history.key"])
    }

    // MARK: - Deleting

    @Test("Deleting everything removes the history, then its key; the next history has a new key")
    func deleteAll() throws {
        folder.writeBoundFile(enclave)
        let key = try folder.key()
        folder.write(Data("left by a crash".utf8), named: "history.json.writing-\(UUID().uuidString)")
        let store = folder.store(enclave)
        #expect(store.hasAnyFile)
        #expect(store.deleteAll())
        #expect(folder.names.isEmpty)
        #expect(!store.hasAnyFile)
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        #expect(try folder.key() != key)
        #expect(folder.store(enclave).entries.map(\.text) == ["new"])
    }

    @Test("A copy of the history in the folder keeps its key, set aside; the next history has its own")
    func deleteAllWithCopy() throws {
        folder.writeBoundFile(FakeEnclave()) // from another Mac, with its copy
        let history = try folder.history()
        let key = try folder.key()
        folder.write(history, named: "history.json.backup-1")
        let store = folder.store(enclave)
        #expect(store.deleteAll())
        let aside = try #require(folder.names.first { $0.hasPrefix("history.key.unused-") })
        #expect(folder.read(aside) == key)
        #expect(folder.mode(folder.directory.appendingPathComponent(aside)) == 0o600)
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        #expect(folder.store(enclave).entries.map(\.text) == ["new"])
        // The copy of another history does not hold this one's key back.
        #expect(store.deleteAll())
        #expect(folder.names == ["history.json.backup-1", aside])
        #expect(folder.read("history.json.backup-1") == history)
    }

    @Test("Something in the folder cannot be read, and could be a copy: the key is set aside")
    func deleteAllWithUnreadableFile() throws {
        folder.writeBoundFile(enclave)
        let key = try folder.key()
        folder.write(try folder.history(), named: "history.json.backup-1")
        let copy = folder.directory.appendingPathComponent("history.json.backup-1")
        chmod(copy.path, 0)
        #expect(folder.store(enclave).deleteAll())
        chmod(copy.path, 0o600)
        let aside = try #require(folder.names.first { $0.hasPrefix("history.key.unused-") })
        #expect(folder.read(aside) == key)
    }

    @Test("The enclave does not answer while a bound history is deleted: it still counts as bound")
    func deleteWhileSilent() throws {
        folder.writeBoundFile(enclave)
        let store = folder.store(enclave, timeout: 0.1)
        let gate = FakeEnclave.Gate()
        enclave.update { $0.gate = gate }
        #expect(store.deleteAll())
        gate.open()
        #expect(folder.isRecordedBound)
    }

    @Test("The history cannot be deleted: its key stays")
    func deleteFails() throws {
        folder.writeBoundFile(enclave)
        let key = try folder.key()
        let store = folder.store(enclave)
        chmod(folder.directory.path, 0o500)
        #expect(!store.deleteAll())
        chmod(folder.directory.path, 0o700)
        #expect(folder.hasHistory)
        #expect(try folder.key() == key)
        #expect(store.deleteAll())
        #expect(folder.names.isEmpty)
    }

    @Test("A crash between the two deletions: the key left is used for the next history")
    func crashBetweenDeletions() throws {
        folder.writeBoundFile(enclave)
        try FileManager.default.removeItem(at: folder.historyURL)
        let store = folder.store(enclave)
        #expect(!store.isUnavailable)
        #expect(store.hasAnyFile)
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        #expect(folder.store(enclave).entries.map(\.text) == ["new"])
    }

    @Test("The key cannot be deleted: tried again at the next launch")
    func keyDeletionRetried() throws {
        let storage = MemoryKeyStorage()
        let store = folder.store(enclave, storage: storage)
        store.replaceEntries(entries)
        storage.refusesToRemove = true
        folder.defaults.set(true, forKey: HistorySettings.offCleanupDoneKey)
        HistoryTurnOff.setEnabled(false, current: true, store: store, defaults: folder.defaults, apply: { _ in }) { _, done in done(true) }
        #expect(!folder.hasHistory)
        #expect(storage.hasRecord)
        // Next launch, history off.
        folder.defaults.set(false, forKey: HistorySettings.enabledKey)
        storage.refusesToRemove = false
        #expect(HistorySettings.runOffCleanupOnce(defaults: folder.defaults, store: folder.store(enclave, storage: storage)))
        #expect(!storage.hasRecord)
    }

    @Test("A history that cannot be read: turning history off asks, then deletes it and its key; on again, it works")
    func turnOffUnreadable() throws {
        folder.writeBoundFile(FakeEnclave()) // another Mac
        let store = folder.store(enclave)
        #expect(store.isUnavailable)

        var applied: [Bool] = []
        HistoryTurnOff.setEnabled(false, current: true, store: store, defaults: folder.defaults, apply: { applied.append($0) }) { count, done in
            #expect(count == 0)
            done(false)
        }
        #expect(applied.isEmpty)
        #expect(folder.hasHistory && folder.hasKey)

        HistoryTurnOff.setEnabled(false, current: true, store: store, defaults: folder.defaults, apply: { applied.append($0) }) { _, done in done(true) }
        #expect(applied == [false])
        #expect(folder.names.isEmpty)
        #expect(!store.isUnavailable)
        store.add(HistoryEntry(text: "new"), keepingAtMost: 10)
        #expect(folder.store(enclave).entries.map(\.text) == ["new"])
    }

    // MARK: - Where the key is kept

    @Test("The key record can be kept elsewhere: the same history file opens")
    func otherStorage() throws {
        folder.writeBoundFile(enclave)
        let history = try folder.history()
        // What a build that keeps it in the keychain would do.
        let elsewhere = MemoryKeyStorage(record: try folder.key())
        #expect(keyFile.remove())
        let store = folder.store(enclave, storage: elsewhere)
        #expect(store.entries == entries)
        #expect(try folder.history() == history)
        store.add(HistoryEntry(text: "more"), keepingAtMost: 100)
        #expect(folder.names == ["history.json"])
        #expect(folder.store(enclave, storage: elsewhere).entries.count == entries.count + 1)
    }

    // MARK: - File modes

    @Test("History and key are readable by the user only (0600), after every save and the migration")
    func modes() throws {
        folder.writeOldFile()
        chmod(folder.historyURL.path, 0o644)
        let store = folder.store(enclave)
        #expect(folder.mode(folder.historyURL) == 0o600)
        #expect(folder.mode(folder.keyURL) == 0o600)
        for index in 0..<3 {
            store.add(HistoryEntry(text: "\(index)"), keepingAtMost: 100)
            #expect(folder.mode(folder.historyURL) == 0o600)
        }
        // A file put back with a wider mode is tightened by the next save.
        chmod(folder.historyURL.path, 0o644)
        store.add(HistoryEntry(text: "again"), keepingAtMost: 100)
        #expect(folder.mode(folder.historyURL) == 0o600)
        #expect(store.deleteAll())
        store.add(HistoryEntry(text: "new"), keepingAtMost: 100)
        #expect(folder.mode(folder.historyURL) == 0o600)
        #expect(folder.mode(folder.keyURL) == 0o600)
    }

    @Test("Without a Secure Enclave too")
    func modesWithoutEnclave() {
        let store = folder.store(nil)
        for _ in 0..<2 {
            store.add(HistoryEntry(text: "text"), keepingAtMost: 10)
            #expect(folder.mode(folder.historyURL) == 0o600)
        }
    }

    @Test("The folder is made private (0700); what is in it keeps its mode")
    func folderMode() throws {
        let existing = folder.directory.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        let file = existing.appendingPathComponent("history.json.backup-1")
        try Data("backup".utf8).write(to: file)
        chmod(file.path, 0o644)
        PrivateFile.makeFolderPrivate(existing)
        #expect(folder.mode(existing) == 0o700)
        #expect(folder.mode(file) == 0o644)

        let new = folder.directory.appendingPathComponent("a/b", isDirectory: true)
        PrivateFile.makeFolderPrivate(new)
        #expect(folder.mode(new) == 0o700)

        // A link to a folder is left alone.
        chmod(existing.path, 0o755)
        let link = folder.directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: existing)
        PrivateFile.makeFolderPrivate(link)
        #expect(folder.mode(existing) == 0o755)
    }

    // MARK: - Timed calls

    @Test("A time-limited enclave has one deadline for all its calls")
    func timeLimited() throws {
        let key = try enclave.makeKey()
        let limited = TimeLimitedEnclave(base: enclave, deadline: Date().addingTimeInterval(5))
        #expect(limited.availability == true)
        _ = try limited.sharedSecret(blob: key.blob, with: key.publicKey)
        enclave.update { $0.isAvailable = false }
        #expect(limited.availability == false)
        let late = TimeLimitedEnclave(base: enclave, deadline: Date())
        #expect(late.availability == nil)
        #expect(!late.isAvailable)
        #expect(throws: HistoryKeyError.timedOut) { try late.makeKey() }
    }

    @Test("A timed call returns the result, the error, or nil when it is too long")
    func timedCall() async throws {
        #expect(try TimedCall.run(timeout: 5, { 42 })?.get() == 42)
        #expect(throws: FakeEnclave.Refused.self) {
            try TimedCall.run(timeout: 5, { () throws -> Int in throw FakeEnclave.Refused() })?.get()
        }
        let gate = FakeEnclave.Gate()
        let late = await withCheckedContinuation { continuation in
            let result = TimedCall.run(timeout: 0.05, late: { continuation.resume(returning: try? $0.get()) }, { () -> Int in
                gate.pass()
                return 7
            })
            #expect(result == nil)
            gate.open()
        }
        #expect(late == 7)
    }
}

/// The real Secure Enclave, through `MacSecureEnclave`, with invented entries in a temporary
/// folder: nothing is kept (an enclave key only exists in the file that holds its blob). Opt-in:
///
///     NANOWHISPER_ENCLAVE_TEST=1 swift test --filter HistoryEnclaveLive
@Suite("HistoryEnclaveLive", .enabled(if: ProcessInfo.processInfo.environment["NANOWHISPER_ENCLAVE_TEST"] != nil))
@MainActor
struct HistoryEnclaveLiveTests {
    @Test("Migration, launches and saves with this Mac's Secure Enclave")
    func live() throws {
        let folder = HistoryFolder()
        let enclave = MacSecureEnclave()
        try #require(enclave.isAvailable)
        func store() -> HistoryStore {
            HistoryStore(
                fileURL: folder.historyURL, key: { HistoryFolder.oldKey },
                keyring: HistoryKeyring(enclave: enclave, storage: HistoryKeyFile(besideHistoryAt: folder.historyURL)),
                defaults: folder.defaults
            )
        }
        func milliseconds(_ body: () -> Void) -> Double {
            let start = Date()
            body()
            return Date().timeIntervalSince(start) * 1000
        }
        folder.writeOldFile()
        var current: HistoryStore!
        print("enclave: migration \(milliseconds { current = store() }) ms")
        #expect(folder.isBound)
        #expect(current.entries == HistoryFixtures.entries)
        print("enclave: launch \(milliseconds { current = store() }) ms, key file \(try folder.key().count) bytes")
        #expect(current.entries == HistoryFixtures.entries)
        let added = HistoryEntry(text: "invented")
        print("enclave: save \(milliseconds { current.add(added, keepingAtMost: 100) }) ms")
        #expect(store().entries == [added] + HistoryFixtures.entries)

        #expect(folder.mode(folder.historyURL) == 0o600)
        #expect(current.deleteAll())
        #expect(folder.names.isEmpty)
    }
}
