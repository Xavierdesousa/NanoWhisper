import Foundation
import AppKit

class SetupManager: ObservableObject {
    @Published var isSettingUp = false
    @Published var setupProgress = ""
    @Published var setupComplete = false
    @Published var setupError: String?

    private let nanowhisperDir: String
    private let venvDir: String

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        nanowhisperDir = "\(home)/.nanowhisper"
        venvDir = "\(nanowhisperDir)/venv"
    }

    var needsSetup: Bool {
        !FileManager.default.fileExists(atPath: "\(venvDir)/bin/python3")
    }

    func runSetup() {
        guard needsSetup else {
            setupComplete = true
            return
        }

        isSettingUp = true
        setupProgress = "Starting setup..."
        setupError = nil

        // Find setup.sh in bundle
        guard let scriptPath = findSetupScript() else {
            setupError = "setup.sh not found in app bundle"
            isSettingUp = false
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.executeSetup(scriptPath: scriptPath)
        }
    }

    private func findSetupScript() -> String? {
        if let resourcePath = Bundle.main.resourcePath {
            let path = "\(resourcePath)/scripts/setup.sh"
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }

        let bundlePath = Bundle.main.bundlePath
        let candidates = [
            "\(bundlePath)/scripts/setup.sh",
            "\(bundlePath)/../scripts/setup.sh",
            "\(bundlePath)/../../scripts/setup.sh",
            "\(bundlePath)/../Resources/scripts/setup.sh",
        ]
        for path in candidates {
            let resolved = (path as NSString).standardizingPath
            if FileManager.default.fileExists(atPath: resolved) {
                return resolved
            }
        }
        return nil
    }

    private func executeSetup(scriptPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        process.environment = ProcessInfo.processInfo.environment

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        // Read output line by line for progress
        let handle = outputPipe.fileHandleForReading

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                self.setupError = "Failed to run setup: \(error.localizedDescription)"
                self.isSettingUp = false
            }
            return
        }

        // Read output in real-time
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lastMeaningfulLine = ""

            while true {
                guard let line = self?.readLine(from: handle) else { break }

                // Filter for meaningful progress lines
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }

                // Pick up key progress messages
                if trimmed.contains("Creating virtual environment") {
                    lastMeaningfulLine = "Creating Python environment..."
                } else if trimmed.contains("Installing dependencies") {
                    lastMeaningfulLine = "Installing dependencies (few minutes)..."
                } else if trimmed.contains("Downloading model") {
                    lastMeaningfulLine = "Downloading model (~2GB)..."
                } else if trimmed.contains("Setup complete") {
                    lastMeaningfulLine = "Setup complete!"
                } else if trimmed.hasPrefix("STEP:") {
                    lastMeaningfulLine = String(trimmed.dropFirst(5))
                } else if trimmed.contains("Installing") || trimmed.contains("Collecting") {
                    // Show pip progress occasionally
                    if trimmed.contains("torch") {
                        lastMeaningfulLine = "Installing PyTorch..."
                    } else if trimmed.contains("nemo") {
                        lastMeaningfulLine = "Installing NeMo toolkit..."
                    }
                }

                if !lastMeaningfulLine.isEmpty {
                    let msg = lastMeaningfulLine
                    DispatchQueue.main.async {
                        self?.setupProgress = msg
                    }
                }
            }
        }

        process.waitUntilExit()

        DispatchQueue.main.async {
            if process.terminationStatus == 0 {
                self.setupComplete = true
                self.isSettingUp = false
                self.setupProgress = "Setup complete!"
            } else {
                self.setupError = "Setup failed (exit code \(process.terminationStatus)). Check that python3 is installed."
                self.isSettingUp = false
            }
        }
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
