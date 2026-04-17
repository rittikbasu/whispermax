#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
DOCS_DIR="$ROOT_DIR/docs"
RELEASE_NOTES_DIR="$DOCS_DIR/releases"

PRODUCT_NAME="$(sed -n 's/^    PRODUCT_NAME: //p' "$ROOT_DIR/project.yml" | head -n 1)"
VERSION="$(sed -n 's/^    MARKETING_VERSION: //p' "$ROOT_DIR/project.yml" | head -n 1)"

if [[ -z "$PRODUCT_NAME" || -z "$VERSION" ]]; then
  echo "Failed to read PRODUCT_NAME or MARKETING_VERSION from project.yml" >&2
  exit 1
fi

RELEASE_NAME="${PRODUCT_NAME}-v${VERSION}-macos"
ARCHIVE_PATH="$DIST_DIR/${RELEASE_NAME}.zip"
RELEASE_NOTES_PATH="$RELEASE_NOTES_DIR/v${VERSION}.md"
DOWNLOAD_URL_PREFIX="https://github.com/rittikbasu/whispermax/releases/download/v${VERSION}/"
FULL_RELEASE_NOTES_URL="https://github.com/rittikbasu/whispermax/releases/tag/v${VERSION}"
PRODUCT_LINK="https://github.com/rittikbasu/whispermax"

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Missing required command: $command_name" >&2
    exit 1
  fi
}

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  echo "Missing release archive: $ARCHIVE_PATH" >&2
  echo "Run ./Scripts/package-release.sh first." >&2
  exit 1
fi

find_generate_appcast_bin() {
  if [[ -n "${WHISPERMAX_GENERATE_APPCAST_BIN:-}" && -x "${WHISPERMAX_GENERATE_APPCAST_BIN}" ]]; then
    echo "${WHISPERMAX_GENERATE_APPCAST_BIN}"
    return 0
  fi

  local candidate
  while IFS= read -r candidate; do
    if [[ -x "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done < <(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path '*SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' \
    -type f 2>/dev/null | sort -r)

  echo "Could not find Sparkle's generate_appcast binary in Xcode DerivedData." >&2
  echo "Build whispermax once with Xcode/xcodebuild first, or set WHISPERMAX_GENERATE_APPCAST_BIN." >&2
  exit 1
}

mkdir -p "$RELEASE_NOTES_DIR"

GENERATE_APPCAST_BIN="$(find_generate_appcast_bin)"

TMP_DIR="$(mktemp -d)"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cp "$ARCHIVE_PATH" "$TMP_DIR/"

if [[ -f "$RELEASE_NOTES_PATH" ]]; then
  cp "$RELEASE_NOTES_PATH" "$TMP_DIR/${RELEASE_NAME}.md"
fi

"$GENERATE_APPCAST_BIN" \
  --download-url-prefix "$DOWNLOAD_URL_PREFIX" \
  --full-release-notes-url "$FULL_RELEASE_NOTES_URL" \
  --embed-release-notes \
  --link "$PRODUCT_LINK" \
  --maximum-versions 1 \
  "$TMP_DIR" >/dev/null

mkdir -p "$DOCS_DIR"
cp "$TMP_DIR/appcast.xml" "$DOCS_DIR/appcast.xml"

echo "Updated $DOCS_DIR/appcast.xml"
echo "Archive $ARCHIVE_PATH"
echo "Feed URL https://raw.githubusercontent.com/rittikbasu/whispermax/master/docs/appcast.xml"
