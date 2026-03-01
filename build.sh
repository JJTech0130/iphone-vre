#!/bin/sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="${SCRIPT_DIR}/.build/release/vphone"
ENTITLEMENTS="${SCRIPT_DIR}/vphone.entitlements"

swift build -c release 2>&1 | tail -5
codesign --force --sign - --entitlements "${ENTITLEMENTS}" "${BINARY}"
