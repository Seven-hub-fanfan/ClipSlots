#!/bin/bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
SCRATCH="${DIRECTORY_TOOLS_SCRATCH_PATH:-/private/tmp/clipslots-directory-tools-build}"
case "$SCRATCH" in
    /private/tmp/clipslots-directory-tools-*|/tmp/clipslots-directory-tools-*) ;;
    *) printf '%s\n' "Use an isolated /tmp/clipslots-directory-tools-* scratch." >&2; exit 2 ;;
esac
swift build --package-path "$ROOT" --target ClipSlotsKit --scratch-path "$SCRATCH" --jobs 2
BIN="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)"
for FIXTURE in Batch Process; do
    swiftc -parse-as-library -I "$BIN/Modules" \
        "$ROOT/scripts/gateway-fixtures/Directory${FIXTURE}Main.swift" \
        "$BIN"/ClipSlotsKit.build/*.swift.o -o "$SCRATCH/directory-${FIXTURE}-tests"
done
swiftc -parse-as-library -I "$BIN/Modules" \
    "$ROOT/Sources/ClipSlots/AgentWorkingDirectoryStore.swift" \
    "$ROOT/scripts/gateway-fixtures/DirectoryGrantMain.swift" \
    "$BIN"/ClipSlotsKit.build/*.swift.o -o "$SCRATCH/directory-Grant-tests"
swiftc -parse-as-library -I "$BIN/Modules" \
    "$ROOT/Sources/ClipSlots/AgentWorkingDirectoryStore.swift" \
    "$ROOT/scripts/gateway-fixtures/DirectoryJournalMain.swift" \
    "$BIN"/ClipSlotsKit.build/*.swift.o -o "$SCRATCH/directory-Journal-tests"
python3 -B "$ROOT/scripts/test-directory-batch.py" --binary "$SCRATCH/directory-Batch-tests" --report "$SCRATCH/batch.json"
python3 -B "$ROOT/scripts/test-directory-process.py" --binary "$SCRATCH/directory-Process-tests" --report "$SCRATCH/process.json"
python3 -B "$ROOT/scripts/test-directory-grant.py" --binary "$SCRATCH/directory-Grant-tests" --report "$SCRATCH/grant.json"
python3 -B "$ROOT/scripts/test-directory-journal.py" --binary "$SCRATCH/directory-Journal-tests" --report "$SCRATCH/journal.json"
