#!/usr/bin/env bash
set -euo pipefail
DEVICE="$1"
SIM="$2"
OUT="$3"
rm -rf "$OUT"
xcodebuild -create-xcframework -framework "$DEVICE" -framework "$SIM" -output "$OUT"