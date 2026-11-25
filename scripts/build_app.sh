#!/bin/zsh
# Builds Babelcap.app (release, arm64) with xcodebuild — needed so MLX's Metal shaders (default.metallib) are compiled.
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

xcodebuild -scheme Babelcap -configuration Release -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode -skipPackagePluginValidation -skipMacroValidation build \
  | grep -E "error:|warning: unable|BUILD (SUCCEEDED|FAILED)" || true
P=.build/xcode/Build/Products/Release
[[ -x "$P/Babelcap" ]] || { echo "build failed"; exit 1; }

APP="build/Babelcap.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$P/Babelcap" "$APP/Contents/MacOS/Babelcap"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R Resources/Benchmark "$APP/Contents/Resources/Benchmark"
# SwiftPM resource bundles; MLX finds its Metal library (default.metallib) in mlx-swift_Cmlx.bundle here.
for b in "$P"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
# Dynamic frameworks from binary packages (Azure Speech SDK) go into Contents/Frameworks, signed with our identity
# (hardened runtime only loads libraries signed by the same team).
mkdir -p "$APP/Contents/Frameworks"
for f in "$P"/*.framework; do cp -R "$f" "$APP/Contents/Frameworks/"; done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Babelcap"
for f in "$APP/Contents/Frameworks"/*.framework; do codesign --force --options runtime -s "$IDENTITY" "$f"; done

ENT=Resources/Babelcap.entitlements
[[ "$IDENTITY" == "-" ]] && ENT=Resources/Babelcap-adhoc.entitlements
codesign --force --options runtime --entitlements "$ENT" -s "$IDENTITY" "$APP"
codesign --verify --verbose "$APP"
echo "Built $APP"
