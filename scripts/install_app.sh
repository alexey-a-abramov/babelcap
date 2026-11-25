#!/bin/zsh
# Build, sign with a STABLE identity, install to ~/Applications/Babelcap.app and launch.
# One fixed path + one fixed signing identity = macOS recognises it as the same, trusted app, so
# Keychain / Microphone / System-Audio permissions are asked once and survive rebuilds.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build_app.sh "${1:-}"

DEST="$HOME/Applications/Babelcap.app"
mkdir -p "$HOME/Applications"
pkill -x Babelcap 2>/dev/null || true
# The app used to be called Subveil: quit it and move the old copy to the Trash (its data is migrated on first launch).
pkill -x Subveil 2>/dev/null || true
sleep 0.5
if [[ -d "$HOME/Applications/Subveil.app" ]]; then
  osascript -e "tell application \"Finder\" to delete POSIX file \"$HOME/Applications/Subveil.app\"" >/dev/null \
    && echo "Moved the old Subveil.app to the Trash"
fi
rm -rf "$DEST"
cp -R build/Babelcap.app "$DEST"

echo "--- signature of installed app ---"
codesign --verify --strict --verbose=2 "$DEST"
REQ="$(codesign -dr - "$DEST" 2>&1 | grep designated || true)"
echo "$REQ"
if [[ "$REQ" != *"certificate leaf"* ]]; then
  echo "WARNING: ad-hoc signature — permissions will be re-requested after every rebuild." >&2
  echo "         Install an Apple Development / Developer ID certificate, or pass one as argument." >&2
fi
open "$DEST"
echo "Installed and launched: $DEST"
