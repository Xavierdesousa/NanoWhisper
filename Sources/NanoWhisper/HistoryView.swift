import SwiftUI

struct HistoryView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if appState.history.isEmpty {
                Spacer()
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 32))
                            .foregroundColor(.secondary)
                        Text("No transcriptions yet")
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                Spacer()
            } else {
                List {
                    ForEach(Array(appState.history.enumerated()), id: \.offset) { index, text in
                        HistoryRow(text: text, index: index + 1)
                    }
                }
                .listStyle(.inset)

                HStack {
                    Spacer()
                    Button("Clear History") {
                        appState.history.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
                    .font(.caption)
                    .padding(8)
                }
            }
        }
        .frame(width: 480, height: 360)
    }
}

struct HistoryRow: View {
    let text: String
    let index: Int
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(index)")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 16, alignment: .trailing)

            Text(text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: copyText) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundColor(copied ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Copy to clipboard")
        }
        .padding(.vertical, 4)
    }

    private func copyText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            copied = false
        }
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "NanoWhisper — History"
        w.contentView = hostingView
        w.contentMinSize = NSSize(width: 320, height: 200)
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.collectionBehavior = [.moveToActiveSpace]
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }
}
