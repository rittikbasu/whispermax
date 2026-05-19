#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
RESOURCE_DIR="$ROOT_DIR/Scripts/Resources"

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

require_command ditto
require_command hdiutil
require_command osascript
require_command shasum
require_command swift
require_command sips

PRODUCT_NAME="$(yaml_value PRODUCT_NAME)"
VERSION="$(yaml_value MARKETING_VERSION)"

if [[ -z "$PRODUCT_NAME" || -z "$VERSION" ]]; then
  echo "Failed to read PRODUCT_NAME or MARKETING_VERSION from project.yml" >&2
  exit 1
fi

RELEASE_NAME="${PRODUCT_NAME}-v${VERSION}-macos"
ZIP_PATH="$DIST_DIR/${RELEASE_NAME}.zip"
DMG_PATH="$DIST_DIR/${RELEASE_NAME}.dmg"
DMG_CHECKSUM_PATH="$DIST_DIR/${RELEASE_NAME}.dmg.sha256"
STABLE_DMG_PATH="$DIST_DIR/${PRODUCT_NAME}-macos.dmg"
STABLE_DMG_CHECKSUM_PATH="$DIST_DIR/${PRODUCT_NAME}-macos.dmg.sha256"
VOLUME_NAME="$PRODUCT_NAME"
BACKGROUND_SOURCE_PATH="$RESOURCE_DIR/dmg-background-source.png"
APPLICATIONS_ICON_PATH="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/ApplicationsFolderIcon.icns"
ALIAS_BADGE_ICON_PATH="/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AliasBadgeIcon.icns"

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Missing release archive: $ZIP_PATH" >&2
  echo "Run ./Scripts/package-release.sh first." >&2
  exit 1
fi

if [[ ! -f "$BACKGROUND_SOURCE_PATH" ]]; then
  echo "Missing DMG background source: $BACKGROUND_SOURCE_PATH" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
EXTRACT_DIR="$TMP_DIR/extracted"
STAGING_DIR="$TMP_DIR/staging"
BACKGROUND_DIR="$STAGING_DIR/.background"
BACKGROUND_PATH="$BACKGROUND_DIR/background.jpg"
RW_DMG_PATH="$TMP_DIR/${RELEASE_NAME}-rw.dmg"
MOUNT_DIR=""

