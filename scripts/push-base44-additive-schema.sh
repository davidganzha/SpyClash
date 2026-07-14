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
STAGE="$CUTOVER_DIR/additive-schema"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/spyclash-base44-additive.XXXXXX")
REMOTE="$WORK/remote.json"
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

# Never let an environment variable turn the stage cleanup below into an
# arbitrary-path deletion primitive. The stage location is fixed inside this
# repository and its parent must not be a symlink to another tree.
if [ "${BASE44_ADDITIVE_STAGE_DIR+x}" = x ]; then
  echo "BASE44_ADDITIVE_STAGE_DIR is not supported; the stage path is fixed at $STAGE." >&2
  exit 64
fi
case "$ROOT" in
  ""|/)
    echo "Unsafe repository root; refusing to prepare a schema stage." >&2
    exit 65
    ;;
esac
if [ "$STAGE" != "$ROOT/.base44-cutover/additive-schema" ]; then
  echo "Unsafe additive schema stage path; refusing to continue." >&2
  exit 65
fi
if [ -L "$CUTOVER_DIR" ]; then
  echo "$CUTOVER_DIR must not be a symbolic link." >&2
  exit 65
fi

for command in curl jq npx; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 69
  }
done

# The CLI auth file contains a bearer token. Require a regular, user-owned,
# mode-600 file before asking the CLI to refresh it or reading it. A token is
# passed to curl only through a mode-600 config file, never process argv.
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
  ([.schemas[].entity_schema] | all(type == "object"))
' "$REMOTE" >/dev/null || {
  echo "Remote Base44 schema response is incomplete; refusing to prepare a push." >&2
  exit 65
}

mkdir -p "$CUTOVER_DIR"
rm -rf "$STAGE"
mkdir -p "$STAGE/base44/entities"
cp "$ROOT/base44/config.jsonc" "$STAGE/base44/config.jsonc"
cp "$APP_FILE" "$STAGE/base44/.app.jsonc"

# Start from the fresh production schema, not from the restrictive final local
# schema. This makes the authoritative Base44 sync additive: every existing
# entity, field, required list and RLS rule is preserved at the JSON value
# level.
jq -c '.schemas[]' "$REMOTE" | while IFS= read -r row; do
  name=$(printf '%s' "$row" | jq -er '.entity_name')
  printf '%s' "$row" | jq '.entity_schema' \
    > "$STAGE/base44/entities/$name.jsonc"
done

add_optional_field() {
  entity=$1
  field=$2
  canonical_file=${3:-"$entity.jsonc"}
  staged="$STAGE/base44/entities/$entity.jsonc"
  canonical="$ROOT/base44/entities/$canonical_file"

  if [ ! -f "$staged" ] || [ ! -f "$canonical" ]; then
    echo "Missing schema for additive field $entity.$field" >&2
    exit 66
  fi

  local_property=$(jq -c --arg field "$field" '.properties[$field] // empty' "$canonical")
  if [ -z "$local_property" ]; then
    echo "Canonical schema has no property $entity.$field" >&2
    exit 66
  fi

  if jq -e --arg field "$field" '.properties | has($field)' "$staged" >/dev/null; then
    jq -e \
      --arg field "$field" \
      --argjson expected "$local_property" \
      '.properties[$field] == $expected' \
      "$staged" >/dev/null || {
        echo "Production definition for $entity.$field differs from the canonical release schema." >&2
        exit 65
      }
    return
  fi

  next="$WORK/$entity.$field.json"
  jq \
    --arg field "$field" \
    --argjson property "$local_property" \
    '.properties[$field] = $property' \
    "$staged" > "$next"
  mv "$next" "$staged"
}

add_optional_field Friendship blocked_by_id
add_optional_field GameHistory player_user_id
add_optional_field GameHistory match_id
add_optional_field GameRoom participant_user_ids
add_optional_field GameRoom match_id
add_optional_field GameRoom terminal_intent
add_optional_field WordPack owner_user_id
add_optional_field AppStoreAccount reservation_state app-store-account.jsonc
add_optional_field Entitlement write_revision entitlement.jsonc

