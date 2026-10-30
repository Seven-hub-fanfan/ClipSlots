#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${JOURNAL_SCRATCH_PATH:?Set a private build directory}"
EVIDENCE="${JOURNAL_EVIDENCE_PATH:?Set an isolated evidence directory}"
case "$SCRATCH" in /tmp/*|/private/tmp/*) ;; *) exit 2 ;; esac
case "$EVIDENCE" in /tmp/clipslots-journal-*|/private/tmp/clipslots-journal-*) ;; *) exit 2 ;; esac
swift build --package-path "$ROOT" --target ClipSlotsKit --scratch-path "$SCRATCH" --jobs 4 > "$SCRATCH/journal-build.log" 2>&1
BIN="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)"
swiftc -parse-as-library -I "$BIN/Modules" "$ROOT/scripts/gateway-fixtures/JournalTestMain.swift" \
    "$BIN"/ClipSlotsKit.build/*.swift.o -o "$SCRATCH/journal-persistence-tests"
"$SCRATCH/journal-persistence-tests" test "$EVIDENCE"
