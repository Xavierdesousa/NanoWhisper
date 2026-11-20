# Transcription engines and models

Last verified against the code: 2026-11-20 (`feat/model-migration-and-cleanup`). Source: PR #13, the
model migration PR and the code.

## What it is

Two engines, chosen by `TranscriptionModelType` (`TranscriptionEngine.swift`):

| Engine | Library | Models offered | Notes |
|---|---|---|---|
| Parakeet | FluidAudio 0.18.3 (`AsrManager`, an actor) | `ParakeetVariant.ultra` (Parakeet Ultra, ~630 MB, **Recommended**, default), `ParakeetVariant.v3` (NVIDIA TDT 0.6B v3, ~480 MB) | 25 European languages, language detected automatically. |
| Whisper | WhisperKit 1.1.1 (`WhisperKit`, non-Sendable class) | `WhisperModelSize.selectable`: base, small, large-v3-turbo (**Recommended**). Obsolete (decoded, replaced, never offered): tiny, medium, large-v3 | 99 languages, optional fixed language and vocabulary hint (`WhisperSettings`). |

"Recommended" is model metadata (`ParakeetVariant.isRecommended`,
`WhisperModelSize.isRecommended`); the pickers add the badge through `ModelLabel.pickerTitle`. The
word is "Recommended", not "Most used": there is no usage data. The Whisper default for a new
`WhisperSettings` is still Base (only marked, not made the default; Turbo needs 82–93 s to load).

## Model rules (maintainer decisions, 2026-11-20)

1. **A model stays selectable as long as it is still published upstream.** Parakeet v3 is still
   published and is still FluidAudio's default (`.v3`; Ultra is "recommended for new
   integrations"), so it stays.
   - **Exception, deliberate curation:** the Whisper lineup is Base, Small, Large v3 Turbo. Tiny
     (no faster than Base in practice on Apple Silicon, much less accurate) and Large v3
     (superseded by its Turbo variant) are still published but no longer offered.
2. **Obsolete models are removed from disk automatically** (once their replacement / the selected
   model is loaded).
3. **Migrations are automatic and smooth** (no gap in dictation, see below).
4. **Still-selectable models are never deleted automatically**; only "Remove Unused Models…" does.

