import CryptoKit
import Foundation

/// Downloads a release, verifies it and puts it in place of the installed app.
///
/// Everything happens in one private directory on the installed app's volume: the archive is
/// downloaded, checked and extracted there, the extracted app is verified there, and that same
/// app is then renamed over the installed one. Any failure leaves the installed app as it was;
/// the directory is removed in all cases.
struct UpdateInstaller: Sendable {
    struct Limits: Sendable {
        /// Largest archive downloaded, in bytes. 0.1.0 is 5.7 MB (models are not in the app).
        var download = 100 * 1024 * 1024
        /// Largest extracted content, in bytes. 0.1.0 is 15.8 MB.
        var extracted = 300 * 1024 * 1024
    }

    var installedApp = Bundle.main.bundleURL
    var installedVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    var requirements = UpdateSignature.acceptedRequirements
    var limits = Limits()
    var session = UpdateInstaller.makeSession()
    /// Fails when the running app may not update itself (an ad-hoc build, for example).
    var verifyRunningApp: @Sendable () throws -> Void = { try UpdateSignature.verifyRunningApp() }
    /// A new private directory on the same volume as the given app.
    var makeStagingDirectory: @Sendable (URL) throws -> URL = { app in
        try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true
        )
    }
    /// Renames the second app over the first. Without the first one's metadata: its quarantine
    /// flag, if any, is not copied.
    var replaceItem: @Sendable (_ installed: URL, _ new: URL) throws -> Void = { installed, new in
        _ = try FileManager.default.replaceItemAt(installed, withItemAt: new, options: .usingNewMetadataOnly)
    }

    static func makeSession(_ configuration: URLSessionConfiguration = .ephemeral) -> URLSession {
        configuration.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: configuration)
    }

    func install(_ offer: UpdateOffer, progress: @MainActor @Sendable (Double) -> Void = { _ in }) async throws {
        try verifyRunningApp()

        let staging = try makeStagingDirectory(installedApp)
        defer {
            // Kept when the installed app is missing: it may be in there (`replaceInstalledApp`).
            if FileManager.default.fileExists(atPath: installedApp.path) {
                try? FileManager.default.removeItem(at: staging)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staging.path)

        let archive = staging.appendingPathComponent("update.zip")
        try await download(offer.archiveURL, to: archive) { await progress($0 * 0.8) }
        if let expected = offer.sha256, try Self.sha256(of: archive) != expected {
            throw UpdateError.digestMismatch
        }
        let app = try await extract(archive, into: staging.appendingPathComponent("contents", isDirectory: true))
        await progress(0.9)
        try verify(app, version: offer.version)
        try replaceInstalledApp(with: app)
        await progress(1)
    }

    // MARK: - Download

    /// The latest release, as GitHub's API describes it. Nil when GitHub does not answer 200.
    func latestRelease() async throws -> GitHubRelease? {
        var request = URLRequest(url: UpdateRepository.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request, delegate: HTTPSRedirects())
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try JSONDecoder().decode(GitHubRelease.self, from: data)
    }

    func download(_ url: URL, to file: URL, progress: (Double) async -> Void = { _ in }) async throws {
        let (bytes, response) = try await session.bytes(for: URLRequest(url: url), delegate: HTTPSRedirects())
        defer { bytes.task.cancel() }
        guard (response as? HTTPURLResponse)?.statusCode == 200, response.url?.scheme?.lowercased() == "https" else {
            throw UpdateError.download
        }
        let expected = response.expectedContentLength
        guard expected <= Int64(limits.download) else { throw UpdateError.downloadTooLarge }

        try Data().write(to: file, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let chunkSize = 256 * 1024
        var chunk = Data(capacity: chunkSize)
        var received = 0
        for try await byte in bytes {
            chunk.append(byte)
            received += 1
            guard received <= limits.download else { throw UpdateError.downloadTooLarge }
            if chunk.count == chunkSize {
                try handle.write(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                if expected > 0 { await progress(min(1, Double(received) / Double(expected))) }
            }
        }
        try handle.write(contentsOf: chunk)
        await progress(1)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Extraction

    /// Extracts `archive` into `directory`, which must not exist, and returns its one app.
    ///
    /// `ditto` keeps everything inside `directory`: it drops `..` and leading slashes from entry
    /// names and does not write through a symbolic link (checked on macOS 27.2).
    func extract(_ archive: URL, into directory: URL) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(
            at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
        let limit = limits.extracted
        let output = await Subprocess.run(
            URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archive.path, directory.path],
            timeout: 120,
            // A listing can fail while `ditto` is writing; the one after it must not.
            stopWhen: { ((try? Self.size(of: directory)) ?? 0) > limit }
        )
        guard try Self.size(of: directory) <= limit else { throw UpdateError.extractedTooLarge }
        guard output?.status == 0 else { throw UpdateError.extraction }

        let apps = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { $0.pathExtension.lowercased() == "app" }
        guard apps.count == 1, let app = apps.first,
              try app.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true,
              try Self.linksStayInside(app, in: directory) else {
            throw UpdateError.unexpectedContents
        }
        return app
    }

    /// Whether every symbolic link in `directory` leads to something inside `app`.
    static func linksStayInside(_ app: URL, in directory: URL) throws -> Bool {
        guard let root = realPath(app) else { return false }
        for file in try files(in: directory, keys: [.isSymbolicLinkKey]) {
            guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else { continue }
            guard let target = realPath(file), target == root || target.hasPrefix(root + "/") else { return false }
        }
        return true
    }

    /// Bytes in the files under `directory`.
    static func size(of directory: URL) throws -> Int {
        try files(in: directory, keys: [.fileSizeKey])
            .reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    /// Everything under `directory`, links not followed.
    private static func files(in directory: URL, keys: [URLResourceKey]) throws -> [URL] {
        var failure: (any Error)?
        let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys, options: [],
            errorHandler: { _, error in
                failure = error
                return false
            }
        )
        guard let enumerator else { throw UpdateError.extraction }
        var files: [URL] = []
        for case let file as URL in enumerator { files.append(file) }
        if let failure { throw failure }
        return files
    }

    /// The path with every symbolic link resolved. Nil when it leads nowhere.
    private static func realPath(_ url: URL) -> String? {
        guard let path = realpath(url.path, nil) else { return nil }
        defer { free(path) }
        return String(cString: path)
    }

    // MARK: - Verification and replacement

    /// Checks the signature, the identifier and the version of `app`.
    func verify(_ app: URL, version: String) throws {
        let info = try UpdateSignature.verify(app, requirements: requirements)
        guard info.identifier == BuildFlavor.productionBundleIdentifier else { throw UpdateError.wrongApp }
        guard info.version == version, let found = AppVersion(version) else {
            throw UpdateError.wrongVersion(found: info.version ?? "?", expected: version)
        }
        guard let installed = AppVersion(installedVersion), installed < found else {
            throw UpdateError.notNewer(found: version, installed: installedVersion)
        }
    }

    private func replaceInstalledApp(with app: URL) throws {
        do {
            try replaceItem(installedApp, app)
        } catch {
            // `replaceItemAt` can fail after moving the original aside; its error says where.
            let fm = FileManager.default
            if !fm.fileExists(atPath: installedApp.path),
               let original = (error as NSError).userInfo["NSFileOriginalItemLocationKey"] as? URL {
                try? fm.moveItem(at: original, to: installedApp)
            }
            throw UpdateError.replacement(error.localizedDescription)
        }
    }
}

/// Follows redirects over https only. GitHub redirects a release download to its asset host,
/// whose name has changed over the years, so the host is not checked: the archive's digest and
/// the app's signature are.
final class HTTPSRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        request.url?.scheme?.lowercased() == "https" ? request : nil
    }
}

/// Opens an app again once this process has exited, so that the two instances never overlap
/// (they share the hotkey, the history and the temporary recordings). No shell: `xargs` passes
/// the path to `open` as one argument when its input ends, and only this process holds the
/// other end of that pipe.
enum Relaunch {
    /// The returned handle must be kept: the app is opened when it is closed, which this
    /// process's exit does.
    static func afterExit(_ app: URL, opener: [String] = ["/usr/bin/open", "-n"]) throws -> FileHandle {
        let input = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xargs")
        process.arguments = ["-0"] + opener
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(app.path.utf8) + [0])
        return input.fileHandleForWriting
    }
}
