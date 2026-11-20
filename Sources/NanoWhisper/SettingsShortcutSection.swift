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

/// The shortcut row: the keys as boxes (`ShortcutKeysView`) and Change…, which records a new
/// combination (press it; Escape cancels). Shared by Settings › General and onboarding.
struct ShortcutRecorderRow: View {
    let shortcut: Shortcut
    let onChange: (Shortcut) -> Void
    @State private var isRecording: Bool

    init(shortcut: Shortcut, onChange: @escaping (Shortcut) -> Void, isRecording: Bool = false) {
        self.shortcut = shortcut
        self.onChange = onChange
        _isRecording = State(initialValue: isRecording)
    }

    static let title = "Start and stop dictation"
    static let caption = "Press once to start, again to stop, in any app."

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title)
                if isRecording {
                    HStack(spacing: 4) {
                        Text("Press the keys you want, or")
                        KeyCapView(glyph: "esc", size: .small)
                        Text("to cancel.")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                } else {
                    SettingsCaption(Self.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isRecording {
                Text("Press a shortcut…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .frame(width: 150, height: 22, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.nwAccent, lineWidth: 1)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .stroke(Color.nwAccent.opacity(0.25), lineWidth: 3)
                    )
                Button("Cancel") { isRecording = false }
            } else {
                ShortcutKeysView(shortcut: shortcut)
                if shortcut != .default {
                    Button {
                        onChange(.default)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Reset to default (\(Shortcut.default.displayString))")
                    .accessibilityLabel("Reset to default shortcut")
                }
                Button("Change…") { isRecording = true }
                    .help("Click, then press a key combination")
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
