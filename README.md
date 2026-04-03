<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="NanoWhisper icon">
</p>

<h1 align="center">NanoWhisper</h1>

<p align="center">
  <a href="https://github.com/Xavierdesousa/NanoWhisper/actions/workflows/ci.yml"><img src="https://github.com/Xavierdesousa/NanoWhisper/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://github.com/Xavierdesousa/NanoWhisper/releases/latest"><img src="https://img.shields.io/github/v/release/Xavierdesousa/NanoWhisper" alt="Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/swift-6.0-orange" alt="Swift">
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
| **Dual engine** | [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (fastest) or [WhisperKit](https://github.com/argmaxinc/WhisperKit) (99 languages) — both run on-device via CoreML |
| **Global shortcut** | Customizable hotkey (default **⌥ Space**) to start/stop recording from anywhere |
| **Recording overlay** | Floating visualizer with live audio bars, timer, and stop button |
| **Auto-paste** | Transcribed text goes straight to your clipboard and active text field |
| **Encrypted history** | Transcriptions stored locally with AES-256-GCM, key bound to your hardware |
| **Media auto-pause** | Pauses playing media during recording, resumes after transcription |
| **Auto-updater** | Checks GitHub releases hourly, one-click install from the menubar |
| **Menubar app** | Lives in your menubar, no dock icon, stays out of your way |
| **Sound feedback** | Audio cues on record start, stop, and empty transcription |
| **Onboarding** | Guided first-launch setup: model download, permissions, preferences |
| **Launch at login** | Start with macOS, ready when you are |

## Install

Download the latest `.zip` from [**Releases**](https://github.com/Xavierdesousa/NanoWhisper/releases/latest), unzip, and drag `NanoWhisper.app` to your Applications folder.

On first launch, an onboarding window walks you through model download, permissions, and preferences.

## Usage

| Action | How |
|---|---|
| Start/stop recording | **⌥ Space** (default) or menubar button |
| Stop via overlay | Hover the overlay → click stop |
| Open history | **⌘H** or Menubar → History |
| Open settings | **⌘,** or Menubar → Settings |
| Quit | Menubar → Quit |

## Permissions

| Permission | Why |
|---|---|
| **Microphone** | Record audio for transcription |
| **Accessibility** | Paste text into the active field (simulates ⌘V) |
| **System Audio Recording** | Detect playing media for auto-pause *(optional)* |

## Whisper Configuration

When using the Whisper engine:

- **Model size** — Tiny (~75 MB), Base (~150 MB), Small (~500 MB), Medium (~1.5 GB), Large-v3 (~3 GB)
- **Language** — auto-detect or pick from 99 languages
- **Vocabulary hint** — improve recognition of technical terms or names

## Requirements

- macOS 14+ (Sonoma)
- Apple Silicon (M1/M2/M3/M4)
- ~1 GB disk (varies by model)

## Build from Source

```bash
git clone https://github.com/Xavierdesousa/NanoWhisper.git
cd NanoWhisper
make app
```

Other targets: `make run` (dev), `make release` (zip), `make clean`.

## License

[GPL v3](LICENSE) — free to use, modify, and redistribute. Forks must remain open-source under the same license.
