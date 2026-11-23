#!/bin/zsh
# Builds Subveil.app (release, arm64). Usage: scripts/build_app.sh [signing identity]
# Default: first "Apple Development" identity in the keychain (stable signature → Keychain/TCC permissions
# survive rebuilds); falls back to ad-hoc "-". Use your Developer ID for distribution + notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${1:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')"
  IDENTITY="${IDENTITY:--}"
fi
echo "Signing with: $IDENTITY"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Subveil"
APP="build/Subveil.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Subveil"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --options runtime --entitlements Resources/Subveil.entitlements -s "$IDENTITY" "$APP"
codesign --verify --verbose "$APP"
echo "Built $APP"
