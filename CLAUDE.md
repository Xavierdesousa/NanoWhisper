# CLAUDE.md

Instructions for coding agents working on NanoWhisper. Read this file first, then
[`docs/wiki/index.md`](docs/wiki/index.md). User-facing documentation is in [`README.md`](README.md).

## What this is

NanoWhisper is a macOS menu bar dictation app: a global hotkey starts the microphone, the
recording is transcribed on-device (Parakeet through FluidAudio, or Whisper through
WhisperKit, both Core ML), and the text is pasted into the frontmost app.

- Swift 6 language mode, SwiftPM only (no Xcode project). `swift-tools-version: 6.2`.
- Built with the macOS 27 SDK / Swift 6.4 (Xcode 27.1). Runs on macOS 14+, Apple Silicon.
- Distributed only through GitHub releases, never the Mac App Store. Releases are signed with
  the self-signed "Moonji Dev" certificate and are **not notarized**.

## Commands

| Command | What it does |
|---|---|
| `swift build` | Debug build of the executable. |
| `swift test` | Unit tests (Swift Testing). CI runs exactly this. |
| `NANOWHISPER_RENDER_DIR=<dir> swift test --filter ViewRender` | Renders onboarding, every Settings pane (the real window, light and dark) and the menu states to PNGs in `<dir>` (offscreen; the suite is skipped without the variable). |
| `make app` | Builds, signs and (re)launches **NanoWhisper Debug.app**. See the flavor rules below. |
| `make onboarding` | Same as `make app`, launched with `--onboarding`. |
| `make ci SIGN_IDENTITY=` | Production bundle, ad-hoc signed, no launch (what CI builds). |
| `make release` | Production bundle + `NanoWhisper-v<version>.zip`. Launches nothing. |
| `make publish` | Creates the GitHub release for the current tag. **Only when the maintainer asks.** |

## Rules

**Build flavors.** `make app` builds "NanoWhisper Debug.app" (bundle id
`com.moonji.nanowhisper.debug`, hotkey ⌃⌥Space, its own history folder and temp-file prefix,
updater off). It shares downloaded models with production. Production comes only from the
release workflow, `make release` or `make publish`.
- You may run `make app` to check a change, but the debug app is a shared resource: when the
  maintainer is testing in it, do not relaunch or quit it and do not edit its defaults
  (`defaults write com.moonji.nanowhisper.debug …`).
- Never kill, relaunch or modify the production app (`NanoWhisper`, `com.moonji.nanowhisper`)
  or its data.
- Anything that could collide between the two builds must be derived from `BuildFlavor`
  (`Sources/NanoWhisper/BuildFlavor.swift`). See [build flavors](docs/wiki/build-and-release.md).

**Git and PRs.**
- One branch per change: `feat/…`, `fix/…`, `chore/…`, `docs/…`, from an up-to-date `origin/main`.
- Open a PR against `main` with `gh pr create`. `main` is protected: the `ci` check must pass
  and the branch must be up to date. Merges are squash-only and done by the maintainer.
- Do not push tags, create releases, run `make publish`, bump the version or merge unless
  the maintainer asks for that specific action.
- Commit messages: conventional prefix (`feat:`, `fix:`, `ci:`, `docs:`, `chore:`).

**Review.** Review locally with the CodeRabbit CLI before opening or updating a PR:
`coderabbit review --agent --committed --base origin/main`. It is rate-limited (3 reviews per
window), so batch your changes before running it. The repository gets no automatic CodeRabbit
PR reviews. Details: [CI and review](docs/wiki/ci-and-review.md).

**Code and text.**
- All code, comments, UI strings, commit messages and PR text are in English.
- Swift 6 strict concurrency: fix isolation errors by design (a non-Sendable engine lives
  inside an actor, as `WhisperEngine` does), not by adding `@unchecked Sendable` or
  `nonisolated(unsafe)`. The few existing ones (`Subprocess.swift`, `RecordingOverlay.swift`)
  are deliberate; do not add more without a comment saying why it is safe.
- Never write transcription text or history in plain text to disk (history is AES-GCM encrypted).
- Strings shown to users are plain and precise; no marketing tone.

