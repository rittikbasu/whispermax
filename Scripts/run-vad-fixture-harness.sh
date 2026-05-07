#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HARNESS="$ROOT_DIR/.vadlab/vad_fixture_harness"
VAD_MODEL="$ROOT_DIR/WhisperMax/Resources/ggml-silero-v6.2.0.bin"

if [[ ! -x "$HARNESS" ]]; then
  "$ROOT_DIR/Scripts/build-vad-fixture-harness.sh"
fi

WHISPER_MODEL=""
if [[ -f "$HOME/Library/Application Support/WhisperMax/Models/ggml-large-v3-turbo.bin" ]]; then
  WHISPER_MODEL="$HOME/Library/Application Support/WhisperMax/Models/ggml-large-v3-turbo.bin"
elif [[ -f "$HOME/Library/Application Support/superwhisper/ggml-large-v3-turbo.bin" ]]; then
  WHISPER_MODEL="$HOME/Library/Application Support/superwhisper/ggml-large-v3-turbo.bin"
else
  echo "missing whisper model; expected app-local or superwhisper model" >&2
  exit 1
fi

exec "$HARNESS" "$WHISPER_MODEL" "$VAD_MODEL" "$@"
