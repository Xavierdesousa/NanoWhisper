# Architecture and recording pipeline

Last verified against the code: 2026-11-20 (`chore/cleanup`, on top of `main` at 935e191).

## What it is

A single SwiftPM executable target, `NanoWhisper` (`Sources/NanoWhisper/`), that runs as a
menu bar app (`LSUIElement`, activation policy `.accessory`). Dependencies: FluidAudio 0.18.3
(Parakeet) and WhisperKit 1.1.1 from `argmaxinc/argmax-oss-swift` (see `Package.swift`).
There is no Xcode project and no app sandbox; the bundle is assembled and signed by the
`Makefile` ([build-and-release.md](build-and-release.md)).

## Components

`AppState` (`AppState.swift`, `@MainActor`) owns every component and orchestrates them:

| Component | Type (file) | Role |
|---|---|---|
| Menu bar UI | `MenuBarController` (`MenuBarController.swift`), `MenuContent` (`MenuBarMenu.swift`) | `NSStatusItem` and its `NSMenu`, built from `MenuContent.lines(for:)` (see below). `AppDelegate` (`NanoWhisperApp.swift`) creates `AppState` and the controller at launch. |
| Hotkey | `HotkeyManager` (`HotkeyManager.swift`) | Carbon `RegisterEventHotKey`; `Shortcut` persisted in `UserDefaults` (`shortcut_keyCode`, `shortcut_modifiers`). |
| Recorder | `AudioRecorder` (`AudioRecorder.swift`) | `AVAudioEngine` input tap, converted to 16 kHz mono Float32 and written to a WAV in the temp dir; publishes an RMS level for the overlay. |
| Overlay | `RecordingOverlayController` (`RecordingOverlay.swift`) | Floating panel with level bars and timer; follows display changes. |
| Model setup | `SetupManager` (`SetupManager.swift`) | Downloads and loads the selected model. See [transcription-engines.md](transcription-engines.md). |
| Transcription | `Transcriber` (`Transcriber.swift`) | Serial queue of transcriptions over the installed engine. An engine error is logged and returned as `TranscriptionResult.failure`, never as empty text. |
| History | `HistoryStore` (`HistoryStore.swift`) | Encrypted history file: entries, load/save, max-count trimming, unavailable state. See below. |
| Temp recordings | `TemporaryRecordings` (`TemporaryRecordings.swift`) | Zero-then-delete of a WAV; removal of this build's leftovers at launch. |
| Paste | `PasteManager` (`PasteManager.swift`) | Puts text on the pasteboard, posts ⌘V with `CGEvent`, restores the previous clipboard after 3 s if untouched. Needs Accessibility. |
| Media pause | `MediaController` (`MediaController.swift`) | See [media-pause.md](media-pause.md). |
| Sounds | `SoundManager` (`SoundManager.swift`) | Start, stop and no-result cues. |
| Settings, onboarding, history windows | `SettingsWindowController`, `OnboardingWindowController`, `HistoryWindowController` | See [onboarding-and-settings.md](onboarding-and-settings.md). |
| Updates | `AutoUpdater` (`AutoUpdater.swift`) | See [build-and-release.md](build-and-release.md). |

## Menu bar menu

Design: "After setup: the menu bar takes over" board (approved 2026-11-20). Built in AppKit
(`MenuBarController`), not SwiftUI's `MenuBarExtra`: in its menu style every item is a plain
text button, so it cannot draw the download bar or the shortcut as key caps.

- **Content is pure:** `AppState.menuState(...)` → `MenuState` → `MenuContent.lines(for:)` →
  `[MenuLine]` (tested in `MenuContentTests`). The controller rebuilds the menu when it opens
  (`menuNeedsUpdate`) and, while it is open, on every `AppState` change (delivered on the main
  queue, which runs during menu tracking); with the same structure it updates items in place.
- **Order:** debug builds only: name and `v<version> · <commit>`; "Finish Setup…" with the
  first missing permission on the right ("Microphone is off", "Accessibility is off") while
  onboarding was never finished and its window is closed; "Start Dictation" / "Stop Dictation"
  with the shortcut as key caps (disabled until the model is ready); one line for the model
  state; the last error; an update line; History…, Settings… ⌘,; Quit <app> ⌘Q.
- **Model line by state** (from `EngineState`, same precedence as before the redesign):
  downloading → "Downloading <model>, 64%" with a bar (no percentage: "Downloading <model>…"
  and an indeterminate bar); compiling → "Optimizing <model> for this Mac…"; setup error →
  "Could not set up <model>", the message, Retry; engine start error → "<model> could not
  start", the message, Retry; first launch before the download → "<model> is not downloaded"
  and "Download <model> (<size>)"; loading → "Loading <model>…"; recording → "Recording…"
  (red); transcribing → "Transcribing…"; else "<model in use> is ready" (during a migration's
  switchover the previous model, plus "Downloading <new>, 42%" with a bar; nothing after a
  failed background download). Update: "Install Update <v> and Relaunch", or "Downloading
  update <v>…" with a bar.
- The board draws only "ready" and "setup not finished"; the other states keep their previous
  content in the board's form. Changed from before: "Show Setup…" is now "Finish Setup…"
  (it still opens onboarding at its first step: the onboarding redesign that would reopen at
  the first unfinished step is not approved); History lost its ⌘H (not on the board); the
  app-name header is shown in debug builds only.
