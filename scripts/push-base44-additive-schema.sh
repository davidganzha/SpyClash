#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_FILE="$ROOT/base44/.app.jsonc"
EXPECTED_APP_ID=69a0e57fa939f578082f8091
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
if [ "$APP_ID" != "$EXPECTED_APP_ID" ]; then
  echo "Repository app id $APP_ID is not the reviewed SpyClash app $EXPECTED_APP_ID." >&2
  exit 77
fi
if [ "${BASE44_APP_ID+x}" = x ] && [ "$BASE44_APP_ID" != "$APP_ID" ]; then
  echo "BASE44_APP_ID targets $BASE44_APP_ID, not reviewed app $APP_ID." >&2
  exit 77
fi
CUTOVER_DIR="$ROOT/.base44-cutover"
FIXED_STAGE="$CUTOVER_DIR/additive-schema"
EVIDENCE_DIR="$CUTOVER_DIR/evidence/additive-schema"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/spyclash-base44-additive.XXXXXX")
STAGE="$WORK/candidate-stage"
REMOTE="$WORK/remote.json"
POST_REMOTE="$WORK/postflight-remote.json"
JIT_REMOTE="$WORK/jit-remote.json"
REVIEWED_MANIFEST="$WORK/reviewed-manifest.json"
AUTH_FILE="$HOME/.base44/auth/auth.json"
LOCK_DIR="$CUTOVER_DIR/.additive-schema.lock"
PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
LOCK_HELD=0
PRODUCTION_LOCK_HELD=0
MODE=prepare
EXPECTED_ENTITY_COUNT=20
EXPECTED_CUSTOM_ENTITY_COUNT=19

cleanup() {
  rm -rf "$WORK"
  if [ "$LOCK_HELD" -eq 1 ]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  if [ "$PRODUCTION_LOCK_HELD" -eq 1 ]; then
    if [ -d "$PRODUCTION_LOCK_DIR" ] && [ ! -L "$PRODUCTION_LOCK_DIR" ]; then
      rm -f -- "$PRODUCTION_LOCK_OWNER"
      rmdir "$PRODUCTION_LOCK_DIR" 2>/dev/null || true
    else
      echo "Refusing unsafe shared Production-lock cleanup." >&2
    fi
  fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

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
  echo "BASE44_ADDITIVE_STAGE_DIR is not supported; the stage path is fixed at $FIXED_STAGE." >&2
  exit 64
fi
case "$ROOT" in
  ""|/)
    echo "Unsafe repository root; refusing to prepare a schema stage." >&2
    exit 65
    ;;
esac
if [ "$FIXED_STAGE" != "$ROOT/.base44-cutover/additive-schema" ]; then
  echo "Unsafe additive schema stage path; refusing to continue." >&2
  exit 65
fi
if [ -L "$CUTOVER_DIR" ]; then
  echo "$CUTOVER_DIR must not be a symbolic link." >&2
  exit 65
fi
if [ -L "$FIXED_STAGE" ]; then
  echo "$FIXED_STAGE must not be a symbolic link." >&2
  exit 65
fi

for command in awk basename chmod cmp cp curl date diff env find grep head id jq mkdir mktemp mv npx rm rmdir sed shasum sort stat sync tr uname wc; do
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
    return 77
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
    return 77
  fi
  if [ "$auth_owner" != "$(id -u)" ]; then
    echo "Base44 CLI authentication is not owned by the current user." >&2
    return 77
  fi
}

fetch_remote_schema() {
  output=$1
  curl_config="$WORK/curl.$$.conf"
  check_auth_file || return $?
  env -u BASE44_APP_ID npx --yes base44@0.1.4 \
    --app-id "$APP_ID" whoami >/dev/null || return $?
  check_auth_file || return $?
  access_token=$(jq -er '.accessToken' "$AUTH_FILE") || return $?
  umask 077
  printf 'header = "Authorization: Bearer %s"\n' "$access_token" \
    > "$curl_config"
  unset access_token
  curl -fsS --connect-timeout 10 --max-time 60 --retry 2 \
    --config "$curl_config" \
    "https://app.base44.com/api/apps/$APP_ID/entity-schemas" \
    > "$output"
  status=$?
  rm -f "$curl_config"
  return "$status"
}

validate_remote_schema() {
  jq -e '
    .total == (.schemas | length) and
    .total > 0 and
    ([.schemas[].entity_name] | all(
      type == "string" and test("^[A-Za-z0-9]+$")
    )) and
    ([.schemas[].entity_name] | unique | length) == .total and
    ([.schemas[].entity_schema] | all(type == "object")) and
    all(.schemas[]; .entity_schema.name == .entity_name)
  ' "$1" >/dev/null
}

