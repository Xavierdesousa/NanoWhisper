import Foundation
import Testing
import FluidAudio
@testable import NanoWhisper

@Suite("Model migrations")
struct ModelMigrationTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "NanoWhisperTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func choices(_ parakeet: ParakeetVariant, _ whisper: WhisperModelSize) -> ModelChoices {
        ModelChoices(parakeet: parakeet, whisper: whisper)
    }

    /// `ModelMigrations.run`, persisting the Parakeet choice as the app does.
    private func runMigrations(on defaults: UserDefaults, choices: ModelChoices, isExistingInstall: Bool) -> ModelMigrations.Outcome {
        ModelMigrations.run(on: defaults, choices: choices, isExistingInstall: isExistingInstall) {
            defaults.set($0.parakeet.rawValue, forKey: ParakeetVariant.defaultsKey)
        }
    }

    @Test("Persistence order: fallback, then choices, then the step (a stop in between re-runs it safely)")
    func persistenceOrder() {
        let defaults = makeDefaults()
        defaults.set("v3", forKey: ParakeetVariant.defaultsKey)
        var seenWhenPersisting: (pending: ParakeetVariant?, step: Int?)?
        _ = ModelMigrations.run(on: defaults, choices: choices(.v3, .base), isExistingInstall: true) { _ in
            seenWhenPersisting = (PendingModelMoves.load(from: defaults).parakeet,
                                  defaults.object(forKey: ModelMigrations.lastAppliedKey) as? Int)
        }
        #expect(seenWhenPersisting?.pending == .v3)
        #expect(seenWhenPersisting?.step == nil)

        // Stopped after the choice was written but before the step: the re-run keeps the fallback.
        defaults.removeObject(forKey: ModelMigrations.lastAppliedKey)
        let rerun = runMigrations(on: defaults, choices: choices(.ultra, .base), isExistingInstall: true)
        #expect(rerun.choices.parakeet == .ultra)
        #expect(rerun.pending.parakeet == .v3)
    }

    // MARK: - Schema

    @Test("The schema: ids strictly increasing; step 1 moves Parakeet to Ultra and leaves Whisper out")
    func schemaShape() {
        let ids = ModelMigrations.steps.map(\.id)
        #expect(ids == ids.sorted() && Set(ids).count == ids.count && ids.first ?? 0 > 0)
        let first = ModelMigrations.steps[0]
        #expect(first.parakeet == .ultra)
        #expect(first.whisper == nil)
        // Every target is offered.
        for step in ModelMigrations.steps {
            if let whisper = step.whisper { #expect(whisper.isSelectable) }
        }
    }

    @Test("Step 1 decision table", arguments: [
        (ParakeetVariant.v3, WhisperModelSize.base, ParakeetVariant.ultra, true),
        (.ultra, .base, .ultra, false),
        (.v3, .small, .ultra, true),
        (.ultra, .largev3Turbo, .ultra, false),
    ])
    func stepOneTable(parakeet: ParakeetVariant, whisper: WhisperModelSize, expected: ParakeetVariant, moved: Bool) {
        let outcome = ModelMigrations.apply(after: 0, choices: choices(parakeet, whisper), pending: PendingModelMoves())
        #expect(outcome.choices.parakeet == expected)
        #expect(outcome.choices.whisper == whisper) // Whisper users keep their size
        #expect(outcome.pending.parakeet == (moved ? parakeet : nil))
        #expect(outcome.pending.whisper == nil)
        #expect(outcome.lastApplied == ModelMigrations.latestStepID)
        #expect(outcome.applied == (moved ? [.init(from: .parakeet(parakeet), to: .parakeet(expected))] : []))
    }

    @Test("Steps already applied do not run again")
    func stepsRunOnce() {
        let outcome = ModelMigrations.apply(after: 1, choices: choices(.v3, .base), pending: PendingModelMoves())
        #expect(outcome.choices.parakeet == .v3)
        #expect(outcome.pending.isEmpty)
        #expect(outcome.lastApplied == 1)
    }

    @Test("An engine absent from a step is untouched; a Whisper-only step moves only Whisper")
    func engineAbsentFromStep() {
        let steps = [
            ModelMigrationStep(id: 1, release: "test", parakeet: .ultra),
            ModelMigrationStep(id: 2, release: "test", whisper: .largev3Turbo),
        ]
        let afterOne = ModelMigrations.apply(steps, after: 0, choices: choices(.ultra, .small), pending: PendingModelMoves())
        #expect(afterOne.choices == choices(.ultra, .largev3Turbo))
        #expect(afterOne.pending == PendingModelMoves(parakeet: nil, whisper: .small))
        let onlyOne = ModelMigrations.apply(Array(steps.prefix(1)), after: 0, choices: choices(.v3, .small), pending: PendingModelMoves())
        #expect(onlyOne.choices.whisper == .small)
    }

    @Test("Chained moves keep the oldest previous model (the one on disk) as the fallback")
    func chainedMovesKeepOldestFallback() {
        let pending = PendingModelMoves(parakeet: .v3, whisper: nil)
        let steps = [ModelMigrationStep(id: 2, release: "test", parakeet: .v3)]
        // Contrived: a pending v3 → Ultra move, then a step targeting v3 again.
        let outcome = ModelMigrations.apply(steps, after: 1, choices: choices(.ultra, .base), pending: pending)
        #expect(outcome.choices.parakeet == .v3)
        #expect(outcome.pending.parakeet == .v3)
    }

    // MARK: - Persistence

    @Test("Existing install on v3: moved to Ultra once, step recorded, fallback persisted")
    func runOnExistingInstall() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "onboardingComplete")
        let existing = ModelMigrations.isExistingInstall(defaults)
        let variant = ParakeetVariant.loadOrMigrate(from: defaults) // what 0.0.5 resolved: v3
        #expect(variant == .v3)
        let outcome = runMigrations(on: defaults, choices: choices(variant, .base), isExistingInstall: existing)
        #expect(outcome.choices.parakeet == .ultra)
        #expect(defaults.integer(forKey: ModelMigrations.lastAppliedKey) == 1)
        #expect(PendingModelMoves.load(from: defaults).parakeet == .v3)
    }

    @Test("New install starts at the latest step and is not migrated")
    func runOnNewInstall() {
        let defaults = makeDefaults()
        #expect(!ModelMigrations.isExistingInstall(defaults))
        let outcome = runMigrations(on: defaults, choices: choices(.v3, .base), isExistingInstall: false)
        #expect(outcome.choices.parakeet == .v3) // untouched: a new install's v3 would be a choice
        #expect(outcome.applied.isEmpty)
        #expect(defaults.integer(forKey: ModelMigrations.lastAppliedKey) == ModelMigrations.latestStepID)
        #expect(defaults.data(forKey: PendingModelMoves.defaultsKey) == nil)
    }

    @Test("A 0.0.5 install already on Ultra is a no-op")
    func runOnUltraInstall() {
        let defaults = makeDefaults()
        defaults.set("ultra", forKey: ParakeetVariant.defaultsKey)
        let outcome = runMigrations(on: defaults, choices: choices(.ultra, .largev3Turbo),
                                          isExistingInstall: ModelMigrations.isExistingInstall(defaults))
        #expect(outcome.applied.isEmpty)
        #expect(outcome.pending.isEmpty)
    }

    @Test("Scenario: migrated by step 1, user reselects v3, relaunch keeps v3, a later step moves them again")
    func reselectAndLaterStep() {
        let defaults = makeDefaults()
        defaults.set("v3", forKey: ParakeetVariant.defaultsKey)

        // Launch 1: step 1 moves v3 → Ultra.
        var outcome = runMigrations(on: defaults, choices: choices(.v3, .base), isExistingInstall: true)
        #expect(outcome.choices.parakeet == .ultra)

        // The user deliberately applies v3 again (AppState clears the engine's pending move).
        var pending = PendingModelMoves.load(from: defaults)
        pending.clear(.parakeet)
        pending.save(to: defaults)
        defaults.set("v3", forKey: ParakeetVariant.defaultsKey)

        // Launch 2: nothing happens.
        outcome = runMigrations(on: defaults, choices: choices(.v3, .base), isExistingInstall: true)
        #expect(outcome.choices.parakeet == .v3)
        #expect(outcome.applied.isEmpty)
        #expect(outcome.pending.isEmpty)

        // A later release adds step 2 for Parakeet: they move like everyone else.
        let future = ModelMigrations.steps + [ModelMigrationStep(id: 2, release: "next", parakeet: .ultra)]
        let later = ModelMigrations.apply(future, after: defaults.integer(forKey: ModelMigrations.lastAppliedKey),
                                          choices: choices(.v3, .base), pending: PendingModelMoves())
        #expect(later.choices.parakeet == .ultra)
        #expect(later.pending.parakeet == .v3)
        #expect(later.lastApplied == 2)
    }

    // MARK: - Obsolete replacements

    @Test("Stored obsolete Whisper sizes are replaced at every launch, with a fallback", arguments: [
        (WhisperModelSize.tiny, WhisperModelSize.base),
        (.medium, .largev3Turbo),
        (.largev3, .largev3Turbo),
    ])
    func obsoleteReplaced(old: WhisperModelSize, replacement: WhisperModelSize) {
        let defaults = makeDefaults()
        defaults.set(ModelMigrations.latestStepID, forKey: ModelMigrations.lastAppliedKey) // steps all done
        let outcome = runMigrations(on: defaults, choices: choices(.ultra, old), isExistingInstall: true)
        #expect(outcome.choices.whisper == replacement)
        #expect(outcome.pending.whisper == old)
        #expect(PendingModelMoves.load(from: defaults).whisper == old)
    }

    @Test("0.0.5 already rewrote Medium to Large v3 Turbo: not replaced again")
    func mediumAlreadyRewritten() {
        let outcome = runMigrations(on: makeDefaults(), choices: choices(.ultra, .largev3Turbo), isExistingInstall: true)
        #expect(outcome.choices.whisper == .largev3Turbo)
        #expect(outcome.pending.whisper == nil)
    }

    @Test("PendingModelMoves persistence: empty removes the key")
    func pendingPersistence() {
        let defaults = makeDefaults()
        PendingModelMoves(parakeet: .v3, whisper: .medium).save(to: defaults)
        #expect(PendingModelMoves.load(from: defaults) == PendingModelMoves(parakeet: .v3, whisper: .medium))
        PendingModelMoves().save(to: defaults)
        #expect(defaults.data(forKey: PendingModelMoves.defaultsKey) == nil)
    }
}

