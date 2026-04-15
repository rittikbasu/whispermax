#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/WhisperMax.xcodeproj"
SCHEME="WhisperMax"
CONFIGURATION="Debug"
SIGNING_IDENTITY="${WHISPERMAX_SIGNING_IDENTITY:-}"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP_PATH="$INSTALL_DIR/WhisperMax.app"

cd "$ROOT_DIR"

if [[ -z "$SIGNING_IDENTITY" ]]; then
  SIGNING_IDENTITY="$(security find-identity -v -p codesigning | awk -F '\"' '/Apple Development/ { print $2; exit }')"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
  echo "No Apple Development signing identity found. Set WHISPERMAX_SIGNING_IDENTITY to override." >&2
  exit 1
fi

xcodegen generate >/dev/null
xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" build CODE_SIGNING_ALLOWED=NO >/dev/null

BUILD_SETTINGS="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings)"
TARGET_BUILD_DIR="$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/ TARGET_BUILD_DIR = / { print $2; exit }')"
FULL_PRODUCT_NAME="$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/ FULL_PRODUCT_NAME = / { print $2; exit }')"
APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"

/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_PATH"
/bin/mkdir -p "$INSTALL_DIR"
/bin/rm -rf "$INSTALL_APP_PATH"
/usr/bin/ditto "$APP_PATH" "$INSTALL_APP_PATH"
/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$INSTALL_APP_PATH"
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "$INSTALL_APP_PATH" >/dev/null 2>&1 || true
/usr/bin/pkill -f '/WhisperMax.app/Contents/MacOS/WhisperMax' || true
/bin/sleep 0.4
/usr/bin/open "$INSTALL_APP_PATH"

echo "$INSTALL_APP_PATH"
