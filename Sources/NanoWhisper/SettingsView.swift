import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var hasAccessibility = PasteManager.checkAccessibility()
    @State private var isRecordingShortcut = false
    @State private var shortcutDisplay: String

    init(appState: AppState) {
        self.appState = appState
        _shortcutDisplay = State(initialValue: appState.hotkeyManager.currentShortcut.displayString)
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $appState.launchAtLogin)
                Toggle("Sound feedback", isOn: $appState.soundEnabled)
            }

            Section("Shortcut") {
                HStack {
                    Text("Record toggle:")
                    Spacer()
                    Button(action: {
                        isRecordingShortcut = true
                    }) {
                        Text(isRecordingShortcut ? "Press shortcut..." : shortcutDisplay)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(isRecordingShortcut ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.2))
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isRecordingShortcut ? Color.accentColor : Color.clear, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                if isRecordingShortcut {
                    Text("Press any key combination with ⌘, ⌥, ⌃, or ⇧")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Button("Cancel") {
                        isRecordingShortcut = false
                    }
                    .font(.caption)
                }
            }

            Section("History") {
                Toggle("History", isOn: $appState.historyEnabled)
                if appState.historyEnabled {
                    Picker("Max transcriptions", selection: $appState.maxHistoryCount) {
                        ForEach([5, 10, 15, 25, 50, 100], id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                }
            }

            Section("Engine") {
                HStack {
                    Text("Model:")
                    Spacer()
                    Text("Parakeet TDT 0.6B v3 (CoreML)")
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("Status:")
                    Spacer()
                    Text(appState.isEngineReady ? "Ready" : "Loading...")
                        .foregroundColor(appState.isEngineReady ? .green : .orange)
                }
            }

            Section("Permissions") {
                HStack {
                    Text("Accessibility (for auto-paste)")
                    Spacer()
                    if hasAccessibility {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Button("Grant") {
                            hasAccessibility = PasteManager.checkAccessibility()
                        }
                    }
                }

                HStack {
                    Text("Microphone")
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                }
            }

            Section("Debug") {
                Toggle("Show debug info in history", isOn: $appState.debugMode)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 440)
        .background(ShortcutRecorder(
            isRecording: $isRecordingShortcut,
            onShortcutCaptured: { keyCode, modifiers in
                let shortcut = Shortcut(
                    keyCode: UInt32(keyCode),
                    modifiers: Shortcut.carbonModifiers(from: modifiers)
                )
                appState.hotkeyManager.updateShortcut(shortcut)
                shortcutDisplay = shortcut.displayString
            }
        ))
    }
}

// NSView-based key event interceptor for capturing shortcuts
struct ShortcutRecorder: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onShortcutCaptured: (UInt16, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderView {
        let view = ShortcutRecorderView()
        view.onShortcutCaptured = onShortcutCaptured
        view.onRecordingChanged = { isRecording = $0 }
        return view
    }

    func updateNSView(_ nsView: ShortcutRecorderView, context: Context) {
        nsView.isRecordingShortcut = isRecording
        if isRecording {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

class ShortcutRecorderView: NSView {
    var isRecordingShortcut = false
    var onShortcutCaptured: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onRecordingChanged: ((Bool) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])

        // Require at least one modifier
        guard !modifiers.isEmpty else {
            // Escape cancels
            if event.keyCode == UInt16(kVK_Escape) {
                isRecordingShortcut = false
                onRecordingChanged?(false)
            }
            return
        }

        onShortcutCaptured?(event.keyCode, modifiers)
        isRecordingShortcut = false
        onRecordingChanged?(false)
    }
}

// Manage a standalone NSWindow for settings
class SettingsWindowController {
    private var window: NSWindow?

    func show(appState: AppState) {
        if let w = window {
            w.collectionBehavior = [.moveToActiveSpace]
            centerOnCurrentScreen(w)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(appState: appState)
        let hostingView = NSHostingView(rootView: settingsView)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "NanoWhisper Settings"
        w.contentView = hostingView
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.collectionBehavior = [.moveToActiveSpace]
        centerOnCurrentScreen(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
