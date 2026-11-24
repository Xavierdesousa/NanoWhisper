import AppKit
import SwiftUI

// The History window's SwiftUI parts: the list (left), the detail (right) and the full-window
// messages (empty, off, unavailable). The window, toolbar and split are AppKit
// (`HistoryWindowController`). Design: "History, list and detail" boards (approved 2026-11-21).

// MARK: - Style

enum HistoryStyle {
    static let listWidth: CGFloat = 300
    static let listMinWidth: CGFloat = 250
    static let listMaxWidth: CGFloat = 420
    static let detailMinWidth: CGFloat = 380
    static let footerHeight: CGFloat = 34
    static let detailTextWidth: CGFloat = 540

    /// The find highlight behind a match: yellow at 50 % (light) / 36 % (dark); on a selected
    /// row (accent behind white text) white at 28 %.
    static let matchHighlight = Color(nsColor: NSColor(name: "nwHistoryMatch") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 214 / 255, blue: 10 / 255, alpha: 0.36)
            : NSColor(srgbRed: 1, green: 204 / 255, blue: 0, alpha: 0.5)
    })
    static let selectedMatchHighlight = Color.white.opacity(0.28)

    /// `text` with every match of `query` on the find highlight.
    static func highlighted(_ text: String, query: String, on selectedRow: Bool = false) -> AttributedString {
        var attributed = AttributedString(text)
        for range in HistorySearch.ranges(of: query, in: text) {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed) else { continue }
            attributed[lower..<upper].backgroundColor = selectedRow ? selectedMatchHighlight : matchHighlight
        }
        return attributed
    }
}

// MARK: - List

struct HistoryListView: View {
    @ObservedObject var model: HistoryWindowModel

    var body: some View {
        VStack(spacing: 0) {
            if model.visibleEntries.isEmpty {
                Text("No Results")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Rectangle().fill(GroupedStyle.separator).frame(height: 1)
            HistoryListFooter(model: model)
        }
        .frame(minWidth: HistoryStyle.listMinWidth)
    }

    private var list: some View {
        List(selection: $model.selection) {
            // Day titles as plain rows rather than `Section`s: the inset style puts a large gap
            // and a line under each section header.
            ForEach(model.sections) { section in
                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, section.id == model.sections.first?.id ? 0 : 8)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                    .accessibilityAddTraits(.isHeader)
                ForEach(section.entries) { entry in
                    HistoryRow(entry: entry, query: model.query, now: model.now(), calendar: model.calendar)
                        .tag(entry.id)
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: UUID.self) { ids in
            if !ids.isEmpty {
                Button("Copy") { model.copy(ids: ids) }
                    .keyboardShortcut("c", modifiers: .command)
                Button("Delete") { model.delete(ids: ids) }
                    .keyboardShortcut(.delete, modifiers: [])
                Divider()
            }
            Button("Clear All…") { model.requestClearAll() }
        }
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let query: String
    let now: Date
    let calendar: Calendar
    /// Increased on a selected row with the list focused (accent behind white text).
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let parts = HistoryText.titleAndPreview(of: entry.text)
        let selected = prominence == .increased
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(HistoryStyle.highlighted(parts.title, query: query, on: selected))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(HistoryText.time(entry.date, calendar: calendar))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !parts.preview.isEmpty {
                Text(HistoryStyle.highlighted(parts.preview, query: query, on: selected))
                    .font(.system(size: 12))
                    .lineSpacing(1)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(HistoryText.dayTitle(for: entry.date, now: now, calendar: calendar)) \(HistoryText.time(entry.date, calendar: calendar)), \(parts.title)"
        )
    }
}

/// "Keeps the last 25. Change…" and "Clear All…" under the list ("Last 25." when narrow).
struct HistoryListFooter: View {
    @ObservedObject var model: HistoryWindowModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(HistoryText.keeps(model.settings.keptCount))
            row(HistoryText.keepsShort(model.settings.keptCount))
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: HistoryStyle.footerHeight)
    }

    private func row(_ keeps: String) -> some View {
        HStack(spacing: 6) {
            Text(keeps)
                .foregroundStyle(.secondary)
                .fixedSize()
            Button("Change…") { model.openSettings() }
                .buttonStyle(.link)
                .fixedSize()
                .help("Open Settings › General, where the number kept is set")
            Spacer(minLength: 12)
            Button("Clear All…") { model.requestClearAll() }
                .buttonStyle(.link)
                .fixedSize()
                .disabled(model.state != .entries)
        }
    }
}

// MARK: - Detail

struct HistoryDetailView: View {
    @ObservedObject var model: HistoryWindowModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if let entry = model.selectedEntry {
                HistoryEntryDetail(
                    entry: entry, query: model.query, showsDebugInfo: model.settings.showsDebugInfo,
                    now: model.now(), calendar: model.calendar
                )
                .id(entry.id)
            } else {
                HistoryShortcutsHint()
            }
            if model.showsUndoToast {
                HistoryUndoToast(undo: model.undo)
                    .padding(.bottom, 16)
                    .transition(.opacity)
            }
        }
        .frame(minWidth: HistoryStyle.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.2), value: model.showsUndoToast)
    }
}

