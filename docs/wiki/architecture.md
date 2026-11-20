# Architecture and recording pipeline

Last verified against the code: 2026-11-20 (`chore/cleanup`, on top of `main` at 935e191); the
Recording overlay section on 2026-11-20 against `feat/voice-note-overlay` (on `main` at 43c1f2d);
the recorder (Recording pipeline, Stopping the recorder) on 2026-11-20 against
`fix/stop-recording-crash` (on `main` at b15be20).

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
| Recorder | `AudioRecorder`, `RecordingWriter` (`AudioRecorder.swift`) | One `AVAudioEngine` per recording; its input tap hands buffers to `RecordingWriter`, which converts them to 16 kHz mono Float32 and writes the WAV in the temp dir; publishes an RMS level for the overlay. Stop order and input changes: [Stopping the recorder](#stopping-the-recorder-crash-of-2026-11-20). |
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
3. `AppState.stopRecording()`: stop sound, overlay switches to loading,
   `audioRecorder.stopRecording()` stops the engine, removes the tap and closes the WAV (in that
   order, see below) and returns its URL, then in a `Task`:
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

If the input changes during a recording and the recorder cannot continue on the new one,
`AudioRecorder.onInputLost` makes `AppState` stop the recording (what was recorded is
transcribed) and show "Recording stopped: the microphone changed" in the menu's error line.

## Stopping the recorder (crash of 2026-11-20)

**The crash.** The debug app (build b15be20, macOS 27.2, Apple Silicon) crashed when the
maintainer stopped a 2 min 44 s dictation with live transcription on:
`EXC_BAD_ACCESS` at address 0 on `com.apple.audio.IOThread.client`, pc = 0, called from the HAL
output unit (AUHAL, `/System/Library/Components/CoreAudio.component`, offset 0xa934) inside
`HALC_ProxyIOContext::IOWorkLoop()`, while the main thread waited in `-[AVAudioEngine stop]` →
`AudioOutputUnitStop` → `usleep`. The WAV header still said 0 bytes of audio (the file is only
finalized when `AVAudioFile` is closed), so the recording was lost for the app.

**Root cause (confirmed).** The old `AudioRecorder.stopRecording()` called
`inputNode.removeTap(onBus: 0)` and then `audioEngine.stop()`. On a running engine,
`removeTap` re-initializes the input chain (`AVAudioEngineImpl::RemoveTapOnNode` →
`AUGraphParser::InitializeActiveNodesInInputChain` → `AUGraphNodeIOV3::DeallocateInputHandler`
→ `AUInterfaceIOV3::SetInputHandler(nil)`), which sets the AUHAL's
`kAudioOutputUnitProperty_SetInputCallback` (property 2005) to {NULL, NULL} from the main
thread while CoreAudio's IO thread keeps running. The AUHAL's IO proc reads the callback
pointer, checks it is not null, does some timestamp work, then **reads it again and calls it
without checking** (disassembly of the component: `ldr x8, [x19, #0x5e0]; cbz` at 0xa894,
`ldr x8, [x19, #0x5e0]; blraaz x8` at 0xa914–0xa930). If the main thread clears it in between,
the IO thread calls address 0. The crash report's registers match this call exactly: x0 (refCon)
= 0, x3 (bus) = 1, x4 (frames) = 512, x5 (ioData) = NULL, lr = component + 0xa934.
- How it was established: the old order traced under lldb in a harness compiling the app's
  `AudioRecorder.swift` (breakpoints on the functions above: `SetInputHandler(nil)` runs inside
  `removeTap`, before `stop`); the writers of the AUHAL field found in the component's
  disassembly (only the constructor and the `SetProperty` case for 2005).
- **Reproduced:** a stress harness that calls `removeTap`/`installTap` repeatedly on a running
  engine with the built-in microphone crashed within 0.4–0.6 s (2,000–4,000 cycles) in four runs
  out of four, with the same signature (pc = 0, AUHAL + 0xa934, `IOWorkLoop` + 10376, same
  registers). The same harness stopping the engine before `removeTap` ran 60 s (474
  stop/remove/install/start cycles) without a crash.
- Not reproduced through the app's own `AudioRecorder` start/stop cycles (old order, 1,467
  cycles of 0.05–0.1 s, no crash, run stopped early; plus one 175 s recording with a
  live-transcription-like consumer on the new code, WAV complete): the window is a few
  instructions per IO cycle (512 frames, 10.7 ms at 48 kHz), so each stop has a small chance.
  These harnesses opened the real microphone; that is no longer allowed (see
  [testing](testing-and-verification.md)), and the fix is now covered by fake-engine tests.
  Nothing points at the recording's length or at live transcription; the extra CPU load of a
  live decode may widen the window (not measured). Whether the input device changed during the
  maintainer's recording is unknown; the log of that session shows no device change, only the
  stop sound's engine starting just before the stop.