schema_set_digest_from_stage() {
  jq -S -s 'sort_by(.name)' "$1"/base44/entities/*.jsonc |
    shasum -a 256 | awk '{print $1}'
}

schema_set_digest_from_remote() {
  jq -S '[.schemas[].entity_schema] | sort_by(.name)' "$1" |
    shasum -a 256 | awk '{print $1}'
}

tree_bytes_digest() {
  tree=$1
  records="$WORK/tree-bytes-records"
  [ -d "$tree" ] || return 65
  if find "$tree" -type l -print | grep -q .; then
    return 65
  fi
  : > "$records"
  (
    cd "$tree"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      printf '%s\t%s\n' "$file" "$(shasum -a 256 "$file" | awk '{print $1}')"
    done
  ) > "$records"
  shasum -a 256 "$records" | awk '{print $1}'
}

local_inputs_digest() {
  {
    printf 'base44/.app.jsonc\t%s\n' "$(shasum -a 256 "$APP_FILE" | awk '{print $1}')"
    printf 'base44/config.jsonc\t%s\n' "$(shasum -a 256 "$ROOT/base44/config.jsonc" | awk '{print $1}')"
    for file in "$ROOT"/base44/entities/*.jsonc; do
      printf 'base44/entities/%s\t%s\n' "$(basename "$file")" \
        "$(shasum -a 256 "$file" | awk '{print $1}')"
    done | LC_ALL=C sort
  } | shasum -a 256 | awk '{print $1}'
}

private_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then
    stat -f '%Lp' "$1"
  else
    stat -c '%a' "$1"
  fi
}

private_owner() {
  if stat -f '%u' "$1" >/dev/null 2>&1; then
    stat -f '%u' "$1"
  else
    stat -c '%u' "$1"
  fi
}

private_links() {
  if stat -f '%l' "$1" >/dev/null 2>&1; then
    stat -f '%l' "$1"
  else
    stat -c '%h' "$1"
  fi
}

secure_private_directory() {
  directory=$1
  [ -d "$directory" ] && [ ! -L "$directory" ] || return 65
  [ "$(private_owner "$directory")" = "$(id -u)" ] || return 65
  chmod 700 "$directory"
  [ "$(private_mode "$directory")" = 700 ] || return 65
}

secure_private_json_file() {
  protected_file=$1
  [ -f "$protected_file" ] && [ ! -L "$protected_file" ] || return 65
  [ "$(private_owner "$protected_file")" = "$(id -u)" ] || return 65
  [ "$(private_links "$protected_file")" = 1 ] || return 65
  chmod 600 "$protected_file"
  [ "$(private_mode "$protected_file")" = 600 ] || return 65
  jq -e . "$protected_file" >/dev/null || return 65
}

install_durable_json() {
  durable_source=$1
  durable_destination=$2
  durable_directory=$3
  durable_label=$4
  case "$durable_destination" in
    "$durable_directory"/attempt.json|"$durable_directory"/postflight.json|"$EVIDENCE_DIR/latest-postflight.json") ;;
    *) echo "Refusing unsafe additive-schema evidence destination." >&2; return 65 ;;
  esac
  case "$durable_label" in
    ""|*[!A-Za-z0-9_-]*) return 65 ;;
  esac
  secure_private_directory "$durable_directory" || return $?
  secure_private_json_file "$durable_source" || return $?
  if [ -e "$durable_destination" ] || [ -L "$durable_destination" ]; then
    secure_private_json_file "$durable_destination" || {
      echo "Unsafe additive-schema evidence destination: $durable_destination" >&2
      return 65
    }
  fi
  durable_temporary=$(mktemp "$durable_directory/.${durable_label}.XXXXXX") || return 70
  chmod 600 "$durable_temporary" || { rm -f -- "$durable_temporary"; return 70; }
  cp "$durable_source" "$durable_temporary" && \
    cmp -s "$durable_source" "$durable_temporary" || {
      rm -f -- "$durable_temporary"
      return 70
    }
  secure_private_json_file "$durable_temporary" || {
    rm -f -- "$durable_temporary"
    return 70
  }
  mv "$durable_temporary" "$durable_destination" || {
    rm -f -- "$durable_temporary"
    return 70
  }
  secure_private_json_file "$durable_destination" || return 70
  sync || return 70
}

acquire_production_lock() {
  if ! mkdir "$PRODUCTION_LOCK_DIR" 2>/dev/null; then
    echo "Another Base44 Production mutation holds $PRODUCTION_LOCK_DIR." >&2
    echo "A stale lock must be reclaimed only after manual PID/path verification." >&2
    return 75
  fi
  PRODUCTION_LOCK_HELD=1
  secure_private_directory "$PRODUCTION_LOCK_DIR" || return $?
  printf 'SECURITY_CUTOVER_STEP_1_ADDITIVE_SCHEMA:%s\n' "$$" > "$PRODUCTION_LOCK_OWNER"
  chmod 600 "$PRODUCTION_LOCK_OWNER"
  [ -f "$PRODUCTION_LOCK_OWNER" ] && [ ! -L "$PRODUCTION_LOCK_OWNER" ] && \
    [ "$(private_owner "$PRODUCTION_LOCK_OWNER")" = "$(id -u)" ] && \
    [ "$(private_links "$PRODUCTION_LOCK_OWNER")" = 1 ] || return 65
}

mkdir -p "$CUTOVER_DIR"
if [ -L "$CUTOVER_DIR/evidence" ] || [ -L "$EVIDENCE_DIR" ]; then
  echo "Additive schema evidence paths must not be symbolic links." >&2
  exit 65
fi
secure_private_directory "$CUTOVER_DIR"
if [ "$MODE" = push ]; then
  acquire_production_lock
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another additive Base44 schema prepare/push is active: $LOCK_DIR" >&2
  exit 75
fi
LOCK_HELD=1
mkdir -p "$EVIDENCE_DIR"
secure_private_directory "$CUTOVER_DIR/evidence"
secure_private_directory "$EVIDENCE_DIR"

if [ "$MODE" = push ]; then
  if [ ! -f "$FIXED_STAGE/manifest.json" ] || [ -L "$FIXED_STAGE" ] || \
     [ -L "$FIXED_STAGE/manifest.json" ]; then
    echo "No fixed reviewed additive stage exists; run the prepare command first." >&2
    exit 77
  fi
  secure_private_json_file "$FIXED_STAGE/manifest.json" || {
    echo "Reviewed additive manifest must be a private, owned regular JSON file." >&2
    exit 65
  }
  cp "$FIXED_STAGE/manifest.json" "$REVIEWED_MANIFEST"
  secure_private_json_file "$REVIEWED_MANIFEST"
  cmp -s "$FIXED_STAGE/manifest.json" "$REVIEWED_MANIFEST" || exit 70
fi

fetch_remote_schema "$REMOTE" || {
  echo "Unable to fetch the fresh Production schema." >&2
  exit 70
}

validate_remote_schema "$REMOTE" || {
  echo "Remote Base44 schema response is incomplete; refusing to prepare a push." >&2
  exit 65
}
remote_digest=$(jq -S '[
  .schemas | sort_by(.entity_name)[] |
  {entity_name, entity_schema}
]' "$REMOTE" | shasum -a 256 | awk '{print $1}')

REMOTE_NAMES="$WORK/remote-names.txt"
CANONICAL_NAMES="$WORK/canonical-names.txt"
STAGE_NAMES="$WORK/stage-names.txt"
UNEXPECTED_REMOTE_NAMES="$WORK/unexpected-remote-names.txt"
jq -r '.schemas[].entity_name' "$REMOTE" | LC_ALL=C sort > "$REMOTE_NAMES"
for canonical_file in "$ROOT"/base44/entities/*.jsonc; do
  jq -er '.name' "$canonical_file"
done | LC_ALL=C sort > "$CANONICAL_NAMES"
canonical_count=$(wc -l < "$CANONICAL_NAMES" | tr -d ' ')
canonical_custom_count=$(grep -vx User "$CANONICAL_NAMES" | wc -l | tr -d ' ')
if [ "$canonical_count" -ne "$EXPECTED_ENTITY_COUNT" ] || \
   [ "$canonical_custom_count" -ne "$EXPECTED_CUSTOM_ENTITY_COUNT" ]; then
  echo "Canonical schema universe is not the reviewed 20 entities / 19 custom entities." >&2
  exit 65
fi
comm -23 "$REMOTE_NAMES" "$CANONICAL_NAMES" > "$UNEXPECTED_REMOTE_NAMES"
if [ -s "$UNEXPECTED_REMOTE_NAMES" ]; then
  echo "Production contains entities outside the reviewed canonical universe; refusing any push:" >&2
  sed 's/^/  /' "$UNEXPECTED_REMOTE_NAMES" >&2
  exit 77
fi

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

# Base44 owns the User row boundary, so the additive stage must preserve the
# live built-in schema instead of replacing it with the local custom-field
# declaration. Merge only the release fields that guarded functions require.
# Existing compatible definitions stay intact to avoid a destructive type
# migration during the write-maintenance window.
add_user_authoritative_field() {
  field=$1
  staged="$STAGE/base44/entities/User.jsonc"
  canonical="$ROOT/base44/entities/User.jsonc"

  if [ ! -f "$staged" ] || [ ! -f "$canonical" ]; then
    echo "Missing User schema for additive field User.$field" >&2
    exit 66
  fi

  local_property=$(jq -c --arg field "$field" \
    '.properties[$field] // empty' "$canonical")
  local_write=$(jq -c --arg field "$field" \
    '.properties[$field].rls.write // empty' "$canonical")
  if [ -z "$local_property" ] || [ -z "$local_write" ]; then
    echo "Canonical User.$field must declare an authoritative write rule." >&2
    exit 66
  fi
  if ! printf '%s' "$local_write" | jq -e \
    '.user_condition.role == "admin"' >/dev/null; then
    echo "Canonical User.$field write rule is not admin-only." >&2
    exit 65
  fi

  if ! jq -e --arg field "$field" '.properties | has($field)' \
    "$staged" >/dev/null; then
    next="$WORK/User.$field.json"
    jq \
      --arg field "$field" \
      --argjson property "$local_property" \
      '.properties[$field] = $property' \
      "$staged" > "$next"
    mv "$next" "$staged"
    return
  fi

  staged_type=$(jq -er --arg field "$field" '.properties[$field].type' \
    "$staged")
  canonical_type=$(printf '%s' "$local_property" | jq -er '.type')
  if [ "$staged_type" != "$canonical_type" ] && ! {
    [ "$staged_type" = number ] && [ "$canonical_type" = integer ]
  }; then
    echo "Production type for User.$field is incompatible with the release schema." >&2
    exit 65
  fi

  if jq -e --arg field "$field" \
    '.properties[$field].rls.write != null' "$staged" >/dev/null; then
    jq -e \
      --arg field "$field" \
      --argjson expected "$local_write" \
      '.properties[$field].rls.write == $expected' \
      "$staged" >/dev/null || {
        echo "Production write rule for User.$field differs from the release authority boundary." >&2
        exit 65
      }
    return
  fi

  next="$WORK/User.$field.authority.json"
  jq \
    --arg field "$field" \
    --argjson write "$local_write" \
    '.properties[$field].rls = (.properties[$field].rls // {}) |
     .properties[$field].rls.write = $write' \
    "$staged" > "$next"
  mv "$next" "$staged"
}

extend_user_enum() {
  field=$1
  staged="$STAGE/base44/entities/User.jsonc"
  canonical="$ROOT/base44/entities/User.jsonc"
  canonical_values=$(jq -c --arg field "$field" \
    '.properties[$field].enum // empty' "$canonical")

  if [ -z "$canonical_values" ]; then
    echo "Canonical User.$field must declare an enum." >&2
    exit 66
  fi
  jq -e --arg field "$field" '
    .properties[$field].type == "string" and
    (.properties[$field].enum | type) == "array" and
    (.properties[$field].enum | all(type == "string"))
  ' "$staged" >/dev/null || {
    echo "Production User.$field is not a compatible string enum." >&2
    exit 65
  }

  next="$WORK/User.$field.enum.json"
  jq \
    --arg field "$field" \
    --argjson values "$canonical_values" '
      .properties[$field].enum = reduce $values[] as $value (
        .properties[$field].enum;
        if index($value) == null then . + [$value] else . end
      )
    ' "$staged" > "$next"
  mv "$next" "$staged"
}

# Ensure every service-role/admin-only entity exists in the local stage before
# adding fields. A missing production LiveActivityRegistration must not make
# preparation fail before its canonical schema can be staged.
for entity_file in \
  CommunityReport.jsonc \
  apple-sign-in-credential.jsonc \
  billing-identity-lifecycle.jsonc \
  ai-word-pack-cache-variant.jsonc \
  ai-word-pack-request-result.jsonc \
  push-device-registration.jsonc \
  live-activity-registration.jsonc \
  push-notification-event.jsonc
do
  entity_name=$(jq -er '.name' "$ROOT/base44/entities/$entity_file")
  if ! jq -e --arg name "$entity_name" \
    '.schemas | any(.entity_name == $name)' "$REMOTE" >/dev/null; then
    cp "$ROOT/base44/entities/$entity_file" \
      "$STAGE/base44/entities/$entity_name.jsonc"
  fi
done

add_optional_field Friendship blocked_by_id
add_optional_field Friendship request_event_id
add_optional_field GameHistory player_user_id
add_optional_field GameHistory match_id
add_optional_field GameHistory match_type
add_optional_field GameHistory ranked
add_optional_field GameRoom participant_user_ids
add_optional_field GameRoom match_id
add_optional_field GameRoom terminal_intent
add_optional_field GameRoom game_started_event_id
add_optional_field GameRoom game_finished_event_id
add_optional_field GameRoom intro_started_at
add_optional_field GameRoom game_paused_at
add_optional_field GameRoom game_paused_total_seconds
add_optional_field RoomInvite notification_event_id
add_optional_field WordPack owner_user_id
add_optional_field AppStoreAccount reservation_state app-store-account.jsonc
add_optional_field Entitlement write_revision entitlement.jsonc
add_optional_field LiveActivityRegistration pending_force_end live-activity-registration.jsonc
add_optional_field LiveActivityRegistration locale live-activity-registration.jsonc

for field in \
  rating \
  games_played \
  games_won \
  ai_generations_today \
  last_ai_generation_date \
  spy_id
do
  add_user_authoritative_field "$field"
done
add_optional_field User spy_card_theme
add_optional_field User spy_card_accent
add_optional_field User spy_card_badge
extend_user_enum language

# After additive fields are applied, every service-role/admin-only entity must
# exactly match the canonical release boundary. Refuse silent production drift.
for entity_file in \
  CommunityReport.jsonc \
  apple-sign-in-credential.jsonc \
  billing-identity-lifecycle.jsonc \
  ai-word-pack-cache-variant.jsonc \
  ai-word-pack-request-result.jsonc \
  push-device-registration.jsonc \
  live-activity-registration.jsonc \
  push-notification-event.jsonc
do
  entity_name=$(jq -er '.name' "$ROOT/base44/entities/$entity_file")
  staged_entity="$STAGE/base44/entities/$entity_name.jsonc"
  jq -e \
    --slurpfile canonical "$ROOT/base44/entities/$entity_file" \
    '. == $canonical[0]' \
    "$staged_entity" >/dev/null || {
      echo "Production schema for $entity_name differs from the canonical release schema." >&2
      exit 65
    }
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
for name in \
  CommunityReport \
  AppleSignInCredential \
  BillingIdentityLifecycle \
  AiWordPackCacheVariant \
  AiWordPackRequestResult \
  PushDeviceRegistration \
  LiveActivityRegistration \
  PushNotificationEvent
do
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

for staged_file in "$STAGE"/base44/entities/*.jsonc; do
  jq -er '.name' "$staged_file"
done | LC_ALL=C sort > "$STAGE_NAMES"
if ! cmp -s "$CANONICAL_NAMES" "$STAGE_NAMES"; then
  echo "Prepared additive target is not the exact reviewed canonical entity-name universe." >&2
  diff -u "$CANONICAL_NAMES" "$STAGE_NAMES" >&2 || true
  exit 65
fi
if [ "$stage_count" -ne "$EXPECTED_ENTITY_COUNT" ]; then
  echo "Prepared additive target must contain exactly $EXPECTED_ENTITY_COUNT entities." >&2
  exit 65
fi
if ! jq -s -e --argjson expected "$EXPECTED_CUSTOM_ENTITY_COUNT" '
  [.[] | select(.name != "User") |
    (.rls.create.user_condition.role == "admin" and
     .rls.update.user_condition.role == "admin" and
     .rls.delete.user_condition.role == "admin")
  ] as $checks |
  ($checks | length) == $expected and all($checks[]; . == true)
' "$STAGE"/base44/entities/*.jsonc >/dev/null; then
  echo "Prepared additive target does not close direct writes for all 19 custom entities." >&2
  exit 65
fi

# An authoritative push from a partial directory deletes omitted schemas.
jq -r '.schemas[].entity_name' "$REMOTE" | while IFS= read -r name; do
  if [ ! -f "$STAGE/base44/entities/$name.jsonc" ]; then
    echo "Prepared stage would omit live entity $name; refusing to continue." >&2
    exit 65
  fi
done

schema_digest=$(schema_set_digest_from_stage "$STAGE")
stage_bytes_digest=$(tree_bytes_digest "$STAGE/base44")
inputs_digest=$(local_inputs_digest)
STAGED_SCHEMAS="$WORK/staged-schemas.json"
SCHEMA_DELTAS="$WORK/schema-deltas.json"
jq -S -s 'sort_by(.name)' "$STAGE"/base44/entities/*.jsonc > "$STAGED_SCHEMAS"
jq -S -n \
  --slurpfile remote "$REMOTE" \
  --slurpfile staged "$STAGED_SCHEMAS" '
    ($remote[0].schemas | map({key:.entity_name,value:.entity_schema}) | from_entries) as $live |
    [
      $staged[0][] as $target |
      ($live[$target.name] // null) as $before |
      select($before == null or $before != $target) |
      {
        entity:$target.name,
        operation:(if $before == null then "add" else "change" end),
        property_additions:(
          if $before == null then ($target.properties // {} | keys)
          else (($target.properties // {} | keys) - ($before.properties // {} | keys)) end
        ),
        property_removals:(
          if $before == null then []
          else (($before.properties // {} | keys) - ($target.properties // {} | keys)) end
        ),
        property_changes:(
          if $before == null then []
          else [($target.properties // {} | keys[]) as $key |
            select(($before.properties // {} | has($key)) and
              $before.properties[$key] != $target.properties[$key]) | $key]
          end
        ),
        rls_changed:(if $before == null then true else (($before.rls // null) != ($target.rls // null)) end),
        target_write_boundary:(
          if $target.name == "User" then "platform-owned"
          elif ($target.rls.create.user_condition.role == "admin" and
                $target.rls.update.user_condition.role == "admin" and
                $target.rls.delete.user_condition.role == "admin") then "admin-only"
          else "invalid" end
        )
      }
    ]
  ' > "$SCHEMA_DELTAS"
jq -e \
  --argjson expected_custom "$EXPECTED_CUSTOM_ENTITY_COUNT" '
    ([.[] | select(.entity != "User" and .target_write_boundary == "admin-only")] | length) <= $expected_custom and
    all(.[]; .entity == "User" or .target_write_boundary == "admin-only")
  ' "$SCHEMA_DELTAS" >/dev/null || {
    echo "Additive schema delta contains a custom entity outside the admin-only write boundary." >&2
    exit 65
  }
schema_deltas_digest=$(shasum -a 256 "$SCHEMA_DELTAS" | awk '{print $1}')
entity_additions=$(comm -13 "$REMOTE_NAMES" "$CANONICAL_NAMES" | jq -Rsc 'split("\n") | map(select(length > 0))')
entity_deletions=$(comm -23 "$REMOTE_NAMES" "$CANONICAL_NAMES" | jq -Rsc 'split("\n") | map(select(length > 0))')
plan_digest=$(printf '%s\n' \
  "$APP_ID" "$remote_digest" "$remote_count" "$stage_count" "$schema_digest" \
  "$stage_bytes_digest" "$inputs_digest" "$schema_deltas_digest" \
  | shasum -a 256 | awk '{print $1}')
jq -n \
  --arg app_id "$APP_ID" \
  --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg remote_digest "$remote_digest" \
  --arg schema_digest "$schema_digest" \
  --arg stage_bytes_digest "$stage_bytes_digest" \
  --arg local_inputs_digest "$inputs_digest" \
  --arg schema_deltas_digest "$schema_deltas_digest" \
  --arg plan_digest "$plan_digest" \
  --argjson remote_count "$remote_count" \
  --argjson prepared_count "$stage_count" \
  --argjson entity_additions "$entity_additions" \
  --argjson entity_deletions "$entity_deletions" \
  --slurpfile schema_deltas "$SCHEMA_DELTAS" \
  '{app_id:$app_id,prepared_at:$prepared_at,remote_count:$remote_count,prepared_count:$prepared_count,remote_digest:$remote_digest,schema_digest:$schema_digest,stage_bytes_digest:$stage_bytes_digest,local_inputs_digest:$local_inputs_digest,schema_deltas_digest:$schema_deltas_digest,plan_digest:$plan_digest,expected_entity_count:20,expected_custom_entity_count:19,entity_additions:$entity_additions,entity_deletions:$entity_deletions,entity_add_count:($entity_additions|length),entity_delete_count:($entity_deletions|length),schema_deltas:$schema_deltas[0],adds:($entity_additions|length),deletes:($entity_deletions|length)}' \
  > "$STAGE/manifest.json"

if [ "$MODE" = prepare ]; then
  if [ -f "$FIXED_STAGE/postflight.json" ] && \
     [ ! -L "$FIXED_STAGE/postflight.json" ]; then
    cp "$FIXED_STAGE/postflight.json" \
      "$EVIDENCE_DIR/legacy-postflight-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
  fi
  rm -rf "$FIXED_STAGE"
  mv "$STAGE" "$FIXED_STAGE"
  echo "Prepared additive Base44 schema stage: $FIXED_STAGE"
  echo "Entities preserved: $remote_count; prepared: $stage_count"
  echo "Plan digest: $plan_digest"
  echo "No remote change was made. Re-run with --push to refetch and apply."
  exit 0
fi

reviewed_plan_digest=$(jq -er '.plan_digest' "$REVIEWED_MANIFEST")
reviewed_stage_bytes_digest=$(jq -er '.stage_bytes_digest' "$REVIEWED_MANIFEST")
reviewed_local_inputs_digest=$(jq -er '.local_inputs_digest' "$REVIEWED_MANIFEST")
reviewed_manifest_digest=$(shasum -a 256 "$REVIEWED_MANIFEST" | awk '{print $1}')

if [ "$plan_digest" != "$reviewed_plan_digest" ] || \
   [ "$stage_bytes_digest" != "$reviewed_stage_bytes_digest" ] || \
   [ "$inputs_digest" != "$reviewed_local_inputs_digest" ]; then
  echo "The JIT additive schema plan or local inputs differ from the fixed reviewed stage." >&2
  echo "The preserved reviewed evidence remains at $FIXED_STAGE/manifest.json." >&2
  exit 77
fi
if ! diff -qr "$STAGE/base44" "$FIXED_STAGE/base44" >/dev/null; then
  echo "JIT additive stage bytes differ from the fixed reviewed stage." >&2
  exit 77
fi

echo "Reproduced reviewed additive Base44 schema stage: $FIXED_STAGE"
echo "Entities preserved: $remote_count; prepared: $stage_count"
echo "Plan digest: $plan_digest"

if [ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]; then
  echo "Set BASE44_CONFIRM_APP_ID=$APP_ID for the intentional production push." >&2
  exit 77
fi
if [ "${BASE44_CONFIRM_ADDITIVE_PLAN_DIGEST:-}" != "$reviewed_plan_digest" ]; then
  echo "Fresh additive plan differs from the inspected plan." >&2
  echo "Inspect $FIXED_STAGE/manifest.json, then set BASE44_CONFIRM_ADDITIVE_PLAN_DIGEST to its plan_digest." >&2
  exit 77
fi
if [ "${BASE44_CONFIRM_ACTION:-}" != "SECURITY_CUTOVER_STEP_1_ADDITIVE_SCHEMA" ]; then
  echo "Set BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_1_ADDITIVE_SCHEMA for this exact cutover step." >&2
  exit 77
fi

# Rehash both the immutable reviewed stage and every local schema input at the
# last possible point before invoking the authoritative CLI mutation.
fetch_remote_schema "$JIT_REMOTE" || {
  echo "Unable to refetch Production schema immediately before push." >&2
  exit 70
}
validate_remote_schema "$JIT_REMOTE" || {
  echo "JIT Production schema response is incomplete or ambiguous." >&2
  exit 65
}
jit_remote_digest=$(jq -S '[
  .schemas | sort_by(.entity_name)[] |
  {entity_name, entity_schema}
]' "$JIT_REMOTE" | shasum -a 256 | awk '{print $1}')
jit_remote_count=$(jq -r '.total' "$JIT_REMOTE")
if [ "$jit_remote_digest" != "$remote_digest" ] || \
   [ "$jit_remote_count" -ne "$remote_count" ]; then
  echo "Production schema changed after JIT plan reproduction; refusing push." >&2
  exit 77
fi
fixed_stage_bytes_now=$(tree_bytes_digest "$FIXED_STAGE/base44")
local_inputs_now=$(local_inputs_digest)
if [ "$fixed_stage_bytes_now" != "$reviewed_stage_bytes_digest" ] || \
   [ "$local_inputs_now" != "$reviewed_local_inputs_digest" ]; then
  echo "Fixed additive stage or local inputs changed immediately before push." >&2
  exit 77
fi
for evidence_destination in \
  "$EVIDENCE_DIR/latest-postflight.json" \
  "$FIXED_STAGE/postflight.json"
do
  if [ -e "$evidence_destination" ] || [ -L "$evidence_destination" ]; then
    secure_private_json_file "$evidence_destination" || {
      echo "Unsafe existing additive-schema postflight destination: $evidence_destination" >&2
      exit 65
    }
  fi
done

attempt_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
attempt_dir="$EVIDENCE_DIR/$attempt_id"
mkdir "$attempt_dir"
secure_private_directory "$attempt_dir"
cp "$REVIEWED_MANIFEST" "$attempt_dir/reviewed-manifest.json"
secure_private_json_file "$attempt_dir/reviewed-manifest.json"
attempt_tmp="$WORK/attempt.json"
jq -n \
  --arg attempted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg app_id "$APP_ID" \
  --arg action "SECURITY_CUTOVER_STEP_1_ADDITIVE_SCHEMA" \
  --arg reviewed_manifest_digest "$reviewed_manifest_digest" \
  --arg reviewed_plan_digest "$reviewed_plan_digest" \
  --arg fixed_stage_bytes_digest "$fixed_stage_bytes_now" \
  --arg local_inputs_digest "$local_inputs_now" \
  --arg jit_remote_digest "$jit_remote_digest" \
  '{attempted_at:$attempted_at,app_id:$app_id,action:$action,reviewed_manifest_digest:$reviewed_manifest_digest,reviewed_plan_digest:$reviewed_plan_digest,fixed_stage_bytes_digest:$fixed_stage_bytes_digest,local_inputs_digest:$local_inputs_digest,jit_remote_digest:$jit_remote_digest,status:"mutation-started-postflight-required",postflight_required:true}' \
  > "$attempt_tmp"
chmod 600 "$attempt_tmp"
jq -e \
  --arg app_id "$APP_ID" \
  --arg action "SECURITY_CUTOVER_STEP_1_ADDITIVE_SCHEMA" \
  --arg plan_digest "$reviewed_plan_digest" '
    .app_id == $app_id and .action == $action and
    .reviewed_plan_digest == $plan_digest and
    .status == "mutation-started-postflight-required" and
    .postflight_required == true
  ' "$attempt_tmp" >/dev/null || exit 65
install_durable_json "$attempt_tmp" "$attempt_dir/attempt.json" "$attempt_dir" attempt

push_status=0
set +e
(cd "$FIXED_STAGE" && env -u BASE44_APP_ID npx --yes base44@0.1.4 \
  --app-id "$APP_ID" entities push)
push_status=$?
set -e

# Always perform and persist an independent fresh schema postflight, even if
# the CLI reported an error after a partial authoritative mutation.
postflight_fetch_status=0
postflight_schema_status=0
actual_count=0
actual_schema_digest=""
admin_write_boundary=false
set +e
fetch_remote_schema "$POST_REMOTE"
postflight_fetch_status=$?
if [ "$postflight_fetch_status" -eq 0 ]; then
  validate_remote_schema "$POST_REMOTE"
  postflight_schema_status=$?
  if [ "$postflight_schema_status" -eq 0 ]; then
    actual_count=$(jq -r '.total' "$POST_REMOTE")
    actual_schema_digest=$(schema_set_digest_from_remote "$POST_REMOTE")
    if jq -e '
      [.schemas[] | select(.entity_name != "User") |
        .entity_schema.rls as $rls |
        ($rls.create.user_condition.role == "admin" and
         $rls.update.user_condition.role == "admin" and
         $rls.delete.user_condition.role == "admin")
      ] as $checks |
      ($checks | length) == 19 and all($checks[]; . == true)
    ' "$POST_REMOTE" >/dev/null; then
      admin_write_boundary=true
    fi
  fi
else
  postflight_schema_status=$postflight_fetch_status
fi
set -e

postflight_matches=false
if [ "$postflight_fetch_status" -eq 0 ] && \
   [ "$postflight_schema_status" -eq 0 ] && \
   [ "$actual_count" -eq "$stage_count" ] && \
   [ "$actual_schema_digest" = "$schema_digest" ] && \
   [ "$admin_write_boundary" = true ]; then
  postflight_matches=true
fi

jq -n \
  --arg attempted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg app_id "$APP_ID" \
  --arg reviewed_manifest_digest "$reviewed_manifest_digest" \
  --arg reviewed_plan_digest "$reviewed_plan_digest" \
  --arg expected_schema_digest "$schema_digest" \
  --arg actual_schema_digest "$actual_schema_digest" \
  --argjson expected_count "$stage_count" \
  --argjson actual_count "$actual_count" \
  --argjson push_status "$push_status" \
  --argjson postflight_fetch_status "$postflight_fetch_status" \
  --argjson postflight_schema_status "$postflight_schema_status" \
  --argjson admin_write_boundary "$admin_write_boundary" \
  --argjson matches_reviewed_stage "$postflight_matches" \
  '{attempted_at:$attempted_at,app_id:$app_id,reviewed_manifest_digest:$reviewed_manifest_digest,reviewed_plan_digest:$reviewed_plan_digest,expected_schema_digest:$expected_schema_digest,actual_schema_digest:($actual_schema_digest | if length == 0 then null else . end),expected_count:$expected_count,actual_count:$actual_count,push_status:$push_status,postflight_fetch_status:$postflight_fetch_status,postflight_schema_status:$postflight_schema_status,admin_write_boundary:$admin_write_boundary,matches_reviewed_stage:$matches_reviewed_stage}' \
  > "$WORK/postflight.json"
chmod 600 "$WORK/postflight.json"
install_durable_json "$WORK/postflight.json" "$attempt_dir/postflight.json" "$attempt_dir" postflight
install_durable_json "$WORK/postflight.json" "$EVIDENCE_DIR/latest-postflight.json" "$EVIDENCE_DIR" latest-postflight
if [ ! -L "$FIXED_STAGE/postflight.json" ]; then
  cp "$WORK/postflight.json" "$FIXED_STAGE/postflight.json" || true
  chmod 600 "$FIXED_STAGE/postflight.json" 2>/dev/null || true
fi

if [ "$push_status" -ne 0 ] || [ "$postflight_matches" != true ]; then
  echo "Additive schema push did not reach the fully reviewed Production state." >&2
  echo "Inspect $attempt_dir/postflight.json; the reviewed manifest was preserved." >&2
  exit 70
fi
echo "Additive schema Production postflight verified."
