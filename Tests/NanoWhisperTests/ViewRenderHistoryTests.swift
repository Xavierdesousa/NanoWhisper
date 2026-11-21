import AppKit
import SwiftUI
import Testing
@testable import NanoWhisper

/// Renders the real History window (toolbar, split, list, detail) offscreen in every state,
/// light and dark, with invented entries (`HistoryFixtures`), never the real history. Opt-in,
/// with the other renders:
///
///     NANOWHISPER_RENDER_DIR=/tmp/renders swift test --filter ViewRender
@Suite("ViewRender History", .enabled(if: ProcessInfo.processInfo.environment["NANOWHISPER_RENDER_DIR"] != nil))
@MainActor
struct ViewRenderHistoryTests {
    private let outputDirectory = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["NANOWHISPER_RENDER_DIR"] ?? NSTemporaryDirectory()
    )

    @Test("History window states, light and dark")
    func historyStates() throws {
        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            try render("history-entries\(suffix)", HistoryFixtures.model(), dark: dark)

            let long = HistoryFixtures.model()
            long.selection = HistoryFixtures.entries[3].id
            try render("history-long\(suffix)", long, dark: dark)

            let none = HistoryFixtures.model()
            none.selection = nil
            try render("history-no-selection\(suffix)", none, dark: dark)

            let copied = HistoryFixtures.model()
            copied.copySelection()
            try render("history-copied\(suffix)", copied, dark: dark)

            let deleted = HistoryFixtures.model()
            deleted.deleteSelection()
            try render("history-deleted-undo\(suffix)", deleted, dark: dark)

            let debug = HistoryFixtures.model(settings: HistoryFixtures.settings(debug: true))
            try render("history-debug-parakeet\(suffix)", debug, dark: dark)
            let whisper = HistoryFixtures.model(settings: HistoryFixtures.settings(debug: true))
            whisper.selection = HistoryFixtures.entries[2].id
            try render("history-debug-whisper\(suffix)", whisper, dark: dark)
            let older = HistoryFixtures.model(settings: HistoryFixtures.settings(debug: true))
            older.selection = HistoryFixtures.entries[6].id
            try render("history-debug-older-entry\(suffix)", older, dark: dark)

            let search = HistoryFixtures.model()
            search.setQuery("migration")
            try render("history-search\(suffix)", search, dark: dark, search: "migration")
            try render("history-search-narrow\(suffix)", search, dark: dark, size: HistoryWindow.minimumContentSize, search: "migration")

            let noResults = HistoryFixtures.model()
            noResults.setQuery("kubernetes")
            try render("history-no-results\(suffix)", noResults, dark: dark, search: "kubernetes")

            try render("history-empty\(suffix)", HistoryFixtures.model(store: HistoryFixtures.store([])), dark: dark)
            try render("history-off\(suffix)", HistoryFixtures.model(
                store: HistoryFixtures.store([]), settings: HistoryFixtures.settings(isEnabled: false)), dark: dark)
            try render("history-unavailable\(suffix)", HistoryFixtures.model(store: HistoryFixtures.unavailableStore()), dark: dark)
            try render("history-narrow\(suffix)", HistoryFixtures.model(), dark: dark, size: HistoryWindow.minimumContentSize)

            try renderAlert("history-alert-clear-all\(suffix)", HistoryAlerts.clearAllAlert(count: 10), dark: dark)
            try renderAlert("history-alert-turn-off\(suffix)", HistoryAlerts.turnOffAlert(count: 10), dark: dark)
        }
    }

    // MARK: - Helpers

    private func render(
        _ name: String, _ model: HistoryWindowModel, dark: Bool,
        size: NSSize = HistoryWindow.defaultContentSize, search: String? = nil
    ) throws {
        _ = NSApplication.shared
        let window = HistoryWindow(model: model)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(size)
        window.refresh()
        if let search { window.toolbarController.searchToolbarItem?.searchField.stringValue = search }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        window.refresh()
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try write(rep, name)
        window.close()
    }

    private func renderAlert(_ name: String, _ alert: NSAlert, dark: Bool) throws {
        _ = NSApplication.shared
        alert.window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        alert.icon = Fixtures.appIcon
        alert.layout()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let frameView = try #require(alert.window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try write(rep, name)
    }

    private func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}
