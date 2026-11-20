# Log

Dated entries, newest first. One entry per change to the project or to this wiki: what changed,
why if not obvious, and the PR. Older history is summarized from `git log`.

## 2026-11-20

- **Overlay and debug marker fixes** (`fix/overlay-and-debug-marker`), from the maintainer's
  test of the debug build:
  - **Live text overlay broken in the real app:** the panel stayed compact (123×40 pt) while
    its content grew to 384×82 pt, because `fittingSize` was read before SwiftUI re-rendered.
    The panel now follows the content's ideal size (`OverlayHostingView`), without an animated
    resize. Reproduced and verified with the real panel in a harness and `OverlayWindowTests`.
  - **Record dot sliding in Try-it:** `PulsingDot`'s `.repeatForever` animation was attached to
    the whole view, so when `onAppear` ran during the panel's first layout (recording started
    from a SwiftUI button in an active app) it also animated the dot's position, forever. The
    animation is now scoped to scale and opacity (`animation(_:body:)`); the panel is also first
    laid out at its real size.
  - **Debug menu bar marker:** an orange band across the bottom of the glyph replaces the dot.
  - **Try it:** "Record a Test or press <shortcut>" with the shortcut as a key cap; the hotkey path
    to a test recording checked in code ([onboarding-and-settings.md](onboarding-and-settings.md)).
  - **Planned (maintainer):** a redesign pass of onboarding, Settings and the overlay next; the
    feedback sounds to be replaced with new original ones ([open-questions.md](open-questions.md)).
  - Pages: [live-transcription.md](live-transcription.md), [testing-and-verification.md](testing-and-verification.md)
    (capturing a real window), [build-and-release.md](build-and-release.md), README.

