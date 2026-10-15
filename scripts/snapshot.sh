#!/bin/bash
# Renders every page (light + dark) and every HUD state to PNGs without launching the app UI.
# Usage: scripts/snapshot.sh <output-dir>
# Uses its own SwiftPM scratch path so several checkouts can build at once.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?output dir}"
SCRATCH="${NEOLESS_SCRATCH:-.build-snapshot}"
swift build -c release --scratch-path "$SCRATCH" --product neoless 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | grep -v Compiling || true
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/neoless"
rm -rf "$OUT"; mkdir -p "$OUT"
"$BIN" --snapshot "$OUT" 2>&1 | grep -v "^20[0-9][0-9]-" || true
ls "$OUT"
