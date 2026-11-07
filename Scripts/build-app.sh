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

# Compile the native icon stack so macOS does not wrap a legacy icon in another tile.
ICON_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp/}SoftLiveIcon.XXXXXX")"
trap 'rm -rf "$ICON_BUILD_DIR"' EXIT
xcrun actool --output-format human-readable-text --platform macosx --target-device mac \
    --minimum-deployment-target 26.0 --app-icon AppIcon \
    --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist" \
    --compile "$ICON_BUILD_DIR" Resources/Branding/AppIcon.icon

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SoftLive"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp "$ICON_BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ICON_BUILD_DIR/Assets.car" "$APP/Contents/Resources/Assets.car"
cp Sources/SoftLive/UI/Branding/Resources/SyncTemplate.png "$APP/Contents/Resources/SyncTemplate.png"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--run" ]]; then
    pkill -x SoftLive || true
    open "$APP"
fi
