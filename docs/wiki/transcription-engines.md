# Transcription engines and models

Last verified against the code: 2026-11-24 (`fix/model-download-hardening`: download, loading, lock;
`fix/whisper-load-from-disk`: Whisper on disk;
the rest 2026-11-20, `feat/model-migration-and-cleanup`). Source: PR #13, the model migration PR and
the code.

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
  model. Parakeet: `ParakeetModelFiles.load(_:progressHandler:)`. Whisper:
  `WhisperEngine(_:localOnly:)` (`WhisperModelFiles.load`: download what is missing, then prewarm and
  load). See [Download](#download-modeldownloadswift).
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

## Download (`ModelDownload.swift`)

Since 2026-11-24 (`fix/model-download-hardening`) the app, not the libraries' defaults, decides
where models come from and which files are taken. Cache folders and file names are unchanged, so
existing downloads (and interrupted ones) are reused.

**A fixed server address.** `ModelServer.configure()` is the first line of `NanoWhisperApp.init`, and
runs again before each download. It sets FluidAudio's `ModelRegistry.baseURL` to
`https://huggingface.co` and removes from this process the variables below (both libraries read them
at each use, so removing them is enough; `WhisperKitConfig.modelEndpoint` is explicit too).

| Variable | Read by | Now |
|---|---|---|
| `REGISTRY_URL`, `MODEL_REGISTRY_URL` | FluidAudio 0.18.3 (`ModelRegistry.baseURL`) | no effect |
| `HF_ENDPOINT` | WhisperKit 1.1.1, only to download the tokenizer when it is not on disk (its model download already used `modelEndpoint`, default `https://huggingface.co`) | no effect |
| `HF_TOKEN`, `HUGGING_FACE_HUB_TOKEN` (both), `HUGGINGFACEHUB_API_TOKEN` (FluidAudio) | sent as a bearer token with every request | no effect: the repositories are public, and an expired token would make downloads fail |
| `https_proxy`, `http_proxy` (lower case) | FluidAudio's session, instead of the system proxy | **kept**: someone may need them, and TLS still authenticates the server. WhisperKit ignores them (system proxy only) |
| `CI_DISABLE_NETWORK_MONITOR` (WhisperKit), `TDT_EMISSION_DELAY_FRAMES`, `CI` (FluidAudio) | offline detection, decoder tuning, compute units in a function the app does not call | kept, nothing to do with the download |

Consequence: a mirror of the model server set with these variables is no longer used.

**Only the model's files** (`ModelFileRule`: plain relative names in the model's own folders).
- Parakeet: `ModelHub.download(subdirectory: "", shouldSkip:)` applies the rule to the listing it
  downloads: the four compiled models and `parakeet_vocab.json`, exactly what
  `AsrModels.modelsExist` requires (FluidAudio's own download also took the top-level `config.json`
  and `parakeet_v3_vocab.json`, which nothing loads). Then `AsrModels.loadLocal`, which makes no
  request. FluidAudio's own loader purges and downloads again a compiled model that does not load;
  `ParakeetModelFiles.load` does the same, once, with the rule.
  - `loadLocal` compared with `load` on a copy of the real Ultra folder (FluidAudio 0.18.3, release
    harness, M3 Pro, 2026-11-24): same text, 0.050–0.067 s on a 5 s clip for both, load 0.08–0.12 s
    once compiled. It skips the "encoder ladder" (multifunction encoders); Ultra's and v3's encoders
    have one function, so it was empty with `load` too. **Re-check at a FluidAudio bump.**
- Whisper (`WhisperModelFiles.swift`): `HubApiWrapper.getFilenames`, the rule, then
  `HubApiWrapper.snapshot` with the accepted names as patterns. `snapshot` lists the repository again,
  but an exact name matches only itself. Then WhisperKit loads the folder with `download: false`. The
  tokenizer's three files are downloaded the same way, by the app.

**Once per model: Whisper is loaded from disk without a request** (`WhisperModelFiles.load`, since
2026-11-24, `fix/whisper-load-from-disk`; before, every load listed the server's files, so Whisper
could not start offline). Parakeet already worked this way (`AsrModels.modelsExist`). Checked at
each load, off the main actor:

