#!/bin/sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# build must happen before readlink
swift build -c release 2>&1 | tail -5

BINARY="${SCRIPT_DIR}/.build/release/fake-usb-keyboard"
BINARY="$(readlink -f "$BINARY")"
ENTITLEMENTS="${SCRIPT_DIR}/keyboard.entitlements"

codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${BINARY}"

sudo -v

sudo "$SCRIPT_DIR/scripts/amfid-allow.py" --path "${BINARY}" &
AMFID_PID=$!

sleep 1

"$BINARY" "$@"
EXIT_CODE=$?

sudo kill "$AMFID_PID" 2>/dev/null || true

exit $EXIT_CODE
