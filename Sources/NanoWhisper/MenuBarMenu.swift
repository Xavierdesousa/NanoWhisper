import Foundation

/// Everything the menu bar menu shows, as plain values (built from `AppState` by
/// `AppState.menuState(permissions:)`; tests build it directly).
struct MenuState: Equatable {
    var appName: String
    /// Debug builds: the menu starts with the app name and `BuildInfo.summary`.
    var debugHeader: String?
    /// Onboarding was never finished and its window is closed.
    var setupUnfinished: Bool
    var microphoneGranted: Bool
    var accessibilityGranted: Bool
    var engine: EngineState
    /// The applied configuration's model, e.g. "Parakeet Ultra".
    var modelName: String
    var modelSize: String
    var isRecording: Bool
    var isTranscribing: Bool
    var lastError: String?
    var update: UpdateStatus.State
    var historyEnabled: Bool
    var historyUnavailable: Bool
}

/// What a menu item does.
enum MenuAction: Equatable {
    case finishSetup
    case toggleDictation
    case retrySetup
    case downloadModel
    case installUpdate
    case showHistory
    case showSettings
    case quit
}

/// One line of the menu. Status and progress lines are disabled (information only).
enum MenuLine: Equatable {
    enum Tone: Equatable {
        case normal
        case recording
        case failure
    }

    /// Debug builds: app name and version · commit.
    case header(title: String, detail: String)
    /// A command. `detail` is muted text on the right; `showsShortcut` draws the record
    /// shortcut there (`ShortcutKeysView`); `keyEquivalent` is a ⌘ key (Settings, Quit).
    case action(MenuAction, title: String, isEnabled: Bool = true, detail: String? = nil,
                showsShortcut: Bool = false, keyEquivalent: String? = nil)
    case status(String, tone: Tone = .normal)
    /// A download: text and a bar (nil fraction: indeterminate).
    case progress(String, fraction: Double?)
    case separator

    /// Whether the line draws the record shortcut (`MenuState` does not carry it).
    var showsShortcut: Bool {
        if case .action(_, _, _, _, let showsShortcut, _) = self { return showsShortcut }
        return false
    }

    /// Identity used to update an open menu in place when only values changed.
    var identity: String {
        switch self {
        case .header: return "header"
        case .action(let action, _, _, _, _, _): return "action.\(action)"
        case .status(let text, _): return "status.\(text.prefix(12))"
        case .progress: return "progress"
        case .separator: return "separator"
        }
    }
}

/// The menu bar menu, as drawn on the "After setup: the menu bar takes over" board: the
/// dictation command with its shortcut, one line naming the model state, History, Settings,
/// Quit; Finish Setup first while onboarding is unfinished; a bar while a model downloads.
/// States the board does not draw (failure, recording, transcribing, error, update) keep
/// today's content in the same form.
enum MenuContent {
    static func lines(for state: MenuState) -> [MenuLine] {
        var lines: [MenuLine] = []

        if let header = state.debugHeader {
            lines.append(.header(title: state.appName, detail: header))
            lines.append(.separator)
        }

        if state.setupUnfinished {
            lines.append(.action(.finishSetup, title: "Finish Setup…", detail: setupReason(state)))
            lines.append(.separator)
        }

        lines.append(.action(
            .toggleDictation,
            title: state.isRecording ? "Stop Dictation" : "Start Dictation",
            isEnabled: state.isRecording || state.engine.isReady,
            showsShortcut: true
        ))
        lines += modelLines(state)

        if let error = state.lastError {
            lines.append(.status(error, tone: .failure))
        }

        switch state.update {
        case .available(let version):
            lines.append(.separator)
            lines.append(.action(.installUpdate, title: "Install Update \(version) and Relaunch"))
        case .downloading(let version, let progress):
            lines.append(.separator)
            lines.append(.progress(version.map { "Downloading update \($0)…" } ?? "Downloading the update…",
                                   fraction: progress))
        case .disabled, .checking, .upToDate:
            break
        }

        lines.append(.separator)
        lines.append(.action(.showHistory, title: historyTitle(state),
                             isEnabled: state.historyEnabled && !state.historyUnavailable))
        lines.append(.action(.showSettings, title: "Settings…", keyEquivalent: ","))
        lines.append(.separator)
        lines.append(.action(.quit, title: "Quit \(state.appName)", keyEquivalent: "q"))
        return lines
    }

    /// The line(s) under Start Dictation: the model in use, its download, or what went wrong.
    static func modelLines(_ state: MenuState) -> [MenuLine] {
        let engine = state.engine
        let name = state.modelName
        if engine.isSettingUp {
            switch ModelStatus.resolve(engine) {
            case .compiling:
                return [.status("Optimizing \(name) for this Mac…")]
            case .downloading(let fraction):
                return [.progress(downloadText(name, fraction), fraction: fraction)]
            default:
                return [.status("Loading \(name)…")]
            }
        }
        if let error = engine.error {
            return [.status("Could not set up \(name)", tone: .failure), .status(error),
                    .action(.retrySetup, title: "Retry")]
        }
        if !engine.isReady, let error = engine.initializationError {
            return [.status("\(name) could not start", tone: .failure), .status(error),
                    .action(.retrySetup, title: "Retry")]
        }
        if !engine.isReady && !engine.setupComplete {
            // First launch: the download waits for the user (`shouldDeferSetupAtLaunch`).
            return [.status("\(name) is not downloaded"),
                    .action(.downloadModel, title: "Download \(name) (\(state.modelSize))")]
        }
        if !engine.isReady {
            return [.status("Loading \(name)…")]
        }

        var lines: [MenuLine]
        if state.isRecording {
            lines = [.status("Recording…", tone: .recording)]
        } else if state.isTranscribing {
            lines = [.status("Transcribing…")]
        } else {
            // During a migration's switchover the previous model is the one in use.
            lines = [.status("\(engine.upgrade?.from.displayName ?? name) is ready")]
        }
        // A migration's new model downloading in the background. A failed or offline
        // download is not shown: dictation works, it retries at next launch.
        if let upgrade = engine.upgrade, case .downloading(let fraction) = upgrade.status {
            lines.append(.progress(downloadText(upgrade.to.displayName, fraction), fraction: fraction))
        }
        return lines
    }

    /// "Downloading Parakeet Ultra, 64%" or "Downloading Whisper Small…" without a percentage.
    static func downloadText(_ name: String, _ fraction: Double?) -> String {
        guard let fraction else { return "Downloading \(name)…" }
        return "Downloading \(name), \(Int((fraction * 100).rounded()))%"
    }

    /// Why setup is unfinished, shown on the right of Finish Setup…
    static func setupReason(_ state: MenuState) -> String? {
        if !state.microphoneGranted { return "Microphone is off" }
        if !state.accessibilityGranted { return "Accessibility is off" }
        return nil
    }

    static func historyTitle(_ state: MenuState) -> String {
        if state.historyUnavailable { return "History (unavailable)" }
        return state.historyEnabled ? "History…" : "History (disabled)"
    }
}
