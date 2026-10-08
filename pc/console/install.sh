#!/bin/sh
# Builds the operations console, installs it as "~/Applications/Mewo Console.app" and opens it.
set -e
cd "$(dirname "$0")"

swift build -c release

APP="$HOME/Applications/Mewo Console.app"
# Replace a running copy.
pkill -x mewo-console 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/mewo-console "$APP/Contents/MacOS/mewo-console"
cp Info.plist "$APP/Contents/Info.plist"
# The page itself is the same one `mewo dashboard` serves.
cp ../dashboard/index.html "$APP/Contents/Resources/index.html"
cp ../menubar/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature: enough to run on this Mac.
codesign --force --sign - "$APP"

open "$APP"
echo "Installed $APP."
