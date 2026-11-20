# Onboarding and Settings

Last verified against the code: 2026-11-20 (`feat/settings-and-menu-redesign`; End of onboarding against `feat/menu-bar-handoff`; the Settings window, colors and sizing again in `feat/redesign-feedback`), with unit tests and offscreen renders; the Settings redesign was not run in the app (see Known limits). Source: PR #15, the model migration PR, the Settings and menu redesign PR and the code.

## What it is

Settings and onboarding read the same `SettingsContext` and share their wording
(`SettingsText`, `ShortcutRecorderRow`, `DictationBehaviorToggles`, `HistorySettingsRows`).
Since the redesign (2026-11-20) Settings has its own pane views; onboarding keeps the sections
it had (its redesign was not approved and is postponed).

| Area | Settings pane (file) | Onboarding |
|---|---|---|
| Shortcut (`ShortcutRecorderRow`, `SettingsShortcutSection.swift`) | General | Shortcut step (`ShortcutSettingsSection`) |
| Open at login, sounds, pause media, history on/off (`DictationBehaviorToggles`, `HistorySettingsRows`, `SettingsGeneralSection.swift`) | General, plus "Keep the last N" (disabled while history is off) | Shortcut step (`GeneralSettingsSection`) |
| Engine, model, status, apply row, Whisper language and vocabulary | Engine (`EnginePane`, `SettingsEnginePane.swift`) | Model step (`ModelSettingsSection`, `SettingsModelSection.swift`) |
| Downloaded models, "Remove Unused Models…" (`ModelStorageRow`, `UnusedModelsSheet`, `SettingsStorageSection.swift`) | Engine | — |
| Live transcription (beta, debug builds only) | Recorder (`RecorderPane`, `SettingsRecorderPane.swift`) | Shortcut step |
| Recorder position (`RecorderPositionPicker` from the Voice note overlay, PR #24; `AppState.recorderPosition` through `SettingsContext.recorderPosition`) | Recorder | — |
| Microphone, Accessibility with live status | Permissions (`PermissionsPane`, `SettingsPermissionsSection.swift`) | Permissions step (`PermissionsSettingsSection`) |
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
    visible while onboarding shows the Dock icon) opens the real window.
  - **Sizing:** each pane is a grouped `Form` with `.scrollDisabled(true)` and
    `.fixedSize(horizontal: false, vertical: true)` (`SettingsPaneForm`), so its fitting size is
    its content. `SettingsTabViewController` alone sizes the window, keeping the top edge: on a
    pane switch, and when the selected pane's content changes height (Whisper options, pending
    change, update states).
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
  - The model line under the selected engine is quiet ("Parakeet Ultra, ~630 MB. Change…");
    Change… shows the picker and the speed/accuracy comparison (`ModelComparisonView`, kept from
    the old Settings). It stays open while the draft names another model.
  - **Whisper language and vocabulary apply right away in Settings** (`SettingsContext
    .setWhisperOptions`), as the design asks: they never load a model. Onboarding still applies
    them with the draft.
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
General, the menu's Start Dictation item and onboarding's Try-it row. Change… swaps the caps
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
- Pickers: the Parakeet "Version" picker offers Ultra and v3; the Whisper size picker offers
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

## Onboarding flow

`OnboardingStep` (`OnboardingFlow.swift`): Welcome → Model → Permissions → Shortcut → Done.

- Step indicator, Back / Continue, Skip Setup on every step but Done. Fixed 560×600 pt window;
  long steps scroll.
- **No step blocks.** `OnboardingProgress.indicatorState(of:current:)`: Model and Permissions
  show as done as soon as their goal is met, even before the user reaches them; a passed step
  whose goal is not met is flagged (`.needsAttention`).
- **First launch does not download before the user has seen the choice.**
  `ModelAvailability.shouldDeferSetupAtLaunch(...)` holds the Parakeet download until the user
  clicks Download on the Model step, or finishes or skips onboarding
  (`AppState.completeOnboarding()` → `loadSelectedModelIfIdle()`). A model already on disk still
  loads at launch. During the deferred state the menu offers "Download <model> (<size>)".
- **Done step "Try it" box:** a recording started while the Done step is showing **and**
  NanoWhisper is the active app is a test (`DictationDestination.onboardingTest`): its text shows
  in the window, is not pasted, not saved. A dictation into another app still pastes.
  - The button and the shortcut are shown as two equal ways to start it ("Record a Test or
    press ⌃⌥Space", the shortcut as key caps, `ShortcutKeysView`).
  - **Hotkey path (checked in code, 2026-11-20):** Carbon hotkey → `HotkeyManager.onHotkeyPressed`
    → `AppState.toggleRecording()` → `startRecording()` → `DictationDestination.atStart(testBoxShowing:
    capturesTestTranscription, appIsActive: NSApp.isActive)`. With the onboarding window in front
    the app is active, so it is a test; pressing again stops it, and the destination chosen at
    start is kept. `capturesTestTranscription` follows the step (`onChange(of: step)`; a new
    hosting view starts at Welcome on each show). It is a normal dictation instead when another
    app is in front, and nothing starts until the model is ready (`toggleRecording` sets
    "Model not loaded yet"). Carbon hotkeys fire while NanoWhisper itself is active.
- While onboarding is open the app uses activation policy `.regular` (Dock icon); it returns to
  `.accessory` when the window closes, however it closes (`AppState.onboardingWindowDidClose()`).
- Closing the window without finishing on a first launch leaves `onboardingComplete` unset, so
  onboarding shows again at the next launch.

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
- Onboarding wording changed with the Settings redesign only where a row is shared: the
  shortcut row (key caps and Change…) and the toggle labels ("Open at login", "Play a sound
  when recording starts and stops", "Pause music and videos while recording", "Keep a history
  of what you dictate"). The steps and their order did not change.

## Known limits / not verified

- Not checked in the app: the Try it recording (button and hotkey), and Grant changing to
  Granted — both need microphone and Accessibility granted to the debug app.
- `PermissionMonitor` polls every second while onboarding is open, and in Settings while the
  Permissions pane is showing.
- Settings redesign (2026-11-20): verified with offscreen renders of the real window (toolbar,
  title, size) in light and dark; since 2026-11-20 also the real window shown on screen
  (`SettingsWindowTests`: every pane switch, each frame of the resize forced and the real
  animation sampled every 16 ms, light and dark). **Not run in the app**: real clicks, focus
  and keyboard navigation between panes, VoiceOver on the key caps and the engine radio rows,
  the toolbar's translucency (drawn by the window server, not in captures). Offscreen windows
  are never key, so controls render in their inactive look.
