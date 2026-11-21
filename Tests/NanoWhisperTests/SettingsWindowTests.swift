import AppKit
import SwiftUI
import Testing
@testable import NanoWhisper

/// The real Settings window, shown on screen while panes are switched. Opt-in, because it shows
/// a window:
///
///     NANOWHISPER_WINDOW_TESTS=1 swift test --filter SettingsWindow
///
/// With `NANOWHISPER_CAPTURE_DIR=<dir>` too, frames are saved as PNGs in
/// `<dir>/settings-switch/`: the settled window after each switch, the window forced through
/// the heights of a resize animation, and frames of the real animation.
///
/// AppKit animations complete only while the test is suspended (`await Task.sleep`): their
/// completions are delivered on the main queue, which a `@MainActor` test occupies while it
/// spins `RunLoop.current.run(until:)`.
@Suite("SettingsWindow", .serialized, .enabled(if: ProcessInfo.processInfo.environment["NANOWHISPER_WINDOW_TESTS"] != nil))
@MainActor
struct SettingsWindowTests {
    private static let captureDirectory = ProcessInfo.processInfo.environment["NANOWHISPER_CAPTURE_DIR"]
        .map { URL(fileURLWithPath: $0).appendingPathComponent("settings-switch", isDirectory: true) }

    private static let switches: [(from: SettingsPane, to: SettingsPane)] = [
        (.general, .engine), (.engine, .general), (.general, .recorder), (.recorder, .advanced),
        (.advanced, .permissions), (.permissions, .engine),
    ]

