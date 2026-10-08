#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BINARY="${WHISPERMAX_QWEN_APP_BINARY:-$HOME/Applications/whispermax.app/Contents/MacOS/whispermax}"
PYTHON="${WHISPERMAX_QWEN_PYTHON:-$ROOT_DIR/.private-bench/phonon/.venv/bin/python}"
MODEL="${WHISPERMAX_QWEN_MODEL:-$HOME/Library/Application Support/Hindsight/Models/Qwen3-ASR-1.7B-8bit}"

if pgrep -x whispermax >/dev/null 2>&1; then
  print -u2 "Quit the running whispermax app before starting its Qwen prototype."
  exit 1
fi

if [[ ! -x "$APP_BINARY" || ! -x "$PYTHON" || ! -d "$MODEL" ]]; then
  print -u2 "The debug app, MLX runtime, or local Qwen model is unavailable."
  exit 1
fi

exec env \
  WHISPERMAX_ASR_BACKEND=qwen-1.7b-8bit \
  WHISPERMAX_QWEN_PYTHON="$PYTHON" \
  WHISPERMAX_QWEN_MODEL="$MODEL" \
  "$APP_BINARY"