- The usual Speech-framework teardown in Apple developer forum answers stops the engine before
  removing the tap; Apple's reference for `removeTap(onBus:)` states no ordering requirement.
  (Apple's SpokenWord sample itself was not re-read.)

**What the recorder does now** (`AudioRecorder.stopRecording()`):
1. `engine.stop()` first. It returns once `AudioOutputUnitStop` has waited for the IO thread to
   stop, so nothing can be cleared under a running IO proc. Traced: with this order,
   `removeTap` on the stopped engine does not touch the input callback at all; the callback is
   only cleared when the engine is deallocated, IO already stopped.
2. `removeTap(onBus: 0)`.
3. `RecordingWriter.finish()`: closes the `AVAudioFile` (`close()` on macOS 15+, release before),
   so the header has its final sizes before the URL is returned. The writer's lock makes
   `finish()` wait for an `append` in progress, and any tap block delivered after it writes
   nothing. Tap blocks are delivered on AVAudioEngine's `RealtimeMessenger.mServiceQueue`, not
   on the IO thread.
- `AudioInputEngine` is the seam: `SystemAudioInputEngine` wraps `AVAudioEngine.inputNode`;
  tests inject `FakeInputEngine`, which flags a tap removed from a running engine.
- The tap block captures the `RecordingWriter` (a `Sendable` class whose file and converter sit
  in an `OSAllocatedUnfairLock`), not the recorder, and is built in a `nonisolated static`
  function: formed inside the `@MainActor` recorder it would inherit main-actor isolation and
  trap in Swift 6's runtime isolation check on the tap queue (seen in the harness with a Combine
  sink formed on the main actor).
- **Input changes:** the recorder observes `AVAudioEngineConfigurationChange` for its engine
  (the engine stops itself when the input's format or device changes). It reinstalls the tap
  with a new converter for the new input format and restarts the engine, writing on in the same
  file; if that fails, it closes the file and calls `onInputLost`. The observer is registered
  with `queue: nil` and only schedules the recovery on the main actor: with `queue: .main` the
  engine's posting thread would wait while the recovery calls back into the engine (CodeRabbit
  finding). Before any tap, `isInputAvailable` checks the input node's hardware format
  (`inputFormat(forBus: 0)`, input scope): a tap in a format the input cannot deliver raises an
  Objective-C exception that Swift cannot catch. Checked in the harness by
  moving the running engine's input to another device (`AUAudioUnit.setDeviceID`, process-local):
  AVAudioEngine posted the notification, recording continued in the same file (3.87 s of audio
  for a 4.05 s recording) and the WAV was complete. **Not verified:** a real change of the
  system default input or a Bluetooth headset connecting (an attempt to switch the system
  default input from the harness did not take effect, and it was not pushed further while the
  maintainer was testing).
- Converter priming drops about 240 frames (15 ms) once per converter (at the start, and after
  an input change); later buffers convert without loss (measured: 10 × 4,800 frames at 48 kHz →
  15,760 frames at 16 kHz, then 1,600 per buffer).

## Recording overlay

Design: "Voice note" (proposal 1) from the maintainer's design canvas, page "Recording overlay"
(developer notes board for sizes, colours and motion). Implemented in `feat/voice-note-overlay`
(2026-11-20). What follows is what the code does; on screen only still captures of the real
panel were checked. **Unverified on screen:** the HUD blur and the window shadow (not in
captures), every animation (spring, breathing, glide, sweep, fades), and the Reduce Motion /
Reduce Transparency fallbacks with the real system settings (captured only with the
environment values forced in a test host).

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
- A leftover at launch is a recording whose app crashed before it was transcribed; its header
  usually says 0 bytes of audio (`AVAudioFile` writes the sizes when it is closed), but the
  samples are in the file.
- **Recovery of interrupted recordings** (`feat/recover-interrupted-recordings`, 2026-11-20; the
  maintainer's rules: "we try the transcription once, no need to tell the user; it appears in
  History as if nothing happened"). `InterruptedRecordings`, `InterruptedRecordingRecovery`,
  `AppState.recoverInterruptedRecordings()`; it replaced `TemporaryRecordings.removeOrphans()`.
  - **At launch** (`InterruptedRecordings.collect`, this build's prefix only, so the other
    build's files are never touched, not even repaired): deleted (zeroed first) when already
    attempted (`….attempted.wav`), when history is off or unavailable, when older than 7 days
    (file creation date), when not a readable WAV, or when shorter than 0.3 s. The others get
    their header repaired (`WAVHeader.repair`: RIFF size, `data` size in whole frames from the
    file length, `fact` frame count; never shrinks a size that already counts more) and are
    kept, oldest first.
  - **Then, silently**: no overlay, sound, paste, notification or menu error line. Each
    recording waits until the app is idle (engine ready, not recording, nothing transcribing,
    the transcriber's queue empty; checked every second), is renamed `….attempted.wav`, goes
    through the normal `Transcriber` queue with the current engine, and is deleted (zeroed)
    whatever the outcome. Non-empty text goes to History with `HistoryStore.insert`, at the
    recording's date, in chronological place (newest first; a full history drops its oldest).
    Empty text or an engine failure: nothing in History.
  - **Exactly once:** the rename happens before the transcription starts, and an attempted
    file found at the next launch is deleted without a retry, so a recording that crashes the
    transcription cannot loop.
  - **Priority:** a recovery never starts while a dictation is recorded or transcribed. One
    already running when the user stops a dictation is finished first (FIFO queue; a
    transcription cannot be interrupted): one recording, well under a second with Parakeet for
    a few minutes of audio (not measured here), longer with Whisper Large.
  - **Logs** (category `InterruptedRecordings`): counts only, never text.
  - **Not verified in the app:** a real crash followed by a relaunch; tests use temporary
    directories, the crash state copied from an open `RecordingWriter` file, and fake
    transcriptions.
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