- **Cleanup** (PR #19, `chore/cleanup`):
  - **History extracted** from `AppState` into `HistoryStore` (`HistoryStore.swift`, with
    `HistoryEntry`, `TranscriptionDebugInfo`, `HistoryCrypto`); temp-recording deletion into
    `TemporaryRecordings`. File format and key unchanged (key derivation pinned by a test).
    One behavior tightening: while history is unavailable, no write happens at all (an open
    History window could overwrite an unreadable file before); saves are now atomic. Stale
    Keychain comments fixed. The zero-then-delete of recordings uses throwing `FileHandle` calls
    (the old ones raise an Objective-C exception on I/O errors) and is documented as best effort.
    [architecture.md](architecture.md#history-storage).
  - **Transcription errors surfaced:** `Transcriber` logs the error and returns
    `TranscriptionResult.failure` (`TranscriptionFailure.engineError` / `.noEngine`) instead of
    empty text; `DictationOutcome.failed` puts "Transcription failed…" in the menu error line
    (overlay still dismissed, no-result sound). An empty result is unchanged ("Empty
    transcription").
  - **README:** Swift badge 6.2+; Gatekeeper first-launch steps for the non-notarized release
    (Apple's "Open Anyway", or `xattr -dr com.apple.quarantine` on the app only); honest wording
    for the history key; debug-only live transcription in the flavor table.
  - **Leftovers:** `Subprocess` comments no longer mention perl. Remaining mentions of perl,
    `mediaremote-adapter`, System Audio Recording, CodeQL, Whisper Medium and sliding-window
    streaming are deliberate (rejected-alternative records in the wiki, the Medium migration in
    code and README).
  - Pages: [architecture.md](architecture.md), [testing-and-verification.md](testing-and-verification.md),
    [open-questions.md](open-questions.md), `CLAUDE.md` source map.

- **Live transcription made debug-only** (PR #18, merged as a77106d): the maintainer found design
  problems in the overlay, so production hides the toggle and never starts a live session, even
  with `liveTranscriptionEnabled` stored on (the value is kept). One flag:
  `BuildFlavor.supportsLiveTranscription`. Pages: [live-transcription.md](live-transcription.md#debug-build-only),
  [build-and-release.md](build-and-release.md) (flavor table), [open-questions.md](open-questions.md).

## 2026-11-19

- **PR #16 updated** (live transcription):
  - **Window cap:** previews of recordings longer than 30 s decode a ≤ 15 s window after a
    frozen boundary, which keeps CPU at ~23 % of one core instead of reaching a full core after
    2.5 min.
  - **Join guard:** stops repeated words at window joins.
  - **Whisper availability:** offered only for Tiny and Base. Large v3 Turbo needs ~0.6 s to
    stop a preview decode.
  - **Integration:** wired to `SettingsContext` and `GeneralSettingsSection` (#15) and to
    `DictationDestination` (the Try-it box gets the final text).
  - **Downloads:** Whisper Base and Large v3 Turbo were downloaded into WhisperKit's default
    cache through the app's `WhisperEngine`, on the maintainer's request.
  - **Pages:** [live-transcription.md](live-transcription.md) rewritten;
    [transcription-engines.md](transcription-engines.md) gained the Whisper cache path and the
    Turbo measurements.
- **Wiki created** (`docs/llm-wiki` branch): `CLAUDE.md` and these pages, from the code on `main`
  (29e84c9), PRs #11–#16 and the maintainer's notes. `swift test` on `main`: 174 tests in 20
  suites passed (Swift 6.4, macOS 27.2); `ViewRender` renders passed.
- **PR #16 open**: live transcription (beta) by re-decoding the growing buffer. Documented in
  [live-transcription.md](live-transcription.md) as not merged. Sliding-window streaming was
  measured and rejected.
- **#15 merged** (29e84c9): onboarding rebuilt as five steps sharing sections with Settings;
  draft/apply rule; first launch no longer downloads before the user sees the choice; replay via
  Settings, `--onboarding`, `--reset-onboarding`, `make onboarding`. Real Microphone status in
  Settings. [onboarding-and-settings.md](onboarding-and-settings.md)
- **#12 merged** (846c466): media pause through Now Playing with osascript/JXA and explicit
  pause/play; media key, CoreAudio tap and the System Audio Recording permission removed.
  `mediaremote-adapter` tried and dropped (Gatekeeper on a non-notarized first install).
  [media-pause.md](media-pause.md)
- **#14 merged** (66ef417): NanoWhisper Debug flavor (`BuildFlavor`), Makefile rewrite,
  `make publish` and `make release-zip-name`, release workflow tolerates an existing release.
  Also an inter-process `flock` around the legacy cache migration (race reproduced 13/40).
  [build-and-release.md](build-and-release.md)
- **#11 merged** (7770591): CI and release on the `xcode-27` preview runner (Swift 6.4);
  CodeQL workflow removed; `LSMinimumSystemVersion` 13.0 → 14.0. [ci-and-review.md](ci-and-review.md)
- **#13 merged** (ac69c71): FluidAudio 0.12.4 → 0.18.3 (traits off), WhisperKit 0.17.0 → 1.1.1
  (`argmax-oss-swift`); Parakeet Ultra (default for new installs), Whisper Large v3 Turbo, Medium
  removed; v3 cache moved to the new folder; serialized transcriptions with a configuration
  snapshot; Swift 6.4 isolation errors fixed with `WhisperEngine`; vocabulary hint now actually
  used. [transcription-engines.md](transcription-engines.md)

## Before 2026-11-19 (from `git log`)

- 2026-04-03: v0.0.4 (current release). README rewritten.
- 2026-03-26: #10, first media pause (CoreAudio tap + Play/Pause key). Replaced by #12.
- 2026-03-25: unit tests and CI (#7), CodeQL workflow (#9), release workflow, CI on `macos-26`.
- 2026-03-24: WhisperKit engine (#6), auto-updater, GPL v3.
- 2026-03-20: onboarding (#3), recording overlay, security audit (#4): encrypted history, hardened
  runtime, secure deletion; Keychain key replaced by an HKDF key from the hardware UUID.
- 2026-03-19: Python/NeMo daemon replaced by FluidAudio Core ML (#2).
- 2026-03-18: initial commit; signing with the "Moonji Dev" certificate.
