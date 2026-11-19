# Transcription engines and models

Last verified against the code: 2026-11-19 (`main` at 29e84c9). Source: PR #13 and the code.

## What it is

Two engines, chosen by `TranscriptionModelType` (`TranscriptionEngine.swift`):

| Engine | Library | Models | Notes |
|---|---|---|---|
| Parakeet | FluidAudio 0.18.3 (`AsrManager`, an actor) | `ParakeetVariant.v3` (NVIDIA TDT 0.6B v3, ~480 MB), `ParakeetVariant.ultra` (Parakeet Ultra, ~630 MB) | 25 European languages, language detected automatically. |
| Whisper | WhisperKit 1.1.1 (`WhisperKit`, non-Sendable class) | `WhisperModelSize`: tiny, base, small, large-v3-turbo, large-v3 | 99 languages, optional fixed language and vocabulary hint (`WhisperSettings`). |

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

## Model defaults and migrations

- **Parakeet variant** (`ParakeetVariant.loadOrMigrate(from:)`): a stored `parakeetVariant`
  wins. Otherwise an existing install (any of `onboardingComplete`, `selectedModelType`,
  `whisperSettings` present in `UserDefaults`) gets **v3**, a new install gets **Ultra**. The
  result is written back once. Why: an update must never trigger a surprise ~600 MB download.
- **Whisper Medium removed**: `openai_whisper-medium` is no longer in WhisperKit's
  supported-model list for any Mac. A stored `medium` decodes to Large v3 Turbo
  (`WhisperModelSize.removedSizeReplacements`) and `WhisperSettings.loadOrMigrate(from:)`
  rewrites the stored value.
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
  `WhisperEngine(model:)` downloads went there). The app never inspects it: reading `~/Documents` would trigger a privacy
  prompt for Parakeet users, so Whisper availability is `ModelAvailability.unknown` unless the
  size is loaded in memory.

### Legacy v3 cache migration

FluidAudio ≤ 0.12 (shipped in v0.0.4) stored v3 in `parakeet-tdt-0.6b-v3-coreml`; 0.18 looks in
`parakeet-tdt-0.6b-v3`. Without a migration every existing user would download v3 again.

`SetupManager.migrateLegacyParakeetV3Cache(currentDirectory:)` runs before every Parakeet load
(either variant) and returns a `LegacyCacheMigration`:

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
- A transcription error returns an empty text, reported to the user as "Empty transcription";
  the error itself is not logged by `Transcriber`.
