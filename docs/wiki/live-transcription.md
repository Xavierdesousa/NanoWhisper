# Live transcription (beta)

Last verified: 2026-11-20, against `feat/voice-note-overlay` (feature from PR #16, debug-only
since PR #18, overlay redesigned in that branch).

## Debug build only

**Decision (maintainer, 2026-11-20):** after trying it, the overlay has design problems, so
production releases do not expose the feature. It stays in "NanoWhisper Debug" (and unbundled
`make run`) so it can keep being worked on. No live code was removed.

- One source of truth: `BuildFlavor.supportsLiveTranscription` (true for debug only).
- **Toggle:** `SettingsContext.offersLiveTranscription` is set from it, and
  the toggle and its caption show only when it is true: Settings › Recorder (`RecorderPane`,
  "Show words in the recorder as you speak", since the Settings redesign) and onboarding's
  "Shortcut and essentials" step (`GeneralSettingsSection`), the only two places.
- **Forced off at recording start:** `LiveTranscriptionSupport.startsSession(enabled:flavor:configuration:)`,
  called by `AppState.beginLiveTranscription()`, returns false in production even when
  `liveTranscriptionEnabled` is stored as true. The stored value is never rewritten (the
  hidden toggle is the only writer), so it is still there if production offers the feature again.
- No release ever exposed it (0.0.4 predates PR #16), so a production user can only have it
  stored on from a self-built production bundle of `main` between #16 and this change.
- Tests: `LiveTranscriptionFlavorTests` (flag, stored on + production ⇒ no session, and the
  section's view tree has no toggle when not offered, with a positive control) and
  `SettingsPaneTests` (the same for `RecorderPane`).

## What it is

An opt-in setting, "Live transcription (beta)" (`UserDefaults` key `liveTranscriptionEnabled`,
off by default), in Settings › Recorder and in onboarding's essentials step (debug build only, see above). While the user speaks, the recording overlay shows the text
recognized so far. Nothing is typed during the recording.

**The maintainer's rule: the overlay text and the delivered text must be identical.** At stop,
the recording is transcribed exactly as with live off. The overlay then shows that final text,
which is the string pasted and stored in history, or shown in onboarding's Try-it box for a test
recording (`DictationDestination.onboardingTest`: never pasted or saved).

**Available with** Parakeet and Whisper Base (`LiveTranscriptionSupport`). For Whisper Small
and Large v3 Turbo the toggle is disabled with a one-line explanation. (Tiny and Large v3 are no
longer offered since the model migration PR, see [transcription-engines.md](transcription-engines.md).)

## Design: re-decode the growing buffer

- **Audio:** `AudioRecorder.startRecording(onSamples:)` hands the session a copy of the same
  16 kHz samples it writes to the WAV. The tap only enqueues, and the samples accumulate off
  the audio thread (`LiveAudioBuffer`).
- **Preview decodes** (`LiveTranscriptionSession`): once 1 s of audio has followed the first
  sound (leading silence skipped), the session decodes the audio so far with the ordinary batch
  path, on a snapshot of the engine and settings the final pass uses
  (`Transcriber.makePreviewDecoder()`). A decode returns the text plus timed pieces: Parakeet
  words grouped from token timings (`Transcriber.words(from:)`), or Whisper segments.
- **Cadence** (`LivePreviewSchedule`): one decode at a time, with starts spaced by
  `max(1 s, 4 × last decode duration)`, so decodes never queue up.
- **Long recordings** (`LivePreviewWindow`):
  - **Up to 30 s** (`fullDecodeLimit`), every decode covers the whole recording.
  - **Past 30 s**, the text before a boundary is frozen. Only a window after it is decoded, at
    most 15 s (`windowLimit`, one Parakeet model window), plus 1 s of acoustic context.
  - **Moving the boundary:** when the window would exceed the limit, the boundary moves to the
    longest pause that leaves 8 s (`windowKeep`) in the window.
  - **Joins:** a window piece belongs to the window when its midpoint is past the boundary.
    `overlapAtJoin` then compares the last frozen words with the first window words, letters
    only. A repeat is dropped from whichever side it covers whole words of:
    - leading window words: "to the | the release", where a short word comes out late;
    - trailing frozen words: "you double | double-check", where the window respells.
- **Display** (`LiveTranscript`): the leading words two consecutive decodes agree on, plus
  the frozen text, are "stable" (primary color); the rest is the dimmed tail. At stop the
  final text replaces both (`finalize(_:)`).
- **At stop:** the decode in flight is cancelled and its result ignored. The normal final pass
  then runs on the WAV, and its text is shown and delivered.
- **Partials never delay or reorder real transcriptions:**
  - They never enter the `Transcriber` queue.
  - They are skipped while `Transcriber.pendingTranscriptions > 0`.
  - Parakeet previews run on their own `AsrManager`, sharing the batch models' `MLModel`
    instances as FluidAudio's parallel chunk workers do.
- **Failure:** a failed preview stops the preview and clears its text (logged). The recording
  and its final pass are unaffected.
- **Lifecycle glue** is in `AppState+LiveTranscription.swift`: `beginLiveTranscription()`,
  `cancelLiveTranscription()`, `showFinalLiveText(_:for:)`, and cancellation on quit.
- **Overlay** (design and details in [architecture.md](architecture.md#recording-overlay)):
  - The compact capsule grows once into a 380 × 87 pt card when text appears, keeping the edges
    pinned by the recorder position (Bottom Center grows upward), and shows the last two lines
    (19 pt line height, 38 pt). Settled words white 94 %, the tail white 55 % (50 % while
    transcribing), a glowing caret after the last word while recording; older lines fade out
    under a 9 pt top mask instead of being cut.
  - The caret is an `NSImage` inside the `Text` (`Caret`), no taller than the 14 pt caret: a
    taller image (room for the glow) made the last line taller, and the bottom-aligned text then
    cut the first visible line. `Text.LayoutKey` would allow an overlay instead, but needs macOS 15.
  - Transcribing with text: "Transcribing…" replaces the timer; the final text then replaces the
    preview (interpolated, 0.15 s) under "Pasted", held 1.2 s.
  - **The panel follows the SwiftUI content's ideal size** (`OverlayHostingView` reports
    `invalidateIntrinsicContentSize()`, the controller resizes on the next main-queue turn).
    Until 2026-11-20 the controller read `fittingSize` right after setting the view model, got
    the pre-update compact size, and the panel stayed 123×40 pt around 384×82 pt of content:
    square dark rectangle, one line cut on both sides, the bars row out of view.
  - **The resize is not animated:** during an animated window resize the content, already at
    its new size, was clipped by the smaller window.

## Decisions and rejected alternatives

- **Sliding-window streaming (FluidAudio `SlidingWindowAsrManager`), rejected:**
  - First text came only after ~5 s, with updates every 4 s.
  - Stray sentence breaks at window edges ended up in the pasted text ("Martin. aux notes de
    version. Ils").
  - With ≤ 2 s chunks, very short clips came out as garbage, because the tail flush freezes a
    decode of ~1.5 s of audio.
  - An earlier version of PR #16 used it; it was removed with its token-revision code and batch
    fallback.
- **Long-recording cap (decided):** decoding everything made CPU grow to a full core after
  ~2.5 min, because FluidAudio decodes audio longer than 15 s on 4 parallel workers. The window
  keeps CPU flat (numbers below). It is display only: the delivered text is always the full
  normal pass.
- **Whisper large sizes (decided: disabled):**
  - A preview decode in flight at stop must end quickly, because the final pass waits for it:
    both use the same `WhisperEngine`.
  - WhisperKit checks cancellation between steps, but cannot interrupt an encoder prediction.
    Large v3 Turbo needs ~0.6 s to stop, and its previews update only every 3–7 s.
  - Base stops in ~10 ms. Small is not measured (disabled). (Tiny was enabled and Large v3
    disabled until both were removed from the lineup.)
- **Stop → paste cost (accepted for Parakeet):** +0.01–0.05 s typically; up to +0.1 s when a long
  preview decode is in flight at stop.

## Measurements (PR #16, 2026-11-19, Apple Silicon, macOS 27.2)

Harness compiling the app's `Transcriber`, `LiveTranscriptionSession`, `LiveTranscript`;
`say` audio (English, French) fed in real time as 85 ms chunks.

**Parakeet Ultra, short clips (no window):** first text at 1.12–1.14 s, then an update every
~1.03 s. CPU is 4–10 % of one core for clips ≤ 5 s and 21–31 % for 26–32 s. Final text was
identical to live off on all clips. The stable words that changed later were mostly
sentence-boundary punctuation.

**Parakeet Ultra, long recordings (window cap):**

| Clip | First text | Update interval (max) | Decode median | Audio per decode | CPU (% of one core) | Final == live off | Stop → paste ON / OFF |
|---|---|---|---|---|---|---|---|
| fr 32 s | 1.14 s | 1.03 s (1.08) | 0.159 s | whole | 35.9 | yes | 0.280 / 0.179 s |
| en 77 s | 1.15 s | 1.03 s (1.13) | 0.155 s | 13.0 s | 27.7 | yes | 0.331 / 0.321 s |
| en 3.9 min | 1.13 s | 1.02 s (1.10) | 0.154 s | 13.0 s | 27.4 | yes | 0.705 / 0.655 s |

- **CPU over the 3.9 min recording,** per 30 s: 33.5, 27.9, 28.0, 27.6, 24.2, 24.8 and 25.8 %
  (an earlier run of the same code: 28.7, then 22.7–24.5 %). Without the cap it was 30, 61, 80,
  87, 97, 100 and 98 %.
- **The first 30 s** are full decodes, at 29–36 % of a core.
- **Memory:** peak resident 116–143 MB.
- **Join stutter:** before the join guard, 1–3 immediate word repeats appeared in previews of the
  77 s and 3.9 min recordings ("to the the release notes", "I looked at at the", "could you
  double double-check"). With `overlapAtJoin`, no immediate repeat appeared in any preview of
  the 32 s, 77 s or 3.9 min recordings.

**Stop with a preview decode in flight (Parakeet, 26 s clip):** the preview ended 5–8 ms after
stop, and the final pass took 0.165–0.168 s median (max 0.211 s) over 100 runs. One 19.4 s final
pass occurred once in an earlier batch and did not reproduce in those 100 runs. The debug app
was running on the same Neural Engine at the time, so outside contention is likely, but that is
**unconfirmed**.

**Whisper** (models downloaded through the app's own `WhisperEngine` into
`~/Documents/huggingface/models/argmaxinc/whisperkit-coreml/`):

| Model | First text | Update interval | Decode median | CPU | Stop → paste ON / OFF (5 s; 26 s clip) | Stop with preview in flight |
|---|---|---|---|---|---|---|
| Base | 1.12–1.21 s | 1.03–1.8 s | 0.12–0.45 s | 6–15 % | 0.21 / 0.14 s; 0.61 / 0.54 s | stops in 9 ms; 0.573 vs 0.522 s |
| Large v3 Turbo | 1.78–1.81 s | 3.3–6.6 s | 0.77–1.23 s | 2–6 % | 0.92 / 0.92 s; 1.93 / 1.92 s | stops in **604 ms**; 2.548 vs 1.963 s |

Final text was identical to live off for both.

## Not verified

- No real-microphone recording in the app.
- Real speech (only TTS audio).
- Several screens, and hover-to-stop with text. Whether a single frame of the expanded content
  in the compact panel shows between the text update and the resize (they are one main-queue
  turn apart) was not checked on screen.
- The "Voice note" card was checked only in captures of the real panel (no behind-window blur in
  them, no live motion), not in the debug app.
- Onboarding's Try-it with live on.
- Whisper Small.
- Parakeet v3: Ultra only, because the v3 cache lacked `JointDecisionv3.mlmodelc`.

See [open-questions.md](open-questions.md).
