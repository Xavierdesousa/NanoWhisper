import Foundation

// MARK: - Models

/// A model the app can run: an engine and its weights or size.
enum SpeechModel: Hashable, Sendable {
    case parakeet(ParakeetVariant)
    case whisper(WhisperModelSize)

    var engine: TranscriptionModelType {
        switch self {
        case .parakeet: return .parakeet
        case .whisper: return .whisper
        }
    }

    var displayName: String {
        switch self {
        case .parakeet(let variant): return variant.displayName
        case .whisper(let size): return "Whisper \(size.displayName)"
        }
    }

    var sizeDescription: String {
        switch self {
        case .parakeet(let variant): return variant.sizeDescription
        case .whisper(let size): return size.sizeDescription
        }
    }

    /// Folder holding this model's files (`ModelStore`).
    var folder: ModelFolder {
        switch self {
        case .parakeet(let variant): return .parakeet(variant)
        case .whisper(let size): return .whisper(size)
        }
    }
}

/// The model chosen for each engine (only one engine is in use at a time).
struct ModelChoices: Equatable, Sendable {
    var parakeet: ParakeetVariant
    var whisper: WhisperModelSize

    func model(for engine: TranscriptionModelType) -> SpeechModel {
        switch engine {
        case .parakeet: return .parakeet(parakeet)
        case .whisper: return .whisper(whisper)
        }
    }

    mutating func select(_ model: SpeechModel) {
        switch model {
        case .parakeet(let variant): parakeet = variant
        case .whisper(let size): whisper = size
        }
    }
}

/// Per engine, the model a migration moved the user away from, until the new model has been
/// loaded once. While it is set, setting up that engine keeps the previous model working (if
/// it is on disk) while the new one downloads (`SwitchoverPlan`). Persisted, so a download that
/// fails or happens offline is retried at the next launch.
struct PendingModelMoves: Codable, Equatable, Sendable {
    var parakeet: ParakeetVariant?
    var whisper: WhisperModelSize?

    static let defaultsKey = "pendingModelMoves"

    var isEmpty: Bool { parakeet == nil && whisper == nil }

    func previousModel(for engine: TranscriptionModelType) -> SpeechModel? {
        switch engine {
        case .parakeet: return parakeet.map(SpeechModel.parakeet)
        case .whisper: return whisper.map(SpeechModel.whisper)
        }
    }

    /// Every previous model still recorded (both engines).
    var previousModels: [SpeechModel] {
        [previousModel(for: .parakeet), previousModel(for: .whisper)].compactMap { $0 }
    }

    /// Record `model` as the one to fall back on, unless an earlier move already recorded one
    /// for its engine (that older model is the one on disk).
    mutating func recordIfAbsent(_ model: SpeechModel) {
        switch model {
        case .parakeet(let variant): if parakeet == nil { parakeet = variant }
        case .whisper(let size): if whisper == nil { whisper = size }
        }
    }

    mutating func clear(_ engine: TranscriptionModelType) {
        switch engine {
        case .parakeet: parakeet = nil
        case .whisper: whisper = nil
        }
    }

    static func load(from defaults: UserDefaults) -> PendingModelMoves {
        guard let data = defaults.data(forKey: defaultsKey),
              let moves = try? JSONDecoder().decode(PendingModelMoves.self, from: data) else { return PendingModelMoves() }
        return moves
    }

    func save(to defaults: UserDefaults) {
        if isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}


// MARK: - Migration schema

/// One migration step: per engine, the model every user of that engine moves to (any other
/// model of that engine → the target). `nil` leaves the engine out of the step.
struct ModelMigrationStep: Sendable {
    /// Strictly increasing; persisted as the last step applied. Never reuse or renumber.
    let id: Int
    /// Release that introduced the step (documentation only).
    let release: String
    let parakeet: ParakeetVariant?
    let whisper: WhisperModelSize?

    init(id: Int, release: String, parakeet: ParakeetVariant? = nil, whisper: WhisperModelSize? = nil) {
        self.id = id
        self.release = release
        self.parakeet = parakeet
        self.whisper = whisper
    }

    /// The step's targets, as models.
    var targets: [SpeechModel] {
        [parakeet.map(SpeechModel.parakeet), whisper.map(SpeechModel.whisper)].compactMap { $0 }
    }
}

/// The model migration schema: moves users to the recommended model of their engine when a
/// release changes it. Think database migrations.
///
/// - A step names, per engine, the model to move to; any other model of that engine moves to
///   it. A user already on the target is not touched; an engine left out (`nil`) is not touched.
/// - Each step runs **once per install** (`lastAppliedKey` holds the last step applied). A user
///   moved by a step who deliberately selects another model keeps it, until a later step names
///   a target for that engine; then they move like everyone else.
/// - A move changes the stored choice and records the old model in `PendingModelMoves`, so
///   the switchover is smooth: the old model keeps working while the new one downloads in the
///   background (`SwitchoverPlan`, `SetupManager`), and the app switches when it is loaded.
///   Offline or failed: the old model stays in use and the download is retried at next launch.
///   Whisper language and vocabulary hint are untouched (only the size changes).
/// - Moves never delete a model that is still selectable. Obsolete folders are removed by
///   `ModelStore.removeObsoleteModels` once the selected model is loaded. Obsolete choices are
///   replaced by `ObsoleteModels`, not by steps.
/// - New installs start at the latest step: their defaults already are what the app offers.
///
/// At every version bump: see the checklist in docs/wiki/build-and-release.md.
enum ModelMigrations {
    /// Ordered. Append new steps; never edit, reorder or remove a shipped one.
    static let steps: [ModelMigrationStep] = [
        // 0.0.4/0.0.5 kept existing installs on Parakeet v3 to avoid a surprise download.
        // Whisper users keep the size they chose (maintainer decision, 2026-11-20).
        ModelMigrationStep(id: 1, release: "0.0.6", parakeet: .ultra),
    ]

