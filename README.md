<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="NanoWhisper icon">
</p>

<h1 align="center">NanoWhisper</h1>

<p align="center">
  <a href="https://github.com/Xavierdesousa/NanoWhisper/actions/workflows/ci.yml"><img src="https://github.com/Xavierdesousa/NanoWhisper/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://github.com/Xavierdesousa/NanoWhisper/releases/latest"><img src="https://img.shields.io/github/v/release/Xavierdesousa/NanoWhisper" alt="Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/swift-6.2%2B-orange" alt="Swift">
  <a href="https://github.com/Xavierdesousa/NanoWhisper/blob/main/LICENSE"><img src="https://img.shields.io/github/license/Xavierdesousa/NanoWhisper" alt="License"></a>
</p>

<p align="center">
  On-device speech-to-text for macOS. Press a shortcut, talk, get text.
</p>

<p align="center">
  Local. Fast. Free. No cloud. No API keys. No subscription.
</p>

## Features

| | |
|---|---|
| **Dual engine** | [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) via [FluidAudio](https://github.com/FluidInference/FluidAudio) (fastest, 25 European languages) or Whisper via [WhisperKit](https://github.com/argmaxinc/argmax-oss-swift) (99 languages) — both run on-device via CoreML |
| **Global shortcut** | Customizable hotkey (default **⌥ Space**) to start/stop recording from anywhere |
| **Recording overlay** | Small dark capsule with a scrolling waveform of your voice, a timer and a stop button; it then says "Pasted" or "No speech detected" |
| **Auto-paste** | Transcribed text goes straight to your clipboard and active text field |
| **Encrypted history** | Transcriptions stored locally with AES-256-GCM, key derived from your Mac's hardware UUID: protects the file at rest (a copy, a backup) and from casual reading, not from other software running under your account |
| **Media auto-pause** | Pauses playing media during recording, resumes after transcription |
| **Auto-updater** | Checks GitHub releases hourly, one-click install from the menubar |
| **Menubar app** | Lives in your menubar, no dock icon, stays out of your way |
| **Sound feedback** | Audio cues on record start, stop, and empty transcription |
| **Onboarding** | One window at first launch: a welcome, a setup page (permissions, the speech model downloading, the shortcut, four settings) and a test dictation |
| **Launch at login** | Start with macOS, ready when you are |

## Install

Download the latest `.zip` from [**Releases**](https://github.com/Xavierdesousa/NanoWhisper/releases/latest), unzip, and drag `NanoWhisper.app` to your Applications folder.

Releases are signed with a self-signed certificate and are **not notarized** by Apple, so macOS blocks the first launch. To allow it once ([Apple's instructions](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)):

1. Open `NanoWhisper.app`. macOS shows a warning; close it (do not move the app to the Trash).
2. Open **System Settings → Privacy & Security** and scroll to **Security**. Next to the message about NanoWhisper, click **Open Anyway** (shown for about an hour after the attempt), then enter your login password.
3. Open NanoWhisper again. From then on it opens normally.

Alternatively, in Terminal: `xattr -dr com.apple.quarantine /Applications/NanoWhisper.app`. Both only allow this app; there is no need to change Gatekeeper's global settings.

On first launch, an onboarding window asks for the microphone and pasting permissions, downloads the speech model (Parakeet Ultra, about 630 MB) while you check the shortcut and settings, and lets you try one dictation; nothing from that test is pasted or saved.

## Usage

| Action | How |
|---|---|
| Start/stop recording | **⌥ Space** (default) or menubar → Start Dictation |
| Stop via overlay | Hover the overlay → click stop |
| Open history | Menubar → History… |
| Open settings | Menubar → Settings… (⌘,) |
| Quit | Menubar → Quit |

Settings has one pane per topic: **General** (shortcut, open at login, sounds, pausing media, history), **Engine** (speech model, its download, Whisper language and vocabulary, removing unused models), **Recorder** (where the recorder appears; live transcription in debug builds), **Permissions**, **Advanced** (updates, debug options).

## Permissions

| Permission | Why |
|---|---|
| **Microphone** | Record audio for transcription |
| **Accessibility** | Paste text into the active field (simulates ⌘V) |

## Models

### Parakeet

Transcribes 25 European languages and detects the language automatically. Two versions:

| Version | Download | Notes |
|---|---|---|
| **Parakeet Ultra** (Recommended) | ~630 MB | Post-trained v3 ([moondream/parakeet-ultra](https://huggingface.co/moondream/parakeet-ultra)): same speed, fewer errors. The default. |
| **Parakeet TDT 0.6B v3** | ~480 MB | NVIDIA's original model. Still available in Settings. |

Word error rate published by FluidAudio ([benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/ParakeetUltra.md)): LibriSpeech test-clean 2.27 % (v3) → 2.13 % (Ultra); FLEURS, mean of 24 languages, 14.81 % → 11.67 %.

**Updating from 0.0.5 or earlier on Parakeet v3:** NanoWhisper moves you to Parakeet Ultra once. If v3 is on your Mac, you keep dictating with it while Ultra downloads in the background (the menu and Settings show the progress); the app switches when Ultra is ready. Offline, it keeps v3 and tries again at the next launch. v3 stays on disk and in the list: if you pick it again in Settings, you stay on it.

### Whisper

- **Model size** — Base (~150 MB), Small (~490 MB), Large v3 Turbo (~630 MB, Recommended: OpenAI's faster large-v3-turbo, accuracy close to Large v3). Tiny, Medium and Large v3 are no longer offered: a saved Tiny becomes Base, a saved Medium or Large v3 becomes Large v3 Turbo (the old model keeps working until the new one is downloaded; language and vocabulary hint are kept).
- **Language** — auto-detect, or pick the spoken language (more reliable on short clips)
- **Vocabulary hint** — words or names passed to Whisper as a prompt to bias recognition of technical terms or names

### Disk space

Models that NanoWhisper no longer offers are deleted automatically once their replacement is loaded (the 0.0.4 copy of Parakeet v3, Whisper Tiny, Medium and Large v3). Whisper models are cleaned up this way only while you use Whisper, so Parakeet users never see a request to access the Documents folder. Models you can still select are never deleted automatically: **Settings → Engine → Remove Unused Models…** lists every NanoWhisper model on disk except the one in use, with sizes, and deletes them after you confirm. Only folders NanoWhisper itself downloads are ever touched.

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon
- ~1 GB disk (varies by model)

## Build from Source

Requires Xcode with Swift 6.2 or later (the package uses SwiftPM traits to build FluidAudio without its TTS and diarization modules).

```bash
git clone https://github.com/Xavierdesousa/NanoWhisper.git
cd NanoWhisper
make app
```

`make app` builds, signs and launches **NanoWhisper Debug**, a separate app that can run next to the released NanoWhisper:

| | NanoWhisper (release) | NanoWhisper Debug (local builds) |
|---|---|---|
| Bundle | `NanoWhisper.app`, `com.moonji.nanowhisper` | `NanoWhisper Debug.app`, `com.moonji.nanowhisper.debug` |
| Default shortcut | ⌥ Space | ⌃⌥ Space |
| Settings, permissions, login item | own | own (granted separately) |
| History | `~/Library/Application Support/NanoWhisper` | `~/Library/Application Support/NanoWhisper Debug` |
| Auto-updater | on | off |
| Live transcription (beta) | not available | available in Settings → Recorder (text in the overlay while you speak) |
| Markers | — | "DEBUG" banner on the icon, orange band across the menubar icon, version and commit in the menu |

Downloaded models are shared by both. `make app` only stops a running NanoWhisper Debug, never the release app.

| Target | Builds | Notes |
|---|---|---|
| `make app` | Debug | Launches it |
| `make onboarding` | Debug | Launches it with `--onboarding` (shows onboarding again; settings and models are kept) |
| `make run` | Debug | Runs the executable without a bundle |
| `make ci` | Release | `NanoWhisper.app`, no launch (used by the release workflow) |
| `make release` | Release | Also creates `NanoWhisper-v<version>.zip`; launches nothing |
| `make notarize` | Release | Notarizes and staples (`NOTARY_PROFILE=<keychain profile>`) |
| `make publish` | Release | Creates the GitHub release for tag `v<version>` with `gh` (fallback when CI can't run); needs a clean tree and the tag pushed to `origin` at HEAD |
| `make test`, `make clean` | | |

Signing uses `SIGN_IDENTITY` (default `Moonji Dev`; set it empty for ad-hoc signing).

Contributing, with or without a coding agent: start with [`CLAUDE.md`](CLAUDE.md) (commands, rules, source map) and the project wiki in [`docs/wiki/index.md`](docs/wiki/index.md) (design decisions, measurements, untested areas).

## License

[GPL v3](LICENSE) — free to use, modify, and redistribute. Forks must remain open-source under the same license.
