#!/bin/zsh
# Builds Subveil.app (release, arm64). Usage: scripts/build_app.sh [signing identity]
# Default identity "-" = ad-hoc (fine locally; use your Developer ID for distribution + notarization).
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${1:--}"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Subveil"
APP="build/Subveil.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Subveil"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --entitlements Resources/Subveil.entitlements -s "$IDENTITY" "$APP"
codesign --verify --verbose "$APP"
echo "Built $APP"
