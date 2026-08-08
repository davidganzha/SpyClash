#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXPECTED_APP_ID=69a0e57fa939f578082f8091
APP_ID=$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ROOT/base44/.app.jsonc" | head -n 1)
[ -n "$APP_ID" ] || exit 65
[ "$APP_ID" = "$EXPECTED_APP_ID" ] || {
  echo "Repository app id $APP_ID is not the canonical SpyClash app $EXPECTED_APP_ID." >&2
  exit 65
}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP=${BASE44_FUNCTION_BACKUP_DIR:-"$ROOT/.base44-cutover/backups/$STAMP"}

if [ -e "$BACKUP" ]; then
  echo "Backup destination already exists: $BACKUP" >&2
  exit 73
fi

mkdir -p "$BACKUP/base44"
cp "$ROOT/base44/config.jsonc" "$BACKUP/base44/config.jsonc"
cp "$ROOT/base44/.app.jsonc" "$BACKUP/base44/.app.jsonc"
(cd "$BACKUP" && \
  env -u BASE44_APP_ID -u BASE44_PROJECTS_BASE44_APP_ID \
    npx --yes base44@0.1.4 --app-id "$APP_ID" functions pull)

count=$(find "$BACKUP/base44/functions" -mindepth 1 -maxdepth 1 -type d \
  2>/dev/null | wc -l | tr -d ' ')
if [ "$count" -eq 0 ]; then
  echo "Remote function backup is empty; refusing to continue." >&2
  exit 65
fi

jq -n \
  --arg app_id "$APP_ID" \
  --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson function_count "$count" \
  '{app_id:$app_id,created_at:$created_at,function_count:$function_count}' \
  > "$BACKUP/manifest.json"

echo "Backed up $count deployed functions to $BACKUP"
