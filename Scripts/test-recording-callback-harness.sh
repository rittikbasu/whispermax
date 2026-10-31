#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build"
OUT="$OUT_DIR/recording_callback_harness"
BUILD_LOG="$OUT_DIR/recording-callback-debug-build.log"
PROJECT_PATH="$ROOT_DIR/WhisperMax.xcodeproj"

mkdir -p "$OUT_DIR"

swiftc \
  -O \
  -o "$OUT" \
  "$ROOT_DIR/WhisperMax/Core/RecordingCallbackCoordinator.swift" \
  "$ROOT_DIR/Scripts/recording_callback_harness.swift"

"$OUT"

if ! xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme WhisperMax \
  -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO > "$BUILD_LOG" 2>&1; then
  tail -n 60 "$BUILD_LOG"
  exit 1
fi

BUILD_SETTINGS="$(xcodebuild -project "$PROJECT_PATH" -scheme WhisperMax -configuration Debug -showBuildSettings)"
TARGET_BUILD_DIR="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/ TARGET_BUILD_DIR = / { print $2; exit }')"
FULL_PRODUCT_NAME="$(printf '%s\n' "$BUILD_SETTINGS" | awk -F ' = ' '/ FULL_PRODUCT_NAME = / { print $2; exit }')"
APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
APP_EXECUTABLE="$APP_PATH/Contents/MacOS/whispermax"

if [[ ! -x "$APP_EXECUTABLE" ]]; then
  echo "Missing built app executable: $APP_EXECUTABLE" >&2
  exit 1
fi

"$APP_EXECUTABLE" --whispermax-test-recording-cancellation
