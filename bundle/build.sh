#!/bin/bash
# Build the Claude.app notification wrapper bundle.
#
# Produces: $OUT_DIR/Claude.app (default: $HOME/.claude/assets/Claude.app)
#
# Optional: drop an AppIcon.icns into bundle/ before running to give the
# notification a custom icon. Without it, the default Swift app icon shows.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${CLAUDE_NOTIFY_BUNDLE_OUT:-$HOME/.claude/assets}"
APP="$OUT_DIR/Claude.app"

command -v swiftc >/dev/null || {
  echo "error: swiftc not found. Install Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
}

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$HERE/Info.plist" "$APP/Contents/Info.plist"

if [ -f "$HERE/AppIcon.icns" ]; then
  cp "$HERE/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  echo "icon: using $HERE/AppIcon.icns"
else
  echo "icon: none found at $HERE/AppIcon.icns (notification will use default app icon)"
fi

swiftc -O -o "$APP/Contents/MacOS/notify" "$HERE/notify.swift"

# Touch the bundle so LaunchServices picks up the new/updated icon.
touch "$APP"

echo "built: $APP"
