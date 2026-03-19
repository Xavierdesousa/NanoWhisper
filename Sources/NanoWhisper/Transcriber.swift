import Foundation

class Transcriber {
    private var connection: SocketConnection?
    private var daemonProcess: Process?
    private let socketPath: String
    private let pidPath: String
    private let lock = NSLock()

    var onReady: (() -> Void)?
    var onError: ((String) -> Void)?

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        socketPath = "\(home)/.nanowhisper/daemon.sock"
        pidPath = "\(home)/.nanowhisper/daemon.pid"
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.connectOrLaunch()
        }
    }

    func transcribe(audioURL: URL) async -> String {
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else {
                    continuation.resume(returning: "")
                    return
                }

                // Try sending, reconnect once if socket is dead (e.g. after sleep)
                var response = self.connection?.sendCommand("TRANSCRIBE:\(audioURL.path)")
                if response == nil {
                    self.connection?.disconnect()
                    self.connection = nil
                    if self.tryConnect() {
                        response = self.connection?.sendCommand("TRANSCRIBE:\(audioURL.path)")
                    }
                }

                if let response = response, response.hasPrefix("OK:") {
                    continuation.resume(returning: String(response.dropFirst(3)))
                } else {
                    let err = response ?? "No response from engine"
                    self.onError?(err)
                    continuation.resume(returning: "")
                }
            }
        }
    }

    /// Stop the daemon process entirely
    func stopDaemon() {
        // Try graceful shutdown via socket
        connection?.sendCommand("QUIT")
        connection?.disconnect()
        connection = nil

        // Also kill by PID if needed
        if let pidStr = try? String(contentsOfFile: pidPath, encoding: .utf8),
           let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }

        daemonProcess?.terminate()
        daemonProcess = nil
    }

    /// Just disconnect the app (leave daemon running)
    func disconnect() {
        connection?.disconnect()
        connection = nil
    }

    deinit {
        disconnect()
    }

    // MARK: - Private

    private func connectOrLaunch() {
        // 1. Try connecting to existing daemon
        if tryConnect() {
            onReady?()
            return
        }

        // 2. No daemon running — launch one
        launchDaemon()
    }

    private func tryConnect() -> Bool {
        let conn = SocketConnection(socketPath: socketPath)
        if conn.connect() {
            // Verify it's alive
            if let response = conn.sendCommand("PING"), response == "PONG" {
                self.connection = conn
                return true
            }
            conn.disconnect()
        }
        return false
    }

    private func launchDaemon() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let venvPython = "\(homeDir)/.nanowhisper/venv/bin/python3"

        guard FileManager.default.fileExists(atPath: venvPython) else {
            onError?("Python venv not found. Run setup first.")
            return
        }

        guard let scriptPath = findScript() else {
            onError?("transcribe.py not found")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: venvPython)
        proc.arguments = [scriptPath]
        proc.environment = ProcessInfo.processInfo.environment

        // Read stdout to track LOADING → READY
        let stdoutPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = FileHandle.nullDevice

        // Don't kill daemon when app exits
        proc.qualityOfService = .userInitiated

        do {
            try proc.run()
            daemonProcess = proc
        } catch {
            onError?("Failed to start engine: \(error.localizedDescription)")
            return
        }

        // Wait for READY signal then connect
        let handle = stdoutPipe.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            while true {
                guard let line = self.readLine(from: handle) else { break }

                if line == "READY" {
                    // Daemon is ready, connect via socket
                    // Small delay to ensure socket is accepting
                    Thread.sleep(forTimeInterval: 0.2)

                    if self.tryConnect() {
                        self.onReady?()
                    } else {
                        self.onError?("Engine started but socket connection failed")
                    }
                    return
                } else if line.hasPrefix("ERR:") {
                    self.onError?(String(line.dropFirst(4)))
                    return
                }
            }
        }
    }

    private func findScript() -> String? {
        if let bundlePath = Bundle.main.resourcePath {
            let path = "\(bundlePath)/scripts/transcribe.py"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        let execDir = Bundle.main.bundlePath
        let candidates = [
            "\(execDir)/scripts/transcribe.py",
            "\(execDir)/../scripts/transcribe.py",
            "\(execDir)/../../scripts/transcribe.py",
            "\(execDir)/../Resources/scripts/transcribe.py",
        ]
        for path in candidates {
            let resolved = (path as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolved) {
                return resolved
            }
        }

        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        let devPath = "\(homeDir)/.nanowhisper/transcribe.py"
        if FileManager.default.fileExists(atPath: devPath) {
            return devPath
        }

        return nil
    }

    private func readLine(from handle: FileHandle) -> String? {
        var data = Data()
        while true {
            let byte = handle.readData(ofLength: 1)
            if byte.isEmpty { return nil }
            if byte[0] == UInt8(ascii: "\n") {
                return String(data: data, encoding: .utf8)
            }
            data.append(byte)
        }
    }
}

// MARK: - Unix Socket Connection

class SocketConnection {
    private let socketPath: String
    private var fd: Int32 = -1

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func connect() -> Bool {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return false }

        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let raw = UnsafeMutableRawPointer(ptr)
            pathBytes.withUnsafeBufferPointer { buf in
                raw.copyMemory(from: buf.baseAddress!, byteCount: buf.count)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, addrLen)
            }
        }

        if result < 0 {
            close(fd)
            fd = -1
            return false
        }
        return true
    }

    @discardableResult
    func sendCommand(_ command: String) -> String? {
        guard fd >= 0 else { return nil }

        let msg = command + "\n"
        let sent = msg.withCString { ptr in
            send(fd, ptr, msg.utf8.count, 0)
        }
        guard sent > 0 else { return nil }

        // Read response (one line)
        var response = Data()
        var buf = [UInt8](repeating: 0, count: 1)
        while true {
            let n = recv(fd, &buf, 1, 0)
            if n <= 0 { return nil }
            if buf[0] == UInt8(ascii: "\n") {
                return String(data: response, encoding: .utf8)
            }
            response.append(buf[0])
        }
    }

    func disconnect() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }

    deinit {
        disconnect()
    }
}
