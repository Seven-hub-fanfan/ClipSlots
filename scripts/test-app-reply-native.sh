#!/bin/bash
set -euo pipefail

ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
SCRATCH="${APP_REPLY_SCRATCH_PATH:-/tmp/clipslots-app-reply-build}"
case "$SCRATCH" in
    /tmp/clipslots-app-reply-*|/private/tmp/clipslots-app-reply-*) ;;
    *) printf '%s\n' "Use an isolated /tmp/clipslots-app-reply-* scratch." >&2; exit 2 ;;
esac
swift build --package-path "$ROOT" --target ClipSlotsKit --scratch-path "$SCRATCH" --jobs 2
BIN="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)"
swiftc -parse-as-library -I "$BIN/Modules" \
    "$ROOT/scripts/gateway-fixtures/GatewayAppReplyLiveMain.swift" \
    "$BIN"/ClipSlotsKit.build/*.swift.o -o "$SCRATCH/app-reply-native-tests"
python3 -B "$ROOT/scripts/test-app-reply-native.py" --binary "$SCRATCH/app-reply-native-tests"
