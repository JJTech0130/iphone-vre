#!/bin/zsh

set -euo pipefail
cd "$(dirname "$0")"

./build_and_sign.sh

./.build/release/vphone-cli \
    --rom ./VM/AVPBooter.vresearch1.bin \
    --disk ./VM/Disk.img \
    --nvram ./VM/nvram.bin \
    --cpu 4 \
    --memory 4096 \
    --serial-log ./VM/serial.log \
    --stop-on-panic \
    --stop-on-fatal-error \
    --sep-rom ./VM/AVPSEPBooter.vresearch1.bin \
    --sep-storage ./VM/SEPStorage \
