import Carbon
import Foundation

/// Which build of the app is running. Production (`NanoWhisper.app`, the GitHub release)
/// and debug (`NanoWhisper Debug.app`, local `make app` builds) can be installed and run
/// side by side, so everything they could collide on is derived from here.
///
/// The flavor is resolved from the bundle identifier only: the production identifier
/// means production, anything else (the debug identifier, or no bundle at all when the
/// executable runs unbundled via `make run`) means debug.
enum BuildFlavor: String, CaseIterable, Sendable {
    case production
    case debug

    static let productionBundleIdentifier = "com.moonji.nanowhisper"
    static let debugBundleIdentifier = "com.moonji.nanowhisper.debug"

    /// The flavor of the running process.
    static let current = BuildFlavor(bundleIdentifier: Bundle.main.bundleIdentifier)

    init(bundleIdentifier: String?) {
        self = bundleIdentifier == Self.productionBundleIdentifier ? .production : .debug
    }

    var isDebug: Bool { self == .debug }

    var bundleIdentifier: String {
        switch self {
        case .production: return Self.productionBundleIdentifier
        case .debug: return Self.debugBundleIdentifier
        }
    }

    /// User-facing app name, used in the menu header and window titles.
    var displayName: String {
        switch self {
        case .production: return "NanoWhisper"
        case .debug: return "NanoWhisper Debug"
        }
    }

    /// `os.Logger` subsystem, so each build's logs can be filtered separately.
    var logSubsystem: String { bundleIdentifier }

    // MARK: - Storage

    /// Folder in Application Support holding the encrypted history.
    var supportDirectoryName: String { displayName }

    func supportDirectory(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent(supportDirectoryName, isDirectory: true)
    }

    /// Prefix of the temporary recordings. Each build deletes leftover files with its own
    /// prefix at launch, so neither prefix may start with the other: the released
    /// production app deletes every `nanowhisper_*.wav` and must never match a debug file.
    var temporaryAudioFilePrefix: String {
        switch self {
        case .production: return "nanowhisper_"
        case .debug: return "nanowhisper-debug_"
        }
    }

    func temporaryAudioFileName(id: UUID = UUID()) -> String {
        "\(temporaryAudioFilePrefix)\(id.uuidString).wav"
    }

    /// Whether a file in the temp directory is a recording written by this build.
    func ownsTemporaryAudioFile(named name: String) -> Bool {
        name.hasPrefix(temporaryAudioFilePrefix) && name.hasSuffix(".wav")
    }

    // MARK: - Behavior

    /// Global hotkey used until the user picks one. Carbon hotkeys are system-wide, so
    /// both builds cannot use the same combination: debug defaults to ⌃⌥Space.
    var defaultShortcut: Shortcut {
        switch self {
        case .production:
            return Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        case .debug:
            return Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | controlKey))
        }
    }

    /// The updater installs the latest GitHub release over the running bundle, which would
    /// turn a debug build into the production app, so it only runs in production.
    var autoUpdatesEnabled: Bool { self == .production }

    /// Live transcription (beta) still has open design problems, so production does not offer
    /// it: the toggle is hidden and no live session starts, even when the stored setting is on
    /// (the stored value is kept). The debug build keeps it so it can be worked on.
    var supportsLiveTranscription: Bool { self == .debug }

    /// Settings › Advanced › "Open Onboarding" (replays onboarding from its opening scene, with
    /// Settings left open) is a tool for working on onboarding: production has no such control
    /// (maintainer, 2026-11-21). `--onboarding` still works in both builds.
    var offersOnboardingReplay: Bool { self == .debug }
}

/// Version information embedded in the bundle's Info.plist.
struct BuildInfo: Equatable, Sendable {
    /// Info.plist key holding the short git commit; the Makefile sets it in debug bundles.
    static let gitCommitKey = "NWGitCommit"

    let version: String?
    let commit: String?

    init(infoDictionary: [String: Any]?) {
        version = infoDictionary?["CFBundleShortVersionString"] as? String
        let commit = infoDictionary?[Self.gitCommitKey] as? String
        self.commit = (commit?.isEmpty ?? true) ? nil : commit
    }

    static let current = BuildInfo(infoDictionary: Bundle.main.infoDictionary)

    /// e.g. `v0.0.4 · abc1234`; `unbundled build` when neither is known (`make run`).
    var summary: String {
        let parts = [version.map { "v\($0)" }, commit].compactMap { $0 }
        return parts.isEmpty ? "unbundled build" : parts.joined(separator: " · ")
    }
}
