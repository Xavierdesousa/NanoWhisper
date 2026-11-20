# Open questions and untested matrix

Last updated: 2026-11-20. Remove an item (and add a [log](log.md) entry) once someone has tested
it, with the date, machine and macOS version.

## For a human to test

| Area | What to test | Why it is open |
|---|---|---|
| First install | Download the release zip from GitHub in a browser, unzip, move to Applications, open. Note what Gatekeeper shows and what the user must do. | Releases are self-signed and not notarized. Never tested from a real download. The README's Install section now gives Apple's "Open Anyway" steps (System Settings → Privacy & Security), checked against Apple's support page on 2026-11-20, not on a real download. |
| Upgrade from 0.0.4 | Let 0.0.4 auto-update to the next release. Then check: if the legacy v3 cache is accepted as complete, v3 starts right away, Ultra downloads in the background and the app switches to it; otherwise Ultra downloads in the foreground (no v3 start). In both cases `parakeet-tdt-0.6b-v3-coreml` is gone, a stored Whisper Medium becomes Large v3 Turbo (Medium works meanwhile, then its folder is deleted), history is readable, permissions still granted. | Each piece is unit-tested; the whole path through the 0.0.4 updater is not. See [transcription-engines.md](transcription-engines.md), [build-and-release.md](build-and-release.md#auto-updater). |
| Model migration (from 0.0.5) | On a 0.0.5 install on Parakeet v3 with Ultra not on disk: dictation works at once on v3; the menu and Settings › Model show "Downloading the improved model (~630 MB)… N%"; dictating during the download works; a recording in progress when Ultra finishes is transcribed with v3, the next one with Ultra; v3 stays on disk and in the picker. Offline: v3 keeps working, Settings says Ultra will download at next launch, nothing in the menu. Re-select v3 in Settings, relaunch: still v3. With production 0.0.5 (on v3) and the new debug build side by side: the debug build does not delete anything production uses. "Remove Unused Models…": list, sizes, total, Documents prompt, access denied, freed space. On a Whisper Tiny / Large v3 install: replaced by Base / Turbo with the old one working until then, then its folder deleted. | Unit tests in temporary directories and offscreen renders only; nothing was run against the real caches or apps, by design ([transcription-engines.md](transcription-engines.md#known-limits--not-verified)). |
| Media pause, other players | Spotify, Apple Music, Safari, real YouTube (Chrome and Safari). Pause and resume, already paused, nothing playing, two sources. | Only Chrome and VLC on macOS 27.2 were tested ([media-pause.md](media-pause.md)). Spotify was not installed. |
| Media pause, other macOS | macOS 14, 15 (before and after 15.4), 26. Expected: works, or fails closed (does nothing). It must never start playback. | MediaRemote entry points differ before 15.4; `MRNowPlayingRequest` may be missing. |
| Live transcription (debug build only) | In a locally built production bundle (`make ci SIGN_IDENTITY=`; it shares the installed release's defaults and ⌥Space, so quit the release first), with `liveTranscriptionEnabled` stored as true: no toggle in Settings › General or onboarding, and no live text in the overlay. In the debug app: real voice, real microphone, short and long (> 2 min) dictations, French and English; Parakeet v3 and Ultra, Whisper Base; overlay on several screens; hover-to-stop with text; onboarding's Try-it with live on. Check overlay text == delivered text. | Production hiding is unit-tested only, never checked in a running production bundle. The feature itself was measured on `say` audio in a harness only (Parakeet Ultra, Whisper Base and Large v3 Turbo) ([live-transcription.md](live-transcription.md)). |
| Onboarding | First launch with no model; Grant prompts turning to Granted; the Try it recording with the button and the hotkey; replay while menu-bar-only. | Agents could not grant microphone/Accessibility to the debug app ([onboarding-and-settings.md](onboarding-and-settings.md)). |
| Models | Clean first download of Parakeet Ultra and Whisper Large v3 Turbo through the app. | Identifiers were checked against Hugging Face only. |
| Transcription failure | Make an engine fail during a real dictation (hard to provoke; e.g. delete the loaded model's files while the app runs). Expect: overlay dismissed, menu error line "Transcription failed. Try again.", no-result sound, nothing pasted or saved. | Unit-tested only (`TranscriptionFailureTests`), with an unloaded `AsrManager`. |
| Debug flavor visuals | The orange band on the menu bar icon in light and dark menu bars, in its three states (normal, mic.slash, download). | Pixel tests and contact-sheet renders only; no screen capture. |
| Recording overlay ("Voice note") | In the debug app: the HUD blur over light and busy wallpapers, the waveform with a real microphone (is the 0.06 silence floor right?), the capsule's breathing and the row's glide, hover-to-stop, "Pasted" / "No speech detected", Try-it (capsule still), each recorder position (Settings › Recorder), several screens, Reduce Motion and Reduce Transparency on. | Checked only in captures of the real panel from `OverlayWindowTests` (no blur, no shadow, no motion), compared with the design rendered in headless Chrome. |
| Settings window (redesign) | Open Settings from the menu and with ⌘, during onboarding; switch panes (window resizes, title follows, last pane reopens); Engine: Change…, switch engine, Revert, Download & Apply, Whisper language and vocabulary applied at once; Remove Unused Models… sheet; Permissions pane updates while open and stops polling when closed; violet tint on switches; dark mode; VoiceOver on key caps and engine rows. | Offscreen renders of the real window and a sizing test only ([onboarding-and-settings.md](onboarding-and-settings.md#settings-window-toolbar-panes)). |
| Menu bar menu (redesign) | Every state in the real menu: the key caps and "Microphone is off" aligned with native items, highlight and click on Start Dictation and Finish Setup…, Return on them, the download bar moving while the menu is open, the migration bar, Retry, the update line, debug header. | The menu is AppKit with view-based items; renders are an approximation from the same lines ([architecture.md](architecture.md#menu-bar-menu)). |
| Recovery of interrupted recordings | Hard to provoke without a crash: with the debug app quit, copy a recording of a few seconds as `$TMPDIR/nanowhisper-debug_<UUID>.wav` with its `data` size zeroed, launch the app: once the model is ready, the text appears in History at the file's date; nothing else shows; the file is gone. Also a dictation started right at launch goes first. | Tested with temporary directories and fake transcriptions only ([architecture.md](architecture.md#temporary-recordings)). |
| Stopping a recording (crash fix) | In the debug app: many dictations of a few seconds to 3+ min, live transcription on and off; switch the default input (System Settings › Sound, or connect a Bluetooth headset) during a recording: recording should go on with the new microphone, or stop with "Recording stopped: the microphone changed" and transcribe what was recorded. | The crash was reproduced and the fix checked in harnesses only (built-in microphone, process-local device switch); the stop race is rare per stop, so its absence in the app can only be shown over time ([architecture.md](architecture.md#stopping-the-recorder-crash-of-2026-11-20)). |
| Release workflow | One tag push on the `xcode-27` runner since PR #14. | Not run since the workflow changed. |

## Roadmap after 0.0.5 (from the maintainer, 2026-11-20)

- New feedback sounds (start, stop, empty result) to replace the current ones.
- Stabilize live transcription, mainly its overlay UI, then enable it in production
  (`BuildFlavor.supportsLiveTranscription`).
- Full redesign of onboarding, Settings and the recording overlay.
- A more visual README with screenshots, then a short motion-design demo of the app in use.
- Look into distributing through Homebrew (a cask; check what it requires for an app that is
  not notarized).

## Open decisions

- Whisper default for a new `WhisperSettings` is still Base, while Large v3 Turbo carries the
  "Recommended" badge (Turbo needs 82–93 s to load and ~0.9 s stop → paste on a 5 s clip vs
  0.14 s for Base). Make Turbo the default, or keep Base?
- Other-flavor protection reads the other app's preferences and keeps only its *selected
  engine's* model (plus 0.0.4's legacy v3 copy and a pending migration's fallback). Should
  "Remove Unused Models…" also keep the other flavor's non-selected engine model?

- Transcription failure in onboarding's Try-it box: the failure goes to the menu error line and
  the box returns to its idle state (any earlier test result is cleared). The box itself shows
  no failure message; adding one would need a field in `TryItState`.
- Transcription failure sound: it reuses the no-result sound. A distinct error sound was not
  added.

- Live transcription in production: hidden since 2026-11-20 because of overlay design problems
  ([live-transcription.md](live-transcription.md#debug-build-only)). To ship it, flip
  `BuildFlavor.supportsLiveTranscription` once the design is settled.

- Notarization with a Developer ID: planned "long term", not now. Note that the
  `mediaremote-adapter` option for media pause was rejected because the app is not notarized
  ([media-pause.md](media-pause.md#why-it-is-this-way)).
- CodeQL: return when it supports Swift 6.4 ([ci-and-review.md](ci-and-review.md)).
- Release runner: `xcode-27` is a preview image; switch to `macos-27` when that label exists.
