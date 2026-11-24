import AppKit
import Carbon
import SwiftUI
import Testing
@testable import NanoWhisper

/// The History window's model (search, selection, copy, delete and undo), its wording, and
/// its keys, with invented entries (`HistoryFixtures`) and a private pasteboard.
@Suite("History window")
@MainActor
struct HistoryWindowTests {
    private let entries = HistoryFixtures.entries

    // MARK: - Search

    @Test("Search ignores case and accents and finds every match")
    func searchRanges() {
        let text = "Migration first; then two MIGRATIONS. Étapes, etapes."
        let migration = HistorySearch.ranges(of: "migration", in: text)
        #expect(migration.map { String(text[$0]) } == ["Migration", "MIGRATION"])
        #expect(HistorySearch.ranges(of: "etape", in: text).map { String(text[$0]) } == ["Étape", "etape"])
        #expect(HistorySearch.ranges(of: "  migration ", in: text).count == 2)
        #expect(HistorySearch.ranges(of: "", in: text).isEmpty)
        #expect(HistorySearch.ranges(of: "   ", in: text).isEmpty)
        #expect(HistorySearch.ranges(of: "kubernetes", in: text).isEmpty)
    }

    @Test("Matches get the find highlight, nothing else does")
    func highlight() {
        let attributed = HistoryStyle.highlighted("Draft the migration guide, then the Migration.", query: "migration")
        let highlighted = attributed.runs.filter { $0.backgroundColor != nil }.map { String(attributed[$0.range].characters) }
        #expect(highlighted == ["migration", "Migration"])
        #expect(HistoryStyle.highlighted("nothing here", query: "migration").runs.allSatisfy { $0.backgroundColor == nil })
    }

    @Test("Searching filters, selects the first match; clearing brings the selection back")
    func searchSelection() {
        let model = HistoryFixtures.model()
        model.selection = entries[4].id
        model.setQuery("migration")
        #expect(model.visibleEntries.map(\.id) == [entries[2].id, entries[8].id])
        #expect(model.selection == entries[2].id)
        #expect(model.subtitle == "2 of 10 match")

        model.setQuery("kubernetes")
        #expect(model.visibleEntries.isEmpty)
        #expect(model.selection == nil)
        #expect(model.subtitle == "No matches")

        model.setQuery("")
        #expect(model.selection == entries[4].id)
        #expect(model.subtitle == "10 dictations")
    }

    // MARK: - Copy

    @Test("Copy puts the selected dictation on the pasteboard, and only there")
    func copyOnlyToPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nanowhisper.tests.copy.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let store = HistoryFixtures.store()
        let model = HistoryFixtures.model(store: store, pasteboard: pasteboard)
        var announced: [String] = []
        model.announce = { announced.append($0) }
        let before = store.entries

        #expect(model.copySelection())
        #expect(pasteboard.string(forType: .string) == entries[0].text)
        #expect(pasteboard.pasteboardItems?.count == 1)
        #expect(model.showsCopied)
        #expect(announced == ["Copied"])
        #expect(store.entries == before)

        model.copy(ids: [entries[3].id])
        #expect(pasteboard.string(forType: .string) == entries[3].text)