    private func makeWindow(dark: Bool, selected: SettingsPane) throws -> (NSWindow, SettingsTabViewController, () -> Void) {
        _ = NSApplication.shared
        let suite = "nanowhisper.window.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(selected.rawValue, forKey: SettingsPane.defaultsKey)
        let fixture = SettingsFixture()
        let tabs = SettingsWindowController.makeTabs(selectedFrom: defaults) { fixture.view(for: $0) }
        let window = SettingsWindowController.makeWindow(tabs: tabs)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 40))
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return (window, tabs, {
            window.close()
            defaults.removePersistentDomain(forName: suite)
        })
    }

    private func index(of pane: SettingsPane) -> Int { SettingsPane.allCases.firstIndex(of: pane)! }

    /// The pane's own height, measured from its SwiftUI content.
    private func paneHeight(_ tabs: SettingsTabViewController, _ pane: SettingsPane) throws -> CGFloat {
        try #require(tabs.contentHeight(of: pane))
    }

    /// The frame view (title bar, toolbar, content). `cacheDisplay` redraws the views and
    /// ignores their alpha: a pane faded out would still show. `CALayer.render(in:)` honours
    /// alpha but does not draw SwiftUI content nested in a clipping view. Only one pane is in
    /// the window at a time now, so `cacheDisplay` shows what is on screen, except while a
    /// pane is hidden during the resize.
    private func snapshot(_ window: NSWindow) throws -> NSBitmapImageRep {
        let frameView = try #require(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        let rep = try #require(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        return rep
    }

    private func save(_ rep: NSBitmapImageRep, _ name: String) throws {
        guard let directory = Self.captureDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func contentHeight(_ window: NSWindow) -> CGFloat {
        window.contentRect(forFrameRect: window.frame).height
    }

    @Test("Pane switches: the window ends at each pane's height, top edge fixed",
          arguments: [false, true])
    func paneSwitches(dark: Bool) async throws {
        let (window, tabs, close) = try makeWindow(dark: dark, selected: .general)
        defer { close() }
        let top = window.frame.maxY
        for (step, change) in Self.switches.enumerated() {
            tabs.selectedTabViewItemIndex = index(of: change.to)
            // Suspends, so the main queue runs: animation completions are delivered there.
            try await Task.sleep(for: .milliseconds(900))
            try save(try snapshot(window), "\(dark ? "dark" : "light")-settled-\(step)-\(change.to.rawValue)")
            #expect(tabs.tabView.subviews.count == 1, "one pane in the window at a time")
            #expect(tabs.tabView.subviews.allSatisfy { $0.alphaValue == 1 }, "\(change.to): the pane is shown")
            #expect(window.title == change.to.title)
            #expect(abs(window.frame.maxY - top) < 1, "\(change.to): the top edge stays in place")
            let expected = try paneHeight(tabs, change.to)
            #expect(abs(contentHeight(window) - expected) < 1.5,
                    "\(change.to): window content \(contentHeight(window)) vs pane \(expected)")
        }
    }

    @Test("Each frame of a pane switch: no pane content above the content area", arguments: [false, true])
    func resizeFrames(dark: Bool) throws {
        for (step, change) in Self.switches.enumerated() {
            let (window, tabs, close) = try makeWindow(dark: dark, selected: change.from)
            defer { close() }
            let fromHeight = contentHeight(window)
            let toHeight = try paneHeight(tabs, change.to)
            let top = window.frame.maxY
            // The steps of the animation, forced one by one (with the pane shown: the
            // stricter case; the animation hides it until the end).
            tabs.animatesResize = false
            tabs.selectedTabViewItemIndex = index(of: change.to)
            // SwiftUI draws the new pane.
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let height = fromHeight + (toHeight - fromHeight) * fraction
                var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: SettingsPane.width, height: height))
                frame.origin = NSPoint(x: window.frame.minX, y: top - frame.height)
                window.setFrame(frame, display: true)
                // A layout pass, as each frame of an animation gets. Before the fix, Auto
                // Layout snapped the window back to the pane's height here (a 501 constraint).
                window.contentView?.needsLayout = true
                window.contentView?.layoutSubtreeIfNeeded()
                #expect(abs(contentHeight(window) - height) < 1,
                        "\(change.from) → \(change.to) at \(fraction): the window keeps the animation's height")
                #expect(abs(tabs.tabView.frame.height - height) < 1, "the panes' area fills the content area")
                try save(try snapshot(window),
                         "\(dark ? "dark" : "light")-frames-\(step)-\(change.from.rawValue)-to-\(change.to.rawValue)-\(Int(fraction * 100))")
                // No visible pane content lies above the content area: it would show through
                // the translucent toolbar (the band of 2026-11-20).
                let content = try #require(window.contentView)
                for paneView in tabs.tabView.subviews where !paneView.isHidden && paneView.alphaValue > 0 {
                    for child in paneView.subviews where !child.isHidden {
                        var rect = child.convert(child.bounds, to: content)
                        if paneView.clipsToBounds {
                            rect = rect.intersection(paneView.convert(paneView.bounds, to: content))
                        }
                        #expect(rect.maxY <= content.bounds.maxY + 0.5,
                                "\(change.from) → \(change.to) at \(fraction): pane content up to \(rect.maxY), content area top \(content.bounds.maxY)")
                        // Pinned to the top, never centered in a window of another height.
                        #expect(abs(rect.maxY - content.bounds.maxY) < 0.5,
                                "\(change.from) → \(change.to) at \(fraction): pane content top \(rect.maxY), content area top \(content.bounds.maxY)")
                    }
                }
            }
        }
    }

    @Test("The real animation: the window moves monotonically to the new height, top fixed; the pane appears only at the end",
          arguments: [false, true])
    func realAnimation(dark: Bool) async throws {
        for (step, change) in Self.switches.prefix(3).enumerated() {
            let (window, tabs, close) = try makeWindow(dark: dark, selected: change.from)
            defer { close() }
            try await Task.sleep(for: .milliseconds(200))
            let top = window.frame.maxY
            let fromHeight = contentHeight(window)
            let toHeight = try paneHeight(tabs, change.to)
            tabs.selectedTabViewItemIndex = index(of: change.to)
            var heights: [CGFloat] = []
            let start = Date()
            while Date().timeIntervalSince(start) < 0.7 {
                // Suspending lets the main queue and run loop run the animation.
                try await Task.sleep(for: .milliseconds(16))
                let height = contentHeight(window)
                heights.append(height)
                let pane = try #require(tabs.tabView.subviews.first)
                #expect(abs(window.frame.maxY - top) < 1, "\(change.to): the top edge stays in place")
                if abs(height - toHeight) > 1.5 {
                    #expect(pane.alphaValue == 0, "\(change.to): the pane is hidden while the window resizes (h \(height))")
                }
                // What is on screen: a hidden pane is not drawn (cacheDisplay ignores alpha).
                let wasHidden = pane.isHidden
                pane.isHidden = pane.alphaValue == 0
                let rep = try snapshot(window)
                pane.isHidden = wasHidden
                try save(rep, String(format: "%@-anim-%d-%@-to-%@-%03ld-h%.0f", dark ? "dark" : "light", step,
                                     change.from.rawValue, change.to.rawValue, heights.count, height))
            }
            #expect(abs((heights.last ?? 0) - toHeight) < 1.5)
            #expect(try #require(tabs.tabView.subviews.first).alphaValue == 1)
            // Monotonic: no snapping back and forth between heights.
            let direction: CGFloat = toHeight >= fromHeight ? 1 : -1
            for (a, b) in zip(heights, heights.dropFirst()) {
                #expect((b - a) * direction >= -0.5, "\(change.from) → \(change.to): height went \(a) → \(b)")
            }
        }
    }

    @Test("The window follows the selected pane's content height, top edge fixed; titled with the pane")
    func followsContentHeight() async throws {
        _ = NSApplication.shared
        let suite = "nanowhisper.window.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PaneHeightModel()
        let tabs = SettingsWindowController.makeTabs(panes: [.general, .engine], selectedFrom: defaults) { pane in
            pane == .general ? AnyView(ResizingPane(model: model)) : AnyView(SettingsPaneForm { SettingsSection("B") { Text("One row").settingsRow() } })
        }
        var selected: [SettingsPane] = []
        tabs.onSelect = { selected.append($0) }
        let window = SettingsWindowController.makeWindow(tabs: tabs)
        window.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 40))
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(300))
        let top = window.frame.maxY
        let short = contentHeight(window)
        #expect(window.title == "General")
        #expect(abs(window.contentRect(forFrameRect: window.frame).width - SettingsPane.width) < 1)

        model.isTall = true
        try await Task.sleep(for: .milliseconds(700))
        let tall = contentHeight(window)
        #expect(tall > short + 100, "the window follows the pane's content (\(short) → \(tall))")
        #expect(abs(window.frame.maxY - top) < 1, "the top edge stays in place")

        tabs.select(.engine)
        try await Task.sleep(for: .milliseconds(700))
        #expect(window.title == "Engine")
        #expect(contentHeight(window) < tall - 100)
        #expect(selected.last == .engine)
    }

    @Test("Engine: the comparison stays in place when the engine or model changes; the bars slide", arguments: [false, true])
    func comparisonInPlace(dark: Bool) async throws {
        _ = NSApplication.shared
        let suite = "nanowhisper.window.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let draft = DraftModel(Fixtures.parakeetUltra)
        let context = SettingsFixture().context
        let tabs = SettingsWindowController.makeTabs(panes: [.engine], selectedFrom: defaults) { _ in
            AnyView(DraftEnginePane(model: draft, context: context))
        }
        let window = SettingsWindowController.makeWindow(tabs: tabs)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setFrameTopLeftPoint(NSPoint(x: 80, y: (NSScreen.main?.visibleFrame.maxY ?? 900) - 40))
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))

        let suffix = dark ? "dark" : "light"
        let ultra = try snapshot(window)
        try save(ultra, "engine-comparison-0-ultra-\(suffix)")
        let before = try #require(Self.speedBar(in: ultra))

        // Another engine: Whisper Base, Speed "High" (4/5 of the bar).
        draft.configuration.modelType = .whisper
        // Frames first (a capture is quick), analysed after (the pixel scan is not).
        var frames: [NSBitmapImageRep] = []
        for _ in 1...10 {
            try await Task.sleep(for: .milliseconds(40))
            frames.append(try snapshot(window))
        }
        try save(frames[3], "engine-comparison-1-to-whisper-mid-\(suffix)")
        var lengths: [Int] = []
        for frame in frames {
            if let bar = Self.speedBar(in: frame) {
                #expect(abs(bar.row - before.row) <= 2, "the bar stays in place while it slides")
                lengths.append(bar.length)
            }
        }
        print("speed bar every ~40 ms: \(before.length) → \(lengths)")
        #expect(lengths == lengths.sorted(by: >), "the bar only shrinks toward its new value")
        try await Task.sleep(for: .milliseconds(300))
        let whisper = try snapshot(window)
        try save(whisper, "engine-comparison-2-whisper-\(suffix)")
        let after = try #require(Self.speedBar(in: whisper))
        #expect(after.row == before.row, "the bar does not move: row \(before.row) → \(after.row)")
        #expect(abs(Double(after.length) / Double(before.length) - 0.8) < 0.03,
                "the speed bar ends at High: \(before.length) → \(after.length) px")

        // Another Whisper model: the comparison stays where it is.
        draft.configuration.whisperSettings.modelSize = .largev3Turbo
        try await Task.sleep(for: .milliseconds(700))
        let turbo = try snapshot(window)
        try save(turbo, "engine-comparison-3-turbo-\(suffix)")
        let turboBar = try #require(Self.speedBar(in: turbo))
        #expect(turboBar.row == before.row)
        #expect(abs(Double(turboBar.length) / Double(before.length) - 0.6) < 0.03, "Medium: 3/5")
    }

    /// The speed bar: the pixel row with the longest run of the system blue, and its length.
    private static func speedBar(in rep: NSBitmapImageRep) -> (row: Int, length: Int)? {
        var best: (row: Int, length: Int)?
        for y in 0..<rep.pixelsHigh {
            var run = 0, longest = 0
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let isBlue = c.blueComponent > 0.8 && c.blueComponent - c.redComponent > 0.45 && c.blueComponent - c.greenComponent > 0.2
                run = isBlue ? run + 1 : 0
                longest = max(longest, run)
            }
            if longest > (best?.length ?? 40) { best = (y, longest) }
        }
        return best
    }
}

/// The Engine pane with a draft the test changes, as the user would with the controls.
@MainActor
private final class DraftModel: ObservableObject {
    @Published var configuration: EngineConfiguration
    init(_ configuration: EngineConfiguration) { self.configuration = configuration }
}

private struct DraftEnginePane: View {
    @ObservedObject var model: DraftModel
    let context: SettingsContext

    var body: some View {
        EnginePane(draft: $model.configuration, context: context)
    }
}
