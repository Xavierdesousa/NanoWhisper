import SwiftUI

@main
struct NanoWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()
    @State private var onboardingShown = false

    var body: some Scene {
        MenuBarExtra {
            if !onboardingShown && appState.isFirstLaunch {
                Button("Show Setup...") {
                    showOnboarding()
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
                    appState.setupManager.runSetup()
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
        appState.hotkeyManager.currentShortcut.displayString
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

    private func triggerOnboardingIfNeeded() {
        guard appState.isFirstLaunch && !onboardingShown else { return }
        // Small delay to let the app finish launching
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            showOnboarding()
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

    private func showOnboarding() {
        onboardingShown = true
        appState.onboardingWindow.show(appState: appState) {
            appState.completeOnboarding()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: "onboardingComplete")
        if isFirstLaunch {
            // Show dock icon during onboarding
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
