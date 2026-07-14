#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
MODE=dry-run

# The implementation reads this variable, so never inherit an apply request
# from the caller's shell. Only the explicit --apply branch below may set it.
unset SPYCLASH_BACKFILL_APPLY

case "${1:-}" in
  "") ;;
  --apply) MODE=apply ;;
  *)
    echo "Usage: $0 [--apply]" >&2
    exit 64
    ;;
esac

if [ "$MODE" = apply ]; then
  APP_ID=$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/base44/.app.jsonc" | head -n 1)
  [ -n "$APP_ID" ] || exit 65
  case "$APP_ID" in
    *[!A-Za-z0-9_-]*)
      echo "Invalid Base44 app id in $ROOT/base44/.app.jsonc" >&2
      exit 65
      ;;
  esac
  if [ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]; then
    echo "Set BASE44_CONFIRM_APP_ID=$APP_ID for the intentional production backfill." >&2
    exit 77
  fi
  SPYCLASH_BACKFILL_APPLY=1 \
    npx --yes -p deno -p base44@0.1.4 -c 'base44 exec' \
    < "$ROOT/scripts/backfill-sensitive-entity-owners.ts"
else
  SPYCLASH_BACKFILL_APPLY=0 \
    npx --yes -p deno -p base44@0.1.4 -c 'base44 exec' \
    < "$ROOT/scripts/backfill-sensitive-entity-owners.ts"
fi
