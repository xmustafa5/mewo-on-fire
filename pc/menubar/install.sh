#!/bin/sh
# Builds the menu bar app, installs it as ~/Applications/mewo-on-fire.app and opens it.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="$HOME/Applications/mewo-on-fire.app"
# Replace a running copy.
pkill -x mewo-menubar 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/mewo-menubar "$APP/Contents/MacOS/mewo-menubar"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature: enough to run on this Mac.
codesign --force --sign - "$APP"

open "$APP"
echo "Installed $APP. Look for the bell in the menu bar."
echo "It opens at login; turn that off with \"Open at Login\" in its ⋯ menu."
