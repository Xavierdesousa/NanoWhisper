# Onboarding and Settings

Last verified against the code: 2026-11-21 (the welcome's recorder flow and the history caption in `feat/welcome-demo-flow`, with unit tests, offscreen renders and real-window tests in a test process, not in the app; the opening scene, the Appearance setting and the debug-only Open Onboarding in `feat/opening-scene-light-overlay`, with unit tests, offscreen renders and real-window tests in a test process, not in the app; window colors, the onboarding window's container and the blank-window fix in `fix/welcome-faster`, in the debug app; `feat/settings-and-menu-redesign`; End of onboarding against `feat/menu-bar-handoff`; the Settings window, colors and sizing again in `feat/redesign-feedback`; onboarding rewritten in `feat/onboarding-icon`; welcome sequence, cards, toolbar icons and the Engine comparison in `fix/onboarding-settings-polish`, also run in the debug app), with unit tests, offscreen renders and window captures; the Settings redesign was not run in the app (see Known limits). Source: PR #15, the model migration PR, the Settings and menu redesign PR, the handoff PR #31, the onboarding "Icon" PR and the code.

## What it is

Settings and onboarding read the same `SettingsContext` and share their wording and rows
(`SettingsText`, `ShortcutRecorderRow`, `EngineChoiceSection`). Settings has its toolbar panes;
onboarding (redesigned 2026-11-20, direction "Icon") is one window of three pages with its own
views (below).

