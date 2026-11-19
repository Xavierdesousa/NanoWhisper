import Foundation
import os

/// `NowPlayingSource` backed by the vendored mediaremote-adapter (Vendor/mediaremote-adapter).
///
/// Since macOS 15.4 only Apple-signed processes may use the private MediaRemote framework, so
/// the adapter's script runs in `/usr/bin/perl`, which loads `MediaRemoteAdapter.framework`
/// from our bundle. Each call is one short-lived perl process (about 30-50 ms), run off the
/// caller's actor and killed after `timeout`.
struct MediaRemoteAdapter: NowPlayingSource {
    static let perlURL = URL(fileURLWithPath: "/usr/bin/perl")
    private static let logger = Logger(subsystem: "com.moonji.nanowhisper", category: "NowPlaying")

    let scriptURL: URL
    let frameworkURL: URL
    /// The adapter gives up on MediaRemote after 2 s; kill perl if it hangs beyond that.
    var timeout: TimeInterval = 3

    /// The adapter shipped in `bundle`, or `nil` when it is missing (e.g. `swift run`).
    static func bundled(in bundle: Bundle = .main) -> MediaRemoteAdapter? {
        guard let scriptURL = bundle.url(forResource: "mediaremote-adapter", withExtension: "pl"),
              let frameworkURL = bundle.privateFrameworksURL?
                  .appendingPathComponent("MediaRemoteAdapter.framework"),
              FileManager.default.fileExists(atPath: frameworkURL.appendingPathComponent("MediaRemoteAdapter").path)
        else { return nil }
        return MediaRemoteAdapter(scriptURL: scriptURL, frameworkURL: frameworkURL)
    }

    func read() async -> NowPlayingReading {
        guard let output = await run(["get", "--no-artwork", "--allow-missing-title"]) else { return .failed }
        let reading = Self.parseGetOutput(output)
        if reading == .failed {
            Self.logger.error("get failed: status \(output.status), stderr: \(output.stderrText, privacy: .public)")
        }
        return reading
    }

    @discardableResult
    func send(_ command: NowPlayingCommand) async -> Bool {
        guard let output = await run(["send", String(command.rawValue)]) else { return false }
        if output.status != 0 {
            Self.logger.error("send \(command.rawValue) failed: status \(output.status), stderr: \(output.stderrText, privacy: .public)")
        }
        return output.status == 0
    }

    private func run(_ arguments: [String]) async -> SubprocessOutput? {
        let binary = frameworkURL.appendingPathComponent("MediaRemoteAdapter")
        if let quarantine = Self.quarantineValue(of: binary), Self.quarantineBlocksLoading(quarantine) {
            // Gatekeeper refuses to load a quarantined, non-notarized framework into perl and
            // shows the user a "not opened" alert on every attempt. Do not try.
            Self.logger.error("MediaRemoteAdapter.framework is quarantined (\(quarantine, privacy: .public)), media control disabled")
            return nil
        }
        let output = await Subprocess.run(
            Self.perlURL,
            arguments: [scriptURL.path, frameworkURL.path] + arguments,
            timeout: timeout
        )
        if output == nil {
            Self.logger.error("adapter \(arguments.first ?? "", privacy: .public) did not start or timed out")
        }
        return output
    }

    // MARK: - Output parsing

    /// Parses the output of `get`: `null` when no app owns Now Playing, otherwise a JSON object
    /// with at least `processIdentifier` and `playing`.
    static func parseGetOutput(_ output: SubprocessOutput) -> NowPlayingReading {
        guard output.status == 0 else { return .failed }
        let text = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "null" {
            // The adapter also prints null when MediaRemote times out, with an error on stderr.
            return output.stderr.isEmpty ? .noSession : .failed
        }
        // Numeric bridging is exact: `playing` must be a boolean, the pid must fit in Int32.
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let playing = object["playing"] as? Bool,
              let pid = object["processIdentifier"] as? Int32,
              pid > 0
        else { return .failed }

        return .session(NowPlayingSession(
            processIdentifier: pid,
            bundleIdentifier: object["bundleIdentifier"] as? String,
            title: object["title"] as? String,
            isPlaying: playing
        ))
    }

    // MARK: - Quarantine

    /// The `com.apple.quarantine` attribute of `url`, or `nil` when it has none.
    static func quarantineValue(of url: URL) -> String? {
        let name = "com.apple.quarantine"
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        let read = getxattr(url.path, name, &buffer, length, 0, 0)
        guard read > 0 else { return nil }
        return String(decoding: buffer.prefix(read), as: UTF8.self)
    }

    /// `"flags;timestamp;agent;uuid"`, flags in hex. Observed on macOS 27: a downloaded,
    /// unapproved framework (0x0081) is refused, one the user approved (0x0040 set, 0x00c1)
    /// loads. Anything unparsable counts as refused.
    static func quarantineBlocksLoading(_ value: String) -> Bool {
        guard let flags = UInt32(value.prefix(while: { $0 != ";" }), radix: 16) else { return true }
        return flags & 0x0040 == 0
    }
}

// MARK: - Subprocess

struct SubprocessOutput: Sendable, Equatable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stderrText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Subprocess {
    /// Runs `executable` with an empty environment, on a background queue. Returns `nil` when
    /// it cannot start or does not exit within `timeout` (it is then killed).
    static func run(_ executable: URL, arguments: [String], timeout: TimeInterval) async -> SubprocessOutput? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runBlocking(executable, arguments: arguments, timeout: timeout))
            }
        }
    }

    private static func runBlocking(_ executable: URL, arguments: [String], timeout: TimeInterval) -> SubprocessOutput? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // No inherited PERL5LIB / PERL5OPT or locale settings.
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain both pipes while the process runs, so it can never block on a full pipe.
        let stdout = PipeReader(stdoutPipe.fileHandleForReading)
        let stderr = PipeReader(stderrPipe.fileHandleForReading)

        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        guard let out = stdout.wait(timeout: 1), let err = stderr.wait(timeout: 1) else { return nil }
        return SubprocessOutput(status: process.terminationStatus, stdout: out, stderr: err)
    }
}

/// Reads a pipe to EOF on a background queue.
private final class PipeReader: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    /// Written once on the reading queue before `done` is signaled; read only after waiting on it.
    private var data = Data()

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            data = handle.readDataToEndOfFile()
            done.signal()
        }
    }

    func wait(timeout: TimeInterval) -> Data? {
        done.wait(timeout: .now() + timeout) == .success ? data : nil
    }
}
