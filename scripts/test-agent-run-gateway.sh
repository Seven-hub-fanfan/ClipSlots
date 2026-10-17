#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${GATEWAY_SCRATCH_PATH:-/tmp/clipslots-gateway-build}"
case "$SCRATCH" in
    /tmp/*|/private/tmp/*) ;;
    *) printf '%s\n' "Gateway scratch path must be under /tmp, never the shared .build." >&2; exit 2 ;;
esac
cd "$ROOT"
swift build --target ClipSlotsKit --scratch-path "$SCRATCH" --jobs 4 > "$SCRATCH.log" 2>&1
BIN="$(swift build --scratch-path "$SCRATCH" --show-bin-path)"
OBJECTS=("$BIN"/ClipSlotsKit.build/*.swift.o)
swiftc -parse-as-library -I "$BIN/Modules" \
    Tests/ClipSlotsKitSmokeTests/AgentRunGatewayTests.swift \
    scripts/gateway-fixtures/GatewayTestMain.swift \
    "${OBJECTS[@]}" -o "$SCRATCH/gateway-fixture-tests"
"$SCRATCH/gateway-fixture-tests"
swiftc -parse-as-library -I "$BIN/Modules" \
    Sources/ClipSlots/AgentBackendCoordinator.swift \
    Sources/ClipSlots/AgentConfigView.swift \
    Sources/ClipSlots/AgentPolishButton.swift \
    scripts/gateway-fixtures/GatewayAppIntegrationMain.swift \
    "${OBJECTS[@]}" -o "$SCRATCH/gateway-app-fixture-tests"
"$SCRATCH/gateway-app-fixture-tests"