1. *Every expected file is there*, a file and not empty: for each of `AudioEncoder`, `MelSpectrogram`
   and `TextDecoder` (`.mlmodelc`): `analytics/coremldata.bin`, `coremldata.bin`, `metadata.json`,
   `model.mil`, `weights/weight.bin`; plus `config.json` and `generation_config.json`
   (`WhisperModelFiles.expectedFiles`, 17 files). These are the files common to the published listings
   of all six sizes (checked 2026-11-24; turbo has exactly these, base and small also a
   `model.mlmodel` in two bundles, medium some `mlcomputeplan.json`: nothing loads them). Last changed
   upstream in January 2025, before the app's first Whisper release. WhisperKit 1.1.1 itself loads
   the three bundles and the tokenizer, and reads neither of the two JSON files; they are expected
   because their absence means the download was interrupted.
2. *Each file is what was downloaded*, when that is known: WhisperKit's Hub client writes a sidecar
   per file (`.cache/huggingface/download/<file>.metadata`: commit, ETag, date), and the ETag is the
   file's digest, SHA-256 for a large file and git blob SHA-1 for the others. A mismatch is a damaged
   file. No sidecar (or another kind of value): the file counts as present. Cost measured (Tiny, 76 MB,
   M3 Pro, debug build, files cached): 0.035–0.042 s, so roughly 0.3 s for Turbo (extrapolated).
3. *The tokenizer*: the folder WhisperKit will use (`tokenizerFolder(for:downloadBase:)`, same search
   order) has the three files, with the same check; without a sidecar, they must parse as JSON. If one
   did not parse, WhisperKit would go to the network by itself.

Missing or damaged: the server is listed, then the unusable files are removed (never before the server
answered) and only those are downloaded; transfers interrupted halfway resume. There is no marker file:
downloads of earlier versions (WhisperKit 0.17.0 and 1.1.1 use the same folders and sidecars) are
recognised as they are. On the maintainer's Mac, the sidecars left by the downloads of 2026-11-19 (Base,
Turbo and their tokenizers, 42 files) equal today's published digests.

**A damaged compiled model crashes Core ML instead of failing** (measured 2026-11-24, macOS 27.2, M3
Pro, Whisper Tiny, one process per case). Neural Engine: `model.mil` missing, empty, truncated or
overwritten → SIGSEGV in `MLModel(contentsOf:)`, also `weights/weight.bin` missing; an encoder whose
weights are all zeros → SIGSEGV, on the CPU too. Truncated weights, or either `coremldata.bin` missing
or damaged → an error. Weights with 500 random bytes → **loads**. `metadata.json` is not needed. So the
check runs *before* Core ML sees the files; a repair after a failed load could not catch these cases.
Repair after a failed load remains for files that had no digest to be checked against
(`unreadableFiles`: bundles that Core ML cannot load on the CPU), once per load. A bundle that is
verified and still does not load is not downloaded again: it would not change.

A digest that does not match what the server sends (if the meaning of ETag changed) must not cause a
download at each launch: the sidecar of a file that was just replaced and still differs is removed, so
the file then counts as present.

Consequences: an updated file on the server is not noticed once the model is complete (as with
Parakeet). Settings and the menu say "Optimizing…" instead of "Downloading…" while a Whisper model that
is on disk loads.

Tests: `ModelDownloadTests`, against `FakeModelServer` (an HTTP server on 127.0.0.1), in temporary
directories. Checked once against the real server (2026-11-24, temporary directories, with
`HF_ENDPOINT`, `REGISTRY_URL` and `MODEL_REGISTRY_URL` naming a closed port and an invalid `HF_TOKEN`):
Ultra completed from a partial folder, loaded and transcribed; Whisper Tiny and its tokenizer
downloaded, loaded and transcribed.

