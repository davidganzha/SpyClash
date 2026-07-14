#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_FILE="$ROOT/base44/.app.jsonc"
APP_ID=$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_FILE" | head -n 1)
[ -n "$APP_ID" ] || {
  echo "Unable to read the Base44 app id from $APP_FILE" >&2
  exit 65
}
case "$APP_ID" in
  *[!A-Za-z0-9_-]*)
    echo "Invalid Base44 app id in $APP_FILE" >&2
    exit 65
    ;;
esac

CUTOVER_DIR="$ROOT/.base44-cutover"
STAGE="$CUTOVER_DIR/final-schema"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/spyclash-base44-final.XXXXXX")
REMOTE="$WORK/remote.json"
REMOTE_NORMALIZED="$WORK/remote-normalized.json"
CANONICAL_NORMALIZED="$WORK/canonical-normalized.json"
REMOTE_NAMES="$WORK/remote-names.txt"
CANONICAL_NAMES="$WORK/canonical-names.txt"
CHANGED_NAMES="$WORK/changed-names.txt"
AUTH_FILE="$HOME/.base44/auth/auth.json"
CURL_CONFIG="$WORK/curl.conf"
MODE=prepare

cleanup() {
  rm -rf "$WORK"
}
trap cleanup EXIT HUP INT TERM

case "${1:-}" in
  "") ;;
  --push) MODE=push ;;
  *)
    echo "Usage: $0 [--push]" >&2
    exit 64
    ;;
esac

# Keep every cleanup target fixed inside this repository. No caller-provided
# path is accepted because an authoritative schema stage is deleted/rebuilt.
if [ "${BASE44_FINAL_STAGE_DIR+x}" = x ]; then
  echo "BASE44_FINAL_STAGE_DIR is not supported; the stage path is fixed at $STAGE." >&2
  exit 64
fi
case "$ROOT" in
  ""|/)
    echo "Unsafe repository root; refusing to prepare a schema stage." >&2
    exit 65
    ;;
esac
if [ "$STAGE" != "$ROOT/.base44-cutover/final-schema" ]; then
  echo "Unsafe final schema stage path; refusing to continue." >&2
  exit 65
fi
if [ -L "$CUTOVER_DIR" ]; then
  echo "$CUTOVER_DIR must not be a symbolic link." >&2
  exit 65
fi

for command in cmp comm curl diff find id jq npx shasum sort stat uname; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 69
  }
done

check_auth_file() {
  if [ ! -f "$AUTH_FILE" ] || [ -L "$AUTH_FILE" ]; then
    echo "Base44 CLI authentication must be a regular non-symlink file." >&2
    exit 77
  fi
  case "$(uname -s)" in
    Darwin)
      auth_mode=$(stat -f '%Lp' "$AUTH_FILE")
      auth_owner=$(stat -f '%u' "$AUTH_FILE")
      ;;
    *)
      auth_mode=$(stat -c '%a' "$AUTH_FILE")
      auth_owner=$(stat -c '%u' "$AUTH_FILE")
      ;;
  esac
  if [ "$auth_mode" != 600 ]; then
    echo "Base44 CLI authentication has mode $auth_mode; run: chmod 600 $AUTH_FILE" >&2
    exit 77
  fi
  if [ "$auth_owner" != "$(id -u)" ]; then
    echo "Base44 CLI authentication is not owned by the current user." >&2
    exit 77
  fi
}

# Refresh authentication, then re-check permissions in case the CLI rewrote
# the file. Curl receives the token through a mode-600 config, never argv.
check_auth_file
npx --yes base44@0.1.4 whoami >/dev/null
check_auth_file
ACCESS_TOKEN=$(jq -er '.accessToken' "$AUTH_FILE")
umask 077
printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" \
  > "$CURL_CONFIG"
unset ACCESS_TOKEN
curl -fsS \
  --config "$CURL_CONFIG" \
  "https://app.base44.com/api/apps/$APP_ID/entity-schemas" \
  > "$REMOTE"
