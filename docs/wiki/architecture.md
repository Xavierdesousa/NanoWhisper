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
| Menu bar UI | `NanoWhisperApp` (`NanoWhisperApp.swift`) | `MenuBarExtra` menu; status line chosen from `AppState`/`SetupManager` state. |
| Hotkey | `HotkeyManager` (`HotkeyManager.swift`) | Carbon `RegisterEventHotKey`; `Shortcut` persisted in `UserDefaults` (`shortcut_keyCode`, `shortcut_modifiers`). |
| Recorder | `AudioRecorder` (`AudioRecorder.swift`) | `AVAudioEngine` input tap, converted to 16 kHz mono Float32 and written to a WAV in the temp dir; publishes an RMS level for the overlay. |
| Overlay | `RecordingOverlayController` (`RecordingOverlay.swift`) | Floating panel ("Voice note" design): record capsule, scrolling waveform, timer, result; placed by `RecorderPosition`; follows display changes. See [Recording overlay](#recording-overlay) below. |
| Model setup | `SetupManager` (`SetupManager.swift`) | Downloads and loads the selected model. See [transcription-engines.md](transcription-engines.md). |
| Transcription | `Transcriber` (`Transcriber.swift`) | Serial queue of transcriptions over the installed engine. An engine error is logged and returned as `TranscriptionResult.failure`, never as empty text. |
| History | `HistoryStore` (`HistoryStore.swift`) | Encrypted history file: entries, load/save, max-count trimming, unavailable state. See below. |
| Temp recordings | `TemporaryRecordings` (`TemporaryRecordings.swift`) | Zero-then-delete of a WAV; removal of this build's leftovers at launch. |
| Paste | `PasteManager` (`PasteManager.swift`) | Puts text on the pasteboard, posts ⌘V with `CGEvent`, restores the previous clipboard after 3 s if untouched. Needs Accessibility. |
| Media pause | `MediaController` (`MediaController.swift`) | See [media-pause.md](media-pause.md). |
| Sounds | `SoundManager` (`SoundManager.swift`) | Start, stop and no-result cues. |
| Settings, onboarding, history windows | `SettingsWindowController`, `OnboardingWindowController`, `HistoryWindowController` | See [onboarding-and-settings.md](onboarding-and-settings.md). |
| Updates | `AutoUpdater` (`AutoUpdater.swift`) | See [build-and-release.md](build-and-release.md). |

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

## Recording overlay

Design: "Voice note" (proposal 1) from the maintainer's design canvas, page "Recording overlay"
(developer notes board for sizes, colours and motion). Implemented in `feat/voice-note-overlay`
(2026-11-20).

- **Files:** `RecordingOverlay.swift` (`RecordingOverlayController`, `RecordingOverlayViewModel`,
  `OverlayState`, `OverlayResult`), `RecordingOverlayView.swift` (views, `OverlayPalette`,
  `OverlayMetrics`, `LiveTranscriptText`, `Caret`), `OverlayWaveform.swift` (`LevelHistory`,
  `WaveformMetrics`, `OverlayWaveform`, `OverlayWaveformView`), `RecorderPosition.swift`,
  `RecorderPositionPicker.swift`.
- **Shape:** compact capsule 184 × 36 pt (radius 18); with live text a card 380 × 87 pt (36 header +
  38 text + 13), same radius, so the header never moves. Always dark: `NSVisualEffectView`
  `.hudWindow` behind the window (masked by a stretchable rounded-rect `maskImage`) under
  `#120826` at 86 %; Reduce Transparency: solid `#1A1029`. White 16 % 0.5 pt inner edge; window
  shadow on, `invalidateShadow()` after each resize and once the appear animation settled.
- **Header:** record capsule 6 × 14 pt (violet gradient, glow that breathes over 2.4 s; lilac without
  glow while transcribing; static with Reduce Motion), waveform, then the timer (or Stop under the
  pointer, or "Transcribing…" when there is text or Reduce Motion is on). The trailing item takes
  the remaining width with `.frame(maxWidth: .infinity)`, not a `Spacer`: the `HStack` spacing on
  both sides of a `Spacer` made the capsule 194 pt instead of 184.
- **Waveform** (`OverlayWaveform`): the peak of the levels of each 50 ms slot, 26 slots (1.3 s),
  starting full of silence. Height `v < 0.06 ? 2 : min(20, 3 + 17 × v^0.85)`; the oldest 7 bars
  fade from 22 %. One `Canvas` in `TimelineView(.animation)`; the row glides `4 pt × progress`
  between slots; Reduce Motion: 10 Hz, no glide. At stop the bars sink to dots in 0.25 s, then a
  highlight sweeps every 1.2 s (none with Reduce Motion). The meter is a plain class, not an
  `ObservableObject`, so the rest of the overlay does not re-render 20 times a second.
  - **Decision (agent): an empty slot repeats the previous value** (up to 2 slots, then
    silence). `AudioRecorder` sends one level per 4096-frame tap buffer (about 85–93 ms), so
    about 40 % of the 50 ms slots get no level; read as silence, steady speech came out as a
    dotted line. The 0.06 silence floor is the design's guess, not tuned on a real microphone.
- **Result** (`OverlayResult`, from `DictationOutcome`): check + "Pasted" (delivered), "Done"
  (onboarding Try-it, or a test whose box is gone; the design has no state for these), warning +
  "No speech detected" (empty), "No audio recorded", "Transcription failed". Held 0.8 s, 1.2 s when
  final text is shown, then a 0.25 s fade. The title is also posted as a VoiceOver announcement.
  `AppState.stopRecording()` now resolves the outcome before dismissing the overlay.
- **Motion:** appear = window alpha 0.15 s + content scale 0.96 → 1 from the pinned edge (spring
  0.3/0.85; none with Reduce Motion); the card's text fades in 0.12 s; the result badge scales in
  0.2 s; the caret blinks (steady with Reduce Motion). Every animation is scoped with
  `.animation(_:body:)` to one modifier, so none can pick up the panel's layout (the PR #20 slide).
  Not done: the word colour change tail → stable is not a separate 0.2 s fade; the text uses
  `.contentTransition(.interpolate)` with a 0.2 s animation keyed on the text instead.
- **Position** (`RecorderPosition`, `AppState.recorderPosition`, `UserDefaults` key
  `recorderPosition`, default `.topCenter`): Top Left, Top Center, Top Right, Bottom Center, 12 pt
  inside the visible frame of the screen with the pointer (`initialFrame(size:in:)`). Growth
  keeps the pinned edges (`frame(fitting:from:within:)`: top or bottom × left, center or right),
  then clamps to the visible frame; a drag lasts for that recording only. Top Center used to
  centre on `screen.frame.midX`; it now uses `visibleFrame.midX` (differs only with a side Dock).
  Bottom corners and the screen middle are not offered (design decision). The design's notes
  call it `OverlayPosition`/`overlayPosition`; the maintainer's brief named it `RecorderPosition`.
- **Picker** (`RecorderPositionPicker(selection:)`): a 300 × 186 pt dark mini screen with the
  still recorder (`RecordingOverlayPreview`, no material) at 0.555 and clickable spots for the
  other positions, beside a `.radioGroup` picker and the caption. Not placed in Settings yet:
  the Settings redesign (separate PR) puts it in its Recorder pane.

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
