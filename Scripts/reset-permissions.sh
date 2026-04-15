#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="${WHISPERMAX_BUNDLE_ID:-$(awk '/PRODUCT_BUNDLE_IDENTIFIER:/ { print $2; exit }' "$ROOT_DIR/project.yml")}"

if [[ -z "$BUNDLE_ID" ]]; then
  echo "Unable to resolve bundle identifier from project.yml" >&2
  exit 1
fi

/usr/bin/tccutil reset Accessibility "$BUNDLE_ID" || true
/usr/bin/tccutil reset Microphone "$BUNDLE_ID" || true
/usr/bin/tccutil reset PostEvent "$BUNDLE_ID" || true
/usr/bin/tccutil reset ListenEvent "$BUNDLE_ID" || true
