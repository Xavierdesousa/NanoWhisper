# Log

Dated entries, newest first. One entry per change to the project or to this wiki: what changed,
why if not obvious, and the PR. Older history is summarized from `git log`.

## 2026-11-19

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
