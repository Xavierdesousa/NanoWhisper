# Onboarding and Settings

Last verified against the code: 2026-11-21 (window colors, the onboarding window's container and the blank-window fix in `fix/welcome-faster`, in the debug app; `feat/settings-and-menu-redesign`; End of onboarding against `feat/menu-bar-handoff`; the Settings window, colors and sizing again in `feat/redesign-feedback`; onboarding rewritten in `feat/onboarding-icon`; welcome sequence, cards, toolbar icons and the Engine comparison in `fix/onboarding-settings-polish`, also run in the debug app), with unit tests, offscreen renders and window captures; the Settings redesign was not run in the app (see Known limits). Source: PR #15, the model migration PR, the Settings and menu redesign PR, the handoff PR #31, the onboarding "Icon" PR and the code.

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
| Updates, "Show debug info in history", "Show Onboarding Again…" | Advanced (`AdvancedPane`, `UpdateStatus`, `SettingsAdvancedPane.swift`) | — |

The Advanced "Debug" group exists in both builds; it is unrelated to the debug **build
flavor** ([build-and-release.md](build-and-release.md)).

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
- **Welcome:** icon, "Speak where you’d type.", the catch phrase, the recorder, the four facts
  (SF Symbols `laptopcomputer`, `lock`, `bolt`; the text cursor is drawn from the design's glyph,
  no plain I-beam symbol exists), Continue. Each element fades up 10 pt over 0.45 s at the
  design's delays (`WelcomePage.Delay`). **The recorder is the real `RecordingOverlayView`** with
  its own `RecordingOverlayViewModel`, driven by `WelcomeRecorderDemo` (no microphone): the card
  from the start (`RecordingOverlayViewModel.showsCardWhileEmpty`), levels sent every 20 ms
  through `OverlayWaveform.start(levels:)` (the real envelope, normalizer and 50 ms slots), words
  set as `LiveTranscript(stable:volatile:)` (the newest two dimmer), the timer from
  `WelcomeDictation.elapsedSeconds`. **Sequence (maintainer's feedback, 2026-11-21;
  `WelcomeRecorderDemo.Phase`):** idle while the page arrives (0:00, no text, flat still
  waveform, `RecordingOverlayViewModel.isPaused`: the capsule still at the dim end of its
  breath, the caret steady); at `recordingStarts` = the last element arrived (0.62 s) +
  `idleWait` (**125 ms**; 1 s then 0.25 s were too long) it records for **3 s** (pulse, timer,
  moving waveform; the 29-word spoken sentence over 2.7 s, faster than real speech on purpose,
  "to show it is fast"); then it freezes, **paused**: three lines, "we'll see" dimmer, the caret
  shown steady (a hidden caret read as a finished note; steady reads as stopped where the next
  word would go), the capsule still, the waveform still (`OverlayWaveform.freeze(with:)`), 0:03.
  The entrance is quick: 0.3 s fades (`FadeUp.duration`) at 0, 0.08, 0.16, 0.24 s (icon,
  headline, catch phrase, recorder), then the four facts **together** with Continue at 0.32 s. A real-window test checks that the idle and the
  frozen recorder draw identical pixels over time. Two traps: a `repeatForever` pulse is not
  stopped by later non-animated changes, so the indicator gets a new identity when it pauses or
  resumes (`.id(isPaused)`); and `OverlayWaveform` is not observable, so the view takes its
  `revision` (bumped on start and freeze) as an input, or it kept its first body (no bars at
  all while recording). Not interactive (`allowsHitTesting(false)`, so no Stop under the
  pointer). Reduce Motion: the frozen frame at once (`WelcomeDictation.frozenHistory()`
  computes the bars the same way), no fades.
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
    dictate ("Encrypted, stays on this Mac."; disabled with the red note when history is
    unavailable); Play a sound when recording starts and stops. Small switches, system accent.
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
| Settings › Advanced › "Show Onboarding Again…" | Opens onboarding; settings kept. |
| The menu's "Finish Setup…" (onboarding never finished, window closed) | Opens onboarding at the welcome page. |
| `--onboarding` launch argument (`make onboarding` for the debug app) | Shows onboarding at launch even if completed; settings kept. |
| `--reset-onboarding` | Clears only the `onboardingComplete` flag (before `AppState` reads it). |
| `--show-handoff` (debug builds only; `make handoff`) | Shows the end-of-onboarding popover about a second after launch; nothing else changes. Parsed by `MenuBarHandoff.isRequestedAtLaunch`, not `LaunchOptions`. |

The first three are parsed by `LaunchOptions` (`OnboardingFlow.swift`); unknown arguments are ignored. A replay never
re-downloads anything unless the user applies another model.

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
