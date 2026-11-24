import Carbon
import Foundation
import Testing
@testable import NanoWhisper

/// Reading the stored shortcut. A throwaway defaults domain only.
@Suite("Stored shortcut")
final class ShortcutStorageTests {
    private let suiteName = "nanowhisper.tests.shortcut.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suiteName))
    }

    deinit {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func store(keyCode: Any?, modifiers: Any?) {
        defaults.set(keyCode, forKey: "shortcut_keyCode")
        defaults.set(modifiers, forKey: "shortcut_modifiers")
    }

    @Test("Nothing stored: the default")
    func nothingStored() {
        #expect(Shortcut.load(from: defaults) == .default)
    }

    @Test("What the recorder can store is read back: any key with at least one modifier", arguments: [
        (kVK_Space, optionKey), (kVK_F5, cmdKey | shiftKey | optionKey | controlKey), (kVK_ANSI_A, shiftKey),
        (kVK_F13, controlKey), (kVK_ANSI_A, cmdKey), // key code 0
    ])
    func roundTrip(keyCode: Int, modifiers: Int) {
        let shortcut = Shortcut(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
        shortcut.save(to: defaults)
        #expect(Shortcut.load(from: defaults) == shortcut)
    }

    @Test("Out of range: the default", arguments: [
        (-1, optionKey), (kVK_Space, -1), (65536, optionKey), (Int(UInt32.max) + 1, optionKey),
        (kVK_Space, Int(UInt32.max) + 1), (Int.min, Int.max),
    ])
    func outOfRange(keyCode: Int, modifiers: Int) {
        store(keyCode: keyCode, modifiers: modifiers)
        #expect(Shortcut.load(from: defaults) == .default)
    }

    @Test("No modifier (or none of the four): the default", arguments: [0, alphaLock, 1])
    func noModifier(modifiers: Int) {
        store(keyCode: kVK_F5, modifiers: modifiers)
        #expect(Shortcut.load(from: defaults) == .default)
        store(keyCode: kVK_F5, modifiers: nil)
        #expect(Shortcut.load(from: defaults) == .default)
    }

    @Test("Not numbers: the default")
    func notNumbers() {
        store(keyCode: ["a"], modifiers: "x")
        #expect(Shortcut.load(from: defaults) == .default)
    }
}
