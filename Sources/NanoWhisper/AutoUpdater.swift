import Foundation
import AppKit
import os

/// Checks GitHub for a newer release and, when asked, installs it and relaunches the app.
/// The release is parsed in `UpdateRelease.swift`; `UpdateInstaller` downloads, verifies and
/// installs it.
@MainActor
class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()

    private let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "AutoUpdater")

    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var error: String?
    /// When the last check reached GitHub (Settings: "Last checked …"). Not persisted.
    @Published private(set) var lastCheckDate: Date?

    private var latestRelease: GitHubRelease?
    private var checkTimer: Timer?
    private let installer: UpdateInstaller
    /// Opens the installed update and quits. Tests replace it.
    private let relaunch: @MainActor (URL) throws -> Void

    /// False in debug builds: installing the latest release would replace the debug
    /// bundle with the production app. When disabled, checks and installs are no-ops.
    let isEnabled: Bool

    init(
        isEnabled: Bool = BuildFlavor.current.autoUpdatesEnabled,
        installer: UpdateInstaller = UpdateInstaller(),
        relaunch: @escaping @MainActor (URL) throws -> Void = { try AutoUpdater.relaunchAndQuit($0) }
    ) {
        self.isEnabled = isEnabled
        self.installer = installer
        self.relaunch = relaunch
    }

    var currentVersion: String { installer.installedVersion }

    func startPeriodicChecks(interval: TimeInterval = 3600) {
        checkTimer?.invalidate()
        guard isEnabled else { return }

        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await checkForUpdates(silent: true)
        }

        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates(silent: true)
            }
        }
    }

    func checkForUpdates(silent: Bool = false) async {
        guard isEnabled, !isChecking, !isDownloading else { return }
        isChecking = true
        error = nil

        defer { isChecking = false }

        do {
            guard let release = try await installer.latestRelease() else {
                if !silent { self.error = "Could not reach GitHub" }
                return
            }
            latestRelease = release
            let remoteVersion = release.version

            // Only update @Published properties when values actually change
            if latestVersion != remoteVersion {
                latestVersion = remoteVersion
            }

            let newer = AutoUpdater.isNewerVersion(remoteVersion, than: currentVersion)
            if updateAvailable != newer {
                updateAvailable = newer
            }
            lastCheckDate = Date()

            if newer {
                logger.info("Update available: \(remoteVersion) (current: \(self.currentVersion))")
            } else if !silent {
                logger.info("Already up to date (\(self.currentVersion))")
            }
        } catch {
            if !silent { self.error = "Network error: \(error.localizedDescription)" }
            logger.error("Update check failed: \(error.localizedDescription)")
        }
    }

    func downloadAndInstall() async {
        guard isEnabled, !isDownloading else { return }
        guard let release = latestRelease else {
            error = "No update to install. Check for updates first."
            return
        }

        isDownloading = true
        downloadProgress = 0
        error = nil

        defer { isDownloading = false }

        do {
            let offer = try UpdateOffer(release: release)
            try await installer.install(offer) { [weak self] in self?.downloadProgress = $0 }
            logger.info("Update \(offer.version) installed, relaunching...")
            do {
                try relaunch(installer.installedApp)
            } catch {
                logger.error("Relaunch failed: \(error.localizedDescription)")
                throw UpdateError.relaunch(version: offer.version)
            }
        } catch let error as UpdateError {
            self.error = error.errorDescription
            logger.error("Update failed: \(String(describing: error))")
        } catch {
            self.error = "Update failed: \(error.localizedDescription)"
            logger.error("Update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Version comparison

    /// False when either text is not a version made of numbers.
    nonisolated static func isNewerVersion(_ remote: String, than current: String) -> Bool {
        guard let remote = AppVersion(remote), let current = AppVersion(current) else { return false }
        return current < remote
    }

    // MARK: - Relaunch

    /// Kept until this process exits (see `Relaunch`).
    private static var relaunchHandle: FileHandle?

    private static func relaunchAndQuit(_ app: URL) throws {
        relaunchHandle = try Relaunch.afterExit(app)
        NSApplication.shared.terminate(nil)
    }
}
