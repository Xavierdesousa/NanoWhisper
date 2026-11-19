# Testing and verification techniques

Last verified: 2026-11-19 — `swift test` on `main` (29e84c9), Swift 6.4, macOS 27.2:
"174 tests in 20 suites passed" (the `ViewRender` suite is reported as skipped in that run);
`ViewRender` (2 tests) then passed with `NANOWHISPER_RENDER_DIR` set.

## Unit tests

Swift Testing (`@Suite`, `@Test`) in `Tests/NanoWhisperTests/`. CI runs `swift test`.

| File | Covers |
|---|---|
| `TranscriptionEngineTests.swift` | Model enums, variant resolution, Medium migration, legacy cache migration incl. concurrent migrations |
| `TranscriberConcurrencyTests.swift` | FIFO queue, configuration captured at submission, stale initializations |
| `MediaControllerTests.swift` | Media session state machine against a fake controller, `pauseMediaEnabled` |
| `NowPlayingTests.swift` | JXA output parsing (real macOS 27.2 outputs), resume rule, `NowPlayingPlaybackController`, `Subprocess` |
| `OnboardingSettingsTests.swift` | Onboarding flow, launch options, permission status, Model section logic, dictation destination |
| `BuildFlavorTests.swift` | Flavor resolution, paths, prefixes, shortcuts, `BuildInfo`, menu bar badge pixels (light and dark) |
| `CodableModelTests.swift`, `GitHubReleaseTests.swift`, `VersionComparisonTests.swift` | Persistence formats, updater parsing and version comparison |
| `TranscriptionFailureTests.swift` | Engine error and missing engine reported as a failure, not as empty text; `DictationOutcome` with a failure |
| `HistoryStoreTests.swift` | Encrypted round trip (no plain text on disk), trimming, unreadable file ⇒ unavailable and never overwritten, plain-text file never read, pinned key derivation |
| `LiveTranscriptionTests.swift`, `LiveTranscriptionFlavorTests.swift` | Live preview schedule, window, joins, transcript; availability per engine; debug-only flag and hidden toggle |
| `ViewRenderTests.swift` | Offscreen renders (below); skipped unless `NANOWHISPER_RENDER_DIR` is set |

Seams used by tests: `Transcriber.transcriptionHandler`, `Transcriber.installParakeet(_:)`,
`MediaPlaybackController` and `NowPlayingSource` fakes, `SetupManager.migrateLegacyParakeetV3Cache(currentDirectory:)`,
`SettingsContext` fixtures (`Fixtures` in `ViewRenderTests.swift`), `HistoryStore(fileURL:key:)`, `BuildFlavor(bundleIdentifier:)`, `AutoUpdater(isEnabled:)`.

## Techniques that work without a screen

Agents have **no screen capture**. These worked on 2026-11-19:

1. **Offscreen PNG renders of SwiftUI views.**
   `NANOWHISPER_RENDER_DIR=<dir> swift test --filter ViewRender` writes every onboarding step and
   Settings in both engine modes (17 PNGs) to `<dir>`; read the PNGs to check layout. Views render
   from fixed `SettingsContext` fixtures (`Fixtures` in `ViewRenderTests.swift`), `HistoryStore(fileURL:key:)`, so no running app is needed. PR #16 used the same
   approach for the overlay.
2. **Standalone harnesses compiling the app's own sources.** Compile selected files from
   `Sources/NanoWhisper/` with a small `main.swift` against the same dependency versions, to run
   real models or real subprocesses outside the app. Used for: Parakeet v3 loading from a cloned
   0.12 cache and the Whisper vocabulary hint (PR #13); Now Playing end to end with Chrome and VLC
   in a bundle signed like `make app` (PR #12); live transcription latency and CPU (PR #16).
   Keep harnesses in the scratchpad, not in the repo. Load models read-only: do not let a harness
   download into the user's model cache.
3. **Driving the debug app through the Accessibility API** (e.g. JXA/`osascript` System Events,
   or AX calls): open windows, read labels, press buttons, check focus. PR #15 verified the
   onboarding replay, the Model step's Apply/Revert and the shortcut recorder this way. Only on
   the debug app, and only when the maintainer is not testing in it.
4. **Process and bundle checks**: `codesign -dv`, `codesign --verify --deep --strict`,
   `lsappinfo`, `pgrep -x`, sha256/mtime of production data to prove it was not touched (PR #14).
5. **Whether a view contains an element, in a unit test:** `dump(view.body, to: &string)` and
   search the string for the label (with a positive control on another label of the same view).
   An offscreen `NSHostingView` exposes **no accessibility tree** to a test process (no
   assistive client is attached), so walking `accessibilityChildren()` finds nothing (tried
   2026-11-20, `LiveTranscriptionFlavorTests`).
6. **Makefile dry runs**: `make -n <target>`; guards of `make publish` were run by hand from the
   `make -n` output, never calling `gh` (PR #14). Workflow steps were run against a fake `gh`/`make`
   on `PATH`.

## What agents cannot verify

Real microphone input in the app (permission not granted to the debug app by agents; do not
trigger prompts), anything visual on the real screen (menu bar, overlay animation, several
displays), TCC prompts, Gatekeeper on a downloaded build. List these as "not verified" in the PR
and in [open-questions.md](open-questions.md).
