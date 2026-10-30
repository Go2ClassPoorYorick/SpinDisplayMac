#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

swift build -c release
APP="$ROOT/dist/SpinDisplay.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/SpinDisplayMac "$APP/Contents/MacOS/SpinDisplayMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"
printf 'Built native app: %s\n' "$APP"
