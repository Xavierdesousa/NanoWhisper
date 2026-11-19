import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @StateObject private var permissions = PermissionMonitor()
    /// Model choices are edited here and take effect on Apply (see `ModelSettingsSection`).
    @State private var draft: EngineConfiguration

    init(appState: AppState) {
        self.appState = appState
        _draft = State(initialValue: appState.engineConfiguration)
    }

    var body: some View {
        SettingsForm(
            context: appState.settingsContext(permissions: permissions),
            draft: $draft,
            autoUpdater: appState.autoUpdater,
            debugMode: $appState.debugMode,
            showOnboarding: { appState.showOnboarding() }
        )
        .frame(width: SettingsForm.size.width, height: SettingsForm.size.height)
        .onAppear { permissions.start() }
        .onDisappear { permissions.stop() }
    }
}

/// The Settings screen, built from the shared sections in the same order as onboarding,
/// followed by the Settings-only Updates and Debug sections.
struct SettingsForm: View {
    let context: SettingsContext
    @Binding var draft: EngineConfiguration
    @ObservedObject var autoUpdater: AutoUpdater
    @Binding var debugMode: Bool
    let showOnboarding: () -> Void

    static let size = CGSize(width: 480, height: 640)

    var body: some View {
        Form {
            ModelSettingsSection(draft: $draft, context: context)
            PermissionsSettingsSection(context: context)
            ShortcutSettingsSection(context: context)
            GeneralSettingsSection(context: context, showsHistoryLimit: true)
            UpdatesSettingsSection(autoUpdater: autoUpdater)

            Section("Debug") {
                Toggle("Show debug info in history", isOn: $debugMode)
                HStack {
                    Text("Onboarding")
                    Spacer()
                    Button("Show Onboarding Again…", action: showOnboarding)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct UpdatesSettingsSection: View {
    @ObservedObject var autoUpdater: AutoUpdater

    var body: some View {
        Section("Updates") {
            HStack {
                Text("Current version")
                Spacer()
                Text("v\(autoUpdater.currentVersion)")
                    .foregroundStyle(.secondary)
            }

            if !autoUpdater.isEnabled {
                Label("Automatic updates are disabled in debug builds", systemImage: "hammer")
                    .foregroundStyle(.secondary)
            } else if autoUpdater.isChecking {
                Label("Checking for updates...", systemImage: "arrow.clockwise")
                    .foregroundStyle(.secondary)
            } else if autoUpdater.isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Downloading update...", systemImage: "arrow.down.circle")
                        .foregroundStyle(.blue)
                    ProgressView(value: autoUpdater.downloadProgress)
                }
            } else if autoUpdater.updateAvailable, let version = autoUpdater.latestVersion {
                HStack {
                    Label("v\(version) available", systemImage: "arrow.up.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Install Update") {
                        Task { await autoUpdater.downloadAndInstall() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                HStack {
                    Label("Up to date", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Check Now") {
                        Task { await autoUpdater.checkForUpdates() }
                    }
                }
            }

            if let err = autoUpdater.error {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

// Manage a standalone NSWindow for settings
@MainActor
class SettingsWindowController {
    private var window: NSWindow?

    func show(appState: AppState) {
        if let w = window {
            // A fresh view when reopened, so the model draft starts from the applied
            // settings (unapplied changes are dropped when the window closes).
            if !w.isVisible {
                w.contentView = NSHostingView(rootView: SettingsView(appState: appState))
            }
            w.collectionBehavior = [.moveToActiveSpace]
            centerOnCurrentScreen(w)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: SettingsForm.size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        w.title = "\(BuildFlavor.current.displayName) Settings"
        w.contentView = NSHostingView(rootView: SettingsView(appState: appState))
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.collectionBehavior = [.moveToActiveSpace]
        centerOnCurrentScreen(w)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window = w
    }

    func close() {
        window?.close()
    }
}
