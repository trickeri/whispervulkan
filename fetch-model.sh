#!/usr/bin/env bash
# Download a ggml whisper model into the whisper.cpp models dir. Idempotent.
# Default: large-v3-turbo (~1.6 GB f16). Uses whisper.cpp's own download script.
set -euo pipefail

MODEL_NAME="${1:-large-v3-turbo}"
WC="${WHISPER_CPP_DIR:-$HOME/programming/whisper.cpp}"
DEST="$WC/models/ggml-${MODEL_NAME}.bin"

if [ -f "$DEST" ]; then
  echo "Model already present: $DEST"
  exit 0
fi
[ -f "$WC/models/download-ggml-model.sh" ] || { echo "whisper.cpp models dir not found at $WC/models" >&2; exit 1; }
sh "$WC/models/download-ggml-model.sh" "$MODEL_NAME"
echo "Fetched: $DEST"
