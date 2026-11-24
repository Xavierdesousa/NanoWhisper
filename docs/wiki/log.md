# Log

Dated entries, newest first. One entry per change to the project or to this wiki: what changed,
why if not obvious, and the PR. Older history is summarized from `git log`.

## 2026-11-24

- **No copy of the recording, and "Not pasted"** (`fix/recording-copy-and-paste-state`): Parakeet reads
  a recording into memory instead of FluidAudio's plain copy in the temp directory (same text,
  measured); a leftover copy that is byte for byte one of our recordings is deleted at launch, the
  others cannot be told apart and stay. The recorder says "Pasted" only when the ⌘V was sent,
  else "Not pasted" (and "Saved in History" when it is). Pages:
  [transcription-engines](transcription-engines.md#parakeet-reads-a-recording-into-memory-2026-11-24),
  [architecture](architecture.md#pasted-or-not), testing, open-questions.
- **Local data handling** (`fix/local-data-hardening`): the dictated text is marked transient and
  confidential on the clipboard, and everything the clipboard held comes back (all items and types,
  bounded); temporary recordings are zeroed in blocks, and links are never followed when zeroing,
  repairing or collecting them; a stored shortcut that the app could not have written gives the
  default; live transcription errors and `osascript`'s stderr are private in the log; the title of
  what is playing goes to `osascript` on standard input. Recordings keep their location (why:
  [architecture](architecture.md#temporary-recordings)). Pages: architecture (new section
  [Clipboard around a paste](architecture.md#clipboard-around-a-paste)), media-pause, testing,
  open-questions.
- **README history sentence restored** (`docs/readme-history-sentence`), at the maintainer's request: it
  describes the key bound to this Mac being built in `feat/history-key-secure-enclave`.
- **Verify the update before installing** (`fix/updater-hardening`, PR #49): the updater checks the
  running app's and the new app's signature against pinned requirements, the identifier, the version
  (equal to the tag's, newer than the running one), the asset's name, address, size and SHA-256, and
  the archive's content, all in a private directory, before replacing the app; it relaunches without
  a shell once the old instance has exited; a failed install now shows in the menu too. New files
  `UpdateRelease.swift`, `UpdateSignature.swift`, `UpdateInstaller.swift`; `Subprocess.run` gained
  `stopWhen`. How to change the signing certificate (bridge release) is written down. Pages:
  [build-and-release](build-and-release.md#auto-updater), testing, architecture, open-questions.
- **README and release workflow tightened** (`chore/release-and-readme-hardening`): the README no longer
  says a backup of the history cannot be read, nor suggests `xattr`; the workflows pin actions by
  commit; a release must be tagged on `main`; the build keychain is removed at the end of the job;
  argmax-oss-swift is pinned `exact:`. Updated [architecture](architecture.md).

## 2026-11-23

- **README rewritten as a product page** (`docs/readme-0.1.0`): hero with a download link, the
  measured speed (up to 327×, 0.19 s median, ~1.8 s for 10 minutes; source
  [transcription-engines](transcription-engines.md#measured-speed-on-real-dictations-2026-11-21)),
  features with **dark** screenshots only (maintainer's choice; `docs/images/`, from the
  `ViewRender` renders at 2x, History with invented entries only), privacy and permissions, the
  Gatekeeper note, usage, requirements. At the maintainer's review: no footnote, no engine names
  in "How it works", no Models, Roadmap, First launch or Build from source sections (build
  instructions live in `CLAUDE.md` and this wiki). How the images were made:
  [testing](testing-and-verification.md#techniques-that-work-without-a-screen), item 1.
- **Version 0.1.0** (`chore/release-0.1.0`): Info.plist bumped; the release flow, the planned Stable/Beta
  channels (GitHub pre-releases, `-beta.N` tags) and auto-update when idle written down in
  [build-and-release](build-and-release.md#release-channels-planned-for-011-not-built-yet); two opening-scene clock
  tests poll instead of a fixed sleep (they flaked on CI).
- **Recorder CPU measured in a release build; no change** (`perf/overlay-waveform-cpu`): the real
  overlay panel in a release harness with synthetic levels (M3 Pro, 120 Hz): 19 % of a core
  recording, 25–26 % with live text, 13 % transcribing, 0.1 % once dismissed; the same in debug
  and on a 144 Hz display. Split: waveform canvas ~8 points, capsule pulse 5–10, live-text
  cross-fade 9–11. Glide by `.offset` (pixel-rounded) or `.transformEffect` (different pixels,
  up to 117/255) and grouped fills (no gain) rejected: no change keeps the look identical.
  Options listed for the maintainer. Pages: architecture (Waveform, CPU), testing (item 11),
  live-transcription, onboarding (correction of the 82–104 %), open-questions.

## 2026-11-21

- **Welcome demo: 5 s, 5 words/s, words in groups** (`fix/welcome-demo-six-words`): 7.2 words/s was a touch
  too fast; a 24-word sentence ("…Let’s split it in two: API first, then the UI.") over a 5 s recording
  (0:05), the words arriving in groups of one to three like the real live text.
- **Live transcription offered in production, as a beta off by default** (`feat/live-transcription-beta-in-production`):
  `BuildFlavor.supportsLiveTranscription` is true for both builds. Updated [live-transcription](live-transcription.md).
- **Welcome demo: faster text, later Replay** (`fix/welcome-demo-text-pace`): the waveform keeps 2.6 words/s
  but the live text writes at 7.2 words/s (`WelcomeDictation.textWordsPerSecond`) so the former 29-word
  sentence is written in the 4 s; the Pasted card stays 1.85 s before the veil (Replay 1.5 s later).
- **The welcome's recorder plays a whole dictation; History's place** (`feat/welcome-demo-flow`):
  the demo records 4.3 s (0:00 → 0:04) at 2.6 words/s with a waveform that follows the words
  ("So the plan for this week is the payment flow."), then the real Transcribing (0.8 s) and
  Pasted (0.35 s) states, then a grey veil with Replay (from 0:00, any number of times); Stop
  shows under the pointer anywhere over the card and ends it at once; Reduce Motion shows the
  end with Replay; nothing moves under the veil (0 % CPU). The history caption says "Open it
  from the menu bar icon." (setup page and Settings › General). Measured long dictation added
  (570.8 s in 1.78 s, 321×). Pages: onboarding-and-settings, transcription-engines, testing
  (hover in tests), log.
- **Measured speed on real dictations** (`docs/measured-speed`): median 126×, best 327× real time,
  median 0.19 s (Parakeet Ultra, M3 Pro). In [transcription-engines](transcription-engines.md#measured-speed-on-real-dictations-2026-11-21).
- **Opening scene, light recorder, theme, debug-only Open Onboarding**
  (`feat/opening-scene-light-overlay`, PR #38): the welcome opens on the approved opening scene (violet
  sunrise, title moment, Get Started, travel into the welcome; values from the prototype's saved
  Tweaks, `OpeningScene.Tweak`); the recording overlay gets a light palette (`OverlayColors`) and
  its drop shadows in a click-through child window; Settings › General › Appearance (System,
  Light, Dark: `NSApp.appearance`); Settings › Advanced's onboarding replay exists only in the
  debug build, keeps Settings open and restarts from the scene. Measured: the scene costs about
  one core while it moves (SwiftUI's per-refresh cost in this window). Pages: onboarding-and-settings
  (Opening scene, Appearance, Replay), architecture (Recording overlay), testing (prototype
  references, CPU), log.
- **History asks before deleting one dictation** (`feat/history-confirm-delete`): an alert that
  also teaches ⌘Z; undo/redo never ask. Updated [architecture](architecture.md#history-window).
- **History window, "List and detail"** (`feat/history-redesign`): a Notes-like split (list by
  day, the dictation in full, toolbar Copy · Delete · search), 880 × 580 pt (min 640 × 420). Copy
  only copies (never pastes), "Copied" 1.5 s; Delete with an Undo capsule and ⌘Z; Clear All
  with an alert; search with highlights and "No Results"; shortcuts taught by tooltips, the
  context menu and the empty detail, and handled by the window itself (no Edit menu, no Dock
  icon; checked with keys posted to a harness app). History… always enabled; the window explains
  empty, off and unavailable. Footer Change… opens Settings › General (`showSettings(pane:)`).
  Data: default kept count 25 (was 15); turning history off deletes it after an alert; a file
  kept while history was off is deleted once, silently, at the first launch after the update;
  debug info stores the model and Whisper's language (old entries load without them);
  Settings › Advanced caption corrected. Debug builds: `--history-sample`.
  [architecture.md](architecture.md#history-window).
- **Try it result in a serif** (`feat/try-it-serif`): the transcribed words use New York (system serif,
  21 pt), like a quotation, at the maintainer's request.
- **Finder's colors, the app in the macOS 26+ design** (`fix/welcome-faster`): the app's binary
  recorded SDK 14.0 (SwiftPM's default build system writes the deployment target), so AppKit ran
  it in the pre-26 design: lighter window and a wallpaper-tinted toolbar, unlike Finder.
  `make build` now links with the real SDK version and checks it. Settings and onboarding no
  longer paint a background: the system draws it and the toolbar header as for Finder (dark,
  raw pixels: header #262726 vs Finder #262727, content #1F1F1F vs #1F1F1F). Light cards black
  3 % (white vanished on the white light background). Side effects fixed: menu text inset
  14 → 16 pt; the onboarding window grew to 672 pt (hosting view now in a container). The
  earlier "#292929 renders #363636" was the sampler's gamma-1.8 conversion, not the window.
  [build-and-release.md](build-and-release.md#the-sdk-version-in-the-binary-macos-26-design),
  [onboarding-and-settings.md](onboarding-and-settings.md#window-colors).
- **No blank Settings window at launch** (`fix/welcome-faster`): a never-inserted
  `MenuBarExtra` before the empty `Settings` scene.
- **Welcome faster** (`fix/welcome-faster`): 0.3 s fades, facts together, 125 ms idle, a 3 s
  dictation of the whole sentence, frozen at 0:03 (maintainer: "too slow, a bit jerky").
  `OnboardingWindowTests` follows the new timeline.
- **Onboarding and Settings polish after the maintainer's test** (`fix/onboarding-settings-polish`):
  the welcome's recorder now waits idle at 0:00 until 0.25 s after the page has arrived
  (`WelcomeDictation.idleWait`; 1 s was "far too long"), records 5.6 s (a three-line
  sentence) and stops **paused** at 0:05 (`RecordingOverlayViewModel.isPaused`: still capsule,
  steady caret, still waveform); the Engine section always shows the model picker with the
  speed/accuracy bars and key points under it, at a fixed height, the bars sliding and the text
  cross-fading on a change; Settings no longer uses a grouped `Form`: one card style
  (`GroupedStyle`, `groupedCard()`) for Settings and onboarding, no border, radius 12, the
  onboarding colors; toolbar icons drawn at their real proportions on 1x displays
  (`ToolbarSymbol`), Recorder's icon is `waveform`. Details and causes:
  [onboarding-and-settings.md](onboarding-and-settings.md).
- **Onboarding redesign, direction "Icon"** (`feat/onboarding-icon`): one 580 × 640 pt window,
  three pages. Welcome with the approved copy, the four facts and the real recorder view playing
  a simulated dictation, frozen mid-sentence at 0:03 (staged fade-up entrance; Reduce Motion:
  the frozen frame at once). Setup page: permissions with circles that become checks, the model
  with a download ring and a hover/focus-only Change… opening the Settings Engine section in a
  sheet, the shortcut row, four switches all on for a new install. Try it: instructions and
  result in the window, the real recorder at its real place; the window opens below the centre
  when the recorder's card would meet it (1440 × 900). Finish Setup calls the menu bar handoff
  (#31). "Pause music and videos while recording" now defaults to on for new installs; "Open at
  login" is turned on once when a new install's setup page shows it. Old onboarding views and
  renders removed. English only (`OnboardingText`). Deviations from the design where the code
  says otherwise: [onboarding-and-settings.md](onboarding-and-settings.md#onboarding). First
  window captures of the debug app (`screencapture -l`, its windows only):
  [testing-and-verification.md](testing-and-verification.md#techniques-that-work-without-a-screen).

## 2026-11-20

- **End of onboarding: the menu bar takes over** (`feat/menu-bar-handoff`): the approved board's
  popovers under the status item. `MenuBarController.showOnboardingHandoff()` (called by
  onboarding's Finish Setup) shows "NanoWhisper is in the menu bar" with the real shortcut and
  recorder position, or the download state; one more "<model> is ready" popover if it was not
  ready. `NSPopover`, `.applicationDefined`, closed on OK, Escape, a click elsewhere or the menu
  opening; never activates the app; OK in the system accent. Debug-only `--show-handoff`
  (`make handoff`). Gotchas recorded: size an `NSPopover` before showing it, popovers invisible
  to AX from outside.
- **Overlay, menu and stop tail, tuned live with the maintainer** (`feat/overlay-menu-tweaks`):
  overlay surface black 90 % with a soft violet inner shadow instead of a rim, no window shadow,
  Stop as an SF Symbol, a clearly visible pulse on the record capsule; waveform levels in dB every
  20 ms through an envelope and a normalizer to the recent loudest speech, silence floor 0.15;
  menu 280 pt wide, no debug header, shortcut as plain glyphs. Recording continues 300 ms after
  the user stops (`AppState.recordingTail`) so the last word is not cut off; the stop sound plays
  after that tail so it is not recorded, and a press during the tail is ignored.
- **Recovery of recordings interrupted by a crash** (`feat/recover-interrupted-recordings`, PR #28):
  the maintainer approved the recommendation of PR #26 with their own rules. At launch, this
  build's leftovers with audio are kept (header repaired) and transcribed once each, silently,
  when the app is idle; the text goes to History at the recording's date. Renamed
  `….attempted.wav` before the attempt, so a crash during it is never retried; too short, too
  old, unreadable or with history off: deleted. Replaces `TemporaryRecordings.removeOrphans()`.
  Details: [architecture.md](architecture.md#temporary-recordings).

- **Feedback on the redesign** (`feat/redesign-feedback`, PR #27): the maintainer's notes after
  trying PRs #24 and #25. Overlay: three lines of live text (card 380 × 106), the waveform takes
  the card's width, silence drawn as dim 1.5 pt marks with a 0.35 floor (room noise was drawn as
  bars), a translucent icon-violet surface with a rim after the icon's tile edge, text opacities
  raised to keep 4.5:1. Settings: the dark band across the toolbar on pane switches is fixed
  (cause: crossfaded panes laid out at the other pane's height overflowing under the toolbar,
  plus `NSTabViewController`'s 501-priority size constraint fighting the manual resize); no
  violet left in Settings, onboarding or the menu (system accent). New opt-in
  `SettingsWindowTests`; animations in tests progress only while the test is suspended. Details:
  [onboarding-and-settings.md](onboarding-and-settings.md#settings-window-toolbar-panes),
  [architecture.md](architecture.md#recording-overlay).

- **Crash when stopping a recording** (`fix/stop-recording-crash`, PR #26): the debug app crashed
  at the end of a 2 min 44 s dictation. Cause: `removeTap` on the running engine cleared the
  AUHAL input callback while CoreAudio's IO thread was about to call it (null call); confirmed
  by disassembly and tracing, reproduced with the same signature in a stress harness.
  `AudioRecorder` now stops the engine before removing the tap, closes the WAV before returning
  it (`RecordingWriter`), and continues on a new input after `AVAudioEngineConfigurationChange`
  (or stops cleanly with `onInputLost`). Recommendation (implemented later, see above) to offer crashed
  recordings at next launch. Details:
  [architecture.md](architecture.md#stopping-the-recorder-crash-of-2026-11-20).

- **Settings and menu redesign** (`feat/settings-and-menu-redesign`, PR #25): approved designs from the
  Claude Design canvas (Settings proposal 1 "Toolbar panes"; the menu of "After setup: the menu
  bar takes over"); the onboarding redesign was not approved and is postponed.
  - Settings: five toolbar panes (General, Engine, Recorder, Permissions, Advanced) in an
    `NSTabViewController` inside the existing `SettingsWindowController`; a SwiftUI `Settings`
    scene was rejected (opening and teardown in a menu bar app). Recorder hosts the recorder
    position picker from the Voice note overlay (PR #24, merged into this branch).
  - Menu: `MenuBarExtra` replaced by an AppKit `NSStatusItem` menu (`MenuBarController`) built
    from `MenuContent.lines(for:)`, for the download bar and the key caps.
  - The shortcut is drawn as flat key caps (`ShortcutKeysView`), in Settings, the menu and
    onboarding's Try-it row (maintainer's request: no 3D keys).
  - Whisper language and vocabulary apply at once in Settings; `AutoUpdater.lastCheckDate`;
    the engine start error no longer names a button.
  - Design text not used because it is not true of the app: "text is copied for you to paste"
    without Accessibility, "Parakeet stays in use until Whisper is ready", byte counts and
    "4 models, 1.7 GB" (would need reading `~/Documents`). Details:
    [onboarding-and-settings.md](onboarding-and-settings.md), [architecture.md](architecture.md#menu-bar-menu).

- **Recording overlay redesign, "Voice note", and the recorder position** (`feat/voice-note-overlay`, PR #24):
  the overlay now follows the approved design (capsule, 26-bar scrolling waveform at 50 ms,
  card for live text with a top fade and a caret, result states with a VoiceOver announcement,
  Reduce Motion and Reduce Transparency fallbacks). New setting `RecorderPosition`
  (`recorderPosition`, Top Center by default; Top Left, Top Right, Bottom Center) with placement
  and growth from the pinned edges, and a standalone `RecorderPositionPicker` for the Settings
  redesign to place. Decisions: empty 50 ms slots repeat the last level (the tap delivers about
  every 85 ms); "Done" for Try-it results (not drawn). Details in
  [architecture.md](architecture.md#recording-overlay). Verified by captures of the real panel
  only.
- **Release 0.0.6**: version bumped in `Resources/Info.plist` (build 6). Released without a
  manual production test, at the maintainer's request. Checked in the debug app on the
  maintainer's Mac before tagging: a launch on Ultra deletes nothing (v3, Ultra, Whisper Base and
  Turbo all kept) and records migration step 1; an install set to v3 with no step recorded is
  moved to Ultra once and v3's files are kept; going back to v3 afterwards is respected on the
  next launch. Not exercised for real: the background download of Ultra while v3 is in use, and
  the removal of obsolete folders (none were present).
- **Model migrations, obsolete models, "Remove Unused Models…"** (`feat/model-migration-and-cleanup`):
  - **Decision reversal:** 0.0.5 kept existing installs on Parakeet v3; the maintainer now wants
    updates to move people to the better model automatically. Rules recorded in
    [transcription-engines.md](transcription-engines.md#model-rules-maintainer-decisions-2026-11-20):
    a model stays while it is published upstream (v3 stays), obsolete models are removed
    automatically, migrations are automatic and smooth, selectable models are never auto-deleted.
  - Migration schema `ModelMigrations.steps` (step 1: Parakeet → Ultra; Whisper left out),
    run once per install; smooth switchover (`ModelSwitchover`): start on the previous model,
    download the new one in the background, switch when loaded and no recording is in progress.
  - Whisper lineup curated to Base, Small, Large v3 Turbo; Tiny → Base, Medium and Large v3 →
    Turbo as declared replacements (`WhisperModelSize.replacement`), separate from steps. Live
    transcription now Base only.
  - "Recommended" badge from model metadata (Ultra, Large v3 Turbo).
  - `ModelStore`: allow-listed folder names, shared lock, automatic removal of obsolete folders,
    Settings › Downloaded Models › "Remove Unused Models…", production/debug protection from the
    other flavor's preferences.
  - Version-bump checklist added to [build-and-release.md](build-and-release.md#models-at-every-version-bump).
  - Nothing was run against the real caches or apps; see [open-questions.md](open-questions.md).
- **Release 0.0.5**: version bumped in `Resources/Info.plist` (build 5). The maintainer tested
  the debug build by hand (media pause in all cases incl. YouTube, onboarding, Try-it, plain
  dictation, live preview after the overlay fix). Roadmap for the next version recorded in
  [open-questions.md](open-questions.md).
- **Overlay and debug marker fixes** (`fix/overlay-and-debug-marker`), from the maintainer's
  test of the debug build:
  - **Live text overlay broken in the real app:** the panel stayed compact (123×40 pt) while
    its content grew to 384×82 pt, because `fittingSize` was read before SwiftUI re-rendered.
    The panel now follows the content's ideal size (`OverlayHostingView`), without an animated
    resize. Reproduced and verified with the real panel in a harness and `OverlayWindowTests`.
  - **Record dot sliding in Try-it:** `PulsingDot`'s `.repeatForever` animation was attached to
    the whole view, so when `onAppear` ran during the panel's first layout (recording started
    from a SwiftUI button in an active app) it also animated the dot's position, forever. The
    animation is now scoped to scale and opacity (`animation(_:body:)`); the panel is also first
    laid out at its real size.
  - **Debug menu bar marker:** an orange band across the bottom of the glyph replaces the dot.
  - **Try it:** "Record a Test or press <shortcut>" with the shortcut as a key cap; the hotkey path
    to a test recording checked in code ([onboarding-and-settings.md](onboarding-and-settings.md)).
  - **Planned (maintainer):** a redesign pass of onboarding, Settings and the overlay next; the
    feedback sounds to be replaced with new original ones ([open-questions.md](open-questions.md)).
  - Pages: [live-transcription.md](live-transcription.md), [testing-and-verification.md](testing-and-verification.md)
    (capturing a real window), [build-and-release.md](build-and-release.md), README.

- **Cleanup** (PR #19, `chore/cleanup`):
  - **History extracted** from `AppState` into `HistoryStore` (`HistoryStore.swift`, with
    `HistoryEntry`, `TranscriptionDebugInfo`, `HistoryCrypto`); temp-recording deletion into
    `TemporaryRecordings`. File format and key unchanged (key derivation pinned by a test).
    One behavior tightening: while history is unavailable, no write happens at all (an open
    History window could overwrite an unreadable file before); saves are now atomic. Stale
    Keychain comments fixed. The zero-then-delete of recordings uses throwing `FileHandle` calls
    (the old ones raise an Objective-C exception on I/O errors) and is documented as best effort.
    [architecture.md](architecture.md#history-storage).
  - **Transcription errors surfaced:** `Transcriber` logs the error and returns
    `TranscriptionResult.failure` (`TranscriptionFailure.engineError` / `.noEngine`) instead of
    empty text; `DictationOutcome.failed` puts "Transcription failed…" in the menu error line
    (overlay still dismissed, no-result sound). An empty result is unchanged ("Empty
    transcription").
  - **README:** Swift badge 6.2+; Gatekeeper first-launch steps for the non-notarized release
    (Apple's "Open Anyway", or `xattr -dr com.apple.quarantine` on the app only); honest wording
    for the history key; debug-only live transcription in the flavor table.
  - **Leftovers:** `Subprocess` comments no longer mention perl. Remaining mentions of perl,
    `mediaremote-adapter`, System Audio Recording, CodeQL, Whisper Medium and sliding-window
    streaming are deliberate (rejected-alternative records in the wiki, the Medium migration in
    code and README).
  - Pages: [architecture.md](architecture.md), [testing-and-verification.md](testing-and-verification.md),
    [open-questions.md](open-questions.md), `CLAUDE.md` source map.

- **Live transcription made debug-only** (PR #18, merged as a77106d): the maintainer found design
  problems in the overlay, so production hides the toggle and never starts a live session, even
  with `liveTranscriptionEnabled` stored on (the value is kept). One flag:
  `BuildFlavor.supportsLiveTranscription`. Pages: [live-transcription.md](live-transcription.md#debug-build-only),
  [build-and-release.md](build-and-release.md) (flavor table), [open-questions.md](open-questions.md).

## 2026-11-19

- **PR #16 updated** (live transcription):
  - **Window cap:** previews of recordings longer than 30 s decode a ≤ 15 s window after a
    frozen boundary, which keeps CPU at ~23 % of one core instead of reaching a full core after
    2.5 min.
  - **Join guard:** stops repeated words at window joins.
  - **Whisper availability:** offered only for Tiny and Base. Large v3 Turbo needs ~0.6 s to
    stop a preview decode.
  - **Integration:** wired to `SettingsContext` and `GeneralSettingsSection` (#15) and to
    `DictationDestination` (the Try-it box gets the final text).
  - **Downloads:** Whisper Base and Large v3 Turbo were downloaded into WhisperKit's default
    cache through the app's `WhisperEngine`, on the maintainer's request.
  - **Pages:** [live-transcription.md](live-transcription.md) rewritten;
    [transcription-engines.md](transcription-engines.md) gained the Whisper cache path and the
    Turbo measurements.
- **Wiki created** (`docs/llm-wiki` branch): `CLAUDE.md` and these pages, from the code on `main`
  (29e84c9), PRs #11–#16 and the maintainer's notes. `swift test` on `main`: 174 tests in 20
  suites passed (Swift 6.4, macOS 27.2); `ViewRender` renders passed.
- **PR #16 open**: live transcription (beta) by re-decoding the growing buffer. Documented in
  [live-transcription.md](live-transcription.md) as not merged. Sliding-window streaming was
  measured and rejected.
- **#15 merged** (29e84c9): onboarding rebuilt as five steps sharing sections with Settings;
  draft/apply rule; first launch no longer downloads before the user sees the choice; replay via
  Settings, `--onboarding`, `--reset-onboarding`, `make onboarding`. Real Microphone status in
  Settings. [onboarding-and-settings.md](onboarding-and-settings.md)
- **#12 merged** (846c466): media pause through Now Playing with osascript/JXA and explicit
  pause/play; media key, CoreAudio tap and the System Audio Recording permission removed.
  `mediaremote-adapter` tried and dropped (Gatekeeper on a non-notarized first install).
  [media-pause.md](media-pause.md)
- **#14 merged** (66ef417): NanoWhisper Debug flavor (`BuildFlavor`), Makefile rewrite,
  `make publish` and `make release-zip-name`, release workflow tolerates an existing release.
  Also an inter-process `flock` around the legacy cache migration (race reproduced 13/40).
  [build-and-release.md](build-and-release.md)
- **#11 merged** (7770591): CI and release on the `xcode-27` preview runner (Swift 6.4);
  CodeQL workflow removed; `LSMinimumSystemVersion` 13.0 → 14.0. [ci-and-review.md](ci-and-review.md)
- **#13 merged** (ac69c71): FluidAudio 0.12.4 → 0.18.3 (traits off), WhisperKit 0.17.0 → 1.1.1
  (`argmax-oss-swift`); Parakeet Ultra (default for new installs), Whisper Large v3 Turbo, Medium
  removed; v3 cache moved to the new folder; serialized transcriptions with a configuration
  snapshot; Swift 6.4 isolation errors fixed with `WhisperEngine`; vocabulary hint now actually
  used. [transcription-engines.md](transcription-engines.md)

## Before 2026-11-19 (from `git log`)

- 2026-04-03: v0.0.4 (current release). README rewritten.
- 2026-03-26: #10, first media pause (CoreAudio tap + Play/Pause key). Replaced by #12.
- 2026-03-25: unit tests and CI (#7), CodeQL workflow (#9), release workflow, CI on `macos-26`.
- 2026-03-24: WhisperKit engine (#6), auto-updater, GPL v3.
- 2026-03-20: onboarding (#3), recording overlay, security audit (#4): encrypted history, hardened
  runtime, secure deletion; Keychain key replaced by an HKDF key from the hardware UUID.
- 2026-03-19: Python/NeMo daemon replaced by FluidAudio Core ML (#2).
- 2026-03-18: initial commit; signing with the "Moonji Dev" certificate.
