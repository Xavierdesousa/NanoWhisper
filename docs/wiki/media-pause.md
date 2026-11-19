# Media pause during dictation

Last verified against the code: 2026-11-19 (`main` at 29e84c9). Source: PR #12, PR #10, the
maintainer, and the code.

## What it is

Setting "Pause media during recording" (`AppState.pauseMediaEnabled`, `UserDefaults` key
`pauseMediaEnabled`, off by default). When on, media that is playing is paused while the user
dictates and resumed after the transcription is pasted. It acts on the system **Now Playing**
session (what Control Center shows), so it covers native players and browser tabs. No
permission is needed.

## How it works

Three layers, each replaceable:

1. `MediaController` (`MediaController.swift`, `@MainActor`): the session state machine.
   - `beginSession(pauseMedia:)` at recording start returns immediately; a background check
     calls `pauseIfPlaying()`.
   - `endSession(_:)` after the transcription; when the last open session ends,
     `resumeIfNoSessionOpen()` resumes, once, only what we paused.
   - Sessions span a recording **and** its transcription and may overlap. Media is never
     resumed while a session is open.
   - A session that begins while the previous resume is still being sent waits for that
     resume (`resumeCall`) before reading the state; otherwise it reads "paused", skips the
     pause, and music plays over the new recording.
2. `MediaPlaybackController` protocol (`MediaPlaybackController.swift`), implemented by
   `NowPlayingPlaybackController` (`NowPlayingPlaybackController.swift`):
   - `playbackState()` reads Now Playing and remembers the session it saw;
   - `pause()` sends an explicit pause to that session and remembers it only if the pause was
     issued;
   - `resume()` re-reads Now Playing and sends play only if `shouldResume(paused:now:)`: same
     pid, bundle id, title and unique identifier (`NowPlayingSession.isSameItem(as:)`), and
     still paused.
3. `NowPlayingSource` protocol, implemented by the actor `MediaRemoteJXA`
   (`MediaRemoteJXA.swift`): runs `/usr/bin/osascript -l JavaScript -e <script> <args>` through
   `Subprocess` (`Subprocess.swift`).
   - `get` prints `null` or one JSON object (pid, bundle id, title, unique identifier, playing).
   - `send 0|1 PID TITLE ID` re-checks inside the script that the same pid still owns Now
     Playing with the same item and the opposite state, then calls
     `MRMediaRemoteSendCommand` with play (0) or pause (1). The toggle (2) is never used.
   - Calls are serialized by a `SerialGate` (the actor is reentrant), and each call first waits
     for the previous send's process (`settlePendingSend()`).

**Fail closed.** A missing class, selector or symbol, a value of the wrong type, a non-zero
exit, anything on stderr, unparsable output or the 3 s timeout gives
`NowPlayingReading.failed` → `MediaPlaybackState.unknown` → nothing is done.

## Gotchas found (2026-11-19, macOS 27.2)

- **`Process` passes arguments in decomposed Unicode (NFD).** A title with an accent never
  matched the one read back, so the pause was never sent. Titles and identifiers therefore
  travel as `none` or `some:` + base64 of their UTF-8 (`MediaRemoteJXA.identityArgument(_:)`).
  Found end to end with the title `Ça "quoted" it's $HOME; …`.
- **A play with no Now Playing owner launches Music.app.** Hence the owner re-check inside the
  script just before sending.
- **osascript drops the command if it exits right after sending.** The script prints `sent`,
  then stays alive until the player's state reflects it (20–80 ms measured, at most 1 s).
  `send` returns at `sent`; the process is reaped in the background and killed after 3 s.
- JXA returns `undefined` for a missing selector instead of failing, so every value is checked
  (`need(...)` in the script).
- Since macOS 15.4 only Apple-signed processes may use MediaRemote; `osascript` is one, which
  is why the call goes through it.

Measured on macOS 27.2: `get` 58–111 ms, `send` 57–116 ms until issued; pause issued
149–205 ms after `beginSession`, resume 134–158 ms after the end (Chrome and VLC).

## Why it is this way

**v1 (PR #10, 2026-03-26):** sampled system audio with a CoreAudio process tap
(`AudioHardwareCreateProcessTap`), then simulated the Play/Pause media **key** with `CGEvent`.
Problems: the key is a blind toggle, so it sometimes resumed paused music or launched Music.app
(user reports), and the tap required the "System Audio Recording" permission
(`NSAudioCaptureUsageDescription`). Both are removed.

**Alternatives rejected (2026-11-19):**

| Alternative | Why rejected |
|---|---|
| Keep the media key, improve detection | The toggle itself is the bug. |
| Perl-based `mediaremote-adapter`, vendored | Works on macOS 27.2 (measured), but ships a native framework; on a quarantined first install of a non-notarized app, Gatekeeper refused to load it into perl and showed an alert. Intermediate commits of PR #12 added then removed it. |
| Remove the quarantine attribute programmatically | Bypasses Gatekeeper. Refused. |
| FineTune-style per-process audio taps | Mutes instead of pausing, needs the System Audio Recording permission, and has documented VoIP and Bluetooth issues. |

**Chosen:** osascript/JXA calling MediaRemote with explicit pause and play only, failing closed
to "unknown → do nothing". Nothing ships in the bundle, so there is nothing to sign, notarize or
for Gatekeeper to assess. Reading through `MRNowPlayingRequest` follows Stephen Kaplan's
published snippet (credited in `MediaRemoteJXA`).

Review decisions kept deliberately (PR #12):
- `isSameItem` compares the unique identifier only when the player publishes one; requiring it
  would stop resume for VLC and Chrome, which publish none.
- No per-session tracking of who asked for pausing in the `pauseIfPlaying` guard: only
  reachable by turning the setting off within the detection window; worst case is one pause
  that is still resumed.

## Known limits

- **Private API.** MediaRemote is private; a macOS update may break it. The script should then
  fail closed (auto-pause silently does nothing), but that has not been observed.
- **One source at a time.** Only the app owning Now Playing (usually the last one started) is
  paused; a second source keeps playing.
- **No resume after a takeover.** If another source takes Now Playing during dictation, the
  paused item is not resumed (deliberate: resume only what we can identify).
- **Untested:** macOS 14–26 (before 15.4 MediaRemote had other entry points and
  `MRNowPlayingRequest` may be missing), Spotify, Safari, Apple Music playback, real YouTube.
  Tested: Chrome tab and VLC on macOS 27.2, through a harness built from the app's sources.
  See [open-questions.md](open-questions.md).
