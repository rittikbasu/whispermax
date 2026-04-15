#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEST_DIR="${ROOT_DIR}/Vendor"
FRAMEWORK_DIR="${DEST_DIR}/whisper.xcframework"
NESTED_FRAMEWORK_DIR="${DEST_DIR}/build-apple/whisper.xcframework"
VERSION="${1:-v1.8.4}"
ZIP_NAME="whisper-${VERSION}-xcframework.zip"
URL="https://github.com/ggml-org/whisper.cpp/releases/download/${VERSION}/${ZIP_NAME}"

if [[ -d "${FRAMEWORK_DIR}" ]]; then
  echo "whisper.xcframework already installed at ${FRAMEWORK_DIR}"
  exit 0
fi

if [[ -d "${NESTED_FRAMEWORK_DIR}" ]]; then
  mv "${NESTED_FRAMEWORK_DIR}" "${FRAMEWORK_DIR}"
  rm -rf "${DEST_DIR}/build-apple"
  echo "Normalized existing whisper.xcframework into ${FRAMEWORK_DIR}"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

mkdir -p "${DEST_DIR}"

echo "Downloading ${URL}"
curl -L --fail --output "${TMP_DIR}/${ZIP_NAME}" "${URL}"
unzip -q "${TMP_DIR}/${ZIP_NAME}" -d "${DEST_DIR}"

if [[ -d "${NESTED_FRAMEWORK_DIR}" ]]; then
  mv "${NESTED_FRAMEWORK_DIR}" "${FRAMEWORK_DIR}"
  rm -rf "${DEST_DIR}/build-apple"
fi

if [[ ! -d "${FRAMEWORK_DIR}" ]]; then
  echo "Failed to install whisper.xcframework"
  exit 1
fi

echo "Installed whisper.xcframework to ${FRAMEWORK_DIR}"
