#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FRAMEWORK_DIR="$ROOT_DIR/Vendor/whisper.xcframework/macos-arm64_x86_64"
OUT_DIR="$ROOT_DIR/.vadlab"
OUT="$OUT_DIR/vad_fixture_harness"

mkdir -p "$OUT_DIR"

swiftc -O \
  -F "$FRAMEWORK_DIR" \
  -Xlinker -rpath -Xlinker "$FRAMEWORK_DIR" \
  -framework whisper \
  -framework AVFoundation \
  -framework Foundation \
  -o "$OUT" \
  "$ROOT_DIR/WhisperMax/Core/ModelLocator.swift" \
  "$ROOT_DIR/WhisperMax/Audio/AudioSampleDecoder.swift" \
  "$ROOT_DIR/WhisperMax/Audio/SpeechActivityService.swift" \
  "$ROOT_DIR/WhisperMax/Core/TranscriptFormatter.swift" \
  "$ROOT_DIR/WhisperMax/Core/TranscriptionChunkPolicy.swift" \
  "$ROOT_DIR/WhisperMax/Transcription/WhisperEngine.swift" \
  "$ROOT_DIR/Scripts/vad_fixture_harness.swift"

echo "built: $OUT"