    /// UserDefaults key: id of the last step applied.
    static let lastAppliedKey = "modelMigrationStep"

    static var latestStepID: Int { steps.last?.id ?? 0 }

    /// A choice changed by a migration.
    struct Move: Equatable, Sendable {
        let from: SpeechModel
        let to: SpeechModel
    }

    struct Outcome: Equatable {
        var choices: ModelChoices
        var pending: PendingModelMoves
        var lastApplied: Int
        /// Moves that changed a choice, in order (for logging).
        var applied: [Move]

        /// Select `target` for its engine and remember the old model as the fallback.
        mutating func move(to target: SpeechModel) {
            let current = choices.model(for: target.engine)
            guard current != target else { return }
            choices.select(target)
            pending.recordIfAbsent(current)
            applied.append(Move(from: current, to: target))
        }
    }

    /// Apply the steps after `lastApplied`, in order. Pure.
    static func apply(
        _ steps: [ModelMigrationStep] = steps,
        after lastApplied: Int,
        choices: ModelChoices,
        pending: PendingModelMoves
    ) -> Outcome {
        var outcome = Outcome(choices: choices, pending: pending, lastApplied: lastApplied, applied: [])
        for step in steps where step.id > lastApplied {
            for target in step.targets {
                outcome.move(to: target)
            }
            outcome.lastApplied = step.id
        }
        return outcome
    }

    /// UserDefaults keys whose presence shows the app ran before (any version).
    static let existingInstallMarkerKeys = ParakeetVariant.existingInstallMarkerKeys + [ParakeetVariant.defaultsKey]

    /// Whether the app ran before. Read it before anything writes to the defaults at launch.
    static func isExistingInstall(_ defaults: UserDefaults) -> Bool {
        existingInstallMarkerKeys.contains { defaults.object(forKey: $0) != nil }
    }

    /// Run the pending steps against the persisted state and persist the result.
    ///
    /// Persisted in a recoverable order: the fallback models first, then the new choices
    /// (`persistChoices`), then the last step applied. If the app stops in between, the next
    /// launch runs the step again; a choice already moved is a no-op and the recorded
    /// fallback is kept.
    /// - Parameters:
    ///   - isExistingInstall: from `isExistingInstall(_:)`, read before launch writes. A new
    ///     install starts at the latest step.
    ///   - persistChoices: stores the resulting choices (the app writes its settings here).
    static func run(
        on defaults: UserDefaults,
        choices: ModelChoices,
        isExistingInstall: Bool,
        persistChoices: (ModelChoices) -> Void
    ) -> Outcome {
        let stored = defaults.object(forKey: lastAppliedKey) as? Int
        let lastApplied = stored ?? (isExistingInstall ? 0 : latestStepID)
        var outcome = apply(after: lastApplied, choices: choices, pending: PendingModelMoves.load(from: defaults))
        ObsoleteModels.replace(in: &outcome)
        outcome.pending.save(to: defaults)
        persistChoices(outcome.choices)
        defaults.set(outcome.lastApplied, forKey: lastAppliedKey)
        return outcome
    }
}

// MARK: - Obsolete models

/// Models that can no longer be selected because they are gone upstream. Separate from the
/// migration steps: a step moves people to a better, recommended model; an obsolete model has
/// a declared replacement because it is gone (`WhisperModelSize.replacement`).
///
/// Checked at every launch (not once): a stored obsolete choice is replaced with the same
/// smooth switchover as a migration (the obsolete model keeps working while its replacement
/// downloads, if its files are still on disk). Its folder is then removed automatically
/// (`ModelFolder.isObsolete`) once the replacement is loaded.
enum ObsoleteModels {
    static func replace(in outcome: inout ModelMigrations.Outcome) {
        if let replacement = outcome.choices.whisper.replacement {
            outcome.move(to: .whisper(replacement))
        }
    }
}

// MARK: - Picker labels

enum ModelLabel {
    static let recommendedBadge = "Recommended"

    /// Picker item, e.g. "Parakeet Ultra (~630 MB) · Recommended".
    static func pickerTitle(name: String, size: String, isRecommended: Bool) -> String {
        let base = "\(name) (\(size))"
        return isRecommended ? "\(base) · \(recommendedBadge)" : base
    }
}
