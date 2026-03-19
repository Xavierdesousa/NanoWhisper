#!/usr/bin/env python3
"""
NanoWhisper transcription daemon.
Runs as a background process, listens on a Unix socket.
Stays alive between app sessions so the model is loaded only once.

Protocol (newline-delimited over Unix socket):
  -> PING                 check if alive
  <- PONG
  -> TRANSCRIBE:<path>    transcribe audio file
  <- OK:<text>
  <- ERR:<message>
  -> QUIT                 shut down daemon
"""

import sys
import os
import socket
import signal
import warnings
import threading
import time
import json

warnings.filterwarnings("ignore")

os.environ.setdefault("NEMO_LOG_LEVEL", "ERROR")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

NANOWHISPER_DIR = os.path.expanduser("~/.nanowhisper")
SOCKET_PATH = os.path.join(NANOWHISPER_DIR, "daemon.sock")
PID_FILE = os.path.join(NANOWHISPER_DIR, "daemon.pid")


_last_transcribe_time = 0.0
_current_preset = "fast"

DECODING_PRESETS = {
    "fast": {"strategy": "greedy_batch"},
    "balanced": {"strategy": "beam", "beam_size": 4},
    "best": {"strategy": "beam", "beam_size": 8},
}


def apply_decoding_preset(model, preset_name):
    """Change the model's decoding strategy."""
    global _current_preset
    from omegaconf import OmegaConf

    preset = DECODING_PRESETS.get(preset_name, DECODING_PRESETS["fast"])
    decoding_cfg = model.cfg.decoding
    decoding_cfg.strategy = preset["strategy"]
    if preset["strategy"] == "beam":
        decoding_cfg.beam.beam_size = preset["beam_size"]
    model.change_decoding_strategy(decoding_cfg)
    _current_preset = preset_name


def load_model():
    import torch
    import nemo.collections.asr as nemo_asr

    if torch.backends.mps.is_available():
        device = "mps"
    else:
        device = "cpu"

    model = nemo_asr.models.ASRModel.from_pretrained("nvidia/parakeet-tdt-0.6b-v3")
    model = model.to(device)
    # Float16 for faster inference on MPS
    if device == "mps":
        model = model.half()
    model.eval()
    return model, device


def get_audio_duration(path):
    """Get audio duration in seconds using soundfile."""
    try:
        import soundfile as sf
        info = sf.info(path)
        return info.duration
    except Exception:
        return -1.0


def trim_silence(path):
    """Trim leading/trailing silence with gentle thresholds to preserve speech.

    Returns (trimmed_path, original_duration, trimmed_duration).
    Falls back to original file on any error.
    """
    try:
        import numpy as np
        import soundfile as sf

        audio, sr = sf.read(path, dtype="float32")
        original_duration = len(audio) / sr

        # Skip trimming for very short audio (<0.5s)
        if original_duration < 0.5:
            return path, original_duration, original_duration

        # RMS energy in sliding windows
        window_ms = 30  # 30ms windows
        window_size = int(sr * window_ms / 1000)
        hop_size = window_size // 2

        # Gentle threshold: -40dB relative to peak RMS (very conservative)
        rms_values = []
        for i in range(0, len(audio) - window_size, hop_size):
            chunk = audio[i : i + window_size]
            rms_values.append(np.sqrt(np.mean(chunk**2)))

        if not rms_values:
            return path, original_duration, original_duration

        peak_rms = max(rms_values)
        if peak_rms < 1e-6:
            return path, original_duration, original_duration

        threshold = peak_rms * 0.01  # -40dB — very gentle

        # Find first and last frame above threshold
        first = 0
        for i, rms in enumerate(rms_values):
            if rms > threshold:
                first = i
                break

        last = len(rms_values) - 1
        for i in range(len(rms_values) - 1, -1, -1):
            if rms_values[i] > threshold:
                last = i
                break

        # Convert to samples with generous padding (200ms each side)
        pad_samples = int(sr * 0.2)
        start_sample = max(0, first * hop_size - pad_samples)
        end_sample = min(len(audio), (last + 1) * hop_size + window_size + pad_samples)

        trimmed = audio[start_sample:end_sample]
        trimmed_duration = len(trimmed) / sr

        # Only trim if we actually save meaningful time (>0.3s)
        if original_duration - trimmed_duration < 0.3:
            return path, original_duration, original_duration

        # Write trimmed audio to temp file
        trimmed_path = path.replace(".wav", "_trimmed.wav")
        sf.write(trimmed_path, trimmed, sr)
        return trimmed_path, original_duration, trimmed_duration

    except Exception:
        orig_dur = get_audio_duration(path)
        return path, orig_dur, orig_dur


