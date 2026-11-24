#!/bin/zsh
# Packages build/Subveil-<version>-arm64.zip for a GitHub release.
# Signed ad-hoc on purpose: a personal development certificate gives other users no Gatekeeper benefit and would
# embed its name in the binary. For a warning-free download use a Developer ID identity + notarization instead.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
swift test
./scripts/build_app.sh "${1:--}"
ZIP="build/Subveil-${VERSION}-arm64.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Subveil.app "$ZIP"
shasum -a 256 "$ZIP"
echo "$ZIP"
