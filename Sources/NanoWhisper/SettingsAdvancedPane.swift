import SwiftUI

/// What Settings › Advanced and the menu show about updates, from `AutoUpdater`.
struct UpdateStatus: Equatable {
    enum State: Equatable {
        /// Debug builds: the updater would install the production app over the debug one.
        case disabled
        case checking
        case downloading(version: String?, progress: Double)
        case available(version: String)
        /// No newer release found (or not checked yet: `lastChecked` is nil).
        case upToDate(lastChecked: Date?)
    }

    var appName: String
    var currentVersion: String
    var state: State
    var error: String?

    init(appName: String, currentVersion: String, state: State, error: String? = nil) {
        self.appName = appName
        self.currentVersion = currentVersion
        self.state = state
        self.error = error
    }

    /// Same precedence as before the redesign: disabled, checking, downloading, available.
    init(
        isEnabled: Bool, isChecking: Bool, isDownloading: Bool, downloadProgress: Double,
        updateAvailable: Bool, latestVersion: String?, lastCheckDate: Date?, error: String?,
        appName: String, currentVersion: String
    ) {
        let state: State
        if !isEnabled {
            state = .disabled
        } else if isChecking {
            state = .checking
        } else if isDownloading {
            state = .downloading(version: latestVersion, progress: downloadProgress)
        } else if updateAvailable, let latestVersion {
            state = .available(version: latestVersion)
        } else {
            state = .upToDate(lastChecked: lastCheckDate)
        }
        self.init(appName: appName, currentVersion: currentVersion, state: state, error: error)
    }

    @MainActor
    init(_ updater: AutoUpdater, appName: String = BuildFlavor.current.displayName) {
        self.init(
            isEnabled: updater.isEnabled, isChecking: updater.isChecking,
            isDownloading: updater.isDownloading, downloadProgress: updater.downloadProgress,
            updateAvailable: updater.updateAvailable, latestVersion: updater.latestVersion,
            lastCheckDate: updater.lastCheckDate, error: updater.error,
            appName: appName, currentVersion: updater.currentVersion
        )
    }

    var versionLine: String { "\(appName) \(currentVersion)" }

    var note: String {
        switch state {
        case .disabled: return "Updates are disabled in debug builds."
        case .checking: return "Checking for updates…"
        case .downloading(let version, _):
            return version.map { "Downloading version \($0)…" } ?? "Downloading the update…"
        case .available(let version): return "Version \(version) is available."
        case .upToDate(let lastChecked):
            guard let lastChecked else { return "Checks for updates every hour." }
            return "You’re up to date. Last checked: \(Self.dateFormatter.string(from: lastChecked))."
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

/// What the update buttons do.
struct UpdateActions {
    var check: () -> Void
    var install: () -> Void
}

/// Settings › Advanced: updates and debug tools.
struct AdvancedPane: View {
    let updates: UpdateStatus
    let actions: UpdateActions
    @Binding var debugMode: Bool
    let showOnboarding: () -> Void

    var body: some View {
        SettingsPaneForm {
            SettingsSection("Updates") {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsRow(title: updates.versionLine, caption: updates.note) {
                        updateButton
                    }
                    if case .downloading(_, let progress) = updates.state {
                        ProgressView(value: progress)
                    }
                    if let error = updates.error {
                        SettingsCaption(error, color: .red)
                    }
                }
                .settingsRow()
            }
            SettingsSection("Debug") {
                SettingsToggle(
                    title: "Show debug info in history",
                    caption: "Audio length, transcription time and speed next to each entry.",
                    isOn: $debugMode
                )
                .settingsRow()
                GroupedRowDivider()
                SettingsRow(title: "Onboarding", caption: "Your settings are kept; nothing downloads unless you apply another model.") {
                    Button("Show Onboarding Again…", action: showOnboarding)
                }
                .settingsRow()
            }
        }
    }

    @ViewBuilder
    private var updateButton: some View {
        switch updates.state {
        case .disabled:
            Button("Check for Updates") {}
                .disabled(true)
        case .checking:
            ProgressView().controlSize(.small)
            Button("Check for Updates") {}
                .disabled(true)
        case .downloading:
            EmptyView()
        case .available:
            Button("Install and Relaunch", action: actions.install)
                .buttonStyle(.borderedProminent)
        case .upToDate:
            Button("Check for Updates", action: actions.check)
        }
    }
}