// MARK: - Switchover

@Suite("Model switchover")
@MainActor
struct ModelSwitchoverTests {
    private let v3 = SpeechModel.parakeet(.v3)
    private let ultra = SpeechModel.parakeet(.ultra)

    @Test("Plan decision table")
    func planTable() {
        func plan(selected: SpeechModel, previous: SpeechModel?, onDisk: Set<SpeechModel>) -> SwitchoverPlan {
            SwitchoverPlan.resolve(selected: selected, previous: previous, isOnDisk: { onDisk.contains($0) })
        }
        // Ultra on disk: load it.
        #expect(plan(selected: ultra, previous: v3, onDisk: [ultra, v3]) == .load(ultra))
        // Only v3 on disk: start on v3, upgrade.
        #expect(plan(selected: ultra, previous: v3, onDisk: [v3]) == .startOnPrevious(v3, upgradeTo: ultra))
        // Neither: normal Ultra download.
        #expect(plan(selected: ultra, previous: v3, onDisk: []) == .load(ultra))
        // No pending move: never falls back.
        #expect(plan(selected: ultra, previous: nil, onDisk: [v3]) == .load(ultra))
        // Whisper replacement with the obsolete model on disk.
        #expect(plan(selected: .whisper(.largev3Turbo), previous: .whisper(.medium), onDisk: [.whisper(.medium)])
                == .startOnPrevious(.whisper(.medium), upgradeTo: .whisper(.largev3Turbo)))
        // A previous model of another engine is ignored.
        #expect(plan(selected: ultra, previous: .whisper(.base), onDisk: [.whisper(.base)]) == .load(ultra))
    }

    private struct LoadError: Error {}

    /// Records the sequence of loads and callbacks.
    private final class Log {
        var events: [String] = []
    }

    private func run(
        _ plan: SwitchoverPlan,
        failing: Set<String> = [],
        readyResult: Bool = true,
        log: Log
    ) async throws {
        try await ModelSwitchover.run(
            plan,
            load: { model, role in
                let name = "\(model.displayName)/\(role)"
                log.events.append("load \(name)")
                if failing.contains(name) { throw LoadError() }
                return model.displayName
            },
            onReady: { loaded, _ in log.events.append("ready \(loaded)"); return readyResult },
            onUpgradeStarted: { from, to in log.events.append("upgrade \(from.displayName) → \(to.displayName)") },
            onUpgraded: { loaded, _ in log.events.append("upgraded \(loaded)") },
            onUpgradeFailed: { _ in log.events.append("upgrade failed") }
        )
    }

    @Test("Ultra on disk or neither on disk: one foreground load")
    func directLoad() async throws {
        let log = Log()
        try await run(.load(ultra), log: log)
        #expect(log.events == ["load Parakeet Ultra/selected", "ready Parakeet Ultra"])
    }

    @Test("v3 on disk: ready on v3 first, Ultra in the background, then the switch")
    func safeSwitchover() async throws {
        let log = Log()
        try await run(.startOnPrevious(v3, upgradeTo: ultra), log: log)
        #expect(log.events == [
            "load Parakeet TDT 0.6B v3/previous",
            "ready Parakeet TDT 0.6B v3",
            "upgrade Parakeet TDT 0.6B v3 → Parakeet Ultra",
            "load Parakeet Ultra/upgrade",
            "upgraded Parakeet Ultra",
        ])
    }

    @Test("Ultra download fails or offline: stays on v3, nothing thrown")
    func upgradeFails() async throws {
        let log = Log()
        try await run(.startOnPrevious(v3, upgradeTo: ultra), failing: ["Parakeet Ultra/upgrade"], log: log)
        #expect(log.events.last == "upgrade failed")
        #expect(log.events.contains("ready Parakeet TDT 0.6B v3"))
        #expect(!log.events.contains { $0.hasPrefix("upgraded") })
    }

    @Test("Previous model unusable: the selected one loads in the foreground")
    func previousFails() async throws {
        let log = Log()
        try await run(.startOnPrevious(v3, upgradeTo: ultra), failing: ["Parakeet TDT 0.6B v3/previous"], log: log)
        #expect(log.events == [
            "load Parakeet TDT 0.6B v3/previous",
            "load Parakeet Ultra/selected",
            "ready Parakeet Ultra",
        ])
    }

    @Test("Both unusable: throws (the setup error shows)")
    func bothFail() async {
        let log = Log()
        await #expect(throws: LoadError.self) {
            try await run(.startOnPrevious(v3, upgradeTo: ultra),
                          failing: ["Parakeet TDT 0.6B v3/previous", "Parakeet Ultra/selected"], log: log)
        }
    }

    @Test("Superseded setup (onReady returns false): no background download")
    func superseded() async throws {
        let log = Log()
        try await run(.startOnPrevious(v3, upgradeTo: ultra), readyResult: false, log: log)
        #expect(log.events == ["load Parakeet TDT 0.6B v3/previous", "ready Parakeet TDT 0.6B v3"])
    }

    @Test("Cancelled during the background download: ends silently")
    func cancelledUpgrade() async throws {
        let log = Log()
        let task = Task { @MainActor in
            try await ModelSwitchover.run(
                .startOnPrevious(v3, upgradeTo: ultra),
                load: { model, role in
                    if role == .upgrade {
                        try await Task.sleep(nanoseconds: 5_000_000_000)
                    }
                    return model.displayName
                },
                onReady: { _, _ in true },
                onUpgradeStarted: { _, _ in log.events.append("started") },
                onUpgraded: { _, _ in log.events.append("upgraded") },
                onUpgradeFailed: { _ in log.events.append("failed") }
            )
        }
        while !log.events.contains("started") { await Task.yield() }
        task.cancel()
        try await task.value
        #expect(log.events == ["started"])
    }

    @Test("Upgrade wording")
    func upgradeText() {
        var upgrade = ModelUpgrade(from: v3, to: ultra, status: .downloading(fraction: 0.42))
        #expect(ModelUpgradeText.progress(upgrade) == "Downloading the improved model (~630 MB)… 42%")
        #expect(ModelUpgradeText.detail(upgrade) == "Parakeet TDT 0.6B v3 stays in use until it is ready.")
        upgrade.status = .downloading(fraction: nil)
        #expect(ModelUpgradeText.progress(upgrade) == "Downloading the improved model (~630 MB)…")
        upgrade.status = .deferred
        #expect(!upgrade.isDownloading)
        #expect(ModelUpgradeText.detail(upgrade).contains("next launch"))
    }

    @Test("Remove Unused Models is disabled while downloading, switching or not loaded")
    func storageAvailability() {
        #expect(ModelStorageContext.unavailableReason(EngineState(isReady: true, setupComplete: true)) == nil)
        #expect(ModelStorageContext.unavailableReason(EngineState(isSettingUp: true)) != nil)
        #expect(ModelStorageContext.unavailableReason(EngineState()) != nil)
        var upgrading = EngineState(isReady: true, setupComplete: true)
        upgrading.upgrade = ModelUpgrade(from: v3, to: ultra, status: .downloading(fraction: nil))
        #expect(ModelStorageContext.unavailableReason(upgrading) != nil)
        upgrading.upgrade?.status = .deferred
        #expect(ModelStorageContext.unavailableReason(upgrading) == nil)
    }
}

