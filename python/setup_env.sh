#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV="$SCRIPT_DIR/.venv"

echo "=== Reachy Mini — Python environment setup ==="

# Use uv's Python 3.12
UV_PYTHON="/Users/maxl/.local/share/uv/python/cpython-3.12.12-macos-aarch64-none/bin/python3"

if [ ! -d "$VENV" ]; then
    echo "Creating venv at $VENV ..."
    uv venv --python "$UV_PYTHON" "$VENV"
fi

echo "Installing reachy-mini ..."
uv pip install --python "$VENV/bin/python" "reachy-mini[all]" 2>/dev/null || \
uv pip install --python "$VENV/bin/python" "reachy-mini"

echo "Installing camera deps ..."
uv pip install --python "$VENV/bin/python" opencv-python-headless Pillow 2>/dev/null || true

echo "Installing live chat deps ..."
uv pip install --python "$VENV/bin/python" "google-genai>=1.0" "openai>=1.65" sounddevice numpy 2>/dev/null || true

echo "Installing Rubik coach deps ..."
uv pip install --python "$VENV/bin/python" \
    "aiortc>=1.13.0" \
    "fastrtc>=0.0.34" \
    "gradio==5.50.1.dev1" \
    "gradio_client>=1.13.3" \
    "huggingface-hub==1.3.0" \
    "python-dotenv" \
    "openai>=2.1" \
    "reachy_mini_toolbox" \
    "reachy_mini_dances_library" \
    "eclipse-zenoh~=1.7.0"

echo "Done. Activate with: source $VENV/bin/activate"
echo "Test daemon: python -c \"import reachy_mini; print('OK')\""
