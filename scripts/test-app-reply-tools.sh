#!/bin/bash
set -euo pipefail

ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
SCRATCH="${APP_REPLY_TOOLS_SCRATCH_PATH:-/tmp/clipslots-app-reply-tools-build}"
case "$SCRATCH" in
    /tmp/clipslots-app-reply-tools-*|/private/tmp/clipslots-app-reply-tools-*) ;;
    *) printf '%s\n' "Use an isolated /tmp/clipslots-app-reply-tools-* scratch." >&2; exit 2 ;;
esac
swift build --package-path "$ROOT" --target ClipSlotsKit --scratch-path "$SCRATCH" --jobs 2
BIN="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)"
swiftc -parse-as-library -I "$BIN/Modules" \
    "$ROOT/scripts/gateway-fixtures/GatewayAppReplyToolsMain.swift" \
    "$BIN"/ClipSlotsKit.build/*.swift.o -o "$SCRATCH/app-reply-tools-tests"
python3 -B "$ROOT/scripts/test-app-reply-tools.py" --binary "$SCRATCH/app-reply-tools-tests"
