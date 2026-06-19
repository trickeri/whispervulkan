#!/usr/bin/env bash
# whispermodel — system-wide Whisper STT daemon.
# Thin launcher over whisper.cpp's whisper-server (large-v3-turbo warm on the GPU;
# backend vulkan|cuda|cpu is chosen when whisper.cpp is built — see build.sh).
# Any app on the machine POSTs 16 kHz wav to http://$WV_HOST:$WV_PORT/inference.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Local overrides (machine-specific paths). See config.env.example.
[ -f "$HERE/config.env" ] && . "$HERE/config.env"

# Defaults — point at the sibling whisper.cpp checkout built with Vulkan.
WHISPER_SERVER_BIN="${WHISPER_SERVER_BIN:-$HOME/programming/whisper.cpp/build/bin/whisper-server}"
WV_MODEL="${WV_MODEL:-$HOME/programming/whisper.cpp/models/ggml-large-v3-turbo.bin}"
WV_HOST="${WV_HOST:-127.0.0.1}"
WV_PORT="${WV_PORT:-48450}"
WV_THREADS="${WV_THREADS:-8}"
WV_LANG="${WV_LANG:-en}"

[ -x "$WHISPER_SERVER_BIN" ] || { echo "whisper-server not found at $WHISPER_SERVER_BIN — run ./build.sh" >&2; exit 1; }
[ -f "$WV_MODEL" ]          || { echo "model not found at $WV_MODEL — run ./fetch-model.sh" >&2; exit 1; }

echo "whispermodel: $WV_MODEL on $WV_HOST:$WV_PORT (${WV_THREADS}t, lang=$WV_LANG)" >&2
# whisper-server is rpath-linked to libwhisper/libggml*.so in its build dir — exec in place.
exec "$WHISPER_SERVER_BIN" \
  --model "$WV_MODEL" \
  --host "$WV_HOST" \
  --port "$WV_PORT" \
  --threads "$WV_THREADS" \
  --language "$WV_LANG" \
  --inference-path /inference \
  --convert
