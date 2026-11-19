# NanoWhisper wiki

Knowledge base maintained by coding agents: decisions, rejected alternatives, measurements,
gotchas and untested areas that the code alone does not tell. How to maintain it is in
[`CLAUDE.md`](../../CLAUDE.md#the-wiki-docswiki). User-facing documentation is the
[README](../../README.md).

| Page | One line |
|---|---|
| [architecture.md](architecture.md) | Components, the recording pipeline from hotkey to paste, history storage. |
| [transcription-engines.md](transcription-engines.md) | Parakeet and Whisper engines, model choices, cache layout and migration, transcription concurrency. |
| [media-pause.md](media-pause.md) | Pausing media during dictation through Now Playing (osascript/JXA), and why not the media key. |
| [live-transcription.md](live-transcription.md) | Live transcription (beta), PR #16: re-decode the growing buffer, window cap on long recordings, which engines offer it and why. |
| [onboarding-and-settings.md](onboarding-and-settings.md) | Shared settings sections, the draft/apply rule, the onboarding steps, replay switches. |
| [build-and-release.md](build-and-release.md) | Production and debug flavors, signing, distribution, release workflow, auto-updater. |
| [ci-and-review.md](ci-and-review.md) | CI runner, branch protection, PR and merge flow, CodeRabbit CLI review. |
| [testing-and-verification.md](testing-and-verification.md) | Test suites and the techniques that work without a screen: renders, harnesses, Accessibility API. |
| [open-questions.md](open-questions.md) | What a human still has to test, and open decisions. |
| [log.md](log.md) | Dated log of changes to the project and to this wiki. |
