import Carbon
import Testing
@testable import NanoWhisper

/// End of onboarding: when the status item's popover shows, what closes it, and its text.
@Suite("Menu bar handoff")
struct MenuBarHandoffTests {
    private static let optionSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    private static let ready = EngineState(isReady: true, setupComplete: true, progressText: "Setup complete!")

    private func message(
        _ popover: MenuBarHandoff.Popover,
        engine: EngineState = Self.ready,
        shortcut: Shortcut = Self.optionSpace,
        position: RecorderPosition = .topCenter
    ) -> HandoffMessage? {
        HandoffMessage.make(
            popover, appName: "NanoWhisper", modelName: "Parakeet Ultra", engine: engine,
            shortcut: shortcut, recorderPosition: position
        )
    }

    // MARK: When it shows

    @Test("Nothing shows before setup is finished")
    func initiallyHidden() {
        let handoff = MenuBarHandoff()
        #expect(handoff.popover == .none)
        #expect(!handoff.announcesReady)
        #expect(message(handoff.popover) == nil)
    }

    @Test("Finish Setup with the model ready: one popover, nothing announced later")
    func finishedReady() {
        var handoff = MenuBarHandoff()
        handoff.setupFinished(engineReady: true)
        #expect(handoff.popover == .setupDone)
        #expect(!handoff.announcesReady)
        handoff.dismiss()
        handoff.engineChanged(isReady: true, menuIsOpen: false)
        #expect(handoff.popover == .none)
    }

    @Test("Finish Setup while the model downloads: a second popover when it is ready, once")
    func finishedDownloading() {
        var handoff = MenuBarHandoff()
        handoff.setupFinished(engineReady: false)
        #expect(handoff.popover == .setupDone)
        #expect(handoff.announcesReady)

        handoff.dismiss() // OK
        handoff.engineChanged(isReady: false, menuIsOpen: false)
        #expect(handoff.popover == .none)

        handoff.engineChanged(isReady: true, menuIsOpen: false)
        #expect(handoff.popover == .modelReady)
        handoff.dismiss()
        handoff.engineChanged(isReady: true, menuIsOpen: false)
        #expect(handoff.popover == .none)
        #expect(!handoff.announcesReady)
    }

    @Test("Ready while the first popover is still open: it becomes the ready one")
    func readyReplacesOpenPopover() {
        var handoff = MenuBarHandoff()
        handoff.setupFinished(engineReady: false)
        handoff.engineChanged(isReady: true, menuIsOpen: false)
        #expect(handoff.popover == .modelReady)
    }

    @Test("Ready while the menu is open: no popover, the menu already says it")
    func readyWithMenuOpen() {
        var handoff = MenuBarHandoff()
        handoff.setupFinished(engineReady: false)
        handoff.dismiss() // the menu opened
        handoff.engineChanged(isReady: true, menuIsOpen: true)
        #expect(handoff.popover == .none)
        #expect(!handoff.announcesReady)
    }

    @Test("Menu already open at Finish Setup: no first popover, the ready one still comes")
    func menuOpenAtFinish() {
        var handoff = MenuBarHandoff()
        handoff.setupFinished(engineReady: false)
        handoff.dismiss() // what the controller does when the menu is open
        #expect(handoff.popover == .none)
        handoff.engineChanged(isReady: true, menuIsOpen: false)
        #expect(handoff.popover == .modelReady)
    }

    @Test("A replay shows it again")
    func replay() {
        var handoff = MenuBarHandoff()
        handoff.setupFinished(engineReady: true)
        handoff.dismiss()
        handoff.setupFinished(engineReady: true)
        #expect(handoff.popover == .setupDone)
    }

    // MARK: Text

    @Test("Model ready: the board's text with the real shortcut and recorder position")
    func readyText() {
        #expect(message(.setupDone) == HandoffMessage(
            title: "NanoWhisper is in the menu bar",
            body: "Press ⌥ Space in any app to dictate, and again to stop. The recorder appears at the top center of the screen. History and Settings are in this menu."
        ))
        #expect(message(.modelReady) == HandoffMessage(
            title: "Parakeet Ultra is ready",
            body: "Press ⌥ Space in any app to dictate, and again to stop. The recorder appears at the top center of the screen."
        ))
    }

    @Test("The shortcut and position are the current ones")
    func currentShortcutAndPosition() throws {
        let shortcut = Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | cmdKey))
        let body = try #require(message(.modelReady, shortcut: shortcut, position: .bottomCenter)?.body)
        #expect(body.hasPrefix("Press ⌃⌘ D in any app"))
        #expect(body.contains("at the bottom center of the screen."))
        #expect(try #require(message(.setupDone, position: .topLeft)?.body).contains("at the top left of the screen."))
    }

    @Test("Not ready yet: says what is happening and how to start once it is")
    func notReadyText() {
        let whenReady = "When it is ready, press ⌥ Space in any app to dictate."
        #expect(message(.setupDone, engine: EngineState(isSettingUp: true, progressText: "Downloading model (48%)..."))?.body
            == "Parakeet Ultra is still downloading (48%). \(whenReady)")
        #expect(message(.setupDone, engine: EngineState(isSettingUp: true, progressText: "Preparing download..."))?.body
            == "Parakeet Ultra is still downloading. \(whenReady)")
        #expect(message(.setupDone, engine: EngineState(isSettingUp: true, progressText: "Compiling model..."))?.body
            == "Parakeet Ultra is being optimized for this Mac. \(whenReady)")
        #expect(message(.setupDone, engine: EngineState(setupComplete: true))?.body
            == "Parakeet Ultra is still loading. \(whenReady)")
        #expect(message(.setupDone, engine: EngineState(error: "No connection"))?.body
            == "Parakeet Ultra could not be set up. Open this menu to try again.")
        #expect(message(.setupDone, engine: EngineState())?.body
            == "Parakeet Ultra is not downloaded yet. Open this menu to download it.")
        #expect(message(.setupDone, engine: EngineState(isSettingUp: true))?.title == "NanoWhisper is in the menu bar")
    }

    // MARK: Debug trigger

    @Test("--show-handoff works in debug builds only")
    func launchArgument() {
        let args = ["/Applications/NanoWhisper Debug.app/Contents/MacOS/NanoWhisperDebug", "--show-handoff"]
        #expect(MenuBarHandoff.isRequestedAtLaunch(arguments: args, flavor: .debug))
        #expect(!MenuBarHandoff.isRequestedAtLaunch(arguments: args, flavor: .production))
        #expect(!MenuBarHandoff.isRequestedAtLaunch(arguments: [args[0]], flavor: .debug))
        #expect(!MenuBarHandoff.isRequestedAtLaunch(arguments: ["--show-handoff"], flavor: .debug)) // argv[0]
    }
}