# These entities are safe to create during the additive phase because both are
# service-role/admin-only boundaries. If a prior attempt already created one,
# require exact equality instead of silently replacing production drift.
for entity_file in CommunityReport.jsonc billing-identity-lifecycle.jsonc; do
  entity_name=$(jq -er '.name' "$ROOT/base44/entities/$entity_file")
  if jq -e --arg name "$entity_name" \
    '.schemas | any(.entity_name == $name)' "$REMOTE" >/dev/null; then
    jq -e \
      --slurpfile canonical "$ROOT/base44/entities/$entity_file" \
      --arg name "$entity_name" \
      '(.schemas[] | select(.entity_name == $name) | .entity_schema) == $canonical[0]' \
      "$REMOTE" >/dev/null || {
        echo "Production schema for $entity_name differs from the canonical release schema." >&2
        exit 65
      }
  else
    cp "$ROOT/base44/entities/$entity_file" \
      "$STAGE/base44/entities/$entity_name.jsonc"
  fi
done

# Turn the additive phase into a write-maintenance boundary for every custom
# server-owned entity. Production read policy is preserved until the mediated
# site is live, but direct client create/update/delete is closed immediately so
# legacy writable fields (for example GameRoom.players/status/timestamps) cannot
# be forged and then promoted into the new stable authority fields. Service-role
# functions and the authenticated admin backfill bypass these rules.
for canonical in "$ROOT"/base44/entities/*.jsonc; do
  entity_name=$(jq -er '.name' "$canonical")
  [ "$entity_name" = User ] && continue
  staged="$STAGE/base44/entities/$entity_name.jsonc"
  if [ ! -f "$staged" ]; then
    echo "Missing staged custom entity $entity_name for write maintenance." >&2
    exit 65
  fi
  write_rules=$(jq -c '{
    create: .rls.create,
    update: .rls.update,
    delete: .rls.delete
  }' "$canonical")
  if ! printf '%s' "$write_rules" | jq -e '
    .create.user_condition.role == "admin" and
    .update.user_condition.role == "admin" and
    .delete.user_condition.role == "admin"
  ' >/dev/null; then
    echo "Canonical write-maintenance RLS is incomplete for $entity_name." >&2
    exit 65
  fi
  next="$WORK/$entity_name.write-maintenance.json"
  jq --argjson rules "$write_rules" '
    .rls = (.rls // {}) |
    .rls.create = $rules.create |
    .rls.update = $rules.update |
    .rls.delete = $rules.delete
  ' "$staged" > "$next"
  mv "$next" "$staged"
done

remote_count=$(jq -r '.total' "$REMOTE")
new_count=0
for name in CommunityReport BillingIdentityLifecycle; do
  if ! jq -e --arg name "$name" '.schemas | any(.entity_name == $name)' \
    "$REMOTE" >/dev/null; then
    new_count=$((new_count + 1))
  fi
done
stage_count=$(find "$STAGE/base44/entities" -type f -name '*.jsonc' | wc -l | tr -d ' ')
expected_count=$((remote_count + new_count))
if [ "$stage_count" -ne "$expected_count" ]; then
  echo "Prepared entity count $stage_count does not match expected $expected_count." >&2
  exit 65
fi

# An authoritative push from a partial directory deletes omitted schemas.
jq -r '.schemas[].entity_name' "$REMOTE" | while IFS= read -r name; do
  if [ ! -f "$STAGE/base44/entities/$name.jsonc" ]; then
    echo "Prepared stage would omit live entity $name; refusing to continue." >&2
    exit 65
  fi
done

schema_digest=$(find "$STAGE/base44/entities" -type f -name '*.jsonc' -print \
  | sort \
  | xargs shasum -a 256 \
  | shasum -a 256 \
  | awk '{print $1}')
jq -n \
  --arg app_id "$APP_ID" \
  --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg schema_digest "$schema_digest" \
  --argjson remote_count "$remote_count" \
  --argjson prepared_count "$stage_count" \
  '{app_id:$app_id,prepared_at:$prepared_at,remote_count:$remote_count,prepared_count:$prepared_count,schema_digest:$schema_digest}' \
  > "$STAGE/manifest.json"

echo "Prepared additive Base44 schema stage: $STAGE"
echo "Entities preserved: $remote_count; prepared: $stage_count"

if [ "$MODE" = prepare ]; then
  echo "No remote change was made. Re-run with --push to refetch and apply."
  exit 0
fi

if [ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]; then
  echo "Set BASE44_CONFIRM_APP_ID=$APP_ID for the intentional production push." >&2
  exit 77
fi

(cd "$STAGE" && npx --yes base44@0.1.4 entities push)
