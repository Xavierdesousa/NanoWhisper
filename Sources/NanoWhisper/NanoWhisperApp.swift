import SwiftUI

@main
struct NanoWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            Text("NanoWhisper")
                .font(.headline)
            Divider()

            // Setup in progress
            if appState.setupManager.isSettingUp {
                Label(appState.setupManager.setupProgress, systemImage: "arrow.down.circle")
                    .foregroundColor(.blue)
                Text("First launch — this takes a few minutes")
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                Label("Recording... (\(shortcutName) to stop)", systemImage: "mic.fill")
                    .foregroundColor(.red)
            }
            // Ready
            else {
                Label("Ready — \(shortcutName) to record", systemImage: "mic")
            }

            // Error
            if let error = appState.lastError {
                Divider()
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.red)
            }

            Divider()

            Button(appState.historyEnabled ? "History" : "History (disabled)") {
                appState.showHistory()
            }
            .disabled(!appState.historyEnabled)
            .keyboardShortcut("h", modifiers: .command)

            Button("Settings...") {
                appState.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit") {
                // Leave daemon running for fast restart
                appState.transcriber.disconnect()
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)

            Button("Quit & Stop Engine") {
                appState.transcriber.stopDaemon()
                NSApplication.shared.terminate(nil)
            }
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
        } else if let nsImage = loadMenuBarIcon() {
            Image(nsImage: nsImage)
        } else {
            Image(systemName: "mic")
        }
    }

    /// Returns an SF Symbol name for non-default states, nil for the default (ready) state
    private var menuBarSFIcon: String? {
        if appState.setupManager.isSettingUp {
            return "arrow.down.circle"
        } else if appState.isRecording {
            return "waveform"
        } else if appState.isTranscribing {
            return "ellipsis.circle"
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
        NSApp.setActivationPolicy(.accessory)
    }
}
