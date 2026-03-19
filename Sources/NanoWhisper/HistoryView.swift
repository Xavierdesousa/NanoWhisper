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
                    Button(action: {
                        showClearConfirm = true
                    }) {
                        HStack(spacing: 4) {
                            Image(systemName: "trash")
                            Text("Clear All")
                        }
                        .font(.caption)
                        .foregroundColor(.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
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
                HistoryRow(entry: entry, onCopy: {
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

            // Actions
            HStack(spacing: 12) {
                Spacer()

                Button(action: {
                    onCopy()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        Text(copied ? "Copied" : "Copy")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)

                Button(action: onDelete) {
                    HStack(spacing: 4) {
                        Image(systemName: "trash")
                        Text("Delete")
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
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

class HistoryWindowController {
    private var window: NSWindow?

    func show(appState: AppState) {
        window?.orderOut(nil)
        window = nil

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
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
