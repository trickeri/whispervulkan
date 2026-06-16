#!/usr/bin/env bash
# Reference client: transcribe an audio file via the whispervulkan daemon.
# Usage: whispervulkan.sh path/to/audio.wav   ->  prints the transcript text
set -euo pipefail
URL="${WHISPER_HTTP_URL:-http://127.0.0.1:48450/inference}"
FILE="${1:?usage: whispervulkan.sh <audio-file>}"
curl -fsS -F "file=@${FILE}" -F "response_format=text" "$URL"
