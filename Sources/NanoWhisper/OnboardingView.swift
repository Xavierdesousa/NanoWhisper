import SwiftUI
import AVFoundation
import Carbon

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @State private var hasAccessibility = PasteManager.checkAccessibility(prompt: false)
    @State private var hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var isRecordingShortcut = false
    @State private var shortcutDisplay: String
    var onDismiss: () -> Void

    init(appState: AppState, onDismiss: @escaping () -> Void) {
        self.appState = appState
        self.onDismiss = onDismiss
        _shortcutDisplay = State(initialValue: appState.hotkeyManager.currentShortcut.displayString)
    }

    private var isReady: Bool {
        appState.isEngineReady && hasAccessibility && hasMicrophone
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 8) {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 64, height: 64)
                }
                Text("Welcome to NanoWhisper")
                    .font(.system(size: 20, weight: .semibold))
                Text("Speech-to-text, right from your menu bar.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 24)
            .padding(.bottom, 12)

            Form {
                // MARK: - Model Selection
                Section {
                    Picker("Engine", selection: $appState.selectedModelType) {
                        ForEach(TranscriptionModelType.allCases, id: \.self) { model in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(model.displayName)
                                Text(model.subtitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .tag(model)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: appState.selectedModelType) { _, newValue in
                        appState.switchModel(to: newValue)
                    }

                    // Comparison bars
                    ModelComparisonView(modelType: appState.selectedModelType)

                    // Model status
                    HStack {
                        Text("Status:")
                        Spacer()
                        if appState.isEngineReady {
                            Text("Ready")
                                .foregroundColor(.green)
                        } else if appState.setupManager.setupError != nil {
                            Text("Error")
                                .foregroundColor(.red)
                        } else {
                            Text(modelStatusText)
                                .foregroundColor(.orange)
                        }
                    }

                    if appState.setupManager.isSettingUp {
                        ProgressView(value: modelProgress)
                            .progressViewStyle(.linear)
                        Text(appState.setupManager.setupProgress)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let err = appState.setupManager.setupError {
                        Text(err)
                            .font(.caption)
                            .foregroundColor(.red)
                        Button("Retry") {
                            appState.switchModel(to: appState.selectedModelType)
                        }
                    }
                } header: {
                    HStack {
                        Text("Model")
                        Spacer()
                        Text(appState.selectedModelType == .parakeet
                             ? "Fastest, auto-multilingual"
                             : "Most accurate, 99 languages")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // MARK: - Whisper Options (conditional)
                if appState.selectedModelType == .whisper {
                    Section("Whisper Options") {
                        Picker("Model size", selection: $appState.whisperSettings.modelSize) {
                            ForEach(WhisperModelSize.allCases, id: \.self) { size in
                                HStack {
                                    Text(size.displayName)
                                    Spacer()
                                    Text(size.sizeDescription)
                                        .foregroundColor(.secondary)
                                        .font(.caption)
                                }
                                .tag(size)
                            }
                        }

                        Picker("Language", selection: languageBinding) {
                            Text("Auto-detect").tag("")
                            Divider()
                            ForEach(WhisperLanguage.supported, id: \.code) { lang in
                                Text(lang.name).tag(lang.code)
                            }
                        }

                        if appState.whisperSettings.language == nil {
                            Label("Auto-detect works best on longer audio. For short clips, setting a language improves accuracy.", systemImage: "info.circle")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Vocabulary hint", text: $appState.whisperSettings.promptText)
                                .textFieldStyle(.roundedBorder)
                            Text("Words or phrases to help recognition (e.g. technical terms, names)")
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
                                hasAccessibility = PasteManager.checkAccessibility(prompt: true)
                                pollAccessibility()
                            }
                        }
                    }

                    HStack {
                        Text("Microphone")
                        Spacer()
                        if hasMicrophone {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                        } else {
                            Button("Grant") {
                                requestMicrophone()
                            }
                        }
                    }
                }

                Section("General") {
                    HStack {
                        Text("Record shortcut")
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

                    Toggle("Launch at login", isOn: $appState.launchAtLogin)
                    Toggle("Sound feedback", isOn: $appState.soundEnabled)
                    Toggle("Pause media during recording", isOn: $appState.pauseMediaEnabled)
                    Toggle("Save transcription history", isOn: $appState.historyEnabled)
                        .disabled(appState.historyUnavailable)
                }
            }
            .formStyle(.grouped)

            Divider()

            // Footer
            HStack {
                HStack(spacing: 4) {
                    Text("Look for the NanoWhisper")
                    if let url = Bundle.main.url(forResource: "menubar_icon", withExtension: "png"),
                       let img = NSImage(contentsOf: url) {
                        Image(nsImage: img)
                            .resizable()
                            .renderingMode(.template)
                            .foregroundColor(.secondary)
                            .frame(width: 14, height: 14)
                    }
                    Text("icon in your menu bar.")
                }
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(isReady ? "Get Started" : "Skip") {
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.regular)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 440, height: appState.selectedModelType == .whisper ? 780 : 640)
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

    private var languageBinding: Binding<String> {
        Binding(
            get: { appState.whisperSettings.language ?? "" },
            set: { appState.whisperSettings.language = $0.isEmpty ? nil : $0 }
        )
    }

    // MARK: - Model helpers

    private var modelStatusText: String {
        let progress = appState.setupManager.setupProgress
        if progress.contains("Compiling") {
            return "Compiling..."
        } else if progress.contains("Downloading") {
            return "Downloading..."
        }
        return "Loading..."
    }

    private var modelProgress: Double {
        let text = appState.setupManager.setupProgress
        if text.contains("Compiling") {
            return 1.0
        }
        if let range = text.range(of: #"\((\d+)%\)"#, options: .regularExpression),
           let pct = Int(text[range].filter(\.isNumber)) {
            return Double(pct) / 100.0
        }
        return 0.0
    }

    // MARK: - Permission helpers

    private func requestMicrophone() {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                hasMicrophone = granted
            }
        }
    }

    private func pollAccessibility() {
        for i in 1...10 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i)) { [self] in
                let granted = PasteManager.checkAccessibility(prompt: false)
                if granted { hasAccessibility = true }
            }
        }
    }
}

// MARK: - Window Controller

@MainActor
class OnboardingWindowController {
    private var window: NSWindow?

    func show(appState: AppState, onDismiss: @escaping () -> Void) {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(appState: appState, onDismiss: {
            onDismiss()
            self.window?.close()
        })
        let hosting = NSHostingView(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "NanoWhisper"
        w.contentView = hosting
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        centerOnCurrentScreen(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func close() {
        window?.close()
    }
}