**Verification.** Agents have no screen capture. Use unit tests, offscreen renders, standalone
harnesses that compile the app's own sources, and the Accessibility API on the debug app.
State in the PR what was not verified. See [testing](docs/wiki/testing-and-verification.md).

## Source map (`Sources/NanoWhisper/`)

| Area | Files |
|---|---|
| App entry, menu bar | `NanoWhisperApp.swift` (`NanoWhisperApp`, `AppDelegate`), `MenuBarController.swift` (status item, `NSMenu`, item views), `MenuBarMenu.swift` (`MenuContent`: menu lines per state), `MenuBarIcon.swift` |
| Orchestration, state | `AppState.swift` (`AppState`), `AppState+LiveTranscription.swift`, `DictationDestination.swift` (`DictationDestination`, `DictationOutcome`, `TranscriptionFailure`) |
| History, temp recordings | `HistoryStore.swift` (`HistoryStore`, `HistoryCrypto`, `HistoryEntry`), `TemporaryRecordings.swift`, `InterruptedRecordings.swift` (leftovers of a crash, `WAVHeader`), `InterruptedRecordingRecovery.swift` |
| Recording, hotkey, paste, sounds | `AudioRecorder.swift`, `HotkeyManager.swift`, `PasteManager.swift`, `SoundManager.swift` |
| Overlay | `RecordingOverlay.swift` (panel, placement, `OverlayResult`), `RecordingOverlayView.swift` (the "Voice note" views), `OverlayWaveform.swift` (level history, bars), `RecorderPosition.swift`, `RecorderPositionPicker.swift` |
| Transcription | `Transcriber.swift` (`Transcriber`, `WhisperEngine`, `SerialGate`), `TranscriptionEngine.swift` (model enums, `WhisperSettings`), `LiveTranscription.swift` and `LiveTranscript.swift` (live preview, debug build only) |
| Model download and cache | `SetupManager.swift`, `ModelMigrations.swift` (migration steps, obsolete replacements), `ModelSwitchover.swift` (smooth switchover), `ModelStore.swift` (allow-listed folders, lock, removal) |
| Media pause | `MediaController.swift`, `MediaPlaybackController.swift`, `NowPlayingPlaybackController.swift`, `MediaRemoteJXA.swift`, `Subprocess.swift` |
| Settings and onboarding | `SettingsView.swift` (window, `SettingsPane`, `SettingsTabViewController`), `Settings*Pane.swift`, `Settings*Section.swift` (panes and the sections onboarding shares), `SettingsStyle.swift`, `SettingsContext.swift`, `ShortcutKeysView.swift`, `OnboardingFlow.swift`, `OnboardingView.swift`, `Permissions.swift`, `ModelComparisonView.swift` |
| History window | `HistoryView.swift` |
| Build flavor, updates | `BuildFlavor.swift`, `AutoUpdater.swift` |
| Misc | `WindowUtils.swift` |

Other: `Tests/NanoWhisperTests/`, `Makefile`, `Resources/` (Info.plist, entitlements, icons,
sounds), `scripts/make-debug-icon.swift`, `.github/workflows/` (`ci.yml`, `release.yml`).

## The wiki (`docs/wiki/`)

`docs/wiki/` is the project's memory: what the code does not say by itself (decisions,
rejected alternatives, measurements, gotchas, untested areas). Agents write and maintain it.

**Read** [`index.md`](docs/wiki/index.md) at the start of a session, and the page for the area
you are about to change before changing it.

**Update** it in the same PR as the change, when you:
- learn something non-obvious (an API quirk, a platform behavior, a trap you fell into);
- make or receive a decision, including what was rejected and why;
- measure something (latency, CPU, sizes): give numbers, conditions and date;
- find that a page is wrong: fix it, do not leave a contradiction.

**How:**
- Edit the relevant page; create a new page only for a new subject, and add it to `index.md`.
- Append a dated entry to [`log.md`](docs/wiki/log.md) (newest first): date, what changed, PR number.
- Keep pages factual. Point to types and functions rather than line numbers. Mark anything
  unverified as such. Update the page's "Last verified" date when you re-check it against the code.
- Do not copy the README's user-facing content; link to it.
