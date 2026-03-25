import Foundation
import AppKit
import os

private struct GitHubRelease: Codable {
    let tagName: String
    let assets: [Asset]

    struct Asset: Codable {
        let name: String
        let browserDownloadUrl: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case assets
    }
}

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
        checkTimer?.invalidate()

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

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            let remoteVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName

            // Only update @Published properties when values actually change
            if latestVersion != remoteVersion {
                latestVersion = remoteVersion
            }

            releaseAssetURL = release.assets
                .first { $0.name.hasSuffix(".zip") }
                .flatMap { URL(string: $0.browserDownloadUrl) }

            let newer = isNewerVersion(remoteVersion, than: currentVersion)
            if updateAvailable != newer {
                updateAvailable = newer
            }

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
        guard let assetURL = releaseAssetURL else {
            error = "No download URL available"
            return
        }

        isDownloading = true
        downloadProgress = 0
        error = nil

        defer { isDownloading = false }

        do {
            let (tempURL, response) = try await URLSession.shared.download(from: assetURL)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                error = "Download failed"
                return
            }

            downloadProgress = 0.5

            let fm = FileManager.default
            let tempDir = fm.temporaryDirectory.appendingPathComponent("nanowhisper_update_\(UUID().uuidString)")
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)

            // Unzip on a background thread to avoid blocking the UI
            let unzipResult = await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                process.arguments = ["-o", tempURL.path, "-d", tempDir.path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus
            }.result

            guard case .success(let status) = unzipResult, status == 0 else {
                error = "Failed to extract update"
                return
            }

            downloadProgress = 0.75

            let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            guard let newApp = contents.first(where: { $0.pathExtension == "app" }) else {
                error = "No .app found in download"
                return
            }

            let currentAppURL = Bundle.main.bundleURL

            let backupURL = currentAppURL.deletingLastPathComponent()
                .appendingPathComponent("NanoWhisper_backup.app")
            try? fm.removeItem(at: backupURL)
            try fm.moveItem(at: currentAppURL, to: backupURL)

            do {
                try fm.moveItem(at: newApp, to: currentAppURL)
            } catch {
                try? fm.moveItem(at: backupURL, to: currentAppURL)
                self.error = "Failed to install update: \(error.localizedDescription)"
                return
            }

            try? fm.removeItem(at: backupURL)
            try? fm.removeItem(at: tempDir)
            try? fm.removeItem(at: tempURL)

            downloadProgress = 1.0
            logger.info("Update installed, relaunching...")

            relaunch(at: currentAppURL)

        } catch {
            self.error = "Update failed: \(error.localizedDescription)"
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
