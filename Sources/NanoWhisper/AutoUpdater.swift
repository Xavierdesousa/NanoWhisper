import Foundation
import AppKit
import os

@MainActor
class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()

    private let logger = Logger(subsystem: "com.moonji.nanowhisper", category: "AutoUpdater")
    private let owner = "Xavierdesousa"
    private let repo = "nanowhisper"

    @Published var updateAvailable = false
    @Published var latestVersion: String?
    @Published var isChecking = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var error: String?

    private var releaseAssetURL: URL?
    private var checkTimer: Timer?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    func startPeriodicChecks(interval: TimeInterval = 3600) {
        // Check on launch after a short delay
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await checkForUpdates(silent: true)
        }
        // Then check periodically
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForUpdates(silent: true)
            }
        }
    }

    func checkForUpdates(silent: Bool = false) async {
        guard !isChecking, !isDownloading else { return }
        isChecking = true
        error = nil

        defer { isChecking = false }

        let urlString = "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 15

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                if !silent { self.error = "Could not reach GitHub" }
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String else {
                if !silent { self.error = "Invalid response from GitHub" }
                return
            }

            let remoteVersion = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
            latestVersion = remoteVersion

            // Find the .zip asset
            if let assets = json["assets"] as? [[String: Any]] {
                releaseAssetURL = assets
                    .first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
                    .flatMap { $0["browser_download_url"] as? String }
                    .flatMap { URL(string: $0) }
            }

            if isNewerVersion(remoteVersion, than: currentVersion) {
                updateAvailable = true
                logger.info("Update available: \(remoteVersion) (current: \(self.currentVersion))")
            } else {
                updateAvailable = false
                if !silent { logger.info("Already up to date (\(self.currentVersion))") }
            }
        } catch {
            if !silent { self.error = "Network error: \(error.localizedDescription)" }
            logger.error("Update check failed: \(error.localizedDescription)")
        }
    }

    func downloadAndInstall() async {
        guard let assetURL = releaseAssetURL else {
            error = "No download URL available"
            return
        }

        isDownloading = true
        downloadProgress = 0
        error = nil

        do {
            // Download to temp
            let (tempURL, response) = try await URLSession.shared.download(from: assetURL)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                error = "Download failed"
                isDownloading = false
                return
            }

            downloadProgress = 0.5

            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory.appendingPathComponent("nanowhisper_update_\(UUID().uuidString)")
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Unzip
            let unzipProcess = Process()
            unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            unzipProcess.arguments = ["-o", tempURL.path, "-d", tempDir.path]
            unzipProcess.standardOutput = FileHandle.nullDevice
            unzipProcess.standardError = FileHandle.nullDevice
            try unzipProcess.run()
            unzipProcess.waitUntilExit()

            guard unzipProcess.terminationStatus == 0 else {
                error = "Failed to extract update"
                isDownloading = false
                return
            }

            downloadProgress = 0.75

            // Find the .app in the extracted contents
            let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                error = "No .app found in download"
                isDownloading = false
                return
            }

            // Replace current app bundle
            guard let currentAppURL = Bundle.main.bundleURL as URL? else {
                error = "Cannot locate current app"
                isDownloading = false
                return
            }

            let backupURL = currentAppURL.deletingLastPathComponent()
                .appendingPathComponent("NanoWhisper_backup.app")
            try? fm.removeItem(at: backupURL)
            try fm.moveItem(at: currentAppURL, to: backupURL)

            do {
                try fm.moveItem(at: newApp, to: currentAppURL)
            } catch {
                // Restore backup on failure
                try? fm.moveItem(at: backupURL, to: currentAppURL)
                self.error = "Failed to install update: \(error.localizedDescription)"
                isDownloading = false
                return
            }

            // Clean up backup and temp
            try? fm.removeItem(at: backupURL)
            try? fm.removeItem(at: tempDir)
            try? fm.removeItem(at: tempURL)

            downloadProgress = 1.0

            logger.info("Update installed, relaunching...")

            // Relaunch
            relaunch(at: currentAppURL)

        } catch {
            self.error = "Update failed: \(error.localizedDescription)"
            isDownloading = false
            logger.error("Update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Version comparison

    private func isNewerVersion(_ remote: String, than current: String) -> Bool {
        let remoteParts = remote.split(separator: ".").compactMap { Int($0) }
        let currentParts = current.split(separator: ".").compactMap { Int($0) }

        for i in 0..<max(remoteParts.count, currentParts.count) {
            let r = i < remoteParts.count ? remoteParts[i] : 0
            let c = i < currentParts.count ? currentParts[i] : 0
            if r > c { return true }
            if r < c { return false }
        }
        return false
    }

    // MARK: - Relaunch

    private func relaunch(at appURL: URL) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1 && open \"\(appURL.path)\""]
        try? task.run()

        NSApplication.shared.terminate(nil)
    }
}