| Area | Settings pane (file) | Onboarding |
|---|---|---|
| Shortcut (`ShortcutRecorderRow`, `SettingsShortcutSection.swift`) | General | Setup page, "Dictation" (the row with `isCompact`: no caption, no reset button) |
| Open at login, sounds, pause media, history on/off (`DictationBehaviorToggles`, `HistorySettingsRows`, `SettingsGeneralSection.swift`) | General, plus "Keep the last N" (disabled while history is off) | Setup page, "Settings" (four switches, same labels; no history size) |
| Engine, model, status, apply row, Whisper language and vocabulary (`EngineChoiceSection`, `SettingsEnginePane.swift`) | Engine (`EnginePane`) | Setup page, "Model" row; its Change… opens `ModelChoiceSheet` with the same section |
| Downloaded models, "Remove Unused Models…" (`ModelStorageRow`, `UnusedModelsSheet`, `SettingsStorageSection.swift`) | Engine | — |
| Live transcription (beta, debug builds only) | Recorder (`RecorderPane`, `SettingsRecorderPane.swift`) | — (Try it says the words show in the recorder when it is on) |
| Recorder position (`RecorderPositionPicker` from the Voice note overlay, PR #24; `AppState.recorderPosition` through `SettingsContext.recorderPosition`) | Recorder | — (Try it names where the recorder appears) |
| Microphone, Accessibility with live status | Permissions (`PermissionsPane`, `SettingsPermissionsSection.swift`) | Setup page, "Getting ready" (`PermissionChecklistRow`) |
| Updates, "Show debug info in history", "Open Onboarding" (debug build only) | Advanced (`AdvancedPane`, `UpdateStatus`, `SettingsAdvancedPane.swift`) | — |
| Appearance: System, Light, Dark (`AppearanceRow`, `AppAppearance.swift`) | General | — (Settings only) |

**History switch (2026-11-21):** turning "Keep a history of what you dictate" off, in Settings
or onboarding, with dictations kept first asks "Turn off history and delete it?" (Turn Off and
Delete / Cancel); confirmed, the history is deleted and turned off; Cancel leaves it on; with
nothing kept there is no alert. `SettingsContext.historyEnabled`'s setter calls
`AppState.setHistoryEnabled(_:)`, so neither view changed. "Keep the last" defaults to 25 (was
15). Details: [architecture.md](architecture.md#history-storage).

**Opening Settings on a pane:** `AppState.showSettings(pane:)` (History's "Change…" opens General,
where the kept count is set); without a pane it reopens the last one. An open window switches
pane.

**Advanced caption (2026-11-21):** "Show debug info in history" says "The model, audio length,
transcription time and speed of each dictation, in the History window." (it said "next to each
entry", and the board's "Engine, timings and audio details" named no model; the model is now
stored, see [architecture.md](architecture.md#history-storage)).

The Advanced "Debug" group exists in both builds ("Show debug info in history"); its "Open
Onboarding" row exists only in the debug **build flavor**
([build-and-release.md](build-and-release.md), [Replay](#replay)).

`AppState.settingsContext(permissions:)` builds the live context; render tests build fixed ones
(`Fixtures`, `SettingsFixture`), so each pane can be drawn without a running app
([testing-and-verification.md](testing-and-verification.md)).

## Settings window (toolbar panes)

Design: Claude Design canvas "NanoWhisper Redesign", Settings page, proposal 1 "Toolbar panes"
(approved 2026-11-20).

- **Window technology: `NSTabViewController` with `tabStyle = .toolbar`** in the existing
  `SettingsWindowController` (`SettingsView.swift`), one `NSHostingController` per pane
  (`SettingsTabViewController`). The toolbar style draws the pane items, and the window title is
  the pane name. The window is `toolbarStyle = .preference`, width 640 pt
  (`SettingsPane.width`), height fitted to the pane.
  - **Rejected: a SwiftUI `Settings` scene** (what the design notes suggested). In a menu bar app
    (accessory policy) it can only be opened through `SettingsLink` / `openSettings`, the window
    does not come to the front by itself, and the app has no hook to rebuild the content at each
    opening or to stop the permission polling when the window closes (a closed window keeps its
    view; `onDisappear` does not run). The window controller already did all of that. The app
    keeps an empty `Settings` scene only as its Scene; its "Settings…" command (app menu,
    visible while onboarding shows the Dock icon) opens the real window. A never-inserted
    `MenuBarExtra` (`isInserted: .constant(false)`) comes before it: with `Settings` as the only
    scene, SwiftUI opened that scene's empty window at every launch (a blank "NanoWhisper Debug
    Settings" window, seen 2026-11-21). Checked on launch of the debug app: no window.
  - **Sizing:** each pane is a `VStack` of `SettingsSection`s with
    `.fixedSize(horizontal: false, vertical: true)` (`SettingsPaneForm`), so its fitting size is
    its content. `SettingsTabViewController` alone sizes the window, keeping the top edge: on a
    pane switch, and when the selected pane's content changes height (Whisper options, pending
    change, update states).
  - **Cards (since 2026-11-21): no grouped `Form`.** The maintainer saw a 1 px line around the
    cards, clipped at the corners (sometimes visible, sometimes not), and different radii and
    colors between onboarding and Settings side by side. Causes: the native grouped `Form`
    draws its section cards with a hairline border, which on a 1x display (the maintainer's
    2560 × 1440 screen) lands on fractional pixels and is clipped at the rounded corners; and
    its card color cannot be changed (`.listRowBackground` has no effect on a macOS grouped
    `Form`, tried in a harness), while onboarding drew its own 10 pt cards with a 0.5 pt stroke.
    Now one style for both (`GroupedStyle`, `groupedCard()`, `GroupedRowDivider` in
    `SettingsStyle.swift`): no border, radius 12 pt continuous (what the native grouped form
    drew, measured on its render), the card #2A2A2D in dark (maintainer's choice), black at 3 %
    in light; the background is the window's own, the same in both windows (see
    [Window colors](#window-colors)). Rows get `.settingsRow()` padding and explicit dividers.
    - The grey switches in the maintainer's onboarding screenshot were only the inactive-window
      look (confirmed by the maintainer).
  - **Toolbar icons (since 2026-11-21): `ToolbarSymbol`.** "Horizontally stretched" icons: on
    a 1x display, a plain `NSImage(systemSymbolName:)` comes out about 1.5 px wider and 1 px
    shorter than the glyph (Engine's square `cpu` drew 21 × 19 px; `slider.horizontal.3` 1.31
    wide for 1.20). The same symbol drawn alone into a 1x bitmap does the same, so it is the
    system's 1x glyph rasterizer, not the toolbar's scaling (in Retina captures the ratios are
    exact). `ToolbarSymbol.image` draws the symbol at 4× into a bitmap and scales it down on a
    1x display (true proportions, slightly softer), as is on Retina; the image is a 32 × 32
    template canvas (the size the toolbar gives a non-symbol image, drawn 1:1; a smaller one is
    scaled up), the glyph at 20 pt as the toolbar showed plain symbols. Trap: the bitmap's
    `size` must be set before `NSGraphicsContext(bitmapImageRep:)` is created, or the symbol is
    drawn at a quarter size (the icons came out as dots). Recorder's icon is `waveform` (what
    the recorder shows; `capsule.portrait` read as an empty outline, `record.circle` reads as a
    Record button).
  - **Pane switch (since 2026-11-20):** no crossfade; the new pane is swapped in at once,
    hidden, the window animates to its height (0.2 s, ease in-out, non-blocking `animator()`),
    then the pane fades in (0.12 s). Reduce Motion: no animation. Each pane is a
    `SettingsPaneController`: a clipping container that follows the content area, holding the
    `NSHostingController`'s view pinned to the top at the content's own height (Auto Layout:
    top, leading, trailing; height from the intrinsic size), so a pane is never laid out at
    another height. Content changes arrive as frame changes of that view.
  - **The glitch it fixes** (maintainer's screenshot, dark, Engine selected: a dark line across
    the toolbar through the pane labels). Measured in the real window (`SettingsWindowTests`,
    and a capture of the previous code's real animation):
    1. The crossfade kept the outgoing pane on screen for about 0.6 s, laid out at the new
       window height. `NSHostingView` centers content taller than itself, so General (431 pt)
       in Engine's 370 pt overflowed 30.5 pt **above the content area, under the translucent
       toolbar** (77 pt for General → Advanced). The line in the screenshot is ~21–30 pt above
       the toolbar's bottom edge: the top of the outgoing pane seen through the toolbar.
    2. Two sizing systems fought: for the selected pane, `NSTabViewController` turns the child's
       `preferredContentSize` into a height constraint at priority **501**, above the window's
       own size (500), so Auto Layout snaps the window back to that height at each layout pass,
       while the controller also ran a blocking `setFrame(_:display:animate:)`. The pane
       controllers therefore no longer expose `preferredContentSize`.
    3. After some switches the window kept the previous pane's height (Advanced and Permissions
       stayed at Recorder's 370 pt instead of 277 and 228); the old sizing test only checked two
       panes.
  - **Rejected:** keeping `NSTabViewController`'s own resizing (it is that 501 constraint, with
    no top-edge control); a crossfade over a top-pinned clipped pane (two panes on screen during
    the resize still overlap); `preferredContentSizeDidChange(for:)` on a plain
    `NSViewController` parent (not called for it) and KVO on the hosting controller's
    `preferredContentSize` (no notification).
- **Last pane remembered**: UserDefaults `settingsPane`; `SettingsPane.restored(_:from:)` falls
  back to General when the stored pane is not shown.
- **Recorder pane**: the recorder position (the overlay PR's `RecorderPositionPicker`, its
  footnote under the group) in both builds, then live transcription in debug builds. In the
  renders the picker's radio buttons sit at the trailing edge of their labels (the board draws
  them before the labels); hosting the picker in a separate `NSHostingView` or forcing
  `.formStyle(.columns)` did not change it. Not changed here: the picker belongs to the overlay
  work.
- **Fresh content at each opening**, so the Engine draft starts from the applied settings
  (unapplied changes are dropped when the window closes). On close the controller stops the
  `PermissionMonitor` and drops the content; the Permissions pane also starts/stops polling on
  appear/disappear, so it polls only while visible.
- **Colors: the system accent color everywhere** (switches, buttons, links, radio marks,
  "Recommended", "Beta", Change…, the shortcut field's focus ring, the recorder position spots,
  the menu's progress bars, onboarding). The brand violet tokens (`nwAccent`, `nwAccentText`)
  were removed on 2026-11-20 at the maintainer's request ("no violet in Settings"); the
  position picker's mini screen is a neutral dark gray (`#2C2C30`, was violet-tinted). The brand
  colors remain only in the recording overlay and the app icon.
- **Engine pane wording** (pure, tested): `EngineStatusDisplay.resolve` (status row: Ready,
  Downloading <model> with "42% of ~630 MB.", migration download with "<previous> stays in use
  until it is ready.", Optimizing, Loading, "Could not set up <model>" / "<model> could not
  start" with **Try Again**, not downloaded with Download/Load) and `EngineApplyDisplay.resolve`
  (pending change: "<model> needs a ~480 MB download" + "Dictation pauses until it is ready."
  when it downloads, else "Changes not applied" with `ModelActionText.applyDetail`). As drawn,
  a pending change replaces the status row while the model in use is ready; otherwise both
  rows show.
  - **Model and comparison (since 2026-11-21, maintainer's request):** under the two engines,
    one "Model" row (Parakeet's versions or Whisper's sizes) and right under it the speed and
    accuracy bars and the key points (`ModelComparisonView`, values in `ModelComparison`),
    always shown, in Settings › Engine and in onboarding's model sheet (the former quiet model
    line and its Change… are gone). The comparison keeps the height of the tallest model's
    text (every offered model's points are laid out in a `ZStack`, only the current one
    visible), so changing engine or model moves nothing; Whisper's language and vocabulary come
    below it. On a change the bars slide (0.35 s) and the text cross-fades (0.25 s); Reduce
    Motion: the bars change at once. The animations are scoped (`animation(_:body:)`, the fill
    an animatable modifier): with `.animation(_:value:)` the same change's layout (Whisper's
    options appearing, the window growing) was animated too, and the text and fills slid
    down and back (seen in a real-window capture). Verified in the real window
    (`SettingsWindowTests`, "comparison stays in place"): the speed bar stays on the same pixel
    row and shrinks 1152 → 1140 → 1012 → 922 px from Parakeet Ultra to Whisper Base.
  - **Whisper language and vocabulary apply right away** (`SettingsContext
    .setWhisperOptions`), as the design asks: they never load a model. The same in onboarding's
    model sheet, which shows the same `EngineChoiceSection`.
  - "Recommended" also marks the Parakeet engine (`TranscriptionModelType.isRecommended`; its
    default model, Ultra, is the recommended one).
  - Not drawn as designed: "4 models, 1.7 GB on this Mac" (counting needs a scan of the Whisper
    cache under `~/Documents`, which would trigger the privacy prompt), byte counts and time
    left in the download line (FluidAudio reports a fraction only), "Download stopped at
    312 MB" (no byte count), and "Parakeet stays in use until Whisper is ready" for a pending
    engine switch (false: `switchModel` releases the current model).
- **Permissions pane**: "Typing in other apps" (Recommended, "macOS calls this Accessibility").
  The design's "Without it, text is copied for you to paste with ⌘V" is not true
  (`PasteManager` restores the previous clipboard after 3 s); the caption says nothing is pasted
  and the text is kept in History if it is on. Buttons: "Allow…" (not asked yet: system
  request) or "Open System Settings" (denied).
- **Advanced pane**: `UpdateStatus` (disabled in debug builds, checking, downloading with a
  bar, available with "Install and Relaunch", up to date with the last check time,
  `AutoUpdater.lastCheckDate`, not persisted).

### Shortcut display

`ShortcutKeysView` (`ShortcutKeysView.swift`): one flat rounded box per key (`KeyCapView`), thin
border, glyph inside, no fill or shadow (maintainer's request, reference: ⌥ ⌘ Y boxes). Spec
from the design notes: 20 pt caps, 11.5 pt medium glyph, radius 5, 3 pt apart; border black
22 % / white 28 %, glyph #3C3C43 / white 85 % (light / dark); 16 pt caps with a 10 pt glyph in
captions and menus. Keys come from `Shortcut.keys` (⌃ ⌥ ⇧ ⌘, then the key). Used in Settings ›
General and onboarding's setup page and Try it page (also inline in a sentence,
`InlineShortcutText`). Change… swaps the caps
for a 150 × 22 pt "Press a shortcut…" field and Cancel; the caption becomes "Press the keys you
want, or [esc] to cancel."

## The apply rule

- Model controls edit a **draft** `EngineConfiguration`. Nothing downloads or switches until the
  user clicks **Apply** or **Download & Apply**; **Revert** drops the draft.
- `EngineConfiguration.changesModel(from:)`: only a different engine, Parakeet variant or
  Whisper size loads a model. Changing only the Whisper language or vocabulary hint applies
  instantly and never restarts a download (`AppState.applyEngine(_:)`).
- `EngineState.applyLoadsModel(changesModel:)` also loads when nothing is ready and nothing is
  running (first launch before the download, after a failure).
- Button and caption wording come from `ModelActionText`, so the cost is stated before the
  click: a button that downloads says so, and the caption gives the size.
- `ModelAvailability`: Parakeet is checked on disk (`parakeetIsOnDisk(_:)`, which also accepts
  the legacy v3 folder); Whisper is `.unknown` unless loaded, because WhisperKit's cache is under
  `~/Documents` and reading it would trigger a privacy prompt.
- The status row always describes the model in use (`ModelStatus.resolve(_:)`), not the draft.
  During a migration's switchover (`EngineState.upgrade`) it shows the selected model as Ready
  (dictation works on the previous one) with "Downloading the improved model (~630 MB)… 42%",
  a progress bar and "<previous> stays in use until it is ready."; after a failed or offline
  download, "<previous> is in use. <new> will download at next launch." The menu shows the same
  progress line while downloading and nothing after a failure.
- Pickers (one "Model" row for both engines): Parakeet's offers Ultra and v3; Whisper's offers
  `WhisperModelSize.selectable` (Base, Small, Large v3 Turbo). The recommended item of each reads
  "<name> (<size>) · Recommended" (`ModelLabel.pickerTitle`, from the model metadata).
- Applying a different Parakeet variant or Whisper size clears that engine's pending migration
  move: the user keeps what they picked ([transcription-engines.md](transcription-engines.md#model-migrations-modelmigrationsswift)).

## Downloaded models (Settings › Engine only)

"Remove Unused Models…" (`ModelStorageRow`), not in onboarding:

1. Disabled, with the reason in the caption, while a download or model switch runs or nothing is
   loaded (`ModelStorageContext.unavailableReason`): "unused" is defined relative to the loaded
   model.
2. Click: scans both caches off the main thread (user-initiated, so the Whisper cache under
   `~/Documents` may show the macOS prompt) and opens `UnusedModelsSheet`: each removable model
   with its size, the total, what is kept (in use; kept for the other flavor), and a note if the
   Documents folder could not be read.
3. Confirm ("Remove <total>"): removal under the shared lock; what is kept is recomputed at that
   moment, so the model in use is never removed even if it changed after the preview. The caption
   then reports "Removed N models and freed X." and any failure. Sheet wording since the
   redesign: "Remove unused models?", the list with the total, "Kept: <model> (<size>), in use.",
   Cancel / "Remove <total>".
- Removable = every folder of the allow-list (`ModelFolder.all`) on disk, except the selected and
  loaded models, pending-migration fallbacks, and what the other flavor may use. Rules and lock:
  [transcription-engines.md](transcription-engines.md#removing-models-modelstoreswift).

## Onboarding

Design: Claude Design canvas "NanoWhisper Redesign", page "Onboarding", direction **"Icon"**
(boards `onb3-icon` "Welcome and setup page", `onb3-try` "Try it", the component `onb3-icon-win`
and the prototype `onb3-proto`; approved 2026-11-20). Implemented in `feat/onboarding-icon`,
English only. Every string is in `OnboardingText` (`OnboardingText.swift`), so a French version
can be added there.

**One window, three pages** (`OnboardingPage`: welcome → setup → Try it; `OnboardingModel` holds
the page and the model sheet). Files: `OnboardingFlow.swift` (pure logic: pages, the setup rows'
states, `TryItStage`, `NewInstallDefaults`, `OnboardingWindowPlacement`, `WelcomeDictation`,
`LaunchOptions`), `OnboardingView.swift` (`OnboardingContent`, the live `OnboardingView`,
`OnboardingWindowController`), `OnboardingWelcomePage.swift`, `OnboardingSetupPage.swift`,
`OnboardingTryItPage.swift`, `OnboardingStyle.swift` (colors, grouped rows, the circle that
becomes a check, the fade-up, `InlineShortcutText`).

- **Window:** 580 × 640 pt for every page, title bar included (`.fullSizeContentView`,
  transparent title bar, no visible title: traffic lights over the content); the window's own
  background, as the Settings window's content ([Window colors](#window-colors)). The
  `NSHostingView` has `sizingOptions = []` and is **not** the window's content view but sits in a
  plain container: left to size the window it added the title bar's safe area (672 pt), and in
  the macOS 26+ design it still did so with `sizingOptions = []` while it was the content view
  (`NSHostingView.windowDidLayout` → `updateAnimatedWindowSize`, during the welcome's entrance;
  seen 2026-11-21 in the debug app, not in tests). Opens with a 0.25 s fade (none with Reduce
  Motion); a page change fades the new page in over 0.3 s.
- **Position** (`OnboardingWindowPlacement.frame(in:recorder:)`): on the screen with the pointer
  (where the recorder appears; `centerOnCurrentScreen` used the same screen), centred, then moved
  away from the recorder's largest frame (the 380 × 106 card, 12 pt inside the visible frame at
  the user's `RecorderPosition`) with a 16 pt gap, only when they would overlap horizontally:
  down for the top positions, up for Bottom Center. On 1440 × 900 (menu bar 24 pt) the window
  goes 16 pt below centre; on a 13-inch Air (1470 × 956) it stays centred (21 pt clear). Clamped
  to the visible frame on smaller screens (the overlap is then unavoidable).
- **Welcome (since 2026-11-21: the opening scene, next section):** the scene, then icon,
  "Speak where you’d type.", the catch phrase, the recorder, the four facts (SF Symbols
  `laptopcomputer`, `lock`, `bolt`; the text cursor is drawn from the design's glyph, no plain
  I-beam symbol exists), Continue. **The recorder is the real `RecordingOverlayView`** with its
  own `RecordingOverlayViewModel`, driven by `WelcomeRecorderDemo` (no microphone), in the
  window's appearance (the light recorder in light): the card from the start
  (`RecordingOverlayViewModel.showsCardWhileEmpty`), levels sent every 20 ms through
  `OverlayWaveform.start(levels:)` (the real envelope, normalizer and 50 ms slots), words set as
  `LiveTranscript(stable:volatile:)` (the newest two dimmer), the timer from
  `WelcomeDictation.elapsedSeconds`. Nothing opens the microphone or pastes: it is a
  simulation. **The demo's flow (since 2026-11-21, `feat/welcome-demo-flow`; maintainer: the
  former freeze at 0:03 looked odd and 29 words in 2.7 s unrealistic).** `WelcomeDictation`
  holds the timings and the pure steps (`phase(at:stoppedAt:)`), `WelcomeRecorderDemo` plays
  them in the view model; times from the press of Get Started:

  | Step (`WelcomeDictation.Phase`) | From | What shows |
  |---|---|---|
  | `idle` | 0.25 s (fades up), arrived 0.7 s | 0:00, no text, flat still waveform, `isPaused` (capsule still at the dim end of its breath) |
  | `recording` | 0.825 s (`idleWait` **125 ms** after it arrived) | pulse, timer 0:00 → 0:04, words at **2.6 words/s** (`wordsPerSecond`), the first 0.2 s in |
  | `transcribing` | the end: 4.3 s later (`recordingDuration`), or at Stop | the real state (`.loading`): light capsule, "Transcribing…", bars sinking then the sweep, **0.8 s** |
  | `pasted` | + 0.8 s | `.finished(.pasted)`: green check, "Pasted", the final text all settled, 0:04, **0.35 s** |
  | `ended` | + 0.35 s (6.275 s without Stop) | a grey veil over the card fades in (0.3 s) with **Replay** (`arrow.counterclockwise`, a standard push button) centred under the pasted line; the clock stops |

  - **Pace:** the maintainer's real dictations run about 1.7–2.2 words/s; at most 1.25 times
    that was asked, so 2.6 (one named constant). The sentence is now the whole phrase said in
    those 4 s, "So the plan for this week is the payment flow." (10 words, one line; its last
    word shows at 3.97 s, then a short silence before the end, as before someone presses Stop).
    Each word shows once said (`wordShowsAt`, 80 % into its slot).
  - **Waveform rhythm:** the levels follow the words (`WelcomeDictation.level(at:)`): room noise
    between words (a gap of 22 % of the slot, 45 % after punctuation), one bump per syllable
    (vowel groups, 1–3), each word a little louder or softer; about 2.6 bursts a second
    instead of the former fixed 12.3 rad/s sine (frantic at this pace).
  - **Recording length:** 4.3 s, not 4.0: at exactly 4 s the transcribing state replaces the
    timer with "Transcribing…", so 0:04 would never be seen while recording.
  - **Stop:** as in the real overlay, the pointer anywhere over the card shows Stop: the view's
    own `onHover` on the whole card (the welcome's recorder had `allowsHitTesting(false)`
    before, so no hover where the content is). Clicking it (`stopRecording()`, also an
    accessibility action while it can stop) ends the recording at once, also in the 125 ms
    idle: the words and the timer stop where they were, then Transcribing, Pasted and the veil
    as when it ends by itself. A phrase cut by Stop is "pasted" with a full stop
    (`finalText(stoppedAt:)`: "So the plan.").
  - **Replay** (`replay()`, only from the veil) starts again at the recording: 0:00, empty text,
    recording; any number of times. The page going away mid-flow (`stop()`) rests it on the
    veil.
  - **Reduce Motion (decided):** nothing plays by itself; the press shows the end at once (the
    pasted card under the veil, `start(reduceMotion: true)`). Replay then plays the flow as the
    real recorder does with Reduce Motion (timer and words; no pulse, no glide, no sweep, the
    veil without a fade): an explicit request, and otherwise Replay would do nothing.
  - **CPU:** the clock (a 20 ms `Timer`) stops at the veil; under it the card shows the pasted
    state (no waveform, no caret), so nothing redraws: 0 % at rest, and a real-window test
    checks that the recorder under the veil draws identical pixels over 1 s. The veil and its
    button exist only while the veil shows (`ReplayVeil`).
  - **CPU while it records (measured 2026-11-21, debug build, test process, 120 Hz built-in
    display, light):** 82–85 % of a core, against 33–41 % for the former demo in the same
    harness (`main`, same machine, run back to back). Not the demo's logic or its views: the
    waveform draws the same ~120 frames a second in both, and swapping in the former recorder
    view, the former sentence, the former levels, no capsule pulse or no veil left it at
    82–90 %. What changed is the text: with **no** text change at all the same card costs
    100–104 %; the former demo changed its text every 93 ms (10.7 words/s), which made the
    window's frames cheaper, the new one every 385 ms. So this is the cost of the real
    overlay's waveform with mostly still text, as the live recorder runs without live text;
    not changed here (the overlay is shared). Not measured in a release build.
  - Two traps (kept): a `repeatForever` pulse is not stopped by later non-animated changes, so
    the indicator gets a new identity when it pauses or resumes (`.id(isPaused)`); and
    `OverlayWaveform` is not observable, so the view takes its `revision` (bumped on start and
    freeze) as an input. Renders use `showStill(at:stoppedAt:)` (the bars computed by
    `WelcomeDictation.history(until:)`).
- **Setup page:** header (icon 36 pt, "Set up NanoWhisper", subtitle), then four grouped sections:
  - *Getting ready* (`PermissionChecklistDisplay`): Microphone (Required) and "Pasting into other
    apps" (Recommended), each with a circle that becomes a check. Microphone not asked: "Allow…"
    (`AVCaptureDevice.requestAccess` through `PermissionMonitor.request`); denied: orange circle,
    "Turned off in System Settings. macOS won’t ask again." in red, "Open System Settings".
    Pasting: "Allow…" shows the system prompt, then "Open System Settings" (Accessibility has no
    denied answer; the circle stays empty). Its caption says "Without it, text stays in History."
    only while history is on (otherwise "Without it, nothing is pasted."): without Accessibility
    `PasteManager` pastes nothing and only History keeps the text. Polled every second while the
    window is open (`PermissionMonitor`, stopped when the window closes).
  - *Model* (`ModelChecklistDisplay`): "<model> by <vendor>" (the user's model on a replay:
    "Whisper Small by OpenAI"), "The speech model that runs on this Mac.", the status on the left:
    a ring that fills with the download and "23% of ~630 MB" on the right; a turning arc without
    a percentage ("Downloading…"), while optimizing or loading a model not on disk yet; a check
    as soon as the model is on this Mac (`ModelAvailability.downloaded`, so a model already
    downloaded is checked at once, even while it loads); a warning, the error and Try Again when
    setup failed; during a migration's switchover, the new model's ring and "<previous> stays in
    use until it is ready.". **Change…** is hidden (opacity 0) until the pointer is over the row
    or the button has keyboard focus (VoiceOver also gets it as an action of the row, not
    verified); it opens `ModelChoiceSheet`: the same `EngineChoiceSection`
    as Settings › Engine (engines, versions, comparison, status, apply row with the draft rule),
    with Done. A draft not applied is dropped on Done, as when Settings closes.
  - *Dictation*: `ShortcutRecorderRow(isCompact: true)`: the title, the key caps and Change… (the
    "Press a shortcut…" field and Cancel while recording).
  - *Settings*: Open at login; Pause music and videos while recording; Keep a history of what you
    dictate ("Encrypted, stays on this Mac. Open it from the menu bar icon."; disabled with the
    red note when history is unavailable); Play a sound when recording starts and stops. Small
    switches, system accent. The caption says where History opens since 2026-11-21 (maintainer:
    users never learned where to find it); it is `SettingsText.keepHistoryCaption`, so Settings ›
    General's history row says the same, on one line in both. Not in the end-of-onboarding
    popover (maintainer's choice; that popover already says "History and Settings are in this
    menu").
  - Footer: the first thing missing ("Allow the microphone to dictate.", "Dictation needs the
    microphone.", "Parakeet keeps downloading while you go on.", else "You can change all of this
    later in Settings.") and Continue, always enabled.
- **Try it:** "Try it", "Press [⌥][Space], say a sentence, then press it again to see what you
  said." (`InlineShortcutText`: the real shortcut's caps inside wrapped, balanced text), a
  484 × 356 stage, Back and Finish Setup. **The recorder is the real overlay at its real place**:
  Start Recording and the shortcut both call `AppState.toggleRecording()`; nothing is drawn in
  the window. Stages (`TryItStage.resolve`): ready ("Press ⌥ Space to start", "or", Start
  Recording, "The recorder appears at the top of the screen, as it will in any app." with the
  user's position); listening (from the start until the stop; Stop); transcribing (from the stop,
  including the 300 ms tail, `AppState.isFinishingRecording`); the result ("You said", the text,
  "Transcribed on this Mac.", "Press ⌥ Space or [Try Again]"; Try Again clears the result, back
  to ready, as the prototype does); nothing recognized; the model not ready (downloading with a
  bar and "64% of ~630 MB", optimizing, loading, failed with Try Again); the microphone missing.
  Finish Setup is off while it listens or transcribes. Back returns to the setup page (it drops
  a result, and a test still running is discarded when it ends).
  - **Nothing is pasted or saved:** the page sets `capturesTestTranscription` (only on Try it);
    `DictationDestination.atStart(testBoxShowing:appIsActive:)` makes a recording started then,
    with the app in front, a test (`DictationOutcome`: shown, or discarded once the page is gone).
    The overlay ends with "Done". Hotkey path unchanged: Carbon hotkey → `toggleRecording()` →
    `startRecording()`; Carbon hotkeys fire while NanoWhisper itself is active.
- **Finish Setup** → `OnboardingModel.finish(stage:)` → `AppState.completeOnboarding()` →
  `OnboardingCompletion.finish`: the `onboardingComplete` flag, the window closes (activation
  policy back to `.accessory`), `loadSelectedModelIfIdle()`, then `onOnboardingFinished`, which
  `AppDelegate` wires to `MenuBarController.showOnboardingHandoff()` (next section). The red close
  button closes the window without finishing: on a first launch onboarding shows again at the
  next launch, and the menu offers "Finish Setup…".
- **First download.** `ModelAvailability.shouldDeferSetupAtLaunch(...)` still holds a new
  install's Parakeet download at launch; it now starts when the setup page opens
  (`AppState.onboardingPageDidAppear(.setup)` → `loadSelectedModelIfIdle()`; also on Try it and
  at Finish Setup). A model already on disk loads at launch. Closing on the welcome page downloads
  nothing.
- **Defaults for a new install** (`NewInstallDefaults`): the four switches start on. Sound and
  history already defaulted to on. "Pause music and videos while recording" is now on for a new
  install; an install that ran before (`ModelMigrations.isExistingInstall`, read at the top of
  `AppState.init` before anything writes) keeps its stored value, or off if it never chose (the
  old default). The resolved value is stored at launch, so it does not flip once the install
  counts as existing. "Open at login" is a login item (`SMAppService`), not a stored value: a new
  install records `launchAtLoginDefaultPending` at its first launch, and the login item is
  registered when the setup page first shows the switch on (once; turning it off sticks).
- **Activation policy:** `.regular` (Dock icon) while the window is open, `.accessory` after,
  however it closes (`AppState.onboardingWindowDidClose()`).
- **Where the code and the design disagree (code followed):**
  - Listening: "Your words write themselves in the recorder" is true only with live
    transcription (debug builds, opt-in). Otherwise the page says "The recorder at the top of the
    screen shows your voice as you speak." (`OnboardingText.listeningNote`).
  - The model still downloading: the board says "The try starts by itself when the download
    finishes"; the prototype only switches the page to ready (starting the microphone by itself
    would not be acceptable), so the note says "You can try it as soon as it’s ready."
  - Microphone never asked on Try it: the board offers "Open System Settings" for denied *or*
    never asked, but an app that never asked is not listed in System Settings; never asked offers
    "Allow…" (the system request) with "Allow the microphone".
  - The recorder's place is the user's `RecorderPosition` in the copy ("at the top left of the
    screen", "at the bottom of the screen"), not always "the top".
  - The download amount keeps the size's "~" ("23% of ~630 MB"): sizes are approximate.
  - Not drawn and added from the code: a failed model setup (warning, Try Again), a model
    optimizing or loading, nothing recognized, history off (Pasting caption) or unavailable.
  - Live transcription is no longer offered in onboarding (the design has four switches); it
    stays in Settings › Recorder. The history size stays in Settings.

### Opening scene (welcome)

Design: Claude Design canvas "NanoWhisper Redesign", page "Onboarding — opening scene"
(prototype `onb4-proto`, component `onb4-win`, key frames `onb4-frames`, notes `onb4-notes`;
approved 2026-11-21). Implemented in `feat/opening-scene-light-overlay`. Files:
`OpeningScene.swift` (every value, the maths, the clock), `OnboardingWelcomePage.swift` (views).

- **Source of the values: the prototype's saved Tweaks** (its `data-props`), read 2026-11-21.
  The maintainer retouched the button's pop after the designer's notes board was published;
  the board (and the prototype's `DEF` fallback and the key-frames board, which ignore the
  saved values) still say button at 2 s, 0.45 s, 88 %, bounce 0.15. **Saved, used:** button at
  1.2 s after the sunrise starts, spring 1.1 s, from 90 %, bounce 0.17. Everything else equals
  the notes. All values are in `OpeningScene.Tweak`, named after the Tweaks:

  | Group | Values |
  |---|---|
  | Sunrise | empty window 0.3 s; rise 1.7 s, cubic-bezier(0.6, 0, 0.3, 1) to 104 % over 80 %, then ease-in-out back to 100 %; breathing 1.2 %, 5 s period (2.5 s each way) |
  | Aura | ellipse 1.3 wide, centre at 50 % across and 60 pt below the bottom edge, reach 1 (radii 1364 × 1050 pt), start 0, softness 0.3, opacity 1, ripple rim 0.3; stops 0, 0.16, 0.42, 0.70, 1; dark `#F4DAFF` `#A24BFF` `#3B1B70` `#1A1424`, light `#B35CFF` `#C892FF` `#E4D0FF` `#F8F3FF` |
  | Title moment (after the sunrise starts) | icon 118 pt from 0.8 s over 0.9 s (88 → 100 %, blur 6 → 0); "NanoWhisper" 40 pt and the headline 16 pt (82 %) from 1.2 s over 1.2 s, rising 8 pt; Get Started from 1.2 s, spring 1.1 s bounce 0.17, from 90 %; group moved −10 pt; button white, 44 pt, ≥ 100 pt wide, 34 pt below the headline |
  | Press and travel | travel after 0.05 s, `.smooth` 0.75 s; title fades 0.25 s, button 0.2 s (dips to 97 → 94 %) |
  | After the press | aura "shrinks into the icon", settle 0.7 s (`.smooth`), ends a 330 pt halo at 35 % |
  | Welcome arrives (after the press) | recorder 0.25 s, catch phrase 0.45 s, facts together 0.55 s, Continue 0.6 s; fade-ups 0.45 s, 10 pt, cubic-bezier(0.2, 0.7, 0.2, 1); recording 0.125 s after the recorder has arrived, 4.3 s (`recordingLength`; was 3 s, see the welcome's recorder above) |

  Moments: the title moment is complete at **2.7 s** (then it breathes and waits); Return
  presses Get Started from 1.83 s (`buttonPressable`, the prototype's rule); after the press the
  recorder records at 0.825 s until 5.125 s (`Times.recordingEnds`), then transcribes, pastes
  and rests under the veil from 6.275 s; the scene's own motion ends at 1.4 s.
- **How:** every frame is a pure function, `OpeningScene.frame(t:pt:dark:reduceMotion:)`, a
  port of the prototype's `renderVals` (same springs: ω = 2π / duration, damping 1 − bounce; same
  cubic-béziers), so the renders at any moment match the prototype (compared with the prototype
  rendered in headless Chrome at the same moments, light and dark: positions, sizes, colours
  and halo match; Core Graphics and Chrome differ slightly in gradient tones).
  `OpeningSceneClock` holds the welcome's start, the press and the resting states; renders build
  a fixed one (`init(fixedAt:pressedFor:)`). Get Started pops from the back (scale and opacity,
  no vertical travel), Return presses it (`.keyboardShortcut(.defaultAction)` while it takes a
  press), then Continue from `continueAt`. The aura is one `EllipticalGradient` ellipse (plus
  the rim ring, screen-blended in dark) in a `drawingGroup`; "shrinks into the icon" moves its
  centre to the icon, thins its outer stops and turns its core to the second colour.
  The icon and the headline sit in the welcome's layout and are offset and scaled from the
  title moment's places to theirs (the headline is the 28 pt text scaled, so it stays sharp);
  the catch phrase rides with the headline.
- **Reduce Motion:** no sunrise and no breathing: the title moment at once; the press
  cross-fades (0.3 s) to the welcome at rest, the icon and the headline faded out and in at
  their places, a halo of the second colour behind the icon (the prototype's "glow" fallback),
  the recorder on its end (pasted, under the veil with Replay).
- **Light:** a lavender dawn with dark text (`#1C1C1E`), the light recorder.
- **When it plays:** each time the welcome appears: first launch, `--onboarding`, "Finish
  Setup…", and the debug build's "Open Onboarding" (which restarts it, [Replay](#replay)).
- **CPU (measured 2026-11-21, release build, test process, 120 Hz built-in display, light):**
  about one core during the entrance (2.7 s, 108 %) and during the travel and arrival (1.4 s,
  92–101 %), 10–23 % while the title moment breathes, 0 % at rest; for comparison the recorder's
  dictation as built costs 36–42 % in the same harness (82–85 % since the welcome-demo flow,
  see the welcome's recorder above: why). Frames delivered: ~117 per second of
  120. Investigated with `sample`: most of each display refresh is SwiftUI's fixed cost for an
  animating hosting view in this window (graph update and dirty propagation, AppKit layout and
  constraint passes, dynamic colour resolution, commit), about 8 ms per refresh **whatever
  animates**: one layer alone (even only the aura) costs as much as all four, the plain
  fade-ups of the welcome alone cost 93 %, and capping the timeline at 60 Hz halved the frames
  but not the CPU. Kept because measured: the aura in Metal (`drawingGroup`; without it, Core
  Graphics redrew the gradient on the main thread at each frame and the breathing cost 113 %
  instead of 10–23 %), small timeline layers (`SceneLayer`) instead of one timeline around the
  page, the recorder and Get Started equatable. Measured neutral, not kept: Metal for the
  icon's blur and the button's shadow. **Not done** (a larger change, if the CPU matters): the
  scene in Core Animation layers (render-server animations, no main-thread work per frame).

**Earlier entrance (2026-11-21, replaced by the scene):** each element faded up 10 pt over
0.3 s at 0, 0.08, 0.16, 0.24 s (icon, headline, catch phrase, recorder), the facts with
Continue at 0.32 s, and the recorder recorded at 0.745 s.

## End of onboarding: the menu bar takes over

Design: "After setup: the menu bar takes over" board and the prototype's last step (approved
2026-11-20). Implementation: [architecture.md](architecture.md#end-of-onboarding-the-handoff-popover).

When the user clicks Finish Setup, onboarding calls `MenuBarController.showOnboardingHandoff()`:
a popover under the status item, once per completed onboarding (a replay shows it again; nothing
is persisted). It closes on OK, Escape, a click anywhere else, or when the menu opens; clicking
the icon then opens the menu as usual. It never activates NanoWhisper.

Wording (`HandoffMessage.make`; the shortcut as the menu writes it, `Shortcut.menuEquivalentString`,
e.g. "⌥ Space"; the position from Settings › Recorder):

| State at Finish Setup | Title | Text |
|---|---|---|
| Model ready | "NanoWhisper is in the menu bar" | "Press ⌥ Space in any app to dictate, and again to stop. The recorder appears at the top center of the screen. History and Settings are in this menu." |
| Downloading | same | "Parakeet Ultra is still downloading (48%). When it is ready, press ⌥ Space in any app to dictate." (no percentage when unknown) |
| Optimizing, loading | same | "… is being optimized for this Mac." / "… is still loading.", then the same "When it is ready…" |
| Setup failed, not downloaded | same | "… could not be set up. Open this menu to try again." / "… is not downloaded yet. Open this menu to download it." |
| Ready later (only if it was not ready at Finish Setup) | "Parakeet Ultra is ready" | "Press ⌥ Space in any app to dictate, and again to stop. The recorder appears at the top center of the screen." |

- The "ready later" popover replaces the first one if it is still open, and is skipped if the
  menu is open at that moment (its model line says it). Shown once.
- **Differences from the board:** the title uses the build's name ("NanoWhisper Debug is in the
  menu bar" in the debug app); the model is named in full ("Parakeet Ultra", as in the menu);
  the recorder position is the user's, not always "top center"; "The icon fills as it
  downloads" is dropped (the capsule icon is a proposal, not built; the icon shows
  `arrow.down.circle` while downloading); OK is the system accent, not the board's color; the
  states the board does not draw (optimizing, loading, failed, not downloaded) got the plain
  texts above.
- Not on the board, so not built: closing the popover when a dictation starts.
- Debug builds: `--show-handoff` (`make handoff`) shows it about a second after launch, to try
  it without going through onboarding (`MenuBarHandoff.isRequestedAtLaunch`; ignored in
  production).
- **Verified:** unit tests (state and text); offscreen renders of the content in light and dark
  (`ViewRender`, `handoff-*.png`); the real `NSPopover` anchored to a real status item in a test
  process, captured in light and dark, placed under the item, following a text change in place,
  closed by a synthesized click on OK while the app is inactive and by Escape
  (`HandoffPopoverWindowTests`, opt-in); in the debug app (`--show-handoff`), the app's log shows
  the popover window on screen right under the status item and its dismissal when the menu was
  opened through the Accessibility API. **Not verified:** what it looks like on the real screen
  (no screen capture), a real click on OK or elsewhere, the "ready later" popover after a real
  download, VoiceOver.

## Replay

| How | Effect |
|---|---|
| Settings › Advanced › "Open Onboarding" (**debug build only**, since 2026-11-21) | Opens onboarding **without closing Settings** (closing onboarding leaves Settings open behind). Clicked again, open or not, it **restarts from the opening scene**: an open window keeps its place and gets new content (`OnboardingPresentation.restart`, `OnboardingWindowController.setContent`; a model sheet still open is ended first). Settings kept. |
| The menu's "Finish Setup…" (onboarding never finished, window closed) | Closes Settings, opens onboarding at the opening scene. |
| `--onboarding` launch argument (`make onboarding` for the debug app; both builds) | Shows onboarding at launch even if completed; settings kept. |
| `--reset-onboarding` | Clears only the `onboardingComplete` flag (before `AppState` reads it). |
| `--show-handoff` (debug builds only; `make handoff`) | Shows the end-of-onboarding popover about a second after launch; nothing else changes. Parsed by `MenuBarHandoff.isRequestedAtLaunch`, not `LaunchOptions`. |
| `--history-sample` (debug builds only) | Not a replay: opens only the History window with invented dictations, nothing else starts ([architecture.md](architecture.md#history-window)). Parsed by `HistorySample.isRequestedAtLaunch`. |

`--onboarding` and `--reset-onboarding` are parsed by `LaunchOptions` (`OnboardingFlow.swift`);
unknown arguments are ignored. "Show Onboarding Again…" (Advanced, both builds) was removed on
2026-11-21 (maintainer: a tool for working on onboarding, not for users; `BuildFlavor
.offersOnboardingReplay`, `AdvancedPane.openOnboardingAction(flavor:_:)`).

**What a replay touches** (checked 2026-11-21 against `AppState.onboardingPageDidAppear`,
`NewInstallDefaults`, `OnboardingCompletion`): nothing is reset when onboarding opens. The setup
page's switches, shortcut and Change… act on the real settings at once, as Settings does (that
is what onboarding does on any run). Showing the setup page loads the selected model only if
nothing is loaded, loading or failed (`loadSelectedModelIfIdle`), and turns on "Open at login"
only once per new install (`launchAtLoginDefaultPending`, consumed at the first showing; never
set on an existing install). Try it makes a recording a test only while its page shows. Finish
Setup sets `onboardingComplete` (already set on a replay), loads the model if idle and shows the
handoff popover. A replay downloads nothing unless the user applies another model, or the
selected model is not on this Mac yet (the setup page then starts its download, as on a first
run); the button's caption says so.

## Why it is this way

- Before PR #15, onboarding was one long form that duplicated Settings (~150 lines), with
  labels that differed between the two, a Microphone status in Settings that was always green,
  and an automatic Parakeet Ultra download at first launch before the user saw the choice.
- Fixed after a real run in the debug app (PR #15): permission polling kept running after the
  window closed, because a closed window keeps its SwiftUI view and `onDisappear` never ran; it
  now stops when the window closes. The menu said "Loading model..." during the deferred
  first-launch state; it now offers the download.
- 2026-11-20, onboarding redesign ("Icon"): the five steps (Welcome, Model, Permissions,
  Shortcut, Done with a step indicator and Skip Setup, 560 × 600 pt) became three pages in a
  580 × 640 pt window; the separate Model step and its in-window model form became one Model row
  whose Change… opens the Settings Engine section in a sheet; the Try-it box moved from the Done
  step to its own page, with the recorder at its real place instead of described in a box. The
  old views (`OnboardingView`'s steps, `OnboardingStep`, `OnboardingProgress`, the step
  indicator, `ModelSettingsSection`, `ModelStatusRow`, `GeneralSettingsSection`,
  `ShortcutSettingsSection`, `PermissionsSettingsSection`, `PermissionRow`) and their renders
  were removed; Settings did not use them.

## Appearance (theme)

Settings › General › Appearance › Theme (2026-11-21): System, Light or Dark, a segmented
control (`AppearanceRow`), in the last section of General. Settings only, not in onboarding.

- `AppAppearance` (`AppAppearance.swift`), stored under `appearance` (`AppAppearance.defaultsKey`,
  as `recorderPosition` is), System when nothing or an unknown value is stored.
  `AppState.appearance` applies it at launch (top of `AppState.init`, before any window) and at
  each change: `NSApp.appearance` = nil (follows macOS) / `.aqua` / `.darkAqua`.
- **Every window follows live** because none sets an appearance of its own: Settings,
  onboarding, History, the recording overlay and its shadow window (tested:
  `AppAppearanceTests`, a window's and the shadow panel's effective appearance after each
  change). Exception: the end-of-onboarding popover takes `NSApp.appearance` when it is made
  (left nil, an `NSPopover` takes the appearance of the status item it points to, i.e. the menu
  bar's); it is short-lived, so a change while it shows is not followed.
- The welcome's recorder follows the onboarding window; Try it uses the real overlay.
- **Not verified:** the status item's `NSMenu` (it should follow `NSApp.appearance`; not
  checked on screen), a change of theme while a recording shows (the panel follows in tests
  of the effective appearance, not seen on screen).

## Window colors

Maintainer, 2026-11-21: the Settings window's header (title bar and toolbar) and background in
Finder's Settings colors (Finder › Settings…), the same background for onboarding, light mode
following the same logic.

- **How:** neither window sets `backgroundColor` and no SwiftUI view paints behind the pages or
  panes (`SettingsPaneForm`, `OnboardingContent`). With its default background, an `NSWindow`'s
  frame view holds a system `NSVisualEffectView` (content background material) and the toolbar
  header is the title bar's scroll pocket over it (a 5 % white fill, blur), exactly what Finder
  gets. A custom `backgroundColor` removes that view and fills flat, and the header then shows
  `windowBackgroundColor` plus the pocket instead. `GroupedStyle.windowNSColor` is
  `NSColor.windowBackgroundColor`, painted only where a view must be opaque (the model choice
  sheet). Nothing is hard-coded, so light mode, Increase Contrast and future macOS releases follow
  the system as Finder does.
- **Why it looked lighter than Finder before:** two separate things.
  1. *The app ran in the pre-macOS 26 design*: its binary recorded SDK 14.0 (see
     [build-and-release.md](build-and-release.md#the-sdk-version-in-the-binary-macos-26-design)).
     In that design the dark window background is `#323232` and the toolbar header a
     wallpaper-tinted material (`#373837` measured), whatever color the window sets. No color
     setting could give Finder's header; linking with the real SDK does.
  2. *The measuring tool lightened dark greys*: `NSBitmapImageRep.colorAt(x:y:)` on a
     `screencapture` PNG returns the values in generic gamma-1.8 RGB, ignoring the PNG's Display P3
     profile, and `.usingColorSpace(.sRGB)` then lifts dark greys: a window painting sRGB #292929
     stores 41,41,41 but read as #363636; Finder's 31,31,31 read as #292929. Read raw pixel
     values (`getPixel`) instead; for greys they are the sRGB values painted (checked with a ladder
     of painted greys 0…255). Nothing in our window lightened what it painted.
- **Measured** on macOS 27.2, dark, built-in Retina display, window-only captures
  (`screencapture -o -l <id>`), raw values, 2026-11-21 (Finder's window active or not: same):

  | | Header | Content |
  |---|---|---|
  | Finder Settings | #262727 | #1F1F1F |
  | Ours before (SDK 14 design, window #292929) | #373837 | #292929 |
  | Ours after, Settings (all five panes, active and inactive) | #262726 – #272727 | #1F1F1F |
  | Ours after, onboarding (no header) | | #202020 |

  The 1-unit differences come from the system's material (the onboarding window measured
  #1F1F1F in a test process). In a test process (same design), light: header and content
  #FFFFFF for both windows. **Finder in light was not measured** (the system appearance was not
  changed); it is the same system view, so it should match.
- **Cards:** dark #2A2A2D kept (on #1F1F1F it reads better than on #292929, where it nearly
  vanished). Light: white vanished on the white macOS 26+ light background, so the card is black
  at 3 % (#F7F7F7 on white), the native grouped `Form`'s card color measured in the same
  conditions.

## Known limits / not verified

- The welcome's recorder flow and the history caption (2026-11-21, `feat/welcome-demo-flow`),
  verified: unit tests (`WelcomeRecorderTests`: pace, timeline and timer, words and final
  text, Stop at any moment, the levels following the words, the demo's steps, Stop, Replay
  three times, Reduce Motion, still moments, wording); offscreen renders of the welcome
  recording, with Stop under the pointer, at 0:04, transcribing, pasted and under the veil,
  light and dark (`ViewRender/welcomeDemo`), of the setup page and Settings › General with the
  new caption; the real window in a test process (`OnboardingWindowTests`: the whole flow to the
  veil, the recorder under the veil still for 1 s and 0 % CPU at rest; a synthesized click on
  Stop ends the recording, then on Replay plays it again to the veil). **Hover** checked once
  with the real pointer moved over the card in a test process (posted `CGEvent` moves, events
  pumped by hand, see [testing](testing-and-verification.md)): Stop showed at all 8 points
  (waveform, the four edges 1.5 pt inside, text, timer, an empty line) and hid outside; not a
  committed test. The real overlay's panel did the same at 5 points with NanoWhisper inactive.
  **Not verified:** the flow in the debug app, VoiceOver (the recorder's "Stop recording"
  action, Replay), Replay with Full Keyboard Access, Reduce Motion on screen (only renders and
  unit tests).

- Opening scene, Appearance, Open Onboarding (2026-11-21, `feat/opening-scene-light-overlay`),
  verified: unit tests (`OpeningSceneTests`: the saved values, the moments, frames at the start,
  the title moment, the pop, the rest, the order of arrival, Reduce Motion, the clock;
  `AppAppearanceTests`, `OpenOnboardingTests`); offscreen renders of the scene at eight moments
  light and dark and with Reduce Motion (`ViewRender/openingScene`, `scene-*.png`), compared with
  the prototype rendered in headless Chrome at the same moments; the real window in a test
  process (`OnboardingWindowTests`: the title moment waits, Return presses Get Started, the
  recorder idle then recording then frozen, CPU; the restart of an open window from the scene).
  **Not verified:** the scene in the app (its first launch or `make onboarding`), on a 60 Hz
  external display, VoiceOver order before and after the press, a theme change while a window is
  open (only the effective appearance was tested), the Settings window staying open behind
  onboarding in the app (activation policy changes on open and close).

- Onboarding ("Icon", 2026-11-21), verified: unit tests (`OnboardingFlowTests`); offscreen renders
  of every page and state in the real window, light and dark (`ViewRender`, `onboarding-*.png`);
  the real window on screen in a test process (`OnboardingWindowTests`: the welcome's entrance
  and dictation over 4 s, Try it with the real recorder panel at Top Center not overlapping the
  window, on the real screen and composited on 1440 × 900); in the debug app (`make onboarding`,
  dark appearance), window captures of the welcome from launch to rest (the entrance, the words,
  the frozen card at 0:03) and of the setup page with both permissions allowed and the model
  checked. Compared with the design boards rendered in headless Chrome.
- **Not verified:** a new install's first run (download starting on the setup page, the login
  item registered, Allow… prompts turning into checks), Change… revealed with the keyboard
  (Full Keyboard Access), the model sheet in the app, the Try it recording in the app (no
  microphone by agents), the window's position on a real 1440 × 900 screen, VoiceOver, macOS 14.
  Captures from a test process show controls in their inactive look (a test process cannot
  activate itself).
- `PermissionMonitor` polls every second while onboarding is open, and in Settings while the
  Permissions pane is showing.
- Settings redesign (2026-11-20): verified with offscreen renders of the real window (toolbar,
  title, size) in light and dark; since 2026-11-20 also the real window shown on screen
  (`SettingsWindowTests`: every pane switch, each frame of the resize forced and the real
  animation sampled every 16 ms, light and dark). **Not run in the app**: real clicks, focus
  and keyboard navigation between panes, VoiceOver on the key caps and the engine radio rows,
  the toolbar's translucency (drawn by the window server, not in captures). Offscreen windows
  are never key, so controls render in their inactive look.
- Polish of 2026-11-21 (`fix/onboarding-settings-polish`), verified: unit tests (the welcome's
  phases and timing, the three-line sentence measured with `NSLayoutManager`, the comparison
  values per engine and model); real-window tests (the welcome idle and frozen recorder pixel
  for pixel still, the comparison in place while its bar slides); offscreen renders; in the
  debug app (dark, captures by window id on the 1x and Retina screens): the welcome sequence,
  every Settings pane (toolbar icons, cards), the setup page. **Not verified:** the Settings
  panes in light mode in the app (the system appearance was not changed; light is from renders
  and window tests), the model sheet opened in the app (its Change… is hover-only and was not
  reached through Accessibility), keyboard focus on the new rows, VoiceOver.
