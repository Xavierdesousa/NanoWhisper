import SwiftUI

@main
struct NanoWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        // Before AppState reads the flag (it decides whether the first download waits).
        if LaunchOptions.current.resetOnboarding {
            UserDefaults.standard.removeObject(forKey: AppState.onboardingCompleteKey)
        }
    }

    var body: some Scene {
        // The menu bar item is AppKit (`MenuBarController`) and the Settings window has its
        // own controller (`SettingsWindowController`). This empty scene only gives the app a
        // Scene; its "Settings…" command (app menu, shown while onboarding puts the app in
        // the Dock) opens the real Settings window instead.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.appState?.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var appState: AppState?
    /// The status item; onboarding's Finish Setup calls its `showOnboardingHandoff()`.
    private(set) var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let onboardingComplete = UserDefaults.standard.bool(forKey: AppState.onboardingCompleteKey)
        let showsOnboarding = LaunchOptions.current.showsOnboardingAtLaunch(onboardingComplete: onboardingComplete)
        // Dock icon only while onboarding is open.
        NSApp.setActivationPolicy(showsOnboarding ? .regular : .accessory)

        let appState = AppState()
        self.appState = appState
        let menuBar = MenuBarController(appState: appState)
        self.menuBar = menuBar
        // Finish Setup: the menu bar takes over, with the "After setup" popover.
        appState.onOnboardingFinished = { [weak menuBar] in menuBar?.showOnboardingHandoff() }

        // On first launch, or with `--onboarding` / `--reset-onboarding`. A short delay lets
        // the app finish launching.
        if showsOnboarding {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                appState.showOnboarding()
            }
        }
    }
}
