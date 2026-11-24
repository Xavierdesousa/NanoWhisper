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
| `NowPlayingTests.swift` | JXA output parsing (real macOS 27.2 outputs), resume rule, `NowPlayingPlaybackController`, `Subprocess` (standard input included); the part of the script that reads standard input, in the real `osascript` (no MediaRemote) |
| `PasteboardSnapshotTests.swift` | Clipboard around a paste, on private pasteboards (never the general one): markers, everything restored, change count, overlapping dictations, bounds, promised data |
| `ShortcutStorageTests.swift` | Reading the stored shortcut: round trip, out-of-range values, no modifier (a throwaway defaults domain) |
| `LogCapture.swift` | Helper: this process's log entries through `OSLogStore`, where private values read `<private>`. Reading takes 1–2 s, so it runs off the main actor; entry dates can precede a `Date()` taken just before logging, hence a 1 s margin |
| `OnboardingSettingsTests.swift` | Launch options, permission status, Model section logic, dictation destination |
| `OnboardingFlowTests.swift` | Onboarding: page order and Back, the page events the app receives, Finish Setup refused while a test listens or transcribes, completion order (flag, window closed, model loaded, then the menu bar handoff), the setup rows' circles and captions per permission and model state, the footer line, every Try it stage and its precedence, new-install defaults (pause media, open at login once), window placement on 1440 × 900 and a 13-inch Air, the welcome's dictation timeline and its frozen frame, the demo driving the real overlay view model |
| `OnboardingWindowTests.swift` | Opt-in (`NANOWHISPER_WINDOW_TESTS`): the real onboarding window shown with fixture content. The welcome's sequence over 9 s (idle at 0:00, recording, then frozen and paused at 0:05; the idle and frozen recorder compared pixel for pixel over time); Try it with the real recorder panel at Top Center, never overlapping the window, light and dark. With `NANOWHISPER_CAPTURE_DIR`: frames of the welcome from 0.12 to 4.2 s, and Try it composited on the real screen and on a 1440 × 900 screen (listening, transcribing, result) |
| `BuildFlavorTests.swift` | Flavor resolution, paths, prefixes, shortcuts, `BuildInfo`, debug menu bar band pixels (light and dark) |
| `OverlayWindowTests.swift` | Opt-in (`NANOWHISPER_WINDOW_TESTS`): the real overlay panel grows with live text from its pinned edges at each position; the record capsule stays in place when started from a SwiftUI button; the header does not move across states. With `NANOWHISPER_CAPTURE_DIR` too: PNGs of every state over light and dark wallpapers, each position on a whole screen, Reduce Motion/Transparency variants and the position picker |
| `RecorderPositionTests.swift`, `OverlayWaveformTests.swift` | Position persistence and default, placement and growth maths, picker geometry; level ring buffer, bar mapping, transcribing sweep, `OverlayResult` |
| `CodableModelTests.swift`, `GitHubReleaseTests.swift`, `VersionComparisonTests.swift` | Persistence formats, updater parsing and version comparison |
| `UpdateTests.swift`, `UpdateFixtures.swift` | The updater: versions, asset name and address, digest; code signature (ad-hoc, unsigned, changed bundles; several requirements); extraction (zero or two apps, links, entry names, size limit); installation in a temporary folder (every refusal leaves the installed app untouched and no temporary file; redirects; size limits) and the whole `AutoUpdater` flow; the relaunch. Bundles are copies of `/usr/bin/true` signed ad hoc, never launched; the network is `StubProtocol`. Removing any one check makes a test fail (19 checks tried, 2026-11-24) |
| `TranscriptionFailureTests.swift` | Engine error and missing engine reported as a failure, not as empty text; `DictationOutcome` with a failure |
| `InterruptedRecordingsTests.swift` | Recordings left by a crash: header repair of the crash state (copied from an open `RecordingWriter` file), what is kept or deleted (too short, too old, unreadable, already attempted, history off; the other build's files untouched; links, directories and pipes left alone, link targets intact), the silent recovery to History at the recording's date, exactly once (a crash during the attempt is not retried), the user's dictation first (a real `Transcriber` queue with its test handler), `HistoryStore.insert` order |
| `HistoryStoreTests.swift` | Encrypted round trip (no plain text on disk), trimming, unreadable file ⇒ unavailable and never overwritten, plain-text file never read, pinned key derivation |
| `HistorySettingsTests.swift` | Default kept count 25 (a stored one kept); the one-time cleanup (history off: file deleted once, never again; history on: nothing deleted, done for good; an unreadable file deleted too); `deleteAll`; turning history off (alert only with dictations kept, Cancel keeps everything, confirm deletes then turns off, turning on never asks); the alerts' wording; entries saved without model or language still load (a sealed file in the old format) |
| `HistoryWindowTests.swift`, `HistoryFixtures.swift` | History window model with invented entries (`HistoryFixtures`: a temporary store, a test key, a private pasteboard): search ranges and highlight, search selection and its restore, copy only to the pasteboard, delete / undo / redo and the selection after each, Clear All, states and subtitles, day sections, wording (titles, dates, debug rows), `HistoryKeyRouting`, and the real `HistoryWindow` handling ⌘C, ⌫, ⌘Z, ⌘F itself; the toolbar's order and tooltips |
| `ViewRenderHistoryTests.swift` | With `NANOWHISPER_RENDER_DIR` (`--filter ViewRender` runs it too): the real History window in every state, light and dark, invented entries; the two alerts' windows |
| `LiveTranscriptionTests.swift`, `LiveTranscriptionFlavorTests.swift` | Live preview schedule, window, joins, transcript; availability per engine; debug-only flag and hidden toggle |
| `ViewRenderTests.swift`, `RenderFixtures.swift` | Offscreen renders (below); skipped unless `NANOWHISPER_RENDER_DIR` is set |
| `SettingsWindowTests.swift` | Opt-in (`NANOWHISPER_WINDOW_TESTS`): the real Settings window on screen. Every pane switch ends at the pane's height with the top edge fixed and one pane shown; each frame of a resize (forced heights, with a layout pass) keeps the window's height and never puts pane content above the content area; the real animation (sampled every 16 ms) is monotonic with the pane hidden until the end; content height changes are followed; the Engine comparison stays on the same pixel row while its speed bar slides to the new value (Parakeet → Whisper → Turbo). With `NANOWHISPER_CAPTURE_DIR`, PNGs of all of it |
| `OverlayContrastTests.swift` | Overlay text contrast ≥ 4.5:1 over light and dark wallpapers with the material ignored |
| `MenuContentTests.swift` | Menu bar menu lines for every app state |
| `MenuBarHandoffTests.swift` | End-of-onboarding popover: when it shows (model ready or not, menu open, replay), the "ready later" popover once, its text with the current shortcut and recorder position, `--show-handoff` debug-only |
| `HandoffPopoverWindowTests.swift` | Opt-in (`NANOWHISPER_WINDOW_TESTS`): the real handoff `NSPopover` anchored to a real status item of the test process, light and dark: placed under the item, 300 pt wide, shown without activating the app, follows a text change in place, closed by a synthesized click on OK and by Escape. With `NANOWHISPER_CAPTURE_DIR`, PNGs of the popover window |
| `AudioRecorderTests.swift` | `RecordingWriter`: 16 kHz mono conversion (48 kHz mono, 44.1 kHz stereo), WAV header final once `finish()` returns, nothing written after it, input format change mid-recording, appends racing `finish()`; the level curve. `AudioRecorder` with `FakeInputEngine` (no real input): stop order (engine stopped before the tap is removed, never a tap removed from a running engine), WAV complete when returned, late tap buffers ignored, input change continuing in the same file, input change that cannot restart (`onInputLost`, file finalized), start failure leaving no file. Swapping the stop order back makes two of these fail (checked) |
| `SettingsPaneTests.swift` | Visible panes and the remembered pane, Recorder pane's live toggle per flavor, shortcut keys, Engine pane status and apply wording, update status |

Seams used by tests: `Transcriber.transcriptionHandler`, `Transcriber.installParakeet(_:)`,
`MediaPlaybackController` and `NowPlayingSource` fakes, `SetupManager.migrateLegacyParakeetV3Cache(currentDirectory:)`,
`SettingsContext` fixtures (`Fixtures` in `ViewRenderTests.swift`), `HistoryStore(fileURL:key:)`, `BuildFlavor(bundleIdentifier:)`, `AutoUpdater(isEnabled:installer:relaunch:)`, `UpdateInstaller`'s properties.

## Techniques that work without a screen

**Two traps when comparing colors or looks (2026-11-21):** the test runner is linked against the
macOS 27 SDK and draws the macOS 26+ design, while app builds up to then recorded SDK 14 and ran
in the pre-26 design (see [build-and-release.md](build-and-release.md#the-sdk-version-in-the-binary-macos-26-design));
check `otool -l <binary> | grep -A4 LC_BUILD_VERSION` before comparing a render with the app.
And to read a pixel of a `screencapture` PNG, use `NSBitmapImageRep.getPixel` (raw values), not
`colorAt(x:y:)` + `usingColorSpace(.sRGB)`: that reads the values as gamma-1.8 RGB and lifts dark
greys (painted #292929 read #363636).

Agents had **no screen capture** until 2026-11-21. These worked on 2026-11-19:

1. **Offscreen PNG renders of SwiftUI views.**
   `NANOWHISPER_RENDER_DIR=<dir> swift test --filter ViewRender` writes every onboarding page
   and state, the opening scene at eight moments and with Reduce Motion (`scene-*.png`, from a
   fixed `OpeningSceneClock`), every Settings pane and Engine state (light and dark), the
   recording overlay in every state, light and dark, on a pale and a saturated wallpaper and
   with Reduce Transparency (`overlay-*.png`, `OverlaySheet`: each overlay with its shadow
   window's view behind it, as on screen), the Remove Unused Models sheet and every menu state
   to `<dir>`; read the PNGs to check layout. The Settings and
   onboarding renders are the **real windows** (`SettingsWindowController.makeWindow`,
   `OnboardingWindowController.makeWindow`, never shown; onboarding with Reduce Motion set in the
   environment so every entrance shows its end and the welcome's recorder its frozen frame): the frame view
   (`contentView.superview`) is cached with the toolbar and title. A window that is never key
   draws controls in their inactive look (grey switches and bars). The menu renders are
   `MenuPreview`, an approximation drawn from `MenuContent` lines (an `NSMenu` cannot be drawn
   offscreen). Views render
   from fixed `SettingsContext` fixtures, so no running app is needed. PR #16 used the same
   approach for the overlay, **and it missed two overlay bugs** that only exist in the real
   panel (window size not following the content, dot animation picking up layout): an offscreen
   render lays the view out once at its final size. For windows, capture the real window, below.
   - **Scale follows the screen the window sits on** (2026-11-23, README screenshots): with the
     maintainer's 1x external display as the main screen, the onboarding and History renders came
     out at 1x (580 × 640 px) while the Settings renders were 2x (not investigated why). For 2x
     images, move the never-shown window onto a Retina screen (`setFrame` into that screen's
     `visibleFrame`) before caching. `.environment(\.controlActiveState, .key)` on the content
     gives SwiftUI buttons their active look (Continue in the accent colour), not the AppKit-backed
     switches. The README images in `docs/images/` were made this way, with a temporary,
     uncommitted patch of the render helpers and a board of `OverlayOnScreen` recorder states,
     then given rounded corners, a hairline edge and a shadow by a Core Graphics script.
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
   - **Animations in tests (2026-11-20):** AppKit animations (`animator()`, `NSTabViewController`
     transitions, `NSAnimationContext` completions) only progress while a `@MainActor` test is
     **suspended** (`try await Task.sleep`): their completions are delivered on the main queue,
     which the test's job occupies while it spins `RunLoop.current.run(until:)`. That explains
     the earlier "alpha animations never run" gotcha; with `await Task.sleep` the real animation
     can be sampled frame by frame. `CALayer.render(in:)` honours alpha but drew no SwiftUI
     content inside a clipping view; `cacheDisplay` draws it but ignores view alpha.
   - **Popovers (feat/menu-bar-handoff, 2026-11-20):** a test process can create a real
     `NSStatusItem` and show an `NSPopover` from it; `cacheDisplay` of the popover window's frame
     view captures the frame, arrow and content (the glass edge comes out as a colored fringe).
     The hosting view inside a popover is flipped: compute click points from the top. In another
     running app, the popover is visible neither to the Accessibility API nor to
     `CGWindowListCopyWindowInfo`; log its window frame from the app instead
     (`log show --info --predicate 'subsystem == "com.moonji.nanowhisper.debug"'`).
   - **Hover (feat/welcome-demo-flow, 2026-11-21):** synthesized mouse moves
     (`NSEvent.mouseEvent(with: .mouseMoved…)` through `window.sendEvent` or `NSApp.sendEvent`)
     do not drive SwiftUI's `onHover`, and `NSApp.postEvent` of one ended the process: tracking
     areas follow the real pointer. A posted real move
     (`CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, …).post(tap: .cghidEventTap)`)
     does move it (the terminal has the permission), but a test process takes no event from the
     window server, since nothing runs `NSApp.run()`; pumping pointer events with
     `NSApp.nextEvent(matching:until:inMode:dequeue:)` + `NSApp.sendEvent` delivered the
     enter/exit, and `onHover` fired, also with the test process inactive and on the
     non-activating overlay panel. **Trap:** after `NSApp.nextEvent` the Swift Testing process
     exited (status 0, no results printed) at its next `await`; usable once, with results
     written to stderr, not as a committed test. It moves the user's pointer: put it back after.
     Synthesized **clicks** do work (`window.sendEvent`, down then up 50 ms later), also on a
     SwiftUI `Button` that only shows on hover once the hover state is set by the test.
   - **Design reference:** the design canvas's HTML can be rendered with headless Chrome
     (`--headless=new --screenshot --force-device-scale-factor=2 --user-data-dir=<scratch>`) to
     compare with the captures side by side.
     **Animated prototypes (2026-11-21, opening scene):** a board's `.dc.html` needs the canvas
     runtime (`support.js`, not among the published files). What worked: download the component
     (`onb4-win`) and its CSS with the Artifact tool, extract its pure script (the motion maths
     and `renderVals`) into a scratch `.js`, and write a small page that calls it with the
     prototype's **saved** Tweak values and a moment from the query string, builds the
     component's markup and links the CSS; headless Chrome then renders any moment
     (`ref.html?t=…&pt=…&theme=…`) to compare with `ViewRender`'s renders of the same moments.
     Read the saved values from the prototype's `data-props` (each Tweak's `default`): the
     script's own `DEF` object and boards that import the component without `cfg` use older
     values.
   - **CPU of an animation (2026-11-21):** (for the overlay panel alone, item 11 is closer to
     the app) `getrusage(RUSAGE_SELF)` before and after a phase in
     an opt-in window test gives the test process's CPU (`OnboardingWindowTests/welcomeEntrance`
     prints it). Measure a release build: `swift build -c release --build-tests -Xswiftc
     -enable-testing`, then `swift test -c release -Xswiftc -enable-testing --skip-build
     --filter …`. Trap: a test that `dump`s the `body` of a view whose opaque type is used only by
     the test fails to link in release (the optimizer strips the type's metadata). To see where
     the time goes, `sample <pid>`; pick **your own** test process by its path
     (`pgrep -f "swiftpm-testing-helper.*<worktree>"`): another agent's tests may be running
     (2026-11-21: a History window test was sampled by mistake).
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
7. **Crash reports and system frameworks** (fix/stop-recording-crash, 2026-11-20): decode an
   `.ips` report (JSON after the first line) for threads, registers and image offsets; read
   the app's unified log of that minute (`/usr/bin/log show --start … --predicate 'process ==
   "NanoWhisperDebug"'`: AVAudioEngine and AUHAL log engine starts/stops and device changes);
   disassemble a component that is not in the shared cache with `otool -tvV` and one that is
   (AVFAudio) with `lldb` attached to any small program, `disassemble -s <start> -e <end>`;
   trace private calls with lldb breakpoints and `bt` commands in a `-s` script
   (`breakpoint command add N` / … / `DONE`; several `-o` on one line keep only the last).
   Crash reports of harnesses land in `~/Library/Logs/DiagnosticReports/` too: delete your own.
   - **Never open the real microphone from a harness or test** (maintainer's rule, 2026-11-20).
     Agent-run processes do have microphone access (TCC granted to the host), but every engine
     start lights the macOS microphone indicator and disturbs the maintainer at the Mac; the
     stress and start/stop harnesses of `fix/stop-recording-crash` were stopped for that reason.
     Test audio code through `AudioInputEngine` with a fake (`FakeInputEngine` in
     `AudioRecorderTests.swift`), synthetic buffers, or `AVAudioEngine` in manual rendering mode.
8. **Makefile dry runs**: `make -n <target>`; guards of `make publish` were run by hand from the
   `make -n` output, never calling `gh` (PR #14). Workflow steps were run against a fake `gh`/`make`
   on `PATH`.
9. **Window captures of the debug app** (since 2026-11-21: the maintainer granted Screen
   Recording to the terminal). Capture **only the debug app's own windows**, by window id:
   `screencapture -x -o -l <id> out.png`, the id from `CGWindowListCopyWindowInfo` filtered by
   the debug process's pid (`pgrep -x NanoWhisperDebug`; the windows' owner *name* is
   "NanoWhisper Debug", with a space). Never a full-screen capture: the maintainer's other
   windows are private. `feat/onboarding-icon` captured the welcome frame by frame this way.
   - **Gotchas (2026-11-21):** `open … --args --onboarding` activates the debug app and its window
     takes the keyboard (Return is Continue, Space presses the focused button). On 2026-11-21,
     after a System Events `click` on the welcome's Continue, the setup page showed the shortcut
     field recording; the app's log then showed real mouse clicks and key input from someone
     using the Mac, going through Try it (a 5 s test recording: the microphone was on) to Finish
     Setup. Launch the debug app with onboarding only when nobody is using it, press buttons only
     with `perform action "AXPress"` on an element read after the last page change, and never
     on Try it (Start Recording opens the microphone). A test process cannot activate itself
     (cooperative activation), so test windows draw controls in their inactive look; the debug
     app's captures show the active look.

10. **Keys in an active app, without touching the debug app or the real data**
    (`feat/history-redesign`, 2026-11-21). Copy `.build/debug/NanoWhisper` into a bundle in the
    scratchpad with another `CFBundleIdentifier` and executable name (flavor debug, own
    defaults), ad-hoc sign it, `open -n <bundle> --args --history-sample`: LaunchServices
    activates it (a test process cannot activate itself: a test that sent keys through
    `NSApp.sendEvent` found its window never key, so it was dropped), and the History sample
    window is key.
    Post keys to that pid only with `CGEvent.postToPid` (from a `swift` script; nothing reaches the
    frontmost app if it changes), read the app's log and its private pasteboard by name, then
    `pkill -x <harness name>`. **Traps:** virtual key codes are key positions, and the
    maintainer's Mac uses French AZERTY (`com.apple.keylayout.French`): ANSI Z (6) types "w" and
    ANSI W (13) types "z"; `log` in zsh is a builtin, call `/usr/bin/log`.

11. **CPU of the real overlay panel, release build** (`perf/overlay-waveform-cpu`, 2026-11-23;
    results in [architecture.md](architecture.md#recording-overlay), Waveform). A harness in the
    scratchpad compiles `OverlayWaveform.swift`, `RecordingOverlayView.swift`,
    `RecordingOverlay.swift`, `RecorderPosition.swift`, `LiveTranscript.swift` and
    `DictationDestination.swift` (nothing else is needed) with a `main.swift`:
    `swiftc -swift-version 6 -O -whole-module-optimization` (or `-Onone` for debug), about a
    minute. The `main.swift` runs `NSApplication` as `.accessory`, shows a
    `RecordingOverlayController`, feeds `show(audioLevelPublisher:)` from a background timer
    like the tap (4–5 levels every 85 ms, speech-like, deterministic), calls
    `updateTranscript(_:for:)` every second for live text and `transitionToLoading()` for
    transcribing, and moves `controller.window` to a chosen screen (the controller places it
    on the pointer's screen). CPU: `getrusage` after a warm-up, in the process; energy impact:
    `top -l N -s 1 -pid <pid> -stats pid,cpu,power` (no sudo). Frames drawn: a counter added by
    `perl` to the copied `Canvas { graphics, size in` closure (the repo is not changed). Cost
    split: switch parts off from the harness (`viewModel.isPaused` stops the pulse,
    `waveform.freeze()` the glide) and `sample <pid> 8`. What SwiftUI made of a view: dump the
    panel's layer tree (`contentView.layer`, each sublayer's `presentation()` position, shadow,
    filters) a frame apart; that showed `.offset` rounded to whole pixels and `.transformEffect`
    kept fractional. Whether two ways of drawing give the same pixels: put both side by side in
    one opaque borderless window on the screen to test, at fixed inputs, `screencapture -x -o
    -l <id>`, compare with `NSBitmapImageRep.getPixel`. **Traps:** WindowServer's CPU (`ps -o
    time=`) is too noisy to attribute while other apps draw; `pgrep -f` on a binary started as
    `./name` does not match a path, use `$!`; a free-standing Swift file with top-level code must
    be named `main.swift`.
12. **A CI machine's three concurrency threads, locally** (2026-11-24). A test that blocks its thread
    can stop the suite on CI (3 cores) and never here. Add a temporary test (not committed) that
    starts `activeProcessorCount - 3` `Task.detached` blocks of `usleep(40_000_000)`, run the suite,
    and `sample` the `swiftpm-testing-helper` process if it stops: the stack names the blocked call.
    `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` (one thread) is not the same: it showed nothing here, and
    `ModelStoreTests.cleanupWaitsForLock` needs two threads.

## What agents cannot verify

Real microphone input (not in the app: its permission is not granted to the debug app by agents,
do not trigger prompts; not in harnesses either, see above), anything visual on the real screen (menu bar, overlay animation, several
displays), TCC prompts, Gatekeeper on a downloaded build. List these as "not verified" in the PR
and in [open-questions.md](open-questions.md).
