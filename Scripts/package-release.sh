#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/WhisperMax.xcodeproj"
SCHEME="WhisperMax"
CONFIGURATION="Release"
DIST_DIR="$ROOT_DIR/dist"
FRAMEWORK_DIR="$ROOT_DIR/Vendor/whisper.xcframework"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

yaml_value() {
  local key="$1"
  sed -n "s/^    ${key}: //p" "$ROOT_DIR/project.yml" | head -n 1
}

require_command xcodegen
require_command xcodebuild
require_command ditto
require_command shasum

PRODUCT_NAME="$(yaml_value PRODUCT_NAME)"
VERSION="$(yaml_value MARKETING_VERSION)"
BUILD_NUMBER="$(yaml_value CURRENT_PROJECT_VERSION)"

if [[ -z "$PRODUCT_NAME" || -z "$VERSION" || -z "$BUILD_NUMBER" ]]; then
  echo "Failed to read PRODUCT_NAME, MARKETING_VERSION, or CURRENT_PROJECT_VERSION from project.yml" >&2
  exit 1
fi

cd "$ROOT_DIR"

xcodegen generate >/dev/null

if [[ ! -d "$FRAMEWORK_DIR" ]]; then
  "$ROOT_DIR/Scripts/install-whisper-framework.sh"
fi

xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  build CODE_SIGNING_ALLOWED=NO >/dev/null

BUILD_SETTINGS="$(xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -configuration "$CONFIGURATION" -showBuildSettings)"
TARGET_BUILD_DIR="$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/ TARGET_BUILD_DIR = / { print $2; exit }')"
FULL_PRODUCT_NAME="$(echo "$BUILD_SETTINGS" | awk -F ' = ' '/ FULL_PRODUCT_NAME = / { print $2; exit }')"

if [[ -z "$TARGET_BUILD_DIR" || -z "$FULL_PRODUCT_NAME" ]]; then
  echo "Failed to resolve build output paths from xcodebuild settings" >&2
  exit 1
fi

APP_PATH="$TARGET_BUILD_DIR/$FULL_PRODUCT_NAME"
RELEASE_NAME="${PRODUCT_NAME}-v${VERSION}-macos"
ZIP_PATH="$DIST_DIR/${RELEASE_NAME}.zip"
CHECKSUM_PATH="$DIST_DIR/${RELEASE_NAME}.sha256"
TMP_DIR="$(mktemp -d)"
STAGED_APP_PATH="$TMP_DIR/$FULL_PRODUCT_NAME"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

mkdir -p "$DIST_DIR"
rm -f "$ZIP_PATH" "$CHECKSUM_PATH"

ditto "$APP_PATH" "$STAGED_APP_PATH"

# Ad-hoc sign the staged app so the bundle is internally consistent without
# requiring a paid Apple Developer account.
/usr/bin/codesign --force --deep --sign - "$STAGED_APP_PATH" >/dev/null 2>&1 || true

ditto -c -k --sequesterRsrc --keepParent "$STAGED_APP_PATH" "$ZIP_PATH"

CHECKSUM="$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')"
printf '%s  %s\n' "$CHECKSUM" "$(basename "$ZIP_PATH")" > "$CHECKSUM_PATH"

echo "Created $ZIP_PATH"
echo "SHA256 $CHECKSUM"
echo "Version $VERSION ($BUILD_NUMBER)"
