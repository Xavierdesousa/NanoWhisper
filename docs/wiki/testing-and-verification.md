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
| `BuildFlavorTests.swift` | Flavor resolution, paths, prefixes, shortcuts, `BuildInfo`, debug menu bar band pixels (light and dark) |
| `OverlayWindowTests.swift` | Opt-in (`NANOWHISPER_WINDOW_TESTS`): the real overlay panel grows with live text from its pinned edges at each position; the record capsule stays in place when started from a SwiftUI button; the header does not move across states. With `NANOWHISPER_CAPTURE_DIR` too: PNGs of every state over light and dark wallpapers, each position on a whole screen, Reduce Motion/Transparency variants and the position picker |
| `RecorderPositionTests.swift`, `OverlayWaveformTests.swift` | Position persistence and default, placement and growth maths, picker geometry; level ring buffer, bar mapping, transcribing sweep, `OverlayResult` |
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
   from fixed `SettingsContext` fixtures, so no running app is needed. PR #16 used the same
   approach for the overlay, **and it missed two overlay bugs** that only exist in the real
   panel (window size not following the content, dot animation picking up layout): an offscreen
   render lays the view out once at its final size. For windows, capture the real window, below.
2. **Capturing a real window of your own:** show it (e.g. the real `RecordingOverlayController`
   panel), then `cacheDisplay` its frame view (`window.contentView!.superview`) into a bitmap.
   The window bounds clip it exactly as on screen; window alpha does not matter, so the window can
   be shown at alpha 0 to stay out of the user's way. `NANOWHISPER_WINDOW_TESTS=1 swift test
   --filter OverlayWindow` does this for the overlay (opt-in: it shows windows and activates the
   test process). To reproduce the onboarding path, start the recording from a SwiftUI `Button`
   in a key window of an active `.regular` app, clicked with a synthesized `NSEvent` sent to that
   window (fix/overlay-and-debug-marker, 2026-11-20).
   - **Gotchas (feat/voice-note-overlay, 2026-11-20):** in a test process `animator()` alpha
     animations never run, so a dismissed panel stays ordered in at alpha 0; look up a test's
     own panel through `controller.window`, never "the first visible overlay panel" (that found
     an earlier test's panel). The behind-window material and the window shadow are drawn by the
     window server and are not in `cacheDisplay`; the capture harness composites the panel over
     a drawn wallpaper with a drawn shadow. Reduce Motion/Transparency cannot be switched on for
     the test process; the views read them from the environment, so a test host sets
     `_accessibilityReduceMotion` / `_accessibilityReduceTransparency` (settable, underscored).
   - **Design reference:** the design canvas's HTML can be rendered with headless Chrome
     (`--headless=new --screenshot --force-device-scale-factor=2 --user-data-dir=<scratch>`) to
     compare with the captures side by side.
3. **Standalone harnesses compiling the app's own sources.** Compile selected files from
   `Sources/NanoWhisper/` with a small `main.swift` against the same dependency versions, to run
   real models or real subprocesses outside the app. Used for: Parakeet v3 loading from a cloned
   0.12 cache and the Whisper vocabulary hint (PR #13); Now Playing end to end with Chrome and VLC
   in a bundle signed like `make app` (PR #12); live transcription latency and CPU (PR #16).
   Keep harnesses in the scratchpad, not in the repo. Load models read-only: do not let a harness
   download into the user's model cache.
4. **Driving the debug app through the Accessibility API** (e.g. JXA/`osascript` System Events,
   or AX calls): open windows, read labels, press buttons, check focus. PR #15 verified the
   onboarding replay, the Model step's Apply/Revert and the shortcut recorder this way. Only on
   the debug app, and only when the maintainer is not testing in it.
5. **Process and bundle checks**: `codesign -dv`, `codesign --verify --deep --strict`,
   `lsappinfo`, `pgrep -x`, sha256/mtime of production data to prove it was not touched (PR #14).
6. **Whether a view contains an element, in a unit test:** `dump(view.body, to: &string)` and
   search the string for the label (with a positive control on another label of the same view).
   An offscreen `NSHostingView` exposes **no accessibility tree** to a test process (no
   assistive client is attached), so walking `accessibilityChildren()` finds nothing (tried
   2026-11-20, `LiveTranscriptionFlavorTests`).
7. **Makefile dry runs**: `make -n <target>`; guards of `make publish` were run by hand from the
   `make -n` output, never calling `gh` (PR #14). Workflow steps were run against a fake `gh`/`make`
   on `PATH`.

## What agents cannot verify

Real microphone input in the app (permission not granted to the debug app by agents; do not
trigger prompts), anything visual on the real screen (menu bar, overlay animation, several
displays), TCC prompts, Gatekeeper on a downloaded build. List these as "not verified" in the PR
and in [open-questions.md](open-questions.md).
