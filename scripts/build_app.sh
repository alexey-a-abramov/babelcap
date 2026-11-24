#!/bin/zsh
# Builds Subveil.app (release, arm64) with xcodebuild — needed so MLX's Metal shaders (default.metallib) are compiled.
# Usage: scripts/build_app.sh [signing identity]
# Default: first "Apple Development" identity in the keychain (stable signature → Keychain/TCC permissions survive
# rebuilds); falls back to ad-hoc "-". Use your Developer ID for distribution + notarization.
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${1:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')"
  IDENTITY="${IDENTITY:--}"
fi
echo "Signing with: $IDENTITY"

xcodebuild -scheme Subveil -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode -skipPackagePluginValidation -skipMacroValidation build \
  | grep -E "error:|warning: unable|BUILD (SUCCEEDED|FAILED)" || true
P=.build/xcode/Build/Products/Release
[[ -x "$P/Subveil" ]] || { echo "build failed"; exit 1; }

APP="build/Subveil.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$P/Subveil" "$APP/Contents/MacOS/Subveil"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Benchmark "$APP/Contents/Resources/Benchmark"
# SwiftPM resource bundles; MLX finds its Metal library (default.metallib) in mlx-swift_Cmlx.bundle here.
for b in "$P"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done

codesign --force --options runtime --entitlements Resources/Subveil.entitlements -s "$IDENTITY" "$APP"
codesign --verify --verbose "$APP"
echo "Built $APP"
