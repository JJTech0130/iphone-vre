#!/bin/sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="${SCRIPT_DIR}/.build/debug/fake-usb-keyboard"
BINARY="$(readlink -f "$BINARY")"
echo "Building fake-usb-keyboard binary at $BINARY..."
ENTITLEMENTS="${SCRIPT_DIR}/keyboard.entitlements"

swift build --target fake-usb-keyboard 2>&1 | tail -5
codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${BINARY}"

sudo -v

sudo "$SCRIPT_DIR/scripts/amfid-allow.py" --path "${BINARY}" &
AMFID_PID=$!

sleep 1

"$BINARY" "$@"
EXIT_CODE=$?

sudo kill "$AMFID_PID" 2>/dev/null || true

exit $EXIT_CODE