- **View-based items:** Start/Stop Dictation and Finish Setup… are `MenuRowView`s (they draw
  something on the right), progress lines are `MenuProgressView`s; the rest are native
  `NSMenuItem`s. `MenuRowView` draws its own selection (`NSVisualEffectView`, `.selection`
  material) from `menu(_:willHighlight:)`, handles the click in `mouseUp` and closes the menu.
  The menu has no state column (`showsStateColumn = false`) and the views' text starts 14 pt
  from the menu edge (`MenuMetrics`), an estimate of where native titles start.
- **Icon:** unchanged (glyph; `arrow.down.circle` while setting up, `mic.slash` while not
  ready; debug band). The board's capsule glyph that fills while downloading is marked as a
  proposal on the board, so it is not implemented.
- **Not verified in the app** (renders use `MenuPreview`, an approximation drawn from the same
  lines; an `NSMenu` cannot be drawn offscreen): alignment of the view-based items with native
  ones, their highlight and click, Return on a highlighted view-based item, live updates of the
  bar while the menu is open, VoiceOver.

## Recording pipeline (today)

1. Hotkey or menu → `AppState.toggleRecording()`. Refuses with "Model not loaded yet" unless
   `isEngineReady`.
2. `AppState.startRecording()`:
   - `mediaController.beginSession(pauseMedia:)` opens a media session; detection runs in
     the background so the microphone is not delayed;
   - start sound, `audioRecorder.startRecording()` (file name from
     `BuildFlavor.temporaryAudioFileName`);
   - `DictationDestination.atStart(testBoxShowing:appIsActive:)` decides whether this is a
     normal dictation or an onboarding "Try it" test;
   - overlay shown. On a microphone error the media session is ended at once.
3. `AppState.stopRecording()`: stop sound, overlay switches to loading, the WAV URL is taken,
   then in a `Task`:
   - `transcriber.transcribe(audioURL:)` (queued, see
     [transcription-engines.md](transcription-engines.md#concurrency-model));
   - the overlay shows the final text (live preview, debug build) and is dismissed, whatever
     the outcome;
   - `DictationOutcome.resolve(...)`: test result shown in onboarding, discarded, "Empty
     transcription" (engine ran, nothing recognized; no-result sound), failed (engine error or
     no engine: `TranscriptionFailure.message` in the menu's error line, same sound; the
     error is in the log, category `Transcriber`: its type public, its description private
     since it could quote the vocabulary hint or text), or delivered;
   - delivered text is added to history (`HistoryStore.add(_:keepingAtMost:)`, if enabled) and pasted;
   - `defer`: the WAV is overwritten with zeros and deleted (`TemporaryRecordings.securelyDelete(at:)`), and the
     media session is ended (media resumes only when no other session is open).

Several recordings can be in flight: a new one may start while the previous one is still
being transcribed. Each keeps its own media session and destination.

## History storage

- File: `history.json` in `~/Library/Application Support/<flavor display name>/`
  (`BuildFlavor.supportDirectory(in:)`), so production and debug never share it.
- `HistoryStore` (`HistoryStore.swift`, `@MainActor`, `ObservableObject`) owns it: `entries`
  (newest first), `isUnavailable`, `add(_:keepingAtMost:)`, `trim(to:)`, `replaceEntries(_:)`.
  It loads in its initializer and writes the whole file (atomically) after each change. `AppState.history`
  and `AppState.historyUnavailable` forward to it (its `objectWillChange` is forwarded too), so
  views did not change. The file URL and key are injectable for `HistoryStoreTests`.
- Encrypted with AES-256-GCM (`HistoryCrypto`). The key is derived with HKDF-SHA256 from the
  machine's `IOPlatformUUID` and the constant salt `com.moonji.nanowhisper.history.v1`
  (pinned by a test).
- If the file cannot be decrypted or decoded (wrong key, damage, plain text), or encryption
  fails, the history is **unavailable**: nothing is read as plain text, nothing is written, and
  the unreadable file is left untouched; the History menu item and toggle are disabled until
  relaunch. (Before the extraction, deleting from an already-open History window could still
  overwrite an unreadable file; the store now refuses every write while unavailable.)
- **What it protects:** the file at rest (a copy, a backup, another Mac) and against casual
  reading. Not against software running under the same user account: the hardware UUID is
  readable by any process and the salt is public.

Why: the first version (2026-03-20) stored the key in the Keychain; the Data Protection
Keychain needs entitlements that fail without a provisioning profile
(`errSecMissingEntitlement -34018`), so commit 240f784 switched to a derived key: no storage,
no prompt, tied to the machine (but readable by any local process, see above). The salt is a crypto constant, not an identifier: changing it
makes existing history unreadable. Both flavors keep it.

## Temporary recordings

- Prefix `nanowhisper_` (production) or `nanowhisper-debug_` (debug), from
  `BuildFlavor.temporaryAudioFilePrefix`.
- At launch, `TemporaryRecordings.removeOrphans()` deletes leftovers with its own prefix only
  (`BuildFlavor.ownsTemporaryAudioFile(named:)`).
- The debug prefix deliberately does not start with `nanowhisper_`: the released v0.0.4 deletes
  every `nanowhisper_*.wav` at launch and would otherwise delete a debug recording in progress.

## History of the architecture

- 2026-03-18: first version used a Python/NeMo daemon over a socket.
- 2026-03-19 (8123843): replaced by FluidAudio Core ML in-process; Python removed entirely.
- 2026-03-24: WhisperKit added as a second engine.
- 2026-11-19: see [log.md](log.md).

## Known limits

- `PasteManager.pasteText` does nothing when NanoWhisper itself is frontmost.
- The clipboard is restored only for plain-text content; other pasteboard types are lost.
  (Read from `PasteManager`; not re-tested.)
- Apple Silicon only (README); not tested on Intel.