// MARK: - Engine handover

@Suite("Engine handover during a switchover")
@MainActor
struct EngineHandoverTests {
    @Test("A recording captured before the upgraded engine is installed keeps the old engine")
    func capturedRecordingKeepsEngine() async throws {
        let transcriber = Transcriber()
        let old = AsrManager(config: .default)
        let new = AsrManager(config: .default)
        #expect(try await transcriber.installParakeet { old })

        let prepared = try await transcriber.prepareParakeet(models: nil) { new }
        // Old engine still in use while the new one was prepared.
        #expect(transcriber.currentAsrManager === old)

        let captured = transcriber.currentConfiguration // stopRecording captures here
        #expect(transcriber.installPrepared(prepared))
        #expect(transcriber.currentAsrManager === new)

        var used: AsrManager?
        transcriber.transcriptionHandler = { configuration, _ in
            used = configuration.asrManager
            return .init(text: "ok", debugInfo: nil)
        }
        _ = await transcriber.transcribe(audioURL: URL(fileURLWithPath: "/tmp/x.wav"), configuration: captured)
        #expect(used === old)
        _ = await transcriber.transcribe(audioURL: URL(fileURLWithPath: "/tmp/y.wav"))
        #expect(used === new)
    }

    @Test("A model switch during preparation discards the prepared engine")
    func switchDiscardsPrepared() async throws {
        let transcriber = Transcriber()
        let old = AsrManager(config: .default)
        #expect(try await transcriber.installParakeet { old })
        let prepared = try await transcriber.prepareParakeet(models: nil) { AsrManager(config: .default) }
        transcriber.invalidatePendingInitialization()
        #expect(!transcriber.installPrepared(prepared))
        #expect(transcriber.currentAsrManager === old)
    }
}
