# Onboarding and Settings

Last verified against the code: 2026-11-19 (`main` at 29e84c9). Source: PR #15 and the code.

## What it is

Settings and onboarding are built from the **same sections**, with the same wording and
behavior. `SettingsView` and `OnboardingView` only assemble them.

| Section | View (file) |
|---|---|
| Model: engine, Parakeet version, Whisper size/language/hint, status, apply row, comparison | `ModelSettingsSection` (`SettingsModelSection.swift`), `ModelComparisonView` |
| Permissions: Microphone, Accessibility, live status | `PermissionsSettingsSection` (`SettingsPermissionsSection.swift`), `PermissionMonitor` (`Permissions.swift`) |
| Shortcut recorder | `ShortcutSettingsSection` (`SettingsShortcutSection.swift`) |
| General: launch at login, sounds, pause media, history | `GeneralSettingsSection` (`SettingsGeneralSection.swift`); the history size shows in Settings only (`showsHistoryLimit`) |
| Settings only: Updates, Debug | `UpdatesSettingsSection`, `Section("Debug")` in `SettingsForm` (`SettingsView.swift`) |

The Settings "Debug" section ("Show debug info in history", `AppState.debugMode`, and "Show
Onboarding Again…") exists in both builds. It is unrelated to the debug **build flavor**
([build-and-release.md](build-and-release.md)).

Every section reads a `SettingsContext` (`SettingsContext.swift`): plain values, bindings and
closures. `AppState.settingsContext(permissions:)` builds the live one; render tests build fixed
ones, so each section can be drawn without a running app
([testing-and-verification.md](testing-and-verification.md)).

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
- While onboarding is open the app uses activation policy `.regular` (Dock icon); it returns to
  `.accessory` when the window closes, however it closes (`AppState.onboardingWindowDidClose()`).
- Closing the window without finishing on a first launch leaves `onboardingComplete` unset, so
  onboarding shows again at the next launch.

## Replay

| How | Effect |
|---|---|
| Settings → Debug → "Show Onboarding Again…" | Opens onboarding; settings kept. |
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

## Known limits / not verified

- Not checked in the app: the Try it recording (button and hotkey), and Grant changing to
  Granted — both need microphone and Accessibility granted to the debug app.
- `PermissionMonitor` polls every second while a window showing it is open.
