# Open questions and untested matrix

Last updated: 2026-11-20. Remove an item (and add a [log](log.md) entry) once someone has tested
it, with the date, machine and macOS version.

## For a human to test

| Area | What to test | Why it is open |
|---|---|---|
| First install | Download the release zip from GitHub in a browser, unzip, move to Applications, open. Note what Gatekeeper shows and what the user must do. | Releases are self-signed and not notarized. Never tested from a real download. The README's Install section does not mention Gatekeeper. |
| Upgrade from 0.0.4 | Let 0.0.4 auto-update to the next release. Then check: Parakeet v3 is kept (no Ultra download), the v3 cache is moved (`parakeet-tdt-0.6b-v3-coreml` gone, only ~12 MB downloaded), a stored Whisper Medium becomes Large v3 Turbo, history is readable, permissions still granted. | Each piece is unit-tested; the whole path through the 0.0.4 updater is not. See [transcription-engines.md](transcription-engines.md), [build-and-release.md](build-and-release.md#auto-updater). |
| Media pause, other players | Spotify, Apple Music, Safari, real YouTube (Chrome and Safari). Pause and resume, already paused, nothing playing, two sources. | Only Chrome and VLC on macOS 27.2 were tested ([media-pause.md](media-pause.md)). Spotify was not installed. |
| Media pause, other macOS | macOS 14, 15 (before and after 15.4), 26. Expected: works, or fails closed (does nothing). It must never start playback. | MediaRemote entry points differ before 15.4; `MRNowPlayingRequest` may be missing. |
| Live transcription (debug build only) | In a locally built production bundle (`make ci SIGN_IDENTITY=`; it shares the installed release's defaults and ⌥Space, so quit the release first), with `liveTranscriptionEnabled` stored as true: no toggle in Settings › General or onboarding, and no live text in the overlay. In the debug app: real voice, real microphone, short and long (> 2 min) dictations, French and English; Parakeet v3 and Ultra, Whisper Tiny and Base; overlay on several screens; hover-to-stop with text; onboarding's Try-it with live on. Check overlay text == delivered text. | Production hiding is unit-tested only, never checked in a running production bundle. The feature itself was measured on `say` audio in a harness only (Parakeet Ultra, Whisper Base and Large v3 Turbo) ([live-transcription.md](live-transcription.md)). |
| Onboarding | First launch with no model; Grant prompts turning to Granted; the Try it recording with the button and the hotkey; replay while menu-bar-only. | Agents could not grant microphone/Accessibility to the debug app ([onboarding-and-settings.md](onboarding-and-settings.md)). |
| Models | Clean first download of Parakeet Ultra and Whisper Large v3 Turbo through the app. | Identifiers were checked against Hugging Face only. |
| Debug flavor visuals | The orange dot on the menu bar icon in light and dark menu bars. | Pixel tests only; no screen capture. |
| Release workflow | One tag push on the `xcode-27` runner since PR #14. | Not run since the workflow changed. |

## Open decisions

- Live transcription in production: hidden since 2026-11-20 because of overlay design problems
  ([live-transcription.md](live-transcription.md#debug-build-only)). To ship it, flip
  `BuildFlavor.supportsLiveTranscription` once the design is settled.

- Notarization with a Developer ID: planned "long term", not now. Note that the
  `mediaremote-adapter` option for media pause was rejected because the app is not notarized
  ([media-pause.md](media-pause.md#why-it-is-this-way)).
- CodeQL: return when it supports Swift 6.4 ([ci-and-review.md](ci-and-review.md)).
- Release runner: `xcode-27` is a preview image; switch to `macos-27` when that label exists.
