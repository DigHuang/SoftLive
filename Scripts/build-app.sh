#!/usr/bin/env bash
# Builds SoftLive.app into ./build.
#   Scripts/build-app.sh          release build
#   Scripts/build-app.sh --run    build, then (re)launch the app
#
# macOS ties the Automation grant (Apple Music) to the code signature. Ad-hoc signatures change
# on every build, so set SIGN_IDENTITY to a stable certificate (see `security find-identity -p codesigning`)
# to keep the grants across rebuilds.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="build/SoftLive.app"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/SoftLive"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SoftLive"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x SoftLive || true
    open "$APP"
fi
