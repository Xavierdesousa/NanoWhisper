# NanoWhisper

Local, offline speech-to-text for macOS. Lives in your menubar, transcribes with [NVIDIA Parakeet](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3), and pastes the result wherever your cursor is.

No cloud. No API keys. No subscription. Just press a shortcut and talk.

## How it works

1. Press **⌥ Space** (customizable)
2. Speak
3. Press **⌥ Space** again
4. Text appears in your active text field + clipboard

Transcription runs entirely on-device using the Parakeet TDT 0.6B v3 model — a multilingual ASR model supporting 25 languages with automatic detection. Works great for French, English, and mixed-language input.

## Requirements

- macOS 13+ (Ventura or later)
- Apple Silicon (M1/M2/M3/M4)
- Python 3.10–3.12 (`brew install python@3.12`)
- ~3GB disk space (model + dependencies)

## Install

```bash
git clone https://github.com/Xavierdesousa/NanoWhisper.git
cd NanoWhisper
make app
open NanoWhisper.app
```

On first launch, the app automatically:
- Creates a Python virtual environment at `~/.nanowhisper/`
- Installs PyTorch + NeMo
- Downloads the Parakeet model (~2GB)

This takes a few minutes. Subsequent launches are instant thanks to the background engine daemon.

## Usage

| Action | How |
|---|---|
| Start/stop recording | **⌥ Space** (default) |
| Change shortcut | Menubar → Settings |
| Quit (keep engine alive) | Menubar → Quit |
| Quit (free all memory) | Menubar → Quit & Stop Engine |

The transcription engine runs as a background daemon. When you **Quit**, the daemon stays alive so reopening the app is instant (~24ms). Use **Quit & Stop Engine** to fully shut it down.

## Permissions

The app will ask for:
- **Microphone** — to record audio
- **Accessibility** — to paste text into the active field (simulates ⌘V)

## Build from source

```bash
# Build release binary + .app bundle
make app

# Run in development (without .app bundle)
make run

# Install Python dependencies manually (optional, app does this automatically)
make setup

# Clean build artifacts
make clean
```

## Project structure

```
├── Sources/NanoWhisper/
│   ├── NanoWhisperApp.swift      # Menubar UI
│   ├── AppState.swift            # App state + recording flow
│   ├── AudioRecorder.swift       # Microphone capture (AVAudioEngine)
│   ├── Transcriber.swift         # Daemon socket client
│   ├── HotkeyManager.swift      # Global shortcut (Carbon API)
│   ├── PasteManager.swift        # Clipboard + ⌘V simulation
│   ├── SetupManager.swift        # Auto-setup on first launch
│   └── SettingsView.swift        # Settings window
├── scripts/
│   ├── transcribe.py             # Transcription daemon (Unix socket server)
│   └── setup.sh                  # Python env + model setup
├── Resources/Info.plist
├── Package.swift
└── Makefile
```

## Sharing with friends

Just send them the repo. They need:
1. Apple Silicon Mac with macOS 13+
2. Python 3.12 (`brew install python@3.12`)
3. Run `make app && open NanoWhisper.app`

No Apple Developer account or code signing required — the app is ad-hoc signed.

## License

MIT