cleanup() {
  if [[ -n "$MOUNT_DIR" ]] && mount | grep -q "on $MOUNT_DIR "; then
    hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

detach_existing_volume_mounts() {
  mount | awk -v volume="/Volumes/$VOLUME_NAME" '
    {
      marker = index($0, " on ")
      if (marker == 0) next
      rest = substr($0, marker + 4)
      end = index(rest, " (")
      if (end == 0) next
      path = substr(rest, 1, end - 1)
      if (path == volume || index(path, volume " ") == 1) print path
    }
  ' | while read -r mounted_path; do
    hdiutil detach "$mounted_path" -quiet || true
  done
}

mkdir -p "$EXTRACT_DIR" "$STAGING_DIR" "$BACKGROUND_DIR" "$DIST_DIR"
rm -f "$DMG_PATH" "$DMG_CHECKSUM_PATH" "$STABLE_DMG_PATH" "$STABLE_DMG_CHECKSUM_PATH"
detach_existing_volume_mounts

ditto -x -k "$ZIP_PATH" "$EXTRACT_DIR"

APP_PATH="$(find "$EXTRACT_DIR" -maxdepth 1 -name '*.app' -type d | head -n 1)"
if [[ -z "$APP_PATH" ]]; then
  echo "No .app bundle found inside $ZIP_PATH" >&2
  exit 1
fi

APP_BUNDLE_NAME="$(basename "$APP_PATH")"
ditto "$APP_PATH" "$STAGING_DIR/$APP_BUNDLE_NAME"

# Use a Finder alias so the target behaves like a normal /Applications drop
# target. We set a composite system icon below because Finder label/icon rendering
# inside custom-background DMGs is inconsistent across macOS versions.
if ! osascript <<APPLESCRIPT >/dev/null 2>&1
set targetFolder to POSIX file "$STAGING_DIR" as alias
tell application "Finder"
  make new alias file to (POSIX file "/Applications" as alias) at targetFolder with properties {name:"Applications"}
end tell
APPLESCRIPT
then
  ln -s /Applications "$STAGING_DIR/Applications"
fi

if [[ ! -L "$STAGING_DIR/Applications" && -f "$APPLICATIONS_ICON_PATH" && -f "$ALIAS_BADGE_ICON_PATH" ]]; then
  swift - "$STAGING_DIR/Applications" "$APPLICATIONS_ICON_PATH" "$ALIAS_BADGE_ICON_PATH" <<'SWIFT'
import AppKit

let targetPath = CommandLine.arguments[1]
let applicationsIconPath = CommandLine.arguments[2]
let aliasBadgeIconPath = CommandLine.arguments[3]

guard
    let applicationsIcon = NSImage(contentsOfFile: applicationsIconPath),
    let aliasBadgeIcon = NSImage(contentsOfFile: aliasBadgeIconPath)
else {
    fatalError("Could not load system Applications alias assets")
}

let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
applicationsIcon.draw(
    in: NSRect(x: 0, y: 0, width: 1024, height: 1024),
    from: .zero,
    operation: .sourceOver,
    fraction: 1
)
aliasBadgeIcon.draw(
    in: NSRect(x: 12, y: 26, width: 250, height: 250),
    from: NSRect(x: 0, y: 0, width: 190, height: 190),
    operation: .sourceOver,
    fraction: 1
)
image.unlockFocus()

if !NSWorkspace.shared.setIcon(image, forFile: targetPath, options: []) {
    fatalError("Could not set Applications drop target icon")
}
SWIFT
fi

sips -s format jpeg -s formatOptions 96 -s dpiWidth 144 -s dpiHeight 144 "$BACKGROUND_SOURCE_PATH" --out "$BACKGROUND_PATH" >/dev/null

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -format UDRW \
  -fs HFS+ \
  -quiet \
  -ov \
  "$RW_DMG_PATH"

ATTACH_OUTPUT="$(hdiutil attach "$RW_DMG_PATH" -readwrite -noverify -noautoopen)"
MOUNT_DIR="$(echo "$ATTACH_OUTPUT" | awk '/\/Volumes\// { print substr($0, index($0, "/Volumes/")); exit }')"

if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  echo "Failed to mount writable DMG." >&2
  echo "$ATTACH_OUTPUT" >&2
  exit 1
fi

osascript <<APPLESCRIPT
set targetFolder to POSIX file "$MOUNT_DIR" as alias
tell application "Finder"
  open targetFolder
  set containerWindow to container window of targetFolder
  set current view of containerWindow to icon view
  set toolbar visible of containerWindow to false
  set statusbar visible of containerWindow to false
  try
    set pathbar visible of containerWindow to false
  end try
  try
    set sidebar width of containerWindow to 0
  end try
  set bounds of containerWindow to {120, 120, 840, 570}

  set viewOptions to icon view options of containerWindow
  set arrangement of viewOptions to not arranged
  set icon size of viewOptions to 112
  set text size of viewOptions to 13
  set background picture of viewOptions to file ".background:background.jpg" of targetFolder

  set position of every item of targetFolder to {900, 900}
  set position of item "$APP_BUNDLE_NAME" of targetFolder to {212, 218}
  set position of item "Applications" of targetFolder to {508, 218}
  try
    set extension hidden of item "$APP_BUNDLE_NAME" of targetFolder to true
  end try

  set selection to {}
  update targetFolder without registering applications
  delay 2
  close containerWindow
  delay 2
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""
hdiutil convert "$RW_DMG_PATH" -format UDZO -imagekey zlib-level=9 -quiet -ov -o "$DMG_PATH"
hdiutil verify "$DMG_PATH" -quiet

ditto "$DMG_PATH" "$STABLE_DMG_PATH"

DMG_CHECKSUM="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
STABLE_DMG_CHECKSUM="$(shasum -a 256 "$STABLE_DMG_PATH" | awk '{print $1}')"

printf '%s  %s\n' "$DMG_CHECKSUM" "$(basename "$DMG_PATH")" > "$DMG_CHECKSUM_PATH"
printf '%s  %s\n' "$STABLE_DMG_CHECKSUM" "$(basename "$STABLE_DMG_PATH")" > "$STABLE_DMG_CHECKSUM_PATH"

echo "Created $DMG_PATH"
echo "Created $STABLE_DMG_PATH"
echo "SHA256 $DMG_CHECKSUM"
