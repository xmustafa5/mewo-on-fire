#!/bin/sh
# Installs ccnotify from the latest GitHub release: downloads the build for
# this computer (Linux x86_64 or macOS) and runs `ccnotify install`, which
# sets up the background service, the Claude Code hooks and the bell icon.
#
#   curl -fsSL https://<download site>/install.sh | sh
#   curl -fsSL https://github.com/xmustafa5/mewo-on-fire/releases/latest/download/install.sh | sh
#
# CCNOTIFY_VERSION=v0.1.0 installs that release instead of the latest one
# (GitHub downloads only).
set -eu

REPO="${CCNOTIFY_REPO:-xmustafa5/mewo-on-fire}"
VERSION="${CCNOTIFY_VERSION:-latest}"
# The download site (web/) fills this in when it serves the script, so the
# archives come from it instead of GitHub.
DOWNLOAD_URL="${CCNOTIFY_DOWNLOAD_URL:-}"

case "$(uname -s)/$(uname -m)" in
  Linux/x86_64 | Linux/amd64) asset=ccnotify-linux-x86_64.tar.gz ;;
  Darwin/*) asset=ccnotify-macos.tar.gz ;;
  *)
    echo "ccnotify: there is no prebuilt release for $(uname -s) $(uname -m)." >&2
    echo "Build it from source: https://github.com/$REPO/tree/main/pc" >&2
    exit 1
    ;;
esac

if [ -n "$DOWNLOAD_URL" ]; then
  url="$DOWNLOAD_URL/$asset"
elif [ "$VERSION" = latest ]; then
  url="https://github.com/$REPO/releases/latest/download/$asset"
else
  url="https://github.com/$REPO/releases/download/$VERSION/$asset"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'exit 1' INT TERM

echo "Downloading $url"
if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$url" -o "$tmp/$asset"
elif command -v wget >/dev/null 2>&1; then
  wget -qO "$tmp/$asset" "$url"
else
  echo "ccnotify: curl or wget is needed" >&2
  exit 1
fi
tar -xzf "$tmp/$asset" -C "$tmp"

"$tmp/ccnotify" install
