import AppKit
import Combine
import Foundation

// MARK: - Text (pure)

/// How History words its entries: row title and preview, dates, word counts, the window's
/// subtitle and the debug info rows. Pure, so tests pin the wording.
enum HistoryText {
    static let windowTitle = "History"

    /// The first sentence (up to its `.`, `?`, `!` or `:` followed by a space or the end), and
    /// what follows it. Without such an end, the first 60 characters cut at a space.
    static func titleAndPreview(of text: String) -> (title: String, preview: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(after: index)
            if ".?!:".contains(text[index]), next == text.endIndex || text[next].isWhitespace {
                let title = String(text[...index])
                return (title, String(text[next...]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            index = next
        }
        guard text.count > 60 else { return (text, "") }
        let limit = text.index(text.startIndex, offsetBy: 60)
        let cut = text[..<limit].lastIndex(where: \.isWhitespace) ?? limit
        return (String(text[..<cut]), String(text[cut...]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    static func words(_ count: Int) -> String { count == 1 ? "1 word" : "\(count) words" }
    static func dictations(_ count: Int) -> String { count == 1 ? "1 dictation" : "\(count) dictations" }

    /// The window's subtitle.
    static func subtitle(state: HistoryWindowState, total: Int, matches: Int?) -> String {
        switch state {
        case .unavailable: return "Unavailable"
        case .off, .empty: return "Nothing kept"
        case .entries:
            guard let matches else { return dictations(total) }
            if matches == 0 { return "No matches" }
            return matches == 1 ? "1 of \(total) matches" : "\(matches) of \(total) match"
        }
    }

    /// "Keeps the last 25." (the list footer), "Last 25." when the list is narrow.
    static func keeps(_ count: Int) -> String { "Keeps the last \(count)." }
    static func keepsShort(_ count: Int) -> String { "Last \(count)." }

    // Day sections and dates

    /// The list's section title: Today, Yesterday, the weekday within the last week, then the
    /// date ("Monday 17 November"; with the year when it is not this year).
    static func dayTitle(for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 1 && days < 7 {
            return formatted(date, template: "EEEE", calendar: calendar, locale: locale)
        }
        return fullDay(date, now: now, calendar: calendar, locale: locale)
    }

    /// The detail's header: "Today at 10:42", "Wednesday 19 November at 9:58".
    static func detailDate(for date: Date, now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let day: String
        if calendar.isDate(date, inSameDayAs: now) {
            day = "Today"
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            day = "Yesterday"
        } else {
            day = fullDay(date, now: now, calendar: calendar, locale: locale)
        }
        return "\(day) at \(time(date, calendar: calendar, locale: locale))"
    }

    /// The time as the system writes it (12 or 24 hours from the user's settings).
    static func time(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return date.formatted(style)
    }

    private static func fullDay(_ date: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return formatted(date, template: sameYear ? "EEEEdMMMM" : "EEEEdMMMMy", calendar: calendar, locale: locale)
    }

    private static func formatted(_ date: Date, template: String, calendar: Calendar, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    // Debug info

    struct DebugRow: Equatable {
        let label: String
        let value: String
    }

    /// The debug card's rows. A field an older entry does not have is left out.
    static func debugRows(_ info: TranscriptionDebugInfo, locale: Locale = .current) -> [DebugRow] {
        var rows: [DebugRow] = []
        if let model = info.model { rows.append(DebugRow(label: "Model", value: model)) }
        if let code = info.language {
            let name = locale.localizedString(forLanguageCode: code) ?? WhisperLanguage.displayName(for: code)
            let how = info.languageDetected == false ? "set in Settings" : "detected"
            rows.append(DebugRow(label: "Language", value: "\(name), \(how)"))
        }
        if let audio = info.audioDuration, audio > 0 {
            rows.append(DebugRow(label: "Audio", value: duration(audio)))
        }
        if let transcription = info.transcribeDuration {
            rows.append(DebugRow(label: "Transcription", value: String(format: "%.2f s", transcription)))
        }
        if let rtf = info.rtf, rtf > 0 {
            rows.append(DebugRow(label: "Real-time factor", value: realTimeFactor(rtf)))
        }
        return rows
    }

    /// "41.6 s", "1 min 52 s".
    static func duration(_ seconds: Double) -> String {
        guard seconds >= 60 else { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        return "\(whole / 60) min \(whole % 60) s"
    }

    /// "0.014 (72× faster than real time)".
    static func realTimeFactor(_ rtf: Double) -> String {
        let factor = String(format: "%.3f", rtf)
        if rtf < 1 { return "\(factor) (\(Int((1 / rtf).rounded()))× faster than real time)" }
        if rtf > 1 { return "\(factor) (slower than real time)" }
        return "\(factor) (real time)"
    }
}

// MARK: - Search (pure)

enum HistorySearch {
    /// The query as searched: surrounding spaces ignored.
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every match of `query` in `text`, ignoring case, accents and width (what
    /// `localizedStandardContains` ignores), in order and without overlap.
    static func ranges(of query: String, in text: String, locale: Locale = .current) -> [Range<String.Index>] {
        let query = normalized(query)
        guard !query.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                     range: searchStart..<text.endIndex, locale: locale) {
            ranges.append(range)
            searchStart = range.isEmpty ? text.index(after: range.lowerBound) : range.upperBound
        }
        return ranges
    }

    static func matches(_ entry: HistoryEntry, query: String) -> Bool {
        !ranges(of: query, in: entry.text).isEmpty
    }
}

// MARK: - Model

/// Which body the window shows.
enum HistoryWindowState: Equatable {
    /// The file could not be decrypted (or encrypted): no list, no actions.
    case unavailable
    /// History is turned off (it then keeps nothing).
    case off
    /// On, nothing dictated yet.
    case empty
    case entries
}

/// What the window shows besides the entries, from the app's settings.
struct HistorySettingsSnapshot: Equatable {
    var isEnabled: Bool
    var keptCount: Int
    var showsDebugInfo: Bool
    var shortcut: Shortcut
}

/// A day of the list.
struct HistoryDaySection: Identifiable, Equatable {
    let id: Date
    let title: String
    let entries: [HistoryEntry]
}

/// The History window's state and actions. Entries come from `HistoryStore` (deleting and
/// undoing write through it); the rest from `settings`, pushed by the window controller.
@MainActor
final class HistoryWindowModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry]
    @Published private(set) var isUnavailable: Bool
    @Published var settings: HistorySettingsSnapshot
    @Published var selection: UUID?
    @Published private(set) var query = ""
    /// "Copied" on the toolbar button, for `copiedDuration` after a copy.
    @Published private(set) var showsCopied = false
    /// The "Dictation deleted · Undo ⌘Z" capsule, for `undoToastDuration` after a delete.
    @Published private(set) var showsUndoToast = false

    static let copiedDuration: TimeInterval = 1.5
    static let undoToastDuration: TimeInterval = 5

    let store: HistoryStore
    let undoManager: UndoManager
    let pasteboard: NSPasteboard
    /// The clock for Today and Yesterday (fixed in renders and tests).
    var now: () -> Date
    var calendar: Calendar
    /// Turn On (history off), and Change… (opens Settings on the pane that sets the count).
    var turnOn: () -> Void = {}
    var openSettings: () -> Void = {}
    /// Asks before Clear All; calls back with `true` to delete.
    var confirmClearAll: (_ count: Int, _ done: @escaping (Bool) -> Void) -> Void = { _, done in done(false) }
    /// Posts a VoiceOver announcement.
    var announce: (String) -> Void = { HistoryWindowModel.postAnnouncement($0) }

    private var selectionBeforeSearch: UUID?
    private var copiedReset: DispatchWorkItem?
    private var toastReset: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    init(
        store: HistoryStore, settings: HistorySettingsSnapshot,
        undoManager: UndoManager = UndoManager(), pasteboard: NSPasteboard = .general,
        now: @escaping () -> Date = Date.init, calendar: Calendar = .current
    ) {
        self.store = store
        self.entries = store.entries
        self.isUnavailable = store.isUnavailable
        self.settings = settings
        self.undoManager = undoManager
        self.pasteboard = pasteboard
        self.now = now
        self.calendar = calendar
        // `@Published` emits before the store's property changes: take the new value.
        store.$entries.dropFirst().sink { [weak self] in self?.entriesDidChange($0) }.store(in: &cancellables)
        store.$isUnavailable.dropFirst().sink { [weak self] in self?.isUnavailable = $0 }.store(in: &cancellables)
        selection = entries.first?.id
    }

    // MARK: State

    var state: HistoryWindowState {
        if isUnavailable { return .unavailable }
        if !settings.isEnabled { return .off }
        return entries.isEmpty ? .empty : .entries
    }

    var isSearching: Bool { !HistorySearch.normalized(query).isEmpty }

    /// The entries shown in the list: all, or those matching the search.
    var visibleEntries: [HistoryEntry] {
        guard isSearching else { return entries }
        return entries.filter { HistorySearch.matches($0, query: query) }
    }

    var sections: [HistoryDaySection] {
        let now = now()
        var sections: [HistoryDaySection] = []
        var current: (day: Date, entries: [HistoryEntry])?
        for entry in visibleEntries {
            let day = calendar.startOfDay(for: entry.date)
            if current?.day == day {
                current?.entries.append(entry)
            } else {
                if let current { sections.append(section(current.day, current.entries, now: now)) }
                current = (day, [entry])
            }
        }
        if let current { sections.append(section(current.day, current.entries, now: now)) }
        return sections
    }

    private func section(_ day: Date, _ entries: [HistoryEntry], now: Date) -> HistoryDaySection {
        HistoryDaySection(id: day, title: HistoryText.dayTitle(for: day, now: now, calendar: calendar), entries: entries)
    }

    var selectedEntry: HistoryEntry? {
        guard let selection else { return nil }
        return visibleEntries.first { $0.id == selection }
    }

    var subtitle: String {
        HistoryText.subtitle(state: state, total: entries.count, matches: isSearching ? visibleEntries.count : nil)
    }

    var canActOnSelection: Bool { state == .entries && selectedEntry != nil }

    // MARK: Search

    func setQuery(_ newValue: String) {
        guard newValue != query else { return }
        let wasSearching = isSearching
        if !wasSearching { selectionBeforeSearch = selection }
        query = newValue
        if isSearching {
            // The first match is selected as you type.
            selection = visibleEntries.first?.id
        } else if wasSearching {
            // Cleared (Esc): back to what was selected before.
            if let previous = selectionBeforeSearch, entries.contains(where: { $0.id == previous }) {
                selection = previous
            } else {
                selection = entries.first?.id
            }
            selectionBeforeSearch = nil
        }
    }

    /// When the window opens: no search, the newest selected (so ⌘C copies it at once).
    func prepareForOpening() {
        query = ""
        selectionBeforeSearch = nil
        selection = entries.first?.id
    }

    // MARK: Copy

    /// Copy the selected dictation to the clipboard. Only the clipboard: nothing is pasted.
    @discardableResult
    func copySelection() -> Bool {
        guard state == .entries, let entry = selectedEntry else { return false }
        copy(entry)
        return true
    }

    func copy(ids: Set<UUID>) {
        guard let entry = entries.first(where: { ids.contains($0.id) }) else { return }
        copy(entry)
    }

    private func copy(_ entry: HistoryEntry) {
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        showsCopied = true
        announce("Copied")
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.showsCopied = false }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.copiedDuration, execute: reset)
    }

    // MARK: Delete and undo

    /// Delete the selected dictation; the next one is selected. Undoable (⌘Z).
    @discardableResult
    func deleteSelection() -> Bool {
        guard state == .entries, let entry = selectedEntry else { return false }
        delete(entry)
        return true
    }

    func delete(ids: Set<UUID>) {
        guard state == .entries else { return }
        // The context menu acts on the clicked row (one at a time).
        guard let entry = visibleEntries.first(where: { ids.contains($0.id) }) else { return }
        delete(entry)
    }

    private func delete(_ entry: HistoryEntry) {
        let visible = visibleEntries
        let wasSelected = selection == entry.id
        var next: UUID?
        if let index = visible.firstIndex(where: { $0.id == entry.id }) {
            if index + 1 < visible.count {
                next = visible[index + 1].id
            } else if index > 0 {
                next = visible[index - 1].id
            }
        }
        store.replaceEntries(store.entries.filter { $0.id != entry.id })
        if wasSelected || selection == nil { selection = next }
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(entry) }
        }
        undoManager.setActionName("Delete Dictation")
        showUndoToast()
        announce("Dictation deleted")
    }

    /// Put a deleted dictation back at its place (by date) and select it. Redoable.
    private func restore(_ entry: HistoryEntry) {
        guard !store.isUnavailable, !store.entries.contains(where: { $0.id == entry.id }) else { return }
        store.insert(entry, keepingAtMost: max(settings.keptCount, store.entries.count + 1))
        selection = entry.id
        hideUndoToast()
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.delete(entry) }
        }
        undoManager.setActionName("Delete Dictation")
        announce("Dictation restored")
    }

    var canUndo: Bool { undoManager.canUndo }

    func undo() {
        guard undoManager.canUndo else { return }
        undoManager.undo()
    }

    func redo() {
        guard undoManager.canRedo else { return }
        undoManager.redo()
    }

    private func showUndoToast() {
        showsUndoToast = true
        toastReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.showsUndoToast = false }
        toastReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.undoToastDuration, execute: reset)
    }

    private func hideUndoToast() {
        toastReset?.cancel()
        showsUndoToast = false
    }

    // MARK: Clear All

    /// Asks first ("Delete all 10 dictations?"), then deletes everything. Not undoable.
    func requestClearAll() {
        guard state == .entries else { return }
        confirmClearAll(entries.count) { [weak self] confirmed in
            guard let self, confirmed else { return }
            self.store.deleteAll()
            // Nothing deleted before can be put back into a cleared history.
            self.undoManager.removeAllActions()
            self.hideUndoToast()
            self.selection = nil
        }
    }

    // MARK: Entries changed

    private func entriesDidChange(_ newEntries: [HistoryEntry]) {
        let hadSelection = selection.map { id in entries.contains { $0.id == id } } ?? false
        entries = newEntries
        // The selected entry went away by other means (trimmed, cleared): the newest.
        if hadSelection, let selection, !newEntries.contains(where: { $0.id == selection }) {
            self.selection = visibleEntries.first?.id
        }
    }

    private static func postAnnouncement(_ text: String) {
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}
