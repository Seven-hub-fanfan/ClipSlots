#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${GATEWAY_LIVE_SCRATCH_PATH:-/tmp/clipslots-gateway-live-build}"
case "$SCRATCH" in
    /tmp/clipslots-gateway-live-*|/private/tmp/clipslots-gateway-live-*|/tmp/clipslots-rea-live-build) ;;
    *) printf '%s\n' "Use an isolated /tmp/clipslots-gateway-live-* scratch." >&2; exit 2 ;;
esac
cd "$ROOT"
if [ "${GATEWAY_LIVE_SKIP_BUILD:-0}" != "1" ]; then
    swift build --target ClipSlotsKit --scratch-path "$SCRATCH" --jobs 2 \
        > /tmp/clipslots-gateway-live-kit-build.log 2>&1
fi
BIN="$(swift build --scratch-path "$SCRATCH" --show-bin-path)"
OBJECTS=("$BIN"/ClipSlotsKit.build/*.swift.o)
swiftc -parse-as-library -I "$BIN/Modules" \
    scripts/gateway-fixtures/GatewayLiveMain.swift \
    "${OBJECTS[@]}" -o "$SCRATCH/gateway-live-tests" \
    > /tmp/clipslots-gateway-live-swift-compile.log 2>&1
swiftc -parse-as-library -I "$BIN/Modules" \
    Tests/ClipSlotsKitSmokeTests/AgentRunGatewayTests.swift \
    Tests/ClipSlotsKitSmokeTests/AgentAuthoritativeContextUsageTests.swift \
    Tests/ClipSlotsKitSmokeTests/AgentContextCompactionTranscriptTests.swift \
    Tests/ClipSlotsKitSmokeTests/AgentTaskSubagentProjectionTests.swift \
    Tests/ClipSlotsKitSmokeTests/AgentTaskSubagentGatewayTests.swift \
    scripts/gateway-fixtures/GatewayTestMain.swift \
    "${OBJECTS[@]}" -o "$SCRATCH/gateway-regression-tests" \
    > /tmp/clipslots-gateway-live-regression-compile.log 2>&1
"$SCRATCH/gateway-regression-tests" > /tmp/clipslots-gateway-live-regression-tests.log 2>&1
python3 gateway/test_live.py --swift-bin "$SCRATCH/gateway-live-tests" \
    > /tmp/clipslots-gateway-live-network-tests.log 2>&1
cat /tmp/clipslots-gateway-live-regression-tests.log
cat /tmp/clipslots-gateway-live-network-tests.log
