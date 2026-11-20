# Onboarding and Settings

Last verified against the code: 2026-11-20 (`feat/settings-and-menu-redesign`), with unit tests and offscreen renders; the Settings redesign was not run in the app (see Known limits). Source: PR #15, the model migration PR, the Settings and menu redesign PR and the code.

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
| Recorder position | Recorder (spot marked `RECORDER POSITION`; the picker comes from the Voice note overlay work) | — |
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
    its content. `NSTabViewController` did not resize the window on every pane switch (it kept
    the previous height in the sizing test), so `SettingsTabViewController` fits the window
    itself on selection and when the selected pane's `preferredContentSize` changes (Whisper
    options, pending change, update states), keeping the top edge in place.
- **Last pane remembered**: UserDefaults `settingsPane`; `SettingsPane.restored(_:from:)` falls
  back to General when the stored pane is not shown.
- **Recorder pane** is hidden while it would be empty (production before the recorder position
  picker is wired: `SettingsPane.visible(recorderHasContent:)`, `RecorderPane.hasContent`).
- **Fresh content at each opening**, so the Engine draft starts from the applied settings
  (unapplied changes are dropped when the window closes). On close the controller stops the
  `PermissionMonitor` and drops the content; the Permissions pane also starts/stops polling on
  appear/disappear, so it polls only while visible.
- **Brand color:** violet (`Color.nwAccent`, `nwAccentText`, `SettingsStyle.swift`) for the
  engine radio marks, "Recommended", "Beta", Change… and the tint. The toolbar selection keeps
  the system look (`NSTabViewController` draws it).
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

## Replay

| How | Effect |
|---|---|
| Settings › Advanced › "Show Onboarding Again…" | Opens onboarding; settings kept. |
| `--onboarding` launch argument (`make onboarding` for the debug app) | Shows onboarding at launch even if completed; settings kept. |
| `--reset-onboarding` | Clears only the `onboardingComplete` flag (before `AppState` reads it). |

Parsed by `LaunchOptions` (`OnboardingFlow.swift`); unknown arguments are ignored. A replay never
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
  title, size) in light and dark and a sizing test; **not run in the app**: real clicks, the
  window's resize animation, focus and keyboard navigation between panes, VoiceOver on the key
  caps and the engine radio rows. Offscreen windows are never key, so controls render in their
  inactive look (grey switches and progress bars): the violet tint is not verified.
