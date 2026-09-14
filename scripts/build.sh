#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
APP="$PWD/dist/Popmoji.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Popmoji "$APP/Contents/MacOS/Popmoji"
cp Info.plist "$APP/Contents/Info.plist"
# Bundle.module resolves the adjacent resource bundle inside the app's main bundle.
cp -R .build/release/Popmoji_Popmoji.bundle "$APP/Contents/Resources/"
if [ -f assets/Popmoji.icns ]; then
  cp assets/Popmoji.icns "$APP/Contents/Resources/Popmoji.icns"
fi
codesign --force --sign - --identifier local.popmoji.app "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built %s\n' "$APP"
