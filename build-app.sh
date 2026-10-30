#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

swift build -c release
APP="$ROOT/dist/SpinDisplay.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SpinDisplayMac "$APP/Contents/MacOS/SpinDisplayMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
# The manufacturer manual is not in the repository (copyright); bundle a local copy if one exists.
if [ -f Resources/help.pdf ]; then
  cp Resources/help.pdf "$APP/Contents/Resources/help.pdf"
else
  rm -f "$APP/Contents/Resources/help.pdf"
fi
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
printf 'Built native app: %s\n' "$APP"
