<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="NanoWhisper icon">
</p>

<h1 align="center">NanoWhisper</h1>

<p align="center">
  <a href="https://github.com/Xavierdesousa/NanoWhisper/actions/workflows/ci.yml"><img src="https://github.com/Xavierdesousa/NanoWhisper/actions/workflows/ci.yml/badge.svg?branch=main" alt="CI"></a>
  <a href="https://github.com/Xavierdesousa/NanoWhisper/releases/latest"><img src="https://img.shields.io/github/v/release/Xavierdesousa/NanoWhisper" alt="Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-blue" alt="Platform">
  <img src="https://img.shields.io/badge/swift-6.2-orange" alt="Swift">
  <a href="https://github.com/Xavierdesousa/NanoWhisper/blob/main/LICENSE"><img src="https://img.shields.io/github/license/Xavierdesousa/NanoWhisper" alt="License"></a>
</p>

<p align="center">
  Local, offline speech-to-text for macOS. Lives in your menubar, transcribes with <a href="https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3">NVIDIA Parakeet</a> or <a href="https://github.com/argmaxinc/WhisperKit">OpenAI Whisper</a>, and pastes the result wherever your cursor is.
</p>

<p align="center">
  No cloud. No API keys. No subscription. Just press a shortcut and talk.
</p>

## How it works

1. Press **⌥ Space** (customizable)
2. A recording overlay appears with a live audio visualizer
3. Press **⌥ Space** again (or click the stop button on the overlay)
4. Text appears in your active text field + clipboard

Transcription runs entirely on-device using CoreML — 100% Swift, no Python, no daemon.

## Features

- **Dual engine** — choose between [Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3) (fastest, auto-multilingual) and [WhisperKit](https://github.com/argmaxinc/WhisperKit) (most accurate, 99 languages)
- **Menubar app** — no dock icon, stays out of your way
- **Recording overlay** — floating visualizer with live audio bars, elapsed timer, and stop button on hover
- **Global hotkey** — customizable shortcut (default ⌥ Space) with reset to default
- **Sound feedback** — audio cues on record start, stop, and empty transcription (toggleable)
- **Encrypted history** — transcriptions encrypted with AES-256-GCM using a hardware-bound key (⌘H to open)
- **Auto-paste** — transcribed text goes to clipboard and is pasted into the active field
- **Auto-updater** — checks GitHub releases hourly, one-click install from the menubar or settings
- **First-launch onboarding** — guided setup with model download progress, permission grants, and preferences
- **Launch at login** — optional, configurable in settings
- **Debug mode** — show transcription timing metrics (audio duration, RTF) in history

### Whisper options

When using the Whisper engine, you can configure:
- **Model size** — Tiny (~75MB), Base (~150MB), Small (~500MB), Medium (~1.5GB), Large-v3 (~3GB)
- **Language** — auto-detect or pick from 99 languages
- **Vocabulary hint** — words or phrases to improve recognition of technical terms

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4)
- ~1GB disk space (varies by model)

## Install

```bash
git clone https://github.com/Xavierdesousa/NanoWhisper.git
cd NanoWhisper
make app
```

On first launch, an onboarding window guides you through:
- Downloading and compiling the CoreML model
- Granting Accessibility and Microphone permissions
- Configuring your shortcut and preferences

## Usage

| Action | How |
|---|---|
| Start/stop recording | **⌥ Space** (default) or menubar button |
| Stop via overlay | Hover the overlay and click the stop button |
| Open history | **⌘H** or Menubar → History |
| Open settings | **⌘,** or Menubar → Settings |
| Quit | Menubar → Quit |

## Permissions

The app needs two permissions (requested during onboarding):
- **Microphone** — to record audio
- **Accessibility** — to paste text into the active field (simulates ⌘V)

## Build from source

```bash
# Build release binary + .app bundle
make app

# Create a release zip for GitHub
make release

# Run in development (without .app bundle)
make run

# Clean build artifacts
make clean
```

## Project structure

```
├── Sources/NanoWhisper/
│   ├── NanoWhisperApp.swift      # Menubar UI + app delegate
│   ├── AppState.swift            # App state + recording flow + encrypted history
│   ├── AudioRecorder.swift       # Microphone capture + audio levels (AVAudioEngine)
│   ├── TranscriptionEngine.swift # Model type definitions (Parakeet / Whisper)
│   ├── Transcriber.swift         # CoreML transcription (FluidAudio + WhisperKit)
│   ├── AutoUpdater.swift         # GitHub-based auto-updater
│   ├── RecordingOverlay.swift    # Floating overlay with visualizer
│   ├── ModelComparisonView.swift # Engine speed/accuracy comparison bars
│   ├── OnboardingView.swift      # First-launch onboarding window
│   ├── HotkeyManager.swift       # Global shortcut (Carbon API)
│   ├── PasteManager.swift        # Clipboard + ⌘V simulation
│   ├── SetupManager.swift        # Model download + compilation
│   ├── SoundManager.swift        # Audio feedback (start/stop/error)
│   ├── SettingsView.swift        # Settings window
│   ├── HistoryView.swift         # History window
│   └── WindowUtils.swift         # Multi-screen window positioning
├── Resources/
│   ├── Info.plist
│   ├── NanoWhisper.entitlements
│   ├── AppIcon.icns
│   ├── menubar_icon.png          # Custom menubar icon
│   ├── start.m4a                 # Record start sound
│   ├── stop.m4a                  # Record stop sound
│   └── noResult.m4a              # Empty transcription sound
├── Package.swift
└── Makefile
```

## Sharing with friends

Just send them the repo. They need:
1. Apple Silicon Mac with macOS 13+
2. Run `make app`

No Python, no Apple Developer account, no code signing required — the app is ad-hoc signed.

## License

[GPL v3](LICENSE) — free to use, modify, and redistribute. Any fork or derivative must also be open-source under the same license.
