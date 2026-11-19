import SwiftUI
import Carbon

/// The record shortcut, shared by Settings and onboarding.
struct ShortcutSettingsSection: View {
    let context: SettingsContext

    var body: some View {
        Section {
            ShortcutRecorderRow(shortcut: context.shortcut, onChange: context.setShortcut)
        } header: {
            Text("Shortcut")
        } footer: {
            Text("Press it anywhere to start recording, press it again to stop. The text is pasted where your cursor is.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Record shortcut" row: click the key cap, press a key combination; Escape cancels.
struct ShortcutRecorderRow: View {
    let shortcut: Shortcut
    let onChange: (Shortcut) -> Void
    @State private var isRecording = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Record shortcut")
                Spacer()
                if shortcut != .default && !isRecording {
                    Button {
                        onChange(.default)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reset to default (\(Shortcut.default.displayString))")
                }
                if isRecording {
                    Button("Cancel") { isRecording = false }
                }
                Button {
                    isRecording = true
                } label: {
                    Text(isRecording ? "Press shortcut…" : shortcut.displayString)
                        .monospacedDigit()
                        .frame(minWidth: 64)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .accentColor : nil)
                .help("Click, then press a key combination")
            }
            if isRecording {
                Text("Press a key combination with ⌘, ⌥, ⌃ or ⇧. Esc cancels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .background(ShortcutRecorder(
            isRecording: $isRecording,
            onShortcutCaptured: { keyCode, modifiers in
                onChange(Shortcut(
                    keyCode: UInt32(keyCode),
                    modifiers: Shortcut.carbonModifiers(from: modifiers)
                ))
            }
        ))
    }
}

/// NSView-based key event interceptor for capturing shortcuts.
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
        nsView.onShortcutCaptured = onShortcutCaptured
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
