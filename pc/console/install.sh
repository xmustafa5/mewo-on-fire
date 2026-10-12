#!/bin/sh
# Installs the operations console and opens it: "~/Applications/Mewo Console.app"
# on macOS, the Linux window (linux/) with an application menu entry on Linux.
set -e
cd "$(dirname "$0")"

if [ "$(uname -s)" = "Linux" ]; then
  if ! python3 -c 'import gi; gi.require_version("Gtk", "3.0"); gi.require_version("WebKit2", "4.1")' 2>/dev/null; then
    echo "The console needs GTK and WebKitGTK for Python: sudo apt install python3-gi gir1.2-webkit2-4.1" >&2
    exit 1
  fi
  command -v mewo >/dev/null 2>&1 || [ -x "$HOME/.local/bin/mewo" ] \
    || echo "Note: the mewo command is not installed yet; the console runs it (curl -fsSL https://www.mewo-on-fire.com/install.sh | sh)."

  SHARE="${XDG_DATA_HOME:-$HOME/.local/share}"
  DIR="$SHARE/mewo-on-fire/console"
  ENTRY="$SHARE/applications/com.torchcorp.mewo-on-fire.console.desktop"
  # Replace a running copy.
  pkill -f "$DIR/mewo-console" 2>/dev/null || true
  mkdir -p "$DIR" "$HOME/.local/bin" "$SHARE/applications"
  install -m 755 linux/mewo-console "$DIR/mewo-console"
  install -m 644 ../../mobile/assets/mewo.png "$DIR/mewo-console.png"
  ln -sf "$DIR/mewo-console" "$HOME/.local/bin/mewo-console"
  cat > "$ENTRY" <<EOF
[Desktop Entry]
Type=Application
Name=Mewo Console
Comment=Mewo on Fire operations console: sessions, flow and the fleet
Exec=$DIR/mewo-console
Icon=$DIR/mewo-console.png
Terminal=false
Categories=Development;Utility;
StartupWMClass=mewo-console
EOF
  update-desktop-database "$SHARE/applications" 2>/dev/null || true

  nohup "$DIR/mewo-console" >/dev/null 2>&1 &
  echo "Installed Mewo Console (application menu, or \`mewo-console\`)."
  exit 0
fi

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
cp ../dashboard/robot-heads.js "$APP/Contents/Resources/robot-heads.js"
cp ../menubar/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc signature: enough to run on this Mac.
codesign --force --sign - "$APP"

open "$APP"
echo "Installed $APP."
