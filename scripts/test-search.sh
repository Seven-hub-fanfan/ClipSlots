#!/bin/bash
set -euo pipefail
ROOT="$(dirname "$(dirname "$(realpath "$0")")")"
SCRATCH="${SEARCH_SCRATCH_PATH:-/private/tmp/clipslots-search-build}"
case "$SCRATCH" in
    /private/tmp/clipslots-search-*|/tmp/clipslots-search-*) ;;
    *) printf '%s\n' "Use an isolated /private/tmp/clipslots-search-* scratch." >&2; exit 2 ;;
esac
swift build --package-path "$ROOT" --product ClipSlotsKitSmokeTests --scratch-path "$SCRATCH" --jobs 2
BIN="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" --show-bin-path)"
CLIPSLOTS_DATA_DIR="$SCRATCH/data" CLIPSLOTS_SEARCH_CACHE_DIR="$SCRATCH/cache" \
    "$BIN/ClipSlotsKitSmokeTests" --search-snapshot-only
swiftc -parse-as-library -I "$BIN/Modules" \
    "$ROOT/Sources/ClipSlots/SlotGlobalSearchResult.swift" \
    "$ROOT/Sources/ClipSlots/SlotSearchSortRule.swift" \
    "$ROOT/Sources/ClipSlots/SlotContent+Thumbnail.swift" \
    "$ROOT/Sources/ClipSlots/ThumbnailDecodeLimiter.swift" \
    "$ROOT/scripts/gateway-fixtures/SearchOrderingMain.swift" \
    "$BIN"/ClipSlotsKit.build/*.swift.o -o "$SCRATCH/search-ordering"
"$SCRATCH/search-ordering"
