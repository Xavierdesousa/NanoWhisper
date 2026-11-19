# Live transcription (beta) — NOT MERGED YET

> **Status: PR #16 (`feat/live-transcription`) is open. Nothing on this page exists on `main`.**
> Written 2026-11-19 from the PR description and the branch at 562ddb8. File and type names
> below refer to that branch. Re-check everything when the PR merges, then remove this banner.

## What it is

An opt-in setting, "Live transcription (beta)" (Settings › General, off by default; on the
branch the `UserDefaults` key is `liveTranscriptionEnabled`). While the user speaks, the
recording overlay shows the text recognized so far. Nothing is typed during the recording.
On `main` today, `GeneralSettingsSection` only has a placeholder comment where the toggle goes.

**The maintainer's rule: the overlay text and the pasted text must be identical.** At stop, the
recording is transcribed exactly as with live off; the overlay then shows that final text, which
is the string pasted and stored in history.

## Design: re-decode the growing buffer

- **Audio:** `AudioRecorder` hands the live session a copy of the same 16 kHz samples it writes
  to the WAV. The tap only enqueues; samples accumulate off the audio thread (`LiveAudioBuffer`).
- **Preview decodes** (`LiveTranscriptionSession`): once 1 s of audio has followed the first
  sound (leading silence skipped), the session decodes **all audio so far** with the ordinary
  batch path, on a snapshot of the engine and settings the final pass uses
  (`Transcriber.makePreviewDecoder()`).
- **Cadence** (`LivePreviewSchedule`): one decode at a time; starts spaced by
  `max(1 s, 4 × last decode duration)`, so wall-clock duty stays ≤ 25 % and decodes never queue.
- **Display** (`LiveTranscript`): the leading words two consecutive decodes agree on are
  "stable" (primary color); the rest is the dimmed tail; at stop the final text replaces both.
- **At stop:** the decode in flight is cancelled and its result ignored; the normal final pass
  runs on the WAV; its text is shown and pasted.
- **Partials never delay or reorder real transcriptions:** they never enter the `Transcriber`
  queue; they are skipped while `Transcriber.pendingTranscriptions > 0`; Parakeet previews run
  on their own `AsrManager` sharing the batch models' `MLModel` instances (as FluidAudio's
  parallel chunk workers do).
- **Failure:** a failed preview stops the preview and clears its text (logged); the recording
  and its final pass are unaffected.
- **Whisper:** same seam through `WhisperEngine.transcribe(audioArray:options:prompt:)`.
- Lifecycle glue is in `AppState+LiveTranscription.swift` (`beginLiveTranscription()`,
  `cancelLiveTranscription()`, `showFinalLiveText(_:for:)`).
- Overlay: grows once to 384×82 pt when text appears, keeps its top edge and center, shows the
  last two lines; Reduce Motion disables the resize animation and dot pulse.

## Why: the rejected alternative

FluidAudio's sliding-window **streaming** engine was measured and rejected: first text only after
~5 s, and stray sentence breaks at window edges that ended up in the pasted text. An earlier
version of PR #16 used it; it was removed with its token-revision code and batch fallback.
Re-decoding with the batch engine gives the same model and settings as the final pass, so the
preview converges on the text that will be pasted.

## Measurements (PR #16, Parakeet Ultra, harness, `say` audio fed in real time as 85 ms chunks)

| Clip | First text | Decode median / max | CPU (% of one core) | Final == live off | Stop → paste ON / OFF |
|---|---|---|---|---|---|
| en 3.2 s | 1.14 s | 0.067 / 0.073 s | 5.6 | yes | 0.060 / 0.048 s |
| en 25.8 s | 1.12 s | 0.114 / 0.180 s | 21.4 | yes | 0.155 / 0.143 s |
| fr 32.2 s | 1.13 s | 0.174 / 0.206 s | 30.9 | yes | 0.193 / 0.179 s |
| en 77.4 s | 1.11 s | 0.196 / 0.333 s | 53.5 | yes | 0.377 / 0.289 s |
| en 3.9 min | 1.15 s | 0.319 / 0.790 s | 81.4 | yes | 0.668 / 0.638 s |

(Selection; the PR has all 10 clips.) Final text was identical to live off on all 10. CPU reaches a
full core after ~2.5 min of recording. Peak resident memory 106–134 MB up to 77 s, 160 MB at
3.9 min. Stable words that later changed were mostly sentence-boundary punctuation.

## Open decisions (for the maintainer)

1. CPU on long recordings: suggested cap past ~60 s (decode only the last ~30 s, freeze earlier
   preview text). Not built.
2. Whisper: keep live enabled unmeasured, or disable it until measured.
3. Stop → paste costs up to +0.1 s when a long preview decode is in flight at stop.

## Not verified

No real-microphone recording in the app; real speech; the resize animation; several screens;
hover-to-stop with text; Whisper live preview (no Whisper model on disk); Parakeet v3 (Ultra only).
See [open-questions.md](open-questions.md).
