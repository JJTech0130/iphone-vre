#!/bin/sh
set -euo pipefail

# wrapper around the vphone binary that automatically
# rebuilds and hooks amfid

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="${SCRIPT_DIR}/.build/release/vphone"
# resolve symlinks in $BINARY
BINARY="$(readlink -f "$BINARY")"
echo "Building vphone binary at $BINARY..."
"$SCRIPT_DIR/scripts/build.sh"

# prompt for sudo password
sudo -v

sudo "$SCRIPT_DIR/scripts/amfid-allow.py" --path "${BINARY}" &
AMFID_PID=$!

sleep 1 # give amfid-allow a moment to set up its hooks

"$BINARY" "$@"
EXIT_CODE=$?

# if for some reason this went wrong, kill it
sudo kill "$AMFID_PID" 2>/dev/null || true

exit $EXIT_CODE
