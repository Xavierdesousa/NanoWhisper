import Foundation

struct SubprocessOutput: Sendable, Equatable {
    let status: Int32
    let stdout: Data
    let stderr: Data

    var stderrText: String {
        String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs short-lived helper processes (`osascript`, for Now Playing; `ditto`, for updates) with an empty
/// environment, off the caller's actor, never letting one hang.
enum Subprocess {
    /// Runs `executable` to completion. Returns `nil` when it cannot start, does not exit
    /// within `timeout`, or `stopWhen` (asked every 0.1 s) says to stop (it is then killed).
    static func run(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        stopWhen: (@Sendable () -> Bool)? = nil
    ) async -> SubprocessOutput? {
        await onBackgroundQueue {
            runBlocking(executable, arguments: arguments, timeout: timeout, stopWhen: stopWhen)
        }
    }

    /// Starts `executable` and returns its first stdout line as soon as it is printed, leaving
    /// the process to finish in the background. The process is reaped when it exits and killed
    /// if it is still running after `killAfter`. `line` is `nil` when it cannot start or prints
    /// no line within `lineTimeout` (it is then killed right away). `input` is written to the
    /// process's standard input, which is then closed; whether the process reads it or not
    /// changes none of these delays.
    static func start(
        _ executable: URL,
        arguments: [String],
        input: Data? = nil,
        lineTimeout: TimeInterval,
        killAfter: TimeInterval
    ) async -> (line: String?, process: BackgroundProcess?) {
        await onBackgroundQueue {
            startBlocking(executable, arguments: arguments, input: input, lineTimeout: lineTimeout, killAfter: killAfter)
        }
    }

    private static func onBackgroundQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: work())
            }
        }
    }

    private static func makeProcess(_ executable: URL, arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        // Nothing inherited from the app's environment (e.g. OSA_LIBRARY_PATH or locale settings).
        process.environment = [:]
        process.standardInput = FileHandle.nullDevice
        return process
    }

    private static func runBlocking(
        _ executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        stopWhen: (@Sendable () -> Bool)?
    ) -> SubprocessOutput? {
        let process = makeProcess(executable, arguments: arguments)
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

        let deadline = DispatchTime.now() + timeout
        var didExit = false
        repeat {
            didExit = exited.wait(timeout: stopWhen == nil ? deadline : min(deadline, .now() + 0.1)) == .success
        } while !didExit && DispatchTime.now() < deadline && stopWhen?() == false

        guard didExit else {
            process.terminate()
            if exited.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        guard let out = stdout.wait(timeout: 1), let err = stderr.wait(timeout: 1) else { return nil }
        return SubprocessOutput(status: process.terminationStatus, stdout: out, stderr: err)
    }

    private static func startBlocking(
        _ executable: URL,
        arguments: [String],
        input: Data?,
        lineTimeout: TimeInterval,
        killAfter: TimeInterval
    ) -> (line: String?, process: BackgroundProcess?) {
        let process = makeProcess(executable, arguments: arguments)
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        let stdinPipe = input == nil ? nil : Pipe()
        if let stdinPipe { process.standardInput = stdinPipe }
        let background = BackgroundProcess(process)

        do {
            try process.run()
        } catch {
            process.terminationHandler = nil // never called: break the retain cycle
            return (nil, nil)
        }
        background.killIfRunning(after: killAfter)
        if let input, let stdinPipe { write(input, to: stdinPipe) }
        let reader = FirstLineReader(stdoutPipe.fileHandleForReading)
        guard let line = reader.wait(timeout: lineTimeout) else {
            background.killIfRunning(after: 0)
            return (nil, background)
        }
        return (line, background)
    }

    /// Writes `input` to a started process on a background queue (it may exceed the pipe's
    /// buffer), then closes the pipe. If the process exits without reading, the write fails.
    private static func write(_ input: Data, to pipe: Pipe) {
        // Only the process must hold the reading end, or a write to a dead one would block.
        try? pipe.fileHandleForReading.close()
        let handle = pipe.fileHandleForWriting
        // An error instead of SIGPIPE, which would end the app.
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            try? handle.close()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: input)
            try? handle.close()
        }
    }
}

/// A process left running by `Subprocess.start`. Foundation reaps it when it exits.
final class BackgroundProcess: @unchecked Sendable {
    private let process: Process
    /// Signaled once the process has exited and been reaped.
    private let exited = DispatchSemaphore(value: 0)

    var processIdentifier: Int32 { process.processIdentifier }

    fileprivate init(_ process: Process) {
        self.process = process
        // Keeps self (and the Process) alive until the process exits.
        process.terminationHandler = { [self] finished in
            finished.terminationHandler = nil
            exited.signal()
        }
    }

    /// Waits until the process has exited, at most `timeout`. Returns whether it exited.
    func waitForExit(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let didExit = exited.wait(timeout: .now() + timeout) == .success
                if didExit { exited.signal() } // let other waiters through
                continuation.resume(returning: didExit)
            }
        }
    }

    /// Terminates the process after `delay` if it is still running, then kills it 0.5 s later.
    fileprivate func killIfRunning(after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [self] in
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) { [self] in
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
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

/// Hands out the first line of a pipe as soon as it arrives, and keeps draining the pipe to
/// EOF so the writer never blocks.
private final class FirstLineReader: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    /// Written once on the reading queue before `ready` is signaled; read only after waiting on it.
    private var line: String?

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var buffer = Data()
            var delivered = false
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                // read(2) returns as soon as anything is available (FileHandle.read(upToCount:)
                // waits for the full count or EOF).
                let count = Darwin.read(handle.fileDescriptor, &chunk, chunk.count)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { break } // EOF or error
                guard !delivered else { continue }
                buffer.append(contentsOf: chunk[..<count])
                if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    line = String(decoding: buffer[..<newline], as: UTF8.self)
                    delivered = true
                    ready.signal()
                }
            }
            try? handle.close()
            if !delivered { ready.signal() } // EOF without a full line: `line` stays nil
        }
    }

    func wait(timeout: TimeInterval) -> String? {
        ready.wait(timeout: .now() + timeout) == .success ? line : nil
    }
}
