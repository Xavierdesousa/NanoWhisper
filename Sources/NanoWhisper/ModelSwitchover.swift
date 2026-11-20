import Foundation

/// How setting up the selected model starts.
enum SwitchoverPlan: Equatable, Sendable {
    /// Load the selected model (downloading it if needed).
    case load(SpeechModel)
    /// A migration moved the user from `previous`, which is on disk while `selected` is not:
    /// start on `previous` so dictation works right away (and offline), download `selected`
    /// in the background, switch when it is loaded.
    case startOnPrevious(SpeechModel, upgradeTo: SpeechModel)

    /// - Parameters:
    ///   - previous: the model a pending migration moved this engine away from, if any.
    ///   - isOnDisk: whether a model's files are complete on disk. Only called for the
    ///     engine being set up (for Whisper, the user is on Whisper: no new Documents prompt).
    static func resolve(
        selected: SpeechModel,
        previous: SpeechModel?,
        isOnDisk: (SpeechModel) -> Bool
    ) -> SwitchoverPlan {
        guard let previous, previous != selected, previous.engine == selected.engine,
              !isOnDisk(selected), isOnDisk(previous) else { return .load(selected) }
        return .startOnPrevious(previous, upgradeTo: selected)
    }
}

/// Why a model is being loaded (lets the loader pick a local-only load or route progress).
enum ModelLoadRole: Sendable {
    /// The selected model, in the foreground: progress shows as setup progress.
    case selected
    /// The previous model, from disk, while the selected one downloads.
    case previous
    /// The selected model, downloaded in the background while the previous one is in use.
    case upgrade
}

/// The switchover sequence, independent of the engines (tests drive it with fakes).
@MainActor
enum ModelSwitchover {
    /// Run `plan`.
    ///
    /// - `onReady`: the first usable model is loaded. Return `false` if this setup was
    ///   superseded (nothing more happens).
    /// - `.startOnPrevious`: after `onReady(previous)`, `onUpgradeStarted`, then the selected
    ///   model loads in the background; `onUpgraded` when it is loaded, `onUpgradeFailed`
    ///   otherwise (the previous model stays in use). Cancellation ends the sequence silently.
    ///   If the previous model fails to load, the selected one loads in the foreground instead.
    /// - Throws only when no model could be made ready.
    static func run<Loaded: Sendable>(
        _ plan: SwitchoverPlan,
        load: (SpeechModel, ModelLoadRole) async throws -> Loaded,
        onReady: (Loaded, SpeechModel) -> Bool,
        onUpgradeStarted: (_ from: SpeechModel, _ to: SpeechModel) -> Void,
        onUpgraded: (Loaded, SpeechModel) -> Void,
        onUpgradeFailed: (any Error) -> Void
    ) async throws {
        switch plan {
        case .load(let model):
            let loaded = try await load(model, .selected)
            _ = onReady(loaded, model)

        case .startOnPrevious(let previous, let selected):
            let first: Loaded
            do {
                first = try await load(previous, .previous)
            } catch {
                try Task.checkCancellation()
                let loaded = try await load(selected, .selected)
                _ = onReady(loaded, selected)
                return
            }
            guard onReady(first, previous) else { return }
            onUpgradeStarted(previous, selected)
            do {
                let loaded = try await load(selected, .upgrade)
                try Task.checkCancellation()
                onUpgraded(loaded, selected)
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                onUpgradeFailed(error)
            }
        }
    }
}

/// Background download of a migration target while the previous model keeps working.
struct ModelUpgrade: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        /// `fraction` is nil when the download reports no percentage (Whisper, preparation).
        case downloading(fraction: Double?)
        /// Failed or offline: the previous model stays in use; retried at next launch or Retry.
        case deferred
    }

    let from: SpeechModel
    let to: SpeechModel
    var status: Status

    var isDownloading: Bool {
        if case .downloading = status { return true }
        return false
    }
}

/// Wording of the upgrade status, shared by the menu and the Model section.
enum ModelUpgradeText {
    /// e.g. "Downloading the improved model (~630 MB)… 42%".
    static func progress(_ upgrade: ModelUpgrade) -> String {
        let base = "Downloading the improved model (\(upgrade.to.sizeDescription))…"
        guard case .downloading(let fraction?) = upgrade.status else { return base }
        return "\(base) \(Int((fraction * 100).rounded()))%"
    }

    /// Second line in the Model section.
    static func detail(_ upgrade: ModelUpgrade) -> String {
        switch upgrade.status {
        case .downloading:
            return "\(upgrade.from.displayName) stays in use until it is ready."
        case .deferred:
            return "\(upgrade.from.displayName) is in use. \(upgrade.to.displayName) will download at next launch."
        }
    }
}
