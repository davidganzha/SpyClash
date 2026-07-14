#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_ID=$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/base44/.app.jsonc" | head -n 1)
[ -n "$APP_ID" ] || exit 65

if [ "${1:-}" != "--deploy" ]; then
  echo "Usage: BASE44_CONFIRM_APP_ID=$APP_ID $0 --deploy" >&2
  echo "No remote change was made."
  exit 64
fi
if [ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]; then
  echo "Set BASE44_CONFIRM_APP_ID=$APP_ID for the intentional maintenance deployment." >&2
  exit 77
fi

STAGE=$(mktemp -d "${TMPDIR:-/tmp}/spyclash-delete-guard.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/base44/functions/deleteAccount"
cp "$ROOT/base44/config.jsonc" "$STAGE/base44/config.jsonc"
cp "$ROOT/base44/.app.jsonc" "$STAGE/base44/.app.jsonc"
cp "$ROOT/scripts/base44-maintenance/deleteAccount/function.jsonc" \
  "$STAGE/base44/functions/deleteAccount/function.jsonc"
cp "$ROOT/scripts/base44-maintenance/deleteAccount/main.ts" \
  "$STAGE/base44/functions/deleteAccount/main.ts"

(cd "$STAGE" && npx --yes base44@0.1.4 functions deploy deleteAccount)
