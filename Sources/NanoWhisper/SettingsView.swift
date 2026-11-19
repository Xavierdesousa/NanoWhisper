import SwiftUI
import Carbon

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var hasAccessibility = PasteManager.checkAccessibility()
    @State private var isRecordingShortcut = false
    @State private var shortcutDisplay: String

    // Local draft state for engine settings (applied on Save)
    @State private var draftModelType: TranscriptionModelType
    @State private var draftWhisperSettings: WhisperSettings

    private var engineDirty: Bool {
        draftModelType != appState.selectedModelType
        || draftWhisperSettings != appState.whisperSettings
    }

    init(appState: AppState) {
        self.appState = appState
        _shortcutDisplay = State(initialValue: appState.hotkeyManager.currentShortcut.displayString)
        _draftModelType = State(initialValue: appState.selectedModelType)
        _draftWhisperSettings = State(initialValue: appState.whisperSettings)
    }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $appState.launchAtLogin)
                Toggle("Sound feedback", isOn: $appState.soundEnabled)
                Toggle("Pause media during recording", isOn: $appState.pauseMediaEnabled)
            }

            Section("Shortcut") {
                HStack {
                    Text("Record toggle:")
                    Spacer()
                    if appState.hotkeyManager.currentShortcut != .default {
                        Button(action: {
                            let def = Shortcut.default
                            appState.hotkeyManager.updateShortcut(def)
                            shortcutDisplay = def.displayString
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Reset to default (\(Shortcut.default.displayString))")
                    }
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
                    .disabled(appState.historyUnavailable)
                if appState.historyUnavailable {
                    Label("History is unavailable — encryption key could not be accessed.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.red)
                }
                if appState.historyEnabled {
                    Picker("Max transcriptions", selection: $appState.maxHistoryCount) {
                        ForEach([5, 10, 15, 25, 50, 100], id: \.self) { n in
                            Text("\(n)").tag(n)
                        }
                    }
                }
            }

            // MARK: - Engine section (draft state)
            Section {
                Picker("Model", selection: $draftModelType) {
                    ForEach(TranscriptionModelType.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }

                // Comparison bars for selected model
                ModelComparisonView(modelType: draftModelType)

                // Status
                HStack {
                    Text("Status:")
                    Spacer()
                    if appState.isEngineReady && !engineDirty {
                        Text("Ready")
                            .foregroundColor(.green)
                    } else if appState.setupManager.isSettingUp {
                        Text(appState.setupManager.setupProgress)
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    } else if engineDirty {
                        Text("Unsaved changes")
                            .foregroundColor(.orange)
                    } else {
                        Text("Loading...")
                            .foregroundColor(.orange)
                    }
                }

                if let err = appState.setupManager.setupError, !engineDirty {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                    Button("Retry") {
                        appState.switchModel(to: appState.selectedModelType)
                    }
                }

                // Save / Revert buttons
                if engineDirty {
                    HStack {
                        Button("Revert") {
                            draftModelType = appState.selectedModelType
                            draftWhisperSettings = appState.whisperSettings
                        }
                        Spacer()
                        Button("Save & Apply") {
                            appState.whisperSettings = draftWhisperSettings
                            appState.switchModel(to: draftModelType)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            } header: {
                HStack {
                    Text("Engine")
                    Spacer()
                    Text(draftModelType == .parakeet
                         ? "Nvidia's Parakeet — fastest, auto-multilingual"
                         : "OpenAI's Whisper — most accurate, 99 languages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // MARK: - Whisper options (draft state)
            if draftModelType == .whisper {
                Section("Whisper Options") {
                    Picker("Model size", selection: $draftWhisperSettings.modelSize) {
                        ForEach(WhisperModelSize.allCases, id: \.self) { size in
                            Text("\(size.displayName) (\(size.sizeDescription))").tag(size)
                        }
                    }

                    Picker("Language", selection: draftLanguageBinding) {
                        Text("Auto-detect").tag("")
                        Divider()
                        ForEach(WhisperLanguage.supported, id: \.code) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }

                    if draftWhisperSettings.language == nil {
                        Label("Auto-detect works best on longer audio. For short clips, setting a language improves accuracy.", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Vocabulary hint", text: $draftWhisperSettings.promptText)
                            .textFieldStyle(.roundedBorder)
                        Text("Words or phrases to improve recognition")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
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

            Section("Updates") {
                HStack {
                    Text("Current version:")
                    Spacer()
                    Text("v\(appState.autoUpdater.currentVersion)")
                        .foregroundColor(.secondary)
                }

                if appState.autoUpdater.isChecking {
                    Label("Checking for updates...", systemImage: "arrow.clockwise")
                        .foregroundColor(.secondary)
                } else if appState.autoUpdater.isDownloading {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Downloading update...", systemImage: "arrow.down.circle")
                            .foregroundColor(.blue)
                        ProgressView(value: appState.autoUpdater.downloadProgress)
                    }
                } else if appState.autoUpdater.updateAvailable, let version = appState.autoUpdater.latestVersion {
                    HStack {
                        Label("v\(version) available", systemImage: "arrow.up.circle.fill")
                            .foregroundColor(.green)
                        Spacer()
                        Button("Install Update") {
                            Task { await appState.autoUpdater.downloadAndInstall() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    HStack {
                        Label("Up to date", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Spacer()
                        Button("Check Now") {
                            Task { await appState.autoUpdater.checkForUpdates() }
                        }
                    }
                }

                if let err = appState.autoUpdater.error {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section("Debug") {
                Toggle("Show debug info in history", isOn: $appState.debugMode)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: draftModelType == .whisper ? 780 : 660)
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

    // MARK: - Bindings

    private var draftLanguageBinding: Binding<String> {
        Binding(
            get: { draftWhisperSettings.language ?? "" },
            set: { draftWhisperSettings.language = $0.isEmpty ? nil : $0 }
        )
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
@MainActor
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
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
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
