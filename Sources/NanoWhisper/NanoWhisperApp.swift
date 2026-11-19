import SwiftUI

@main
struct NanoWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @State private var launchOnboardingTriggered = false

    init() {
        // Before AppState reads the flag (it decides whether the first download waits).
        if LaunchOptions.current.resetOnboarding {
            UserDefaults.standard.removeObject(forKey: AppState.onboardingCompleteKey)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            if appState.isFirstLaunch && !appState.isOnboardingVisible {
                Button("Show Setup...") {
                    appState.showOnboarding()
                }
                Divider()
            }
            Text("NanoWhisper")
                .font(.headline)
            Divider()

            // Setup in progress
            if appState.setupManager.isSettingUp {
                Label(appState.setupManager.setupProgress, systemImage: "arrow.down.circle")
                    .foregroundColor(.blue)
            }
            // Setup failed
            else if let setupErr = appState.setupManager.setupError {
                Label("Setup failed", systemImage: "xmark.circle")
                    .foregroundColor(.red)
                Text(setupErr)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Retry Setup") {
                    appState.switchModel(to: appState.selectedModelType)
                }
            }
            // Engine loading
            else if !appState.isEngineReady {
                Label("Loading model...", systemImage: "arrow.clockwise")
                    .foregroundColor(.secondary)
            }
            // Transcribing
            else if appState.isTranscribing {
                Label("Transcribing...", systemImage: "ellipsis.circle")
                    .foregroundColor(.orange)
            }
            // Recording
            else if appState.isRecording {
                Label("Recording... (\(shortcutName))", systemImage: "mic.fill")
                    .foregroundColor(.red)
                Button("Stop Recording") {
                    appState.toggleRecording()
                }
            }
            // Ready
            else {
                Label("Ready — \(shortcutName)", systemImage: "mic")
                Button("Start Recording") {
                    appState.toggleRecording()
                }
            }

            // Error
            if let error = appState.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Divider()

            Button(appState.historyUnavailable ? "History (unavailable)" : appState.historyEnabled ? "History" : "History (disabled)") {
                appState.showHistory()
            }
            .disabled(!appState.historyEnabled || appState.historyUnavailable)
            .keyboardShortcut("h", modifiers: .command)

            Button("Settings...") {
                appState.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            if appState.autoUpdater.updateAvailable, let version = appState.autoUpdater.latestVersion {
                Button("Update available: v\(version)") {
                    Task { await appState.autoUpdater.downloadAndInstall() }
                }
            } else if appState.autoUpdater.isDownloading {
                Label("Downloading update...", systemImage: "arrow.down.circle")
                    .foregroundColor(.blue)
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.menu)
    }

    private var shortcutName: String {
        appState.shortcut.displayString
    }

    @ViewBuilder
    private var menuBarLabel: some View {
        if let sfIcon = menuBarSFIcon {
            Image(systemName: sfIcon)
                .onAppear { triggerOnboardingIfNeeded() }
        } else if let nsImage = loadMenuBarIcon() {
            Image(nsImage: nsImage)
                .onAppear { triggerOnboardingIfNeeded() }
        } else {
            Image(systemName: "mic")
                .onAppear { triggerOnboardingIfNeeded() }
        }
    }

    /// Once per launch: on first launch, or with `--onboarding` / `--reset-onboarding`.
    private func triggerOnboardingIfNeeded() {
        guard !launchOnboardingTriggered,
              LaunchOptions.current.showsOnboardingAtLaunch(onboardingComplete: !appState.isFirstLaunch)
        else { return }
        launchOnboardingTriggered = true
        // Small delay to let the app finish launching
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            appState.showOnboarding()
        }
    }

    private var menuBarSFIcon: String? {
        if appState.setupManager.isSettingUp {
            return "arrow.down.circle"
        } else if !appState.isEngineReady {
            return "mic.slash"
        } else {
            return nil
        }
    }

    private func loadMenuBarIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "menubar_icon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }

}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let onboardingComplete = UserDefaults.standard.bool(forKey: AppState.onboardingCompleteKey)
        if LaunchOptions.current.showsOnboardingAtLaunch(onboardingComplete: onboardingComplete) {
            // Show dock icon during onboarding
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
