import AppKit
import SwiftUI
import Testing
@testable import NanoWhisper

/// Settings › General › Appearance: System, Light or Dark for the whole app.
@Suite("App appearance", .serialized)
@MainActor
struct AppAppearanceTests {
    @Test("System follows macOS; Light and Dark set Aqua and Dark Aqua")
    func mapping() {
        #expect(AppAppearance.system.appearanceName == nil)
        #expect(AppAppearance.system.nsAppearance == nil)
        #expect(AppAppearance.light.appearanceName == .aqua)
        #expect(AppAppearance.dark.appearanceName == .darkAqua)
        #expect(AppAppearance.allCases.map(\.title) == ["System", "Light", "Dark"])
        #expect(AppAppearance.defaultValue == .system)
    }

    @Test("Stored under its own key; System when nothing or something unknown is stored")
    func persistence() throws {
        let suite = "nanowhisper.appearance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(AppAppearance.load(from: defaults) == .system)
        AppAppearance.dark.save(to: defaults)
        #expect(defaults.string(forKey: AppAppearance.defaultsKey) == "dark")
        #expect(AppAppearance.load(from: defaults) == .dark)
        AppAppearance.light.save(to: defaults)
        #expect(AppAppearance.load(from: defaults) == .light)
        defaults.set("sepia", forKey: AppAppearance.defaultsKey)
        #expect(AppAppearance.load(from: defaults) == .system)
        #expect(AppAppearance.defaultsKey == "appearance")
    }

    @Test("Applied to the app, windows follow at once: the overlay picks its palette from them")
    func windowsFollow() throws {
        let app = NSApplication.shared
        let previous = app.appearance
        defer { app.appearance = previous }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let shadow = OverlayShadowPanel(viewModel: RecordingOverlayViewModel())
        #expect(window.appearance == nil && shadow.appearance == nil, "no appearance of their own")

        // Windows learn of the change from the app (KVO); let the run loop deliver it.
        func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        AppAppearance.dark.apply(to: app)
        settle()
        #expect(app.appearance?.name == .darkAqua)
        #expect(OverlayColors.forAppearance(window.effectiveAppearance) == .dark)
        #expect(OverlayColors.forAppearance(shadow.effectiveAppearance) == .dark)

        AppAppearance.light.apply(to: app)
        settle()
        #expect(app.appearance?.name == .aqua)
        #expect(OverlayColors.forAppearance(window.effectiveAppearance) == .light)
        #expect(OverlayColors.forAppearance(shadow.effectiveAppearance) == .light)

        AppAppearance.system.apply(to: app)
        #expect(app.appearance == nil)
    }

    @Test("Settings › General shows the Appearance row")
    func generalPaneRow() {
        var tree = ""
        dump(GeneralPane(context: Fixtures.onboardingContext()).body, to: &tree)
        #expect(tree.contains("\"Shortcut\""), "positive control")
        #expect(tree.contains("\"Appearance\""))
        #expect(tree.contains("AppearanceRow"))
        #expect(AppearanceRow.title == "Theme")
    }
}

/// Settings › Advanced › "Open Onboarding": debug builds only.
@Suite("Open Onboarding (debug only)")
@MainActor
struct OpenOnboardingTests {
    @Test("Only the debug build offers it")
    func flavor() {
        #expect(BuildFlavor.debug.offersOnboardingReplay)
        #expect(!BuildFlavor.production.offersOnboardingReplay)
        #expect(AdvancedPane.openOnboardingAction(flavor: .production) {} == nil)
        var opened = 0
        let action = AdvancedPane.openOnboardingAction(flavor: .debug) { opened += 1 }
        action?()
        #expect(opened == 1)
    }

    @Test("Production's Advanced pane has no onboarding row", arguments: BuildFlavor.allCases)
    func paneRow(flavor: BuildFlavor) {
        let pane = AdvancedPane(
            updates: Fixtures.updates(.upToDate(lastChecked: nil)), actions: UpdateActions(check: {}, install: {}),
            debugMode: .constant(false), openOnboarding: AdvancedPane.openOnboardingAction(flavor: flavor) {}
        )
        var tree = ""
        dump(pane.body, to: &tree)
        #expect(tree.contains("\"Show debug info in history\""), "positive control")
        #expect(tree.contains("\"\(AdvancedPane.openOnboardingTitle)\"") == (flavor == .debug))
        #expect(!tree.contains("Show Onboarding Again"), "the old control is gone from both builds")
    }
}
