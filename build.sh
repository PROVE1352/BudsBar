#!/bin/zsh
# Build BudsBar.app (release), ad-hoc sign it and install to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)/BudsBar

APP=build/BudsBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/BudsBar"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/en.lproj Resources/ko.lproj "$APP/Contents/Resources/"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=1 "$APP"

DEST="$HOME/Applications/BudsBar.app"
mkdir -p "$HOME/Applications"
# Quit a running copy first so the new binary is picked up.
pkill -x BudsBar 2>/dev/null && sleep 1 || true
rm -rf "$DEST"
cp -R "$APP" "$DEST"
echo "installed: $DEST"
echo "CLI: \"$DEST/Contents/MacOS/BudsBar\" --cli status"
