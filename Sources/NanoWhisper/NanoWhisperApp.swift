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
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.menu)
    }

    private var shortcutName: String {
        appState.hotkeyManager.currentShortcut.displayString
    }

    private var menuBarIcon: String {
        if appState.setupManager.isSettingUp {
            return "arrow.down.circle"
        } else if appState.isRecording {
            return "waveform"
        } else if appState.isTranscribing {
            return "ellipsis.circle"
        } else if !appState.isEngineReady {
            return "mic.slash"
        } else {
            return "mic"
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
