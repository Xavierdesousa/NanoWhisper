import SwiftUI

struct HistoryView: View {
    @ObservedObject var appState: AppState
    @State private var showClearConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            if appState.history.isEmpty {
                Spacer()
                VStack(spacing: 10) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 36, weight: .light))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No transcriptions yet")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else {
                historyList

                Divider()

                HStack {
                    Text("\(appState.history.count) transcription\(appState.history.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    ActionButton(label: "Clear All", icon: "trash", color: .red.opacity(0.8)) {
                        showClearConfirm = true
                    }
                    .alert("Clear History", isPresented: $showClearConfirm) {
                        Button("Cancel", role: .cancel) {}
                        Button("Clear All", role: .destructive) {
                            appState.history.removeAll()
                        }
                    } message: {
                        Text("Are you sure you want to delete all transcriptions? This cannot be undone.")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
    }

    private var historyList: some View {
        List {
            ForEach(Array(appState.history.enumerated()), id: \.element.id) { index, entry in
                HistoryRow(entry: entry, showDebug: appState.debugMode, onCopy: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                }, onDelete: {
                    appState.history.remove(at: index)
                })
                .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let showDebug: Bool
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var copied = false
    @State private var isHovering = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    @ViewBuilder
    private func debugInfoView(_ info: TranscriptionDebugInfo) -> some View {
        HStack(spacing: 12) {
            if let audio = info.audioDuration, audio > 0 {
                debugTag("Audio", String(format: "%.1fs", audio))
            }
            if let transcribe = info.transcribeDuration {
                debugTag("Transcribe", String(format: "%.2fs", transcribe))
            }
            if let rtf = info.rtf {
                debugTag("RTF", String(format: "%.2fx", rtf))
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.06)))
    }

    private func debugTag(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .foregroundColor(.secondary)
            Text(value)
                .foregroundColor(.primary)
        }
        .font(.system(size: 10, design: .monospaced))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Date header
            HStack(spacing: 6) {
                Text(Self.dateFormatter.string(from: entry.date))
                Text("·")
                Text(Self.timeFormatter.string(from: entry.date))
                Spacer()
            }
            .font(.system(size: 11))
            .foregroundColor(.secondary.opacity(0.7))

            // Text content
            Text(entry.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Debug info
            if showDebug, let info = entry.debugInfo {
                debugInfoView(info)
            }

            // Actions
            HStack(spacing: 12) {
                Spacer()

                ActionButton(
                    label: copied ? "Copied" : "Copy",
                    icon: copied ? "checkmark" : "doc.on.doc",
                    color: copied ? .green : .secondary
                ) {
                    onCopy()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                }

                ActionButton(label: "Delete", icon: "trash", color: .secondary, action: onDelete)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }
}

struct ActionButton: View {
    let label: String
    let icon: String
    var color: Color = .secondary
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? Color.primary.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

@MainActor
class HistoryWindowController {
    private var window: NSWindow?

    func show(appState: AppState) {
        if let w = window {
            w.collectionBehavior = [.moveToActiveSpace]
            centerOnCurrentScreen(w)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = HistoryView(appState: appState)
        let hostingView = NSHostingView(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "NanoWhisper — History"
        w.contentView = hostingView
        w.contentMinSize = NSSize(width: 380, height: 260)
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.collectionBehavior = [.moveToActiveSpace]
        centerOnCurrentScreen(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
