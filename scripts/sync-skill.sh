#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SKILL="$ROOT_DIR/skills/clipslots-manager/SKILL.md"
LEGACY_DRAFT="$ROOT_DIR/docs/clipslots-cli-skill-draft.md"
MODE="${1:-}"
if [[ $# -gt 1 || ( -n "$MODE" && "$MODE" != "--check" ) ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 2
fi

# The bundled skill declares itself the canonical source. Older checkouts may
# still have a draft: preserve that workflow, but fail check mode on drift.
if [[ -f "$LEGACY_DRAFT" ]]; then
  if [[ "$MODE" == "--check" ]]; then
    cmp "$LEGACY_DRAFT" "$SKILL"
  else
    mkdir -p "$(dirname "$SKILL")"
    cp "$LEGACY_DRAFT" "$SKILL"
  fi
fi
test -s "$SKILL"
grep -q '^name: clipslots-manager$' "$SKILL"
echo "OK: bundled clipslots-manager skill is ready"
