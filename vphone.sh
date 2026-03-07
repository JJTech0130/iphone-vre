#!/bin/sh
set -euo pipefail

# wrapper around the vphone binary that automatically
# rebuilds and packages as an app bundle for proper TCC support

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

swift build -c release
BINARY="${SCRIPT_DIR}/.build/release/vphone"
# resolve symlinks in $BINARY
BINARY="$(readlink -f "$BINARY")"
ENTITLEMENTS="${SCRIPT_DIR}/vphone.entitlements"
BUNDLE="${SCRIPT_DIR}/vphone.app"

# Assemble the app bundle
mkdir -p "${BUNDLE}/Contents/MacOS"
cp "${BINARY}" "${BUNDLE}/Contents/MacOS/vphone"
cp "${SCRIPT_DIR}/Info.plist" "${BUNDLE}/Contents/Info.plist"

# Sign the bundle (not just the inner binary) so TCC can resolve the bundle ID
codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${BUNDLE}"

# prompt for sudo password
sudo -v

sudo "$SCRIPT_DIR/scripts/amfid-allow.py" --path "${BUNDLE}/" &
AMFID_PID=$!

sleep 1 # give amfid-allow a moment to set up its hooks

# Run the binary directly from inside the bundle so NSBundle.main resolves
# the Info.plist and TCC sees the proper bundle identifier.
"${BUNDLE}/Contents/MacOS/vphone" "$@"
EXIT_CODE=$?

# if for some reason this went wrong, kill it
sudo kill "$AMFID_PID" 2>/dev/null || true

exit $EXIT_CODE
