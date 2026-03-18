#!/bin/bash
set -e

NANOWHISPER_DIR="$HOME/.nanowhisper"
VENV_DIR="$NANOWHISPER_DIR/venv"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== NanoWhisper Setup ==="
echo ""

# Find a compatible Python (3.10-3.12, NeMo doesn't support 3.13+ yet)
PYTHON=""
for candidate in python3.12 python3.11 python3.10; do
    if command -v "$candidate" &>/dev/null; then
        PYTHON="$(command -v "$candidate")"
        break
    fi
done

if [ -z "$PYTHON" ]; then
    echo "ERROR: Python 3.10-3.12 not found. NeMo requires Python <=3.12."
    echo "  Install with: brew install python@3.12"
    exit 1
fi

PYTHON_VERSION=$($PYTHON -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
echo "Using Python $PYTHON_VERSION ($PYTHON)"

# Create directory
mkdir -p "$NANOWHISPER_DIR"

# Copy transcribe script
if [ -f "$SCRIPT_DIR/transcribe.py" ]; then
    cp "$SCRIPT_DIR/transcribe.py" "$NANOWHISPER_DIR/transcribe.py"
    echo "Copied transcribe.py to $NANOWHISPER_DIR"
fi

# Create venv
if [ ! -d "$VENV_DIR" ]; then
    echo "STEP:Creating Python environment..."
    echo "Creating virtual environment..."
    $PYTHON -m venv "$VENV_DIR"
else
    echo "Virtual environment already exists."
fi

source "$VENV_DIR/bin/activate"

echo "STEP:Installing PyTorch..."
echo "Installing dependencies (this may take a few minutes)..."
pip install --upgrade pip -q

# Install Cython first (needed by some NeMo deps)
pip install Cython -q

# Install PyTorch (Apple Silicon optimized)
pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu -q

echo "STEP:Installing NeMo toolkit..."
# Install NeMo ASR
pip install "nemo_toolkit[asr]" -q

echo ""
echo "STEP:Downloading model (~2GB)..."
echo "Downloading model (first run only, ~2GB)..."
python3 -c "
import nemo.collections.asr as nemo_asr
print('Downloading nvidia/parakeet-tdt-0.6b-v3 ...')
model = nemo_asr.models.ASRModel.from_pretrained('nvidia/parakeet-tdt-0.6b-v3')
print('Model downloaded and cached.')
"

echo ""
echo "=== Setup complete! ==="
echo "You can now open NanoWhisper.app"
echo "The model is cached and will load faster on next launch."
