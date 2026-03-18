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

warnings.filterwarnings("ignore")

os.environ.setdefault("NEMO_LOG_LEVEL", "ERROR")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

NANOWHISPER_DIR = os.path.expanduser("~/.nanowhisper")
SOCKET_PATH = os.path.join(NANOWHISPER_DIR, "daemon.sock")
PID_FILE = os.path.join(NANOWHISPER_DIR, "daemon.pid")


def load_model():
    import torch
    import nemo.collections.asr as nemo_asr

    if torch.backends.mps.is_available():
        device = "mps"
    else:
        device = "cpu"

    model = nemo_asr.models.ASRModel.from_pretrained("nvidia/parakeet-tdt-0.6b-v3")
    model = model.to(device)
    model.eval()
    return model


def transcribe(model, path):
    result = model.transcribe([path])

    if isinstance(result, tuple):
        text = result[0][0] if result[0] else ""
    elif isinstance(result, list):
        item = result[0]
        if isinstance(item, str):
            text = item
        elif hasattr(item, "text"):
            text = item.text
        else:
            text = str(item)
    else:
        text = str(result)

    return text.strip()


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
                elif msg.startswith("TRANSCRIBE:"):
                    path = msg[len("TRANSCRIBE:") :]
                    try:
                        text = transcribe(model, path)
                        conn.sendall(f"OK:{text}\n".encode("utf-8"))
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
        model = load_model()
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