struct HistoryEntryDetail: View {
    let entry: HistoryEntry
    let query: String
    let showsDebugInfo: Bool
    let now: Date
    let calendar: Calendar

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("\(HistoryText.detailDate(for: entry.date, now: now, calendar: calendar)) · \(HistoryText.words(HistoryText.wordCount(entry.text)))")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(HistoryStyle.highlighted(entry.text, query: query))
                    .font(.system(size: 14.5))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: HistoryStyle.detailTextWidth, alignment: .leading)
                    .padding(.top, 12)
                if showsDebugInfo, let info = entry.debugInfo {
                    let rows = HistoryText.debugRows(info)
                    if !rows.isEmpty {
                        HistoryDebugCard(rows: rows)
                            .frame(maxWidth: HistoryStyle.detailTextWidth, alignment: .leading)
                            .padding(.top, 22)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 34)
            .padding(.top, 22)
            .padding(.bottom, 64)
        }
    }
}

/// "Debug info": a card (the shared `groupedCard()`), label and value per row.
struct HistoryDebugCard: View {
    let rows: [HistoryText.DebugRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Debug info")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(rows, id: \.label) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .frame(width: 110, alignment: .leading)
                        Text(row.value)
                            .textSelection(.enabled)
                    }
                }
            }
            .font(.system(size: 12))
            .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .groupedCard()
        .accessibilityElement(children: .combine)
    }
}

/// Nothing selected: the four shortcuts, in the flat key boxes of Settings.
struct HistoryShortcutsHint: View {
    static let shortcuts: [(keys: [ShortcutKey], text: String)] = [
        ([.init(glyph: "⌘", spokenName: "Command"), .init(glyph: "C", spokenName: "C")], "Copy the selected dictation"),
        ([.init(glyph: "⌫", spokenName: "Delete")], "Delete it"),
        ([.init(glyph: "⌘", spokenName: "Command"), .init(glyph: "Z", spokenName: "Z")], "Undo a delete"),
        ([.init(glyph: "⌘", spokenName: "Command"), .init(glyph: "F", spokenName: "F")], "Search"),
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("No dictation selected")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(Self.shortcuts, id: \.text) { shortcut in
                    GridRow {
                        KeyCaps(keys: shortcut.keys)
                            .gridColumnAlignment(.trailing)
                        Text(shortcut.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(shortcut.keys.map(\.spokenName).joined(separator: " ")): \(shortcut.text)")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Key boxes for keys that are not a `Shortcut` (⌘C, ⌫).
struct KeyCaps: View {
    let keys: [ShortcutKey]
    var size: KeyCapSize = .regular

    var body: some View {
        HStack(spacing: size.spacing) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                KeyCapView(glyph: key.glyph, size: size)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keys.map(\.spokenName).joined(separator: " "))
    }
}

/// "Dictation deleted · Undo ⌘Z", for 5 s after a delete (⌘Z keeps working after it).
struct HistoryUndoToast: View {
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("Dictation deleted")
            Button(action: undo) {
                HStack(spacing: 6) {
                    Text("Undo").fontWeight(.medium)
                    KeyCaps(keys: [.init(glyph: "⌘", spokenName: "Command"), .init(glyph: "Z", spokenName: "Z")], size: .small)
                }
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Undo")
        }
        .font(.system(size: 12.5))
        .padding(.leading, 14)
        .padding(.trailing, 5)
        .frame(height: 34)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 9, y: 4)
        .fixedSize()
    }
}

// MARK: - Full-window messages

/// History empty, off, or unavailable: one message instead of the list and detail.
struct HistoryMessageView: View {
    @ObservedObject var model: HistoryWindowModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                switch model.state {
                case .unavailable where model.unavailableReason == .olderFormat:
                    message(symbol: "lock.open", title: HistoryText.olderFormatTitle, text: HistoryText.olderFormat)
                    Button("Use This History", action: model.useOlderFile)
                        .padding(.top, 16)
                case .unavailable:
                    message(symbol: "lock", title: HistoryText.unreadableTitle, text: HistoryText.unreadable)
                    message(HistoryText.unreadableForGood)
                case .off:
                    message(symbol: "pause.circle", title: "History is off",
                            text: "Dictations are pasted but not kept. Turn it on to find them here later, encrypted on this Mac.")
                    Button("Turn On", action: model.turnOn)
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 16)
                case .empty, .entries:
                    message(symbol: "clock.arrow.circlepath", title: "No dictations yet",
                            text: "What you dictate appears here, newest first.")
                    HStack(spacing: 5) {
                        Text("Press")
                        ShortcutKeysView(shortcut: model.settings.shortcut)
                        Text("in any app to start.")
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The last dictation deleted: the list is gone, the Undo capsule stays.
            .overlay(alignment: .bottom) {
                if model.showsUndoToast && model.state == .empty {
                    HistoryUndoToast(undo: model.undo).padding(.bottom, 16)
                }
            }
            if model.state == .empty {
                Rectangle().fill(GroupedStyle.separator).frame(height: 1)
                HStack(spacing: 6) {
                    Text(HistoryText.keeps(model.settings.keptCount))
                        .foregroundStyle(.secondary)
                    Button("Change…") { model.openSettings() }
                        .buttonStyle(.link)
                    Spacer()
                }
                .font(.system(size: 11.5))
                .padding(.horizontal, 16)
                .frame(height: 38)
            }
        }
    }

    @ViewBuilder
    private func message(symbol: String, title: String, text: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 40, weight: .light))
            .foregroundStyle(.tertiary)
            .padding(.bottom, 14)
            .accessibilityHidden(true)
        Text(title)
            .font(.system(size: 17, weight: .semibold))
            .multilineTextAlignment(.center)
        message(text)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 380)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 6)
    }
}