rm -f "$CURL_CONFIG"

jq -e '
  .total == (.schemas | length) and
  .total > 0 and
  ([.schemas[].entity_name] | all(
    type == "string" and test("^[A-Za-z0-9]+$")
  )) and
  ([.schemas[].entity_name] | unique | length) == .total and
  ([.schemas[].entity_schema] | all(type == "object"))
' "$REMOTE" >/dev/null || {
  echo "Remote Base44 schema response is incomplete or ambiguous; refusing to prepare a push." >&2
  exit 65
}

jq -S '[
  .schemas | sort_by(.entity_name)[] |
  {entity_name, entity_schema}
]' "$REMOTE" > "$REMOTE_NORMALIZED"
remote_digest=$(shasum -a 256 "$REMOTE_NORMALIZED" | awk '{print $1}')

mkdir -p "$CUTOVER_DIR"
rm -rf "$STAGE"
mkdir -p "$STAGE/base44/entities"
cp "$ROOT/base44/config.jsonc" "$STAGE/base44/config.jsonc"
cp "$APP_FILE" "$STAGE/base44/.app.jsonc"
cp "$ROOT"/base44/entities/*.jsonc "$STAGE/base44/entities/"

jq -r '.schemas[].entity_name' "$REMOTE" | LC_ALL=C sort > "$REMOTE_NAMES"
: > "$CANONICAL_NAMES"
for schema in "$STAGE"/base44/entities/*.jsonc; do
  jq -e '
    (.name | type == "string" and test("^[A-Za-z0-9]+$")) and
    (.type == "object") and
    (.properties | type == "object")
  ' "$schema" >/dev/null || {
    echo "Invalid canonical entity schema: $schema" >&2
    exit 65
  }
  jq -er '.name' "$schema" >> "$CANONICAL_NAMES"
done
LC_ALL=C sort -o "$CANONICAL_NAMES" "$CANONICAL_NAMES"

canonical_count=$(wc -l < "$CANONICAL_NAMES" | tr -d ' ')
canonical_unique_count=$(sort -u "$CANONICAL_NAMES" | wc -l | tr -d ' ')
if [ "$canonical_count" -eq 0 ] || [ "$canonical_count" -ne "$canonical_unique_count" ]; then
  echo "Canonical schema names are empty or duplicated; refusing to continue." >&2
  exit 65
fi

jq -S -s 'sort_by(.name)' "$STAGE"/base44/entities/*.jsonc \
  > "$CANONICAL_NORMALIZED"
canonical_digest=$(shasum -a 256 "$CANONICAL_NORMALIZED" | awk '{print $1}')

# Entity-set equality is the hard no-delete/no-add boundary. If production has
# drifted, stop for investigation instead of allowing an authoritative push to
# remove an unknown live entity or silently introduce an unexpected one.
if ! cmp -s "$REMOTE_NAMES" "$CANONICAL_NAMES"; then
  echo "Live and canonical entity sets differ; refusing the final schema push." >&2
  echo "Canonical-only names:" >&2
  comm -13 "$REMOTE_NAMES" "$CANONICAL_NAMES" | sed 's/^/  /' >&2
  echo "Live-only names (would be deleted):" >&2
  comm -23 "$REMOTE_NAMES" "$CANONICAL_NAMES" | sed 's/^/  /' >&2
  exit 65
fi

require_live_property() {
  entity=$1
  field=$2
  jq -e --arg entity "$entity" --arg field "$field" '
    [.schemas[] | select(.entity_name == $entity) |
      .entity_schema.properties | has($field)] == [true]
  ' "$REMOTE" >/dev/null || {
    echo "Live schema is missing additive prerequisite $entity.$field." >&2
    exit 65
  }
}

require_live_property Friendship blocked_by_id
require_live_property GameHistory player_user_id
require_live_property GameHistory match_id
require_live_property GameRoom participant_user_ids
require_live_property GameRoom match_id
require_live_property GameRoom terminal_intent
require_live_property WordPack owner_user_id
require_live_property AppStoreAccount reservation_state
require_live_property Entitlement write_revision

: > "$CHANGED_NAMES"
mkdir -p "$STAGE/diff"
for schema in "$STAGE"/base44/entities/*.jsonc; do
  name=$(jq -er '.name' "$schema")
  live_normalized="$WORK/live-$name.json"
  canonical_normalized="$WORK/canonical-$name.json"
  jq -S --arg name "$name" \
    '[.schemas[] | select(.entity_name == $name) | .entity_schema][0]' \
    "$REMOTE" > "$live_normalized"
  jq -S . "$schema" > "$canonical_normalized"
  if ! cmp -s "$live_normalized" "$canonical_normalized"; then
    printf '%s\n' "$name" >> "$CHANGED_NAMES"
    if diff -u \
      -L "live/$name.json" \
      -L "canonical/$name.json" \
      "$live_normalized" \
      "$canonical_normalized" \
      > "$STAGE/diff/$name.diff"; then
      echo "Schema comparison for $name changed while preparing its diff." >&2
      exit 65
    else
      diff_status=$?
      if [ "$diff_status" -ne 1 ]; then
        echo "Unable to generate the schema diff for $name." >&2
        exit 65
      fi
    fi
  fi
done
LC_ALL=C sort -o "$CHANGED_NAMES" "$CHANGED_NAMES"

remote_count=$(jq -r '.total' "$REMOTE")
changed_count=$(wc -l < "$CHANGED_NAMES" | tr -d ' ')
changed_json=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$CHANGED_NAMES")
plan_digest=$(printf '%s\n' \
  "$APP_ID" "$remote_digest" "$canonical_digest" "$changed_json" \
  | shasum -a 256 | awk '{print $1}')
jq -n \
  --arg app_id "$APP_ID" \
  --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg remote_digest "$remote_digest" \
  --arg canonical_digest "$canonical_digest" \
  --arg plan_digest "$plan_digest" \
  --argjson live_count "$remote_count" \
  --argjson canonical_count "$canonical_count" \
  --argjson changed_entities "$changed_json" \
  '{app_id:$app_id,prepared_at:$prepared_at,live_count:$live_count,canonical_count:$canonical_count,remote_digest:$remote_digest,canonical_digest:$canonical_digest,plan_digest:$plan_digest,changed_entities:$changed_entities,adds:0,deletes:0}' \
  > "$STAGE/manifest.json"

echo "Prepared final Base44 schema stage: $STAGE"
echo "App id: $APP_ID"
echo "Entities: live=$remote_count canonical=$canonical_count adds=0 deletes=0 changes=$changed_count"
echo "Plan digest: $plan_digest"
if [ "$changed_count" -gt 0 ]; then
  sed 's/^/  change: /' "$CHANGED_NAMES"
fi

if [ "$MODE" = prepare ]; then
  echo "No remote change was made. Inspect the fresh diff and re-run with --push."
  exit 0
fi

if [ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]; then
  echo "Set BASE44_CONFIRM_APP_ID=$APP_ID for the intentional final schema push." >&2
  exit 77
fi
if [ "${BASE44_CONFIRM_FINAL_PLAN_DIGEST:-}" != "$plan_digest" ]; then
  echo "Fresh live/canonical plan differs from the inspected plan." >&2
  echo "Inspect $STAGE/manifest.json and every diff, then set BASE44_CONFIRM_FINAL_PLAN_DIGEST to its plan_digest." >&2
  exit 77
fi
if [ "$changed_count" -eq 0 ]; then
  echo "Live schema already matches the canonical final schema; no push was made."
  exit 0
fi

(cd "$STAGE" && npx --yes base44@0.1.4 entities push)