**Not built** (assessed 2026-11-24, maintainer's decision):
- *Pinning a revision.* Models come from the `main` branch. WhisperKit: `getFilenames` and `snapshot`
  take a `revision`, one argument each; `WhisperKitConfig` and the tokenizer download do not.
  FluidAudio: `ModelRegistry.revisionOverrides` works, but a pinned revision needs a
  `.fluidaudio-revision` marker in the folder: FluidAudio compares (over the network) a folder that
  has none, and an older NanoWhisper or another FluidAudio app sharing the cache **deletes** a folder
  whose marker is not the revision it expects. Not usable on the shared cache.
- *An embedded manifest* (per model: repository, revision, files, sizes, SHA-256) with an app-owned
  downloader. Both libraries load from a folder (`AsrModels.loadLocal`,
  `WhisperKitConfig(modelFolder:download: false)`, `tokenizerFolder`), so no fork is needed. Existing
  caches would be checked in place, file by file, and only files that differ downloaded again, with
  the smooth switchover while that happens.

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
  Persisted in a recoverable order: fallback (`pendingModelMoves`), then the choices, then
  `modelMigrationStep`; a stop in between re-runs the step, which is then a no-op.
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
| no | yes | `.startOnPrevious`: load the previous model (Parakeet: `ParakeetModelFiles.load`, which skips the download when complete; Whisper: `WhisperEngine(_:localOnly:)`, which never downloads the model) → engine ready, dictation works offline → download the selected model in the background (`SetupManager.upgrade`, progress in the menu and the Model section: "Downloading the improved model (~630 MB)… 42%") → `onUpgradeLoaded` |
| no | no | normal download of the selected model |

- "On disk" for Whisper means every expected file is there (`ModelStore.isWhisperModelOnDisk`; until
  2026-11-24, that the three bundles' folders existed). An interrupted download of the selected
  model therefore resumes in the background while the previous one is used.
- Previous model fails to load (or is damaged): the selected one downloads in the foreground instead.
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
- **First launch** does not download anything at launch:
  `ModelAvailability.shouldDeferSetupAtLaunch(isFirstLaunch:modelType:parakeetOnDisk:)`. Since
  the onboarding redesign (2026-11-21) the download starts when onboarding's setup page opens,
  where the model is shown with Change…. See [onboarding-and-settings.md](onboarding-and-settings.md#onboarding).

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
  engine. Never deletes a selectable model (v3 stays after the move to Ultra). Deferred while a
  recording or transcription is in flight (it may still hold the previous engine); runs when
  that transcription finishes.
- **Manual:** Settings › Engine › Downloaded models › "Remove Unused Models…" (see
  [onboarding-and-settings.md](onboarding-and-settings.md)).
- **Lock:** every removal holds the same `flock` as the legacy migration
  (`FluidAudio/Models/.parakeet-v3-migration.lock`, name kept for 0.0.5 compatibility,
  `ModelStore.withExclusiveLock`), and re-lists the folders under the lock. Since 2026-11-24 the
  lock is awaited with `LOCK_NB` every 50 ms, off the main actor and for at most 10 s
  (`ModelStore.lockTimeout`); the file is opened with `O_NOFOLLOW | O_NONBLOCK`. Lock still taken:
  nothing is removed (`ModelRemovalReport.lockBusy`; the automatic cleanup tries again the next time
  an engine is ready, Settings says so after "Remove Unused Models…").
- **Production and debug share the caches.** Each flavor protects what the *other* flavor may use,
  read from its preferences (`UserDefaults(suiteName:)` of the other bundle id, read only;
  `ModelCleanupPolicy.usedByOtherFlavor`): its selected engine's model; for an install with no
  `parakeetVariant` key (0.0.4) both v3 folders; its pending move's previous model. Only the other
  flavor's *selected engine* counts: if it later switches engine it re-downloads what it needs,
  like any flavor that finds its model gone (downloaded again on setup).
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
| Move fails | both folders removed best effort; v3 downloads normally | `.failed` |
| Lock still taken after 10 s | nothing; v3 downloads normally if it is missing, and the next launch migrates (`.removedDuplicate`) | `.lockBusy` |

After a move, only the files that changed are downloaded (`JointDecisionv3`, ~12 MB).

The whole check-and-move holds an exclusive `flock` on
`FluidAudio/Models/.parakeet-v3-migration.lock`. Why: production and debug share the cache and
can launch together; without the lock, the process that lost the rename deleted the winner's
freshly moved folder in its failure path (a test reproduced it in 13 of 40 runs, PR #14). If the
lock file cannot be opened, the migration runs unlocked. It runs off the main actor (until
2026-11-24 it ran on it, and waited for the lock without a limit).

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

## Measured speed on real dictations (2026-11-21)

Source: the maintainer's own dictations, read from the History debug info (audio length and
the model's transcription time, `TranscriptionDebugInfo`), extracted at their request with a
script that decrypted the history in memory and printed only numbers (never the text). These
figures are the reference for the README and marketing material (also on the Claude Design
canvas, page "Key numbers"); do not publish other numbers without re-measuring.

Conditions: Parakeet Ultra, MacBook Pro M3 Pro 18 GB (Mac15,7), macOS 27.2, debug build of
`main` (the code of 0.1.0), mostly French speech. "× real time" = audio length ÷ transcription
time; it excludes the 0.3 s recording tail and the paste.

| | Debug build, current code (n = 25, 23.7 min of audio) | Released 0.0.5/0.0.6 (n = 14) |
|---|---|---|
| Median speed | **126×** | 80× |
| Mean / overall (Σ audio ÷ Σ time) | 140× / 174× | 88× / 97× |
| 25th / 75th / 90th percentile | 106× / 148× / 250× | 44× / 132× / 137× |
| Best | **327×** (269.7 s of speech in 0.82 s) | 182× |
| Median transcription time | **0.19 s** (18 of 25 under 0.25 s) | 0.39 s |
| Longest transcription time | 1.23 s (a 130.6 s dictation) | 0.83 s |

By length (current code): under 15 s → median 103× (0.10 s); 15–60 s → 126× (0.19 s); over
60 s → 236× (0.67 s). Short dictations are dominated by a fixed cost of about 0.1 s, so the
ratio grows with length.

**Long-dictation reference** (added later on 2026-11-21, same conditions: debug build, Parakeet
Ultra, M3 Pro): one dictation of **570.8 s of speech (9 min 31 s, 960 words) transcribed in
1.78 s = 321× real time**, "9½ minutes of speech, text in 1.8 s". The table above describes
the first 25 dictations and does not include it. The best ratio stays **327×** (the 269.7 s,
4 min 30 s dictation).

Not verified: why the released build was slower on the same Mac (different model or code
version at the time, warm-up; the entries of that build do not record the model); other Macs.
Honest claims: "up to 327× faster than real time", "typically about 125×", "most dictations
are text in under a quarter of a second", "9½ minutes of speech, text in 1.8 s".

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
  dictating on v3; the engine swap in the running app; `WhisperEngine(_:localOnly:)`
  loading an obsolete Whisper model offline (Tiny loads offline since 2026-11-24, below); the
  Documents prompt and "access denied" path with real TCC (tested with `chmod 000`); reading the
  other flavor's preferences with `UserDefaults(suiteName:)` from the real app; deleting a
  model folder while another process has it loaded.
- A 0.0.4 install updating directly: its v3 is in the legacy folder, which
  `ModelAvailability.parakeetIsOnDisk(.v3)` accepts only if FluidAudio 0.18 considers it
  complete; otherwise the plan is a foreground Ultra download instead of starting on v3. Not
  checked against a real 0.0.4 cache.
- Whisper from disk (2026-11-24), checked with the real Tiny model in temporary directories, through
  `WhisperEngine`: downloaded from the real server with its tokenizer, then loaded and a `say` clip
  transcribed with outbound network denied (`sandbox-exec`) and no request to a local server set as
  `HF_ENDPOINT`; same for a copy without sidecars; a copy with a truncated `model.mil` was repaired
  (one file) and transcribed. Not checked with Base, Small or Turbo (size), nor in the app; the
  time the check takes on Turbo is extrapolated.
- Not checked: `AsrModels.modelsExist` only looks for `coremldata.bin` in each Parakeet bundle (and for
  `*.partial` files), so a Parakeet bundle without `model.mil` or weights counts as complete; whether
  it then crashes like Whisper's was not tried.
- Download changes of 2026-11-24: not run in the app itself; a clean first download of a whole
  model in the app, and a load repaired by a second download with a real model, not checked; a
  proxy set with `https_proxy` not checked.
- A transcription error returns an empty text, reported to the user as "Empty transcription";
  the error itself is not logged by `Transcriber`.
