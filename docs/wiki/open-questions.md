# Open questions and untested matrix

Last updated: 2026-11-20. Remove an item (and add a [log](log.md) entry) once someone has tested
it, with the date, machine and macOS version.

## For a human to test

| Area | What to test | Why it is open |
|---|---|---|
| First install | Download the release zip from GitHub in a browser, unzip, move to Applications, open. Note what Gatekeeper shows and what the user must do. | Releases are self-signed and not notarized. Never tested from a real download. The README's Install section now gives Apple's "Open Anyway" steps (System Settings → Privacy & Security), checked against Apple's support page on 2026-11-20, not on a real download. |
| Upgrade from 0.0.4 | Let 0.0.4 auto-update to the next release. Then check: Parakeet v3 is kept (no Ultra download), the v3 cache is moved (`parakeet-tdt-0.6b-v3-coreml` gone, only ~12 MB downloaded), a stored Whisper Medium becomes Large v3 Turbo, history is readable, permissions still granted. | Each piece is unit-tested; the whole path through the 0.0.4 updater is not. See [transcription-engines.md](transcription-engines.md), [build-and-release.md](build-and-release.md#auto-updater). |
| Media pause, other players | Spotify, Apple Music, Safari, real YouTube (Chrome and Safari). Pause and resume, already paused, nothing playing, two sources. | Only Chrome and VLC on macOS 27.2 were tested ([media-pause.md](media-pause.md)). Spotify was not installed. |
| Media pause, other macOS | macOS 14, 15 (before and after 15.4), 26. Expected: works, or fails closed (does nothing). It must never start playback. | MediaRemote entry points differ before 15.4; `MRNowPlayingRequest` may be missing. |
| Live transcription (debug build only) | In a locally built production bundle (`make ci SIGN_IDENTITY=`; it shares the installed release's defaults and ⌥Space, so quit the release first), with `liveTranscriptionEnabled` stored as true: no toggle in Settings › General or onboarding, and no live text in the overlay. In the debug app: real voice, real microphone, short and long (> 2 min) dictations, French and English; Parakeet v3 and Ultra, Whisper Tiny and Base; overlay on several screens; hover-to-stop with text; onboarding's Try-it with live on. Check overlay text == delivered text. | Production hiding is unit-tested only, never checked in a running production bundle. The feature itself was measured on `say` audio in a harness only (Parakeet Ultra, Whisper Base and Large v3 Turbo) ([live-transcription.md](live-transcription.md)). |
| Onboarding | First launch with no model; Grant prompts turning to Granted; the Try it recording with the button and the hotkey; replay while menu-bar-only. | Agents could not grant microphone/Accessibility to the debug app ([onboarding-and-settings.md](onboarding-and-settings.md)). |
| Models | Clean first download of Parakeet Ultra and Whisper Large v3 Turbo through the app. | Identifiers were checked against Hugging Face only. |
| Transcription failure | Make an engine fail during a real dictation (hard to provoke; e.g. delete the loaded model's files while the app runs). Expect: overlay dismissed, menu error line "Transcription failed. Try again.", no-result sound, nothing pasted or saved. | Unit-tested only (`TranscriptionFailureTests`), with an unloaded `AsrManager`. |
| Debug flavor visuals | The orange band on the menu bar icon in light and dark menu bars, in its three states (normal, mic.slash, download). | Pixel tests and contact-sheet renders only; no screen capture. |
| Recording overlay | After fix/overlay-and-debug-marker: live text in the real app (panel grows, rounded corners, bars row visible, two lines wrap), and the red dot still during a Try-it recording. | Reproduced and checked with the real panel in a harness and `OverlayWindowTests`, not in the debug app. |
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
