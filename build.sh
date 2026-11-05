#!/bin/zsh
# Builds NotchTune.app from source. No downloads, no dependencies.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=NotchTune.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotchTune "$APP/Contents/MacOS/NotchTune"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"   # local ad-hoc signature
echo "Built $(pwd)/$APP"