History of this decision: 0.0.5 kept existing installs on v3 to avoid a surprise ~600 MB
download. After using it, the maintainer reversed that ("an update must move people to the
better model automatically"), first asking to remove v3 entirely, then settling on the rules
above: v3 stays (it is still published), users are moved to Ultra once, and v3 is not deleted.

User-facing model descriptions and published error rates are in the [README](../../README.md#models).

## How it works

- `SetupManager.runSetup(modelType:parakeetVariant:whisperSettings:)` downloads and loads the
  model. Parakeet: `AsrModels.downloadAndLoad(version:progressHandler:)`. Whisper:
  `WhisperEngine(model:)` (download, prewarm, load).
  - `setupGeneration` drops results and progress of a download that a newer request replaced.
  - `loadedParakeetVariant` / `loadedWhisperModelSize` record what is in memory, so
    `AppState.switchModel(to:parakeetVariant:)` reuses a model that is already loaded.
- When `setupComplete` turns true, `AppState.startEngine()` installs the engine in the
  `Transcriber` (`initializeParakeet(models:)` or `initializeWhisper(engine:settings:)`).
- Parakeet: each recording gets a fresh `TdtDecoderState` (independent utterances).
- Whisper: `WhisperEngine.transcribe(audioPath:options:prompt:)`. The vocabulary hint is
  encoded with the kit's tokenizer, with a leading space and special tokens removed, as
  WhisperKit's CLI does (`WhisperEngine.promptTokens(for:encode:specialTokenBegin:)`), and
  passed as `DecodingOptions.promptTokens`.

## Model migrations (`ModelMigrations.swift`)

A schema, like database migrations: `ModelMigrations.steps` is an ordered table of
`ModelMigrationStep(id:release:parakeet:whisper:)`. A step names, **per engine, the model every
user of that engine moves to** (any other model → target); `nil` leaves the engine out. Current
table:

| Step | Release | Parakeet | Whisper |
|---|---|---|---|
| 1 | 0.0.6 | → Ultra | — (Whisper users keep their size, maintainer decision) |

- **Runs once per install.** `modelMigrationStep` (UserDefaults) holds the last step applied;
  pending steps run in order at launch (`ModelMigrations.run(on:choices:isExistingInstall:)`). A
  new install (no `onboardingComplete`, `selectedModelType`, `whisperSettings` or
  `parakeetVariant` key, read before launch writes anything) starts at the latest step.
- **Going back is respected until the next step.** A user moved by step 1 who applies v3 again in
  Settings stays on v3 (`AppState.applyEngine` clears that engine's pending move; step 1 never
  runs again). A later step with a Parakeet target moves them like everyone else. Tested in
  `ModelMigrationTests.reselectAndLaterStep`.
- Before the steps, `ParakeetVariant.loadOrMigrate(from:)` still resolves what 0.0.5 would have
  (stored value, else v3 for existing installs and Ultra for new ones); step 1 then moves v3.
- A move changes the stored choice only (Whisper: only the size; language and vocabulary hint are
  kept) and records the old model in `PendingModelMoves` (`pendingModelMoves`, JSON), the fallback
  for the switchover. Cleared when the engine runs the selected model (`AppState.engineDidBecomeReady`)
  or when the user picks another model for that engine.

### Obsolete models (`ObsoleteModels`, `WhisperModelSize.replacement`)

Separate concept from steps: a step moves people to a better recommended model; an obsolete model
has a **declared replacement** because it is no longer offered. Checked at every launch (not once).

| Obsolete | Replacement | Why |
|---|---|---|
| Whisper Medium (`openai_whisper-medium`) | Large v3 Turbo | Not in WhisperKit's supported-model list for any Mac (0.0.5). |
| Whisper Tiny (`openai_whisper-tiny`) | Base | Curation (2026-11-20). |
| Whisper Large v3 (`openai_whisper-large-v3`) | Large v3 Turbo | Curation (2026-11-20). |

A stored obsolete size decodes as itself (no more rewrite at decode time) and is replaced with the
same smooth switchover as a migration. 0.0.5 already rewrote a stored Medium to Turbo at decode
time: those installs hold Turbo and are not replaced again (their Medium folder, if any, is
removed by the automatic cleanup the next time Whisper is loaded).

### Smooth switchover (`ModelSwitchover.swift`)

`SwitchoverPlan.resolve(selected:previous:isOnDisk:)` (pure), then `ModelSwitchover.run` (generic,
tested with fakes), driven by `SetupManager.runSetup(...previousModel:)`:

| Selected on disk | Previous on disk | Plan |
|---|---|---|
| yes | any | load the selected model |
| no | yes | `.startOnPrevious`: load the previous model (Parakeet: `downloadAndLoad`, which skips the download when complete; Whisper: `WhisperEngine(model:localFolder:)`, local only) → engine ready, dictation works offline → download the selected model in the background (`SetupManager.upgrade`, progress in the menu and the Model section: "Downloading the improved model (~630 MB)… 42%") → `onUpgradeLoaded` |
| no | no | normal download of the selected model |

- Previous model fails to load: the selected one downloads in the foreground instead.
- Background download fails or offline: `upgrade.status = .deferred`, logged, nothing alarming
  (Settings: "<old> is in use. <new> will download at next launch."; the menu shows nothing).
  The pending move persists, so the next launch retries; so does the Retry action
  (`switchModel(to:)` re-runs the plan).
- Switching engines (`AppState.adoptUpgradedModel`): Parakeet prepares the new `AsrManager`
  (`Transcriber.prepareParakeet`) while the old one keeps working, then installs it synchronously
  (`installPrepared`) only when no recording is in progress (`installPendingEngineIfIdle`, also
  called by `stopRecording` after it captured the recording's configuration with
  `transcribe(audioURL:configuration:)`). A recording or a queued transcription keeps the engine
  it started with. A model switch in between discards the prepared engine (generation check).
- `isOnDisk` for Whisper reads `~/Documents`; it is only called while setting up Whisper with a
  pending move, i.e. for someone already on Whisper (no new privacy prompt).

## Model defaults

- **Large v3 Turbo** maps to `openai_whisper-large-v3-v20240930_626MB`: OpenAI's
  large-v3-turbo, compressed to 626 MB. WhisperKit's model-support config lists it for every
  Apple Silicon Mac (and makes it the M1 default). It is the only multilingual model in that
  list between Small and Large v3 (distil-large-v3 is English-only).
- **First launch** does not download anything before the user has seen the choice:
  `ModelAvailability.shouldDeferSetupAtLaunch(isFirstLaunch:modelType:parakeetOnDisk:)`.
  See [onboarding-and-settings.md](onboarding-and-settings.md).

## Cache layout

Models are **shared** by the production and debug builds; neither path depends on the bundle id
and the app is not sandboxed.

- FluidAudio: `~/Library/Application Support/FluidAudio/Models/<folder>`
  (`AsrModels.defaultCacheDirectory(for:)`). Parakeet v3 is in `parakeet-tdt-0.6b-v3`.
- WhisperKit: `~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/<variant>`
  (WhisperKit's `HubApi` default download base; confirmed by the PR #16 harness, whose
  `WhisperEngine(model:)` downloads went there). Reading `~/Documents` triggers the macOS
  privacy prompt, so the app reads it only for someone on Whisper (switchover check, automatic
  cleanup) or when the user clicks "Remove Unused Models…". Whisper availability in the Model
  section stays `ModelAvailability.unknown` unless the size is loaded in memory.

Measured on the maintainer's Mac (2026-11-20): FluidAudio `parakeet-tdt-0.6b-v3` 473 MB, a
re-downloaded legacy `parakeet-tdt-0.6b-v3-coreml` 470 MB, `parakeet-ultra` 603 MB; WhisperKit
Base 140 MB, Large v3 Turbo 598 MB.

### Removing models (`ModelStore.swift`)

All file operations go through `ModelStore` (roots injectable: `ModelStore(root:)` in tests,
`ModelStore.live()` in the app). Tests never touch the real caches.

- **Allow-list:** only folders in `ModelFolder.all` can be deleted, by literal name:
  `parakeet-ultra`, `parakeet-tdt-0.6b-v3`, `parakeet-tdt-0.6b-v3-coreml` (FluidAudio);
  `openai_whisper-tiny`, `-base`, `-small`, `-medium`, `-large-v3`,
  `openai_whisper-large-v3-v20240930_626MB` (WhisperKit). Unknown folders (other apps' models,
  e.g. FluidAudio's VAD), symbolic links and parent directories are never touched; `remove`
  re-checks that the target's parent is the cache root.
- **Automatic** (`AppState.removeObsoleteModelsInBackground`, after each `engineDidBecomeReady`,
  detached, failures logged): folders with `isObsolete` (legacy v3 copy, Whisper Tiny, Medium,
  Large v3) that are not in use. In use = selected model + loaded models + previous models of
  pending moves (`ModelCleanupPolicy.inUse`), so an obsolete model being replaced is deleted only
  once its replacement is loaded. The Whisper cache is included only when Whisper is the selected
  engine. Never deletes a selectable model (v3 stays after the move to Ultra).
- **Manual:** Settings → Downloaded Models → "Remove Unused Models…" (see
  [onboarding-and-settings.md](onboarding-and-settings.md)).
- **Lock:** every removal holds the same `flock` as the legacy migration
  (`FluidAudio/Models/.parakeet-v3-migration.lock`, name kept for 0.0.5 compatibility,
  `ModelStore.withExclusiveLock`), and re-lists the folders under the lock.
- **Production and debug share the caches.** Each flavor protects what the *other* flavor may use,
  read from its preferences (`UserDefaults(suiteName:)` of the other bundle id, read only;
  `ModelCleanupPolicy.usedByOtherFlavor`): its selected engine's model; for an install with no
  `parakeetVariant` key (0.0.4) both v3 folders; its pending move's previous model. Only the other
  flavor's *selected engine* counts: if it later switches engine it re-downloads what it needs,
  like any flavor that finds its model gone (`downloadAndLoad` / WhisperKit download on setup).
  Not handled: a model the other flavor has loaded but no longer has selected in its stored
  settings (memory-mapped Core ML files survive deletion on macOS; not verified).

### Legacy v3 cache migration

FluidAudio ≤ 0.12 (shipped in v0.0.4) stored v3 in `parakeet-tdt-0.6b-v3-coreml`; 0.18 looks in
`parakeet-tdt-0.6b-v3`. Without a migration every existing user would download v3 again.

`SetupManager.migrateLegacyParakeetV3Cache(currentDirectory:)` runs before every **v3** load (since
the model migration PR; before, before either variant: for Ultra it only created a v3 copy nobody
selected, and the legacy folder is now removed by the automatic cleanup) and returns a
`LegacyCacheMigration`:

| Situation | Action | Result |
|---|---|---|
| No legacy folder | nothing | `.notNeeded` |
| New folder missing | legacy folder **moved** (atomic rename, same parent) | `.moved` |
| New folder complete (`AsrModels.modelsExist(at:version:)`) | legacy folder deleted | `.removedDuplicate` |
| New folder incomplete (interrupted download) | new folder removed, legacy moved in | `.replacedIncomplete` |
| Move fails | both folders removed best effort; FluidAudio downloads normally | `.failed` |

After a move, FluidAudio downloads only the files that changed (`JointDecisionv3`, ~12 MB).

The whole check-and-move holds an exclusive `flock` on
`FluidAudio/Models/.parakeet-v3-migration.lock`. Why: production and debug share the cache and
can launch together; without the lock, the process that lost the rename deleted the winner's
freshly moved folder in its failure path (a test reproduced it in 13 of 40 runs, PR #14). If the
lock file cannot be opened, the migration runs unlocked.

Why a move: the maintainer's requirement is that nothing remains at the old path after the
update, and a rename in the same parent folder is atomic.

## Concurrency model

- `Transcriber` is `@MainActor`. `transcribe(audioURL:)` captures `currentConfiguration`
  (engine **and** Whisper settings) before its first suspension, then waits on a FIFO
  `SerialGate`. Consequences:
  - transcriptions run one at a time, in submission order, and none is dropped;
  - a recording uses the engine and settings in effect when it was submitted, even if the
    model, language or hint changes while it waits; a queued recording keeps its engine alive.
- Why a gate although `AsrManager` is an actor: actors are reentrant; two calls would
  interleave at every `await` and share the manager's progress session and MLMultiArray cache.
- `WhisperEngine` is an actor that creates and owns the `WhisperKit` instance, so the
  non-Sendable kit never crosses an isolation boundary; it has its own `SerialGate`. This is
  the fix for the Swift 6.4 errors "sending 'manager'/'kit' risks causing data races" that broke
  `main` before PR #13, without `@unchecked Sendable` or `nonisolated(unsafe)`.
- `engineGeneration`: bumped by every initialization and by
  `invalidatePendingInitialization()` (called on model switch). A Parakeet initialization that
  finishes after a newer one started is discarded (`installParakeet` returns `false`).
- `Transcriber.transcriptionHandler` is a test seam that replaces inference.

## Known limits / not verified

- PR #13 did not run the app, the Parakeet Ultra download or the Large v3 Turbo download; the
  identifiers were checked against the Hugging Face repositories only. The PR #16 harness
  loaded Parakeet Ultra from an existing cache on the maintainer's machine; a clean first
  download of Ultra or Large v3 Turbo through the app has not been recorded.
- Whisper Base and Large v3 Turbo were downloaded and run through the app's `WhisperEngine` in
  the PR #16 harness (2026-11-19, Apple Silicon, macOS 27.2). Both transcribed English and
  French correctly.
  - **Sizes on disk:** Base 143 MB, Turbo 606 MB.
  - **Load time:** Turbo needed 82–93 s per process start even with the files on disk; Base
    needed 3–18 s.
  - **Final pass:** Turbo took 0.8 s (3 s clip) to 3.1 s (32 s clip); Base took 0.09–0.8 s.
  - **Cancellation:** a cancelled Turbo decode releases the engine only after ~0.6 s, because an
    encoder prediction cannot be interrupted ([live-transcription.md](live-transcription.md)).
  - **Not measured:** Large v3.
- **Model migration PR (2026-11-20): nothing was run against the real caches or the apps**, by
  design (the maintainer's installed app depends on them). Verified by unit tests in temporary
  directories (`ModelMigrationTests`, `ModelSwitchoverTests`, `EngineHandoverTests`,
  `ModelStoreTests`) and offscreen renders. Not verified: a real background Ultra download while
  dictating on v3; the engine swap in the running app; `WhisperEngine(model:localFolder:)`
  loading an obsolete Whisper model offline (WhisperKit may still fetch the tokenizer); the
  Documents prompt and "access denied" path with real TCC (tested with `chmod 000`); reading the
  other flavor's preferences with `UserDefaults(suiteName:)` from the real app; deleting a
  model folder while another process has it loaded.
- A 0.0.4 install updating directly: its v3 is in the legacy folder, which
  `ModelAvailability.parakeetIsOnDisk(.v3)` accepts only if FluidAudio 0.18 considers it
  complete; otherwise the plan is a foreground Ultra download instead of starting on v3. Not
  checked against a real 0.0.4 cache.
- A transcription error returns an empty text, reported to the user as "Empty transcription";
  the error itself is not logged by `Transcriber`.