        model.selection = nil
        #expect(!model.copySelection())
    }

    // MARK: - Delete and undo

    @Test("Deleting one dictation asks first; Cancel keeps it, and undo/redo never ask")
    func deleteAsksFirst() {
        let store = HistoryFixtures.store()
        let model = HistoryFixtures.model(store: store)
        var asked = 0
        var answer = false
        model.confirmDelete = { done in asked += 1; done(answer) }
        model.selection = entries[1].id

        #expect(model.deleteSelection())
        #expect(asked == 1)
        #expect(store.entries.count == entries.count)
        #expect(!model.canUndo)

        model.delete(ids: [entries[0].id])
        #expect(asked == 2)
        #expect(store.entries.count == entries.count)

        answer = true
        model.deleteSelection()
        #expect(asked == 3)
        #expect(!store.entries.contains { $0.id == entries[1].id })
        model.undo()
        model.redo()
        #expect(asked == 3)
    }

    @Test("The delete alert says how to undo, and Escape cancels")
    func deleteAlertText() {
        let alert = HistoryAlerts.deleteOneAlert()
        #expect(alert.messageText == "Delete this dictation?")
        #expect(alert.informativeText.contains("⌘Z"))
        #expect(alert.buttons.map(\.title) == ["Delete", "Cancel"])
        #expect(alert.buttons[0].hasDestructiveAction)
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
    }

    @Test("Deleting selects the next one; undo puts it back at its place and selects it; redo deletes again")
    func deleteUndoRedo() {
        let store = HistoryFixtures.store()
        let model = HistoryFixtures.model(store: store)
        model.selection = entries[1].id

        #expect(model.deleteSelection())
        #expect(store.entries.map(\.id) == entries.filter { $0.id != entries[1].id }.map(\.id))
        #expect(model.selection == entries[2].id)
        #expect(model.showsUndoToast)
        #expect(model.canUndo)

        model.undo()
        #expect(store.entries.map(\.id) == entries.map(\.id))
        #expect(model.selection == entries[1].id)
        #expect(!model.showsUndoToast)

        model.redo()
        #expect(!store.entries.contains { $0.id == entries[1].id })
        model.undo()
        #expect(store.entries.map(\.id) == entries.map(\.id))
    }

    @Test("Deleting the last one selects the one before; deleting while searching selects the next match")
    func deleteEdges() {
        let model = HistoryFixtures.model()
        model.selection = entries[9].id
        model.deleteSelection()
        #expect(model.selection == entries[8].id)

        let searching = HistoryFixtures.model()
        searching.setQuery("migration")
        searching.deleteSelection()
        #expect(searching.selection == entries[8].id)
        #expect(searching.visibleEntries.map(\.id) == [entries[8].id])
    }

    @Test("Several deletes undo in reverse order, each at its place")
    func multipleUndo() {
        let store = HistoryFixtures.store()
        let model = HistoryFixtures.model(store: store)
        model.selection = entries[0].id
        // Each key press is its own undo step: the run loop's groups in the app
        // (`groupsByEvent`), explicit ones here. Spinning the run loop does not always close a
        // group when other main-actor tests run inside it.
        model.undoManager.groupsByEvent = false
        for _ in 0..<2 {
            model.undoManager.beginUndoGrouping()
            model.deleteSelection()
            model.undoManager.endUndoGrouping()
        }
        #expect(store.entries.first?.id == entries[2].id)
        model.undo()
        #expect(store.entries.first?.id == entries[1].id)
        model.undo()
        #expect(store.entries.map(\.id) == entries.map(\.id))
        #expect(model.selection == entries[0].id)
    }

    @Test("Turning history off drops the undo of a delete, even once it is on again")
    func offDropsUndo() {
        let store = HistoryFixtures.store()
        let model = HistoryFixtures.model(store: store)
        model.deleteSelection()
        #expect(model.canUndo)
        store.deleteAll()
        model.settings.isEnabled = false
        #expect(!model.canUndo)
        #expect(!model.showsUndoToast)
        model.settings.isEnabled = true
        model.undo()
        #expect(store.entries.isEmpty)
    }

    @Test("Clear All asks first; confirmed, everything is deleted and there is nothing to undo")
    func clearAll() {
        let store = HistoryFixtures.store()
        let model = HistoryFixtures.model(store: store)
        model.deleteSelection()
        var asked: Int?
        model.confirmClearAll = { count, done in asked = count; done(false) }
        model.requestClearAll()
        #expect(asked == 9)
        #expect(store.entries.count == 9)

        model.confirmClearAll = { _, done in done(true) }
        model.requestClearAll()
        #expect(store.entries.isEmpty)
        #expect(!store.hasFile)
        #expect(!model.canUndo)
        #expect(model.state == .empty)
    }

    // MARK: - States

    @Test("States and subtitles: entries, empty, off, unavailable")
    func states() {
        #expect(HistoryFixtures.model().state == .entries)
        let empty = HistoryFixtures.model(store: HistoryFixtures.store([]))
        #expect(empty.state == .empty)
        #expect(empty.subtitle == "Nothing kept")
        let off = HistoryFixtures.model(settings: HistoryFixtures.settings(isEnabled: false))
        #expect(off.state == .off)
        #expect(!off.copySelection())
        #expect(!off.deleteSelection())
        let unavailable = HistoryFixtures.model(store: HistoryFixtures.unavailableStore())
        #expect(unavailable.state == .unavailable)
        #expect(unavailable.subtitle == "Unavailable")
        #expect(HistoryText.subtitle(state: .entries, total: 1, matches: nil) == "1 dictation")
        #expect(HistoryText.subtitle(state: .entries, total: 10, matches: 1) == "1 of 10 matches")
    }

    @Test("A file in the older format: Use This History shows it; a failure says so and changes nothing")
    func olderFormat() {
        let enclave = FakeEnclave()
        let (folder, store) = HistoryFixtures.olderFormatStore(enclave: enclave)
        let model = HistoryFixtures.model(store: store)
        var failures = 0
        model.showUseOlderFailed = { failures += 1 }
        #expect(model.state == .unavailable)
        #expect(model.unavailableReason == .olderFormat)
        #expect(model.subtitle == "Unavailable")

        enclave.update { $0.refusesToOpen = true }
        model.useOlderFile()
        #expect(failures == 1)
        #expect(model.unavailableReason == .olderFormat)

        enclave.update { $0.refusesToOpen = false }
        model.useOlderFile()
        #expect(failures == 1)
        #expect(model.state == .entries)
        #expect(model.entries == HistoryFixtures.entries)
        #expect(model.selection == HistoryFixtures.entries[0].id)
        #expect(folder.isBound)

        // Only for an older file.
        let unreadable = HistoryFixtures.model(store: HistoryFixtures.unavailableStore())
        unreadable.showUseOlderFailed = { failures += 1 }
        unreadable.useOlderFile()
        #expect(failures == 1)
        #expect(unreadable.state == .unavailable)
    }

    @Test("The newest is selected when the window opens")
    func openingSelection() {
        let model = HistoryFixtures.model()
        model.setQuery("review")
        model.selection = nil
        model.prepareForOpening()
        #expect(model.query.isEmpty)
        #expect(model.selection == entries[0].id)
    }

    @Test("Day sections: Today, Yesterday, then the weekday")
    func sections() {
        let model = HistoryFixtures.model()
        #expect(model.sections.map(\.title) == ["Today", "Yesterday", "Thursday", "Tuesday"])
        #expect(model.sections.map(\.entries.count) == [3, 4, 2, 1])
    }

    // MARK: - Wording

    @Test("Row title is the first sentence; the rest is the preview")
    func titleAndPreview() {
        #expect(HistoryText.titleAndPreview(of: "Good morning. Today we finish.") == ("Good morning.", "Today we finish."))
        #expect(HistoryText.titleAndPreview(of: "Is it 3.5 or 4? Tell me.") == ("Is it 3.5 or 4?", "Tell me."))
        #expect(HistoryText.titleAndPreview(of: "Constraints: offline first") == ("Constraints:", "offline first"))
        #expect(HistoryText.titleAndPreview(of: "short note") == ("short note", ""))
        let long = String(repeating: "word ", count: 20)
        let parts = HistoryText.titleAndPreview(of: long)
        #expect(parts.title.count <= 60)
        #expect(!parts.title.hasSuffix(" "))
        #expect((parts.title + " " + parts.preview) == long.trimmingCharacters(in: .whitespaces))
    }

    @Test("Dates: Today, Yesterday, weekday within a week, then the date")
    func dates() {
        let calendar = HistoryFixtures.calendar
        let locale = Locale(identifier: "en_GB")
        let now = HistoryFixtures.now
        func daysAgo(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: now)! }
        #expect(HistoryText.dayTitle(for: daysAgo(0), now: now, calendar: calendar, locale: locale) == "Today")
        #expect(HistoryText.dayTitle(for: daysAgo(1), now: now, calendar: calendar, locale: locale) == "Yesterday")
        #expect(HistoryText.dayTitle(for: daysAgo(2), now: now, calendar: calendar, locale: locale) == "Thursday")
        #expect(HistoryText.dayTitle(for: daysAgo(6), now: now, calendar: calendar, locale: locale) == "Sunday")
        #expect(HistoryText.dayTitle(for: daysAgo(7), now: now, calendar: calendar, locale: locale) == "Saturday 14 November")
        // Another year: with the year (the locale's punctuation).
        let older = HistoryText.dayTitle(for: daysAgo(400), now: now, calendar: calendar, locale: locale)
        #expect(older.hasPrefix("Friday") && older.hasSuffix("17 October 2025"))
        let at = calendar.date(bySettingHour: 10, minute: 42, second: 0, of: now)!
        #expect(HistoryText.detailDate(for: at, now: now, calendar: calendar, locale: locale) == "Today at 10:42")
        #expect(HistoryText.detailDate(for: daysAgo(2), now: now, calendar: calendar, locale: locale) == "Thursday 19 November at 11:00")
        #expect(HistoryText.words(1) == "1 word")
        #expect(HistoryText.wordCount("  one two\nthree ") == 3)
    }

    @Test("Debug rows: model, language for Whisper, audio, transcription, real-time factor")
    func debugRows() {
        let whisper = TranscriptionDebugInfo(audioDuration: 34.2, transcribeDuration: 2.91, rtf: 2.91 / 34.2,
                                             model: "Whisper Large v3 Turbo", language: "fr", languageDetected: true)
        #expect(HistoryText.debugRows(whisper, locale: Locale(identifier: "en_GB")) == [
            .init(label: "Model", value: "Whisper Large v3 Turbo"),
            .init(label: "Language", value: "French, detected"),
            .init(label: "Audio", value: "34.2 s"),
            .init(label: "Transcription", value: "2.91 s"),
            .init(label: "Real-time factor", value: "0.085 (12× faster than real time)"),
        ])
        var set = whisper
        set.languageDetected = false
        #expect(HistoryText.debugRows(set, locale: Locale(identifier: "en_GB"))[1].value == "French, set in Settings")
        let parakeet = TranscriptionDebugInfo(audioDuration: 112.4, transcribeDuration: 1.41, rtf: 1.41 / 112.4, model: "Parakeet Ultra")
        #expect(HistoryText.debugRows(parakeet).map(\.label) == ["Model", "Audio", "Transcription", "Real-time factor"])
        #expect(HistoryText.duration(112.4) == "1 min 52 s")
        #expect(HistoryText.realTimeFactor(1.5) == "1.500 (slower than real time)")
    }

    // MARK: - Keys

    @Test("Key routing: ⌘C, ⌫, ⌘Z, ⌘F go to History unless text has the focus")
    func keyRouting() {
        typealias R = HistoryKeyRouting
        func route(_ key: String, _ code: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags = .command, _ focus: R.Focus = .list) -> R.Route {
            R.route(key: key, keyCode: code, modifiers: modifiers, focus: focus)
        }
        #expect(route("c") == .history(.copy))
        #expect(route("C", 0, [.command, .capsLock]) == .history(.copy))
        #expect(route("c", 0, .command, .text(hasSelection: true)) == .textAction("copy:"))
        #expect(route("c", 0, .command, .text(hasSelection: false)) == .history(.copy))
        #expect(route("c", 0, .command, .searchField(hasSelection: true)) == .textAction("copy:"))
        #expect(route("c", 0, .command, .searchField(hasSelection: false)) == .history(.copy))
        #expect(route("\u{7f}", 51, []) == .history(.delete))
        #expect(route("\u{f728}", 117, [.function]) == .history(.delete))
        #expect(route("\u{7f}", 51, [], .searchField(hasSelection: false)) == .pass)
        #expect(route("\u{7f}", 51, [], .text(hasSelection: true)) == .history(.delete))
        #expect(route("\u{7f}", 51, .command) == .pass)
        #expect(route("z") == .history(.undo))
        #expect(route("z", 0, .command, .searchField(hasSelection: false)) == .history(.undo))
        #expect(route("z", 0, [.command, .shift]) == .history(.redo))
        #expect(route("f") == .history(.find))
        #expect(route("w") == .history(.close))
        #expect(route("a") == .pass)
        #expect(route("a", 0, .command, .searchField(hasSelection: false)) == .textAction("selectAll:"))
        #expect(route("v", 0, .command, .searchField(hasSelection: false)) == .textAction("paste:"))
        #expect(route("v") == .pass)
        #expect(route("x", 0, .command, .text(hasSelection: true)) == .pass)
        #expect(route("q") == .pass)
        #expect(route("c", 0, [.command, .option]) == .pass)
    }

    private func key(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ))
    }

    @Test("The real window handles ⌘C, ⌫, ⌘Z and ⌘F itself (no menu bar needed)")
    func windowKeys() throws {
        _ = NSApplication.shared
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("nanowhisper.tests.keys.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let store = HistoryFixtures.store()
        let model = HistoryFixtures.model(store: store, pasteboard: pasteboard)
        let window = HistoryWindow(model: model)
        defer { window.close() }
        // The window asks with a modal alert; answer it here (the alert is tested on its own).
        var deleteAsked = 0
        model.confirmDelete = { done in deleteAsked += 1; done(true) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        #expect(window.undoManager === model.undoManager)

        // ⌘C: a key equivalent.
        #expect(window.performKeyEquivalent(with: try key("c", UInt16(kVK_ANSI_C), .command, window: window)))
        #expect(pasteboard.string(forType: .string) == entries[0].text)

        // ⌫: a plain key down, through sendEvent.
        window.sendEvent(try key("\u{7f}", UInt16(kVK_Delete), [], window: window))
        #expect(deleteAsked == 1)
        #expect(store.entries.first?.id == entries[1].id)
        #expect(model.selection == entries[1].id)

        // ⌘Z puts it back.
        #expect(window.performKeyEquivalent(with: try key("z", UInt16(kVK_ANSI_Z), .command, window: window)))
        #expect(store.entries.map(\.id) == entries.map(\.id))

        // ⌘F: the search field takes the focus; then ⌫ edits the search, not the history.
        #expect(window.performKeyEquivalent(with: try key("f", UInt16(kVK_ANSI_F), .command, window: window)))
        let field = try #require(window.toolbarController.searchToolbarItem?.searchField)
        #expect((window.firstResponder as? NSTextView)?.delegate === field)
        #expect(window.keyFocus == .searchField(hasSelection: false))
        window.sendEvent(try key("\u{7f}", UInt16(kVK_Delete), [], window: window))
        #expect(store.entries.count == entries.count)
    }

    @Test("Toolbar: Copy first, then Delete, then search; tooltips name the shortcuts")
    func toolbar() throws {
        _ = NSApplication.shared
        let window = HistoryWindow(model: HistoryFixtures.model())
        defer { window.close() }
        let identifiers = window.toolbar?.items.map(\.itemIdentifier)
        #expect(identifiers == [.flexibleSpace, HistoryToolbarController.actionsItem, HistoryToolbarController.searchItem])
        let actions = window.toolbarController.actions
        #expect(actions.label(forSegment: 0) == "Copy")
        #expect(actions.toolTip(forSegment: 0) == "Copy the selected dictation (⌘C)")
        #expect(actions.toolTip(forSegment: 1) == "Delete the selected dictation (⌫)")
        #expect(window.toolbarController.searchToolbarItem?.toolTip == "Search (⌘F)")
        #expect(window.title == "History")
        #expect(window.subtitle == "10 dictations")
        #expect(window.contentMinSize == NSSize(width: 640, height: 420))

        window.model.copySelection()
        window.refresh()
        #expect(actions.label(forSegment: 0) == "Copied")
        window.model.selection = nil
        window.refresh()
        #expect(!actions.isEnabled(forSegment: 1))
    }
}