def transcribe(model, path):
    global _last_transcribe_time

    now = time.time()
    idle_time = now - _last_transcribe_time if _last_transcribe_time > 0 else -1.0

    # Trim silence
    actual_path, original_duration, trimmed_duration = trim_silence(path)
    was_trimmed = actual_path != path

    t0 = time.time()
    result = model.transcribe([actual_path])
    transcribe_duration = time.time() - t0

    # Clean up trimmed file
    if was_trimmed:
        try:
            os.unlink(actual_path)
        except Exception:
            pass

    _last_transcribe_time = time.time()

    # Unwrap result — model.transcribe() returns various formats depending on decoding strategy
    def extract_text(r):
        if isinstance(r, str):
            return r
        if isinstance(r, tuple):
            return extract_text(r[0])
        if isinstance(r, list):
            if len(r) == 0:
                return ""
            return extract_text(r[0])
        if hasattr(r, "text"):
            return r.text
        # Hypothesis with y_sequence but no text — decode via tokenizer
        if hasattr(r, "y_sequence") and hasattr(model, "tokenizer"):
            ids = r.y_sequence.tolist() if hasattr(r.y_sequence, "tolist") else list(r.y_sequence)
            return model.tokenizer.ids_to_text(ids)
        return str(r)

    text = extract_text(result)

    text = text.strip()

    debug_info = {
        "audio_duration": round(original_duration, 2),
        "trimmed_duration": round(trimmed_duration, 2) if was_trimmed else None,
        "transcribe_duration": round(transcribe_duration, 3),
        "idle_since_last": round(idle_time, 1) if idle_time >= 0 else None,
        "rtf": round(transcribe_duration / trimmed_duration, 2) if trimmed_duration > 0 else None,
        "preset": _current_preset,
    }

    return text, debug_info


def handle_client(conn, model, shutdown_event):
    """Handle a single client connection."""
    try:
        buf = b""
        while not shutdown_event.is_set():
            data = conn.recv(4096)
            if not data:
                break
            buf += data
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                msg = line.decode("utf-8").strip()
                if not msg:
                    continue
                if msg == "PING":
                    conn.sendall(b"PONG\n")
                elif msg == "QUIT":
                    conn.sendall(b"OK:bye\n")
                    shutdown_event.set()
                    return
                elif msg.startswith("DECODING:"):
                    preset_name = msg[len("DECODING:"):]
                    try:
                        apply_decoding_preset(model, preset_name)
                        conn.sendall(f"OK:{preset_name}\n".encode("utf-8"))
                    except Exception as e:
                        conn.sendall(f"ERR:{e}\n".encode("utf-8"))
                elif msg.startswith("TRANSCRIBE:"):
                    path = msg[len("TRANSCRIBE:") :]
                    try:
                        text, debug_info = transcribe(model, path)
                        debug_json = json.dumps(debug_info)
                        conn.sendall(f"OK:{text}\tDEBUG:{debug_json}\n".encode("utf-8"))
                    except Exception as e:
                        conn.sendall(f"ERR:{e}\n".encode("utf-8"))
                else:
                    conn.sendall(b"ERR:unknown command\n")
    except (BrokenPipeError, ConnectionResetError):
        pass
    finally:
        conn.close()


def cleanup():
    for path in [SOCKET_PATH, PID_FILE]:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def main():
    os.makedirs(NANOWHISPER_DIR, exist_ok=True)

    # Check if another daemon is already running
    if os.path.exists(PID_FILE):
        try:
            with open(PID_FILE) as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, 0)  # check if alive
            print(f"Daemon already running (pid {old_pid})", flush=True)
            sys.exit(0)
        except (ProcessLookupError, ValueError):
            cleanup()  # stale pid file

    # Clean up old socket
    if os.path.exists(SOCKET_PATH):
        os.unlink(SOCKET_PATH)

    # Write PID
    with open(PID_FILE, "w") as f:
        f.write(str(os.getpid()))

    # Signal stdout that we're loading
    print("LOADING", flush=True)

    try:
        model, device = load_model()
    except Exception as e:
        print(f"ERR:Failed to load model: {e}", flush=True)
        cleanup()
        sys.exit(1)

    print("READY", flush=True)

    # Start socket server
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    server.listen(2)
    server.settimeout(1.0)  # allow periodic shutdown check

    shutdown_event = threading.Event()

    def signal_handler(sig, frame):
        shutdown_event.set()

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    while not shutdown_event.is_set():
        try:
            conn, _ = server.accept()
            # Handle each client in a thread (simple, one at a time transcription)
            t = threading.Thread(target=handle_client, args=(conn, model, shutdown_event))
            t.daemon = True
            t.start()
        except socket.timeout:
            continue
        except OSError:
            break

    server.close()
    cleanup()


if __name__ == "__main__":
    main()
