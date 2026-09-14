#!/bin/bash
set -euo pipefail

REPO="AlexBaldman/Popmoji"
VERSION="${POPMOJI_VERSION:-0.1.1}"
INSTALL_DIR="${POPMOJI_INSTALL_DIR:-/Applications}"
if [ ! -d "$INSTALL_DIR" ] || [ ! -w "$INSTALL_DIR" ]; then
  INSTALL_DIR="$HOME/Applications"
  mkdir -p "$INSTALL_DIR"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
ARCHIVE="$TMP_DIR/Popmoji.zip"
URL="https://github.com/$REPO/releases/download/v$VERSION/Popmoji-$VERSION.zip"

echo "Downloading Popmoji v$VERSION…"
curl -fL --retry 3 --silent --show-error "$URL" -o "$ARCHIVE"
unzip -q "$ARCHIVE" -d "$TMP_DIR/unpacked"
rm -rf "$INSTALL_DIR/Popmoji.app"
cp -R "$TMP_DIR/unpacked/Popmoji.app" "$INSTALL_DIR/Popmoji.app"
codesign --verify --deep --strict "$INSTALL_DIR/Popmoji.app"
open "$INSTALL_DIR/Popmoji.app"
echo "Installed Popmoji to $INSTALL_DIR/Popmoji.app"
echo "Enable Accessibility at System Settings → Privacy & Security → Accessibility."
