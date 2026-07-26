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
FIXED_STAGE="$CUTOVER_DIR/final-schema"
CHECK_STAGE="$CUTOVER_DIR/final-schema-check"
EVIDENCE_DIR="$CUTOVER_DIR/evidence/final-schema"
REVIEWED_SNAPSHOTS="$EVIDENCE_DIR/reviewed-stages"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/spyclash-base44-final.XXXXXX")
STAGE="$WORK/candidate-stage"
REMOTE="$WORK/remote.json"
POST_REMOTE="$WORK/postflight-remote.json"
JIT_REMOTE="$WORK/jit-remote.json"
REVIEWED_MANIFEST="$WORK/reviewed-manifest.json"
REMOTE_NORMALIZED="$WORK/remote-normalized.json"
CANONICAL_NORMALIZED="$WORK/canonical-normalized.json"
REMOTE_NAMES="$WORK/remote-names.txt"
CANONICAL_NAMES="$WORK/canonical-names.txt"
CHANGED_NAMES="$WORK/changed-names.txt"
PROPERTY_DELTAS="$WORK/property-deltas.jsonl"
AUTH_FILE="$HOME/.base44/auth/auth.json"
LOCK_DIR="$CUTOVER_DIR/.final-schema.lock"
PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
LOCK_HELD=0
PRODUCTION_LOCK_HELD=0
MODE=prepare

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
  --check) MODE=check ;;
  --push) MODE=push ;;
  *)
    echo "Usage: $0 [--check|--push]" >&2
    exit 64
    ;;
esac

# Keep every cleanup target fixed inside this repository. No caller-provided
# path is accepted because an authoritative schema stage is deleted/rebuilt.
if [ "${BASE44_FINAL_STAGE_DIR+x}" = x ]; then
  echo "BASE44_FINAL_STAGE_DIR is not supported; the stage path is fixed at $FIXED_STAGE." >&2
  exit 64
fi
case "$ROOT" in
  ""|/)
    echo "Unsafe repository root; refusing to prepare a schema stage." >&2
    exit 65
    ;;
esac
if [ "$FIXED_STAGE" != "$ROOT/.base44-cutover/final-schema" ]; then
  echo "Unsafe final schema stage path; refusing to continue." >&2
  exit 65
fi
if [ -L "$CUTOVER_DIR" ]; then
  echo "$CUTOVER_DIR must not be a symbolic link." >&2
  exit 65
fi
if [ -L "$FIXED_STAGE" ] || [ -L "$CHECK_STAGE" ]; then
  echo "Final schema stage paths must not be symbolic links." >&2
  exit 65
fi

for command in awk basename chmod cmp comm cp curl date diff env find grep head id jq mkdir mktemp mv npx rm rmdir sed shasum sort stat sync tr uname wc; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 69
  }
done

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

reviewed_payload_digest() {
  stage=$1
  base_digest=$(tree_bytes_digest "$stage/base44") || return $?
  diff_digest=$(tree_bytes_digest "$stage/diff") || return $?
  printf '%s\n%s\n' "$base_digest" "$diff_digest" |
    shasum -a 256 | awk '{print $1}'
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
    *) echo "Refusing unsafe final-schema evidence destination." >&2; return 65 ;;
  esac
  case "$durable_label" in
    ""|*[!A-Za-z0-9_-]*) return 65 ;;
  esac
  secure_private_directory "$durable_directory" || return $?
  secure_private_json_file "$durable_source" || return $?
  if [ -e "$durable_destination" ] || [ -L "$durable_destination" ]; then
    secure_private_json_file "$durable_destination" || {
      echo "Unsafe final-schema evidence destination: $durable_destination" >&2
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

secure_private_tree_modes() {
  private_tree=$1
  [ -d "$private_tree" ] && [ ! -L "$private_tree" ] || return 65
  if find "$private_tree" -type l -print | grep -q .; then
    return 65
  fi
  find "$private_tree" -type d -exec chmod 700 {} +
  find "$private_tree" -type f -exec chmod 600 {} +
  secure_private_directory "$private_tree"
}

preserve_reviewed_stage() {
  if [ ! -e "$FIXED_STAGE" ] && [ ! -L "$FIXED_STAGE" ]; then
    return 0
  fi
  [ -d "$FIXED_STAGE" ] && [ ! -L "$FIXED_STAGE" ] || {
    echo "Existing final-schema reviewed stage is unsafe." >&2
    return 65
  }
  secure_private_tree_modes "$FIXED_STAGE" || return $?
  secure_private_json_file "$FIXED_STAGE/manifest.json" || {
    echo "Existing final-schema reviewed manifest is unsafe." >&2
    return 65
  }
  reviewed_tree_digest=$(tree_bytes_digest "$FIXED_STAGE") || return $?
  case "$reviewed_tree_digest" in
    ""|*[!0-9a-f]*) return 65 ;;
  esac
  [ "${#reviewed_tree_digest}" -eq 64 ] || return 65
  mkdir -p "$REVIEWED_SNAPSHOTS"
  secure_private_directory "$REVIEWED_SNAPSHOTS" || return $?
  reviewed_snapshot="$REVIEWED_SNAPSHOTS/$reviewed_tree_digest"
  if [ -e "$reviewed_snapshot" ] || [ -L "$reviewed_snapshot" ]; then
    [ -d "$reviewed_snapshot" ] && [ ! -L "$reviewed_snapshot" ] || return 65
    [ "$(tree_bytes_digest "$reviewed_snapshot")" = "$reviewed_tree_digest" ] || return 65
    secure_private_tree_modes "$reviewed_snapshot" || return $?
    return 0
  fi
  reviewed_candidate=$(mktemp -d "$REVIEWED_SNAPSHOTS/.candidate.XXXXXX") || return 70
  cp -R "$FIXED_STAGE/." "$reviewed_candidate/" || {
    rm -rf -- "$reviewed_candidate"
    return 70
  }
  secure_private_tree_modes "$reviewed_candidate" || {
    rm -rf -- "$reviewed_candidate"
    return 70
  }
  [ "$(tree_bytes_digest "$reviewed_candidate")" = "$reviewed_tree_digest" ] || {
    rm -rf -- "$reviewed_candidate"
    return 70
  }
  mv "$reviewed_candidate" "$reviewed_snapshot" || {
    rm -rf -- "$reviewed_candidate"
    return 70
  }
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
  printf 'SECURITY_CUTOVER_STEP_6_FINAL_SCHEMA:%s\n' "$$" > "$PRODUCTION_LOCK_OWNER"
  chmod 600 "$PRODUCTION_LOCK_OWNER"
  [ -f "$PRODUCTION_LOCK_OWNER" ] && [ ! -L "$PRODUCTION_LOCK_OWNER" ] && \
    [ "$(private_owner "$PRODUCTION_LOCK_OWNER")" = "$(id -u)" ] && \
    [ "$(private_links "$PRODUCTION_LOCK_OWNER")" = 1 ] || return 65
}

mkdir -p "$CUTOVER_DIR"
if [ -L "$CUTOVER_DIR/evidence" ] || [ -L "$EVIDENCE_DIR" ]; then
  echo "Final schema evidence paths must not be symbolic links." >&2
  exit 65
fi
secure_private_directory "$CUTOVER_DIR"
if [ "$MODE" = push ]; then
  acquire_production_lock
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another final Base44 schema prepare/push is active: $LOCK_DIR" >&2
  exit 75
fi
LOCK_HELD=1
mkdir -p "$EVIDENCE_DIR" "$REVIEWED_SNAPSHOTS"
secure_private_directory "$CUTOVER_DIR/evidence"
secure_private_directory "$EVIDENCE_DIR"
secure_private_directory "$REVIEWED_SNAPSHOTS"

if [ "$MODE" = push ]; then
  if [ ! -f "$FIXED_STAGE/manifest.json" ] || [ -L "$FIXED_STAGE" ] || \
     [ -L "$FIXED_STAGE/manifest.json" ]; then
    echo "No fixed reviewed final schema stage exists; run the prepare command first." >&2
    exit 77
  fi
  secure_private_tree_modes "$FIXED_STAGE" || exit 65
  secure_private_json_file "$FIXED_STAGE/manifest.json" || {
    echo "Reviewed final-schema manifest must be a private, owned regular JSON file." >&2
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
  echo "Remote Base44 schema response is incomplete or ambiguous; refusing to prepare a push." >&2
  exit 65
}

# The additive phase is also the temporary write-maintenance boundary. Every
# custom entity must already be admin-only for create/update/delete before the
# coordinated server functions are eligible for deployment.
jq -e '
  [.schemas[] | select(.entity_name != "User") |
    .entity_schema.rls as $rls |
    ($rls.create.user_condition.role == "admin" and
     $rls.update.user_condition.role == "admin" and
     $rls.delete.user_condition.role == "admin")
  ] as $checks |
  ($checks | length) == 19 and all($checks[]; . == true)
' "$REMOTE" >/dev/null || {
  echo "Live custom entities do not have the complete additive admin-write boundary." >&2
  exit 65
}

jq -S '[
  .schemas | sort_by(.entity_name)[] |
  {entity_name, entity_schema}
]' "$REMOTE" > "$REMOTE_NORMALIZED"
remote_digest=$(shasum -a 256 "$REMOTE_NORMALIZED" | awk '{print $1}')

mkdir -p "$STAGE/base44/entities"
cp "$ROOT/base44/config.jsonc" "$STAGE/base44/config.jsonc"
cp "$APP_FILE" "$STAGE/base44/.app.jsonc"
cp "$ROOT"/base44/entities/*.jsonc "$STAGE/base44/entities/"

# User is a platform-owned entity. The canonical file deliberately declares
# only SpyClash custom fields, so an authoritative push must merge and preserve
# every live platform property/top-level boundary that is absent locally. In
# particular, role and its required constraint must never be deleted merely
# because Base44 does not duplicate built-ins in the checked-in declaration.
live_user="$WORK/live-User.json"
canonical_user="$ROOT/base44/entities/User.jsonc"
staged_user="$STAGE/base44/entities/User.jsonc"
jq -e '
  [.schemas[] | select(.entity_name == "User") | .entity_schema] |
  length == 1 and
  .[0].properties.role.type == "string"
' "$REMOTE" >/dev/null || {
  echo "Live Base44 User schema does not expose the required platform role field." >&2
  exit 65
}
jq '[.schemas[] | select(.entity_name == "User") | .entity_schema][0]' \
  "$REMOTE" > "$live_user"
jq -n \
  --slurpfile live "$live_user" \
  --slurpfile canonical "$canonical_user" '
    $live[0] as $l |
    $canonical[0] as $c |
    ($l.properties | with_entries(
      select(.key as $key | ($c.properties | has($key) | not))
    )) as $platform_properties |
    ($platform_properties | keys) as $platform_names |
    ($l + $c) |
    .properties = ($platform_properties + $c.properties) |
    .required = (((($c.required // []) +
      [($l.required // [])[] | select(. as $field | $platform_names | index($field))]) |
      unique)) |
    if (.required | length) == 0 then del(.required) else . end |
    if ($l | has("rls")) then .rls = $l.rls else . end
  ' > "$staged_user"

jq -e --slurpfile live "$live_user" --slurpfile canonical "$canonical_user" '
  . as $target |
  ["id", "email", "full_name", "role", "created_date", "updated_date", "created_by"] as $known_platform_names |
  (($live[0].properties | keys) - ($canonical[0].properties | keys)) as $platform_names |
  $target.properties.role == $live[0].properties.role and
  all($known_platform_names[]; . as $field |
    if ($live[0].properties | has($field)) then
      $target.properties[$field] == $live[0].properties[$field]
    else true end) and
  all($platform_names[]; . as $field |
    $target.properties[$field] == $live[0].properties[$field]) and
  (((($target.required // []) | index("role")) != null) ==
    ((($live[0].required // []) | index("role")) != null)) and
  (if ($live[0] | has("rls")) then $target.rls == $live[0].rls else true end)
' "$staged_user" >/dev/null || {
  echo "Final User target failed to preserve the live platform role contract." >&2
  exit 65
}
platform_user_fields=$(jq -c -n \
  --slurpfile live "$live_user" \
  --slurpfile canonical "$canonical_user" '
    (($live[0].properties | keys) - ($canonical[0].properties | keys)) | sort
  ')

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
require_live_property Friendship request_event_id
require_live_property GameHistory player_user_id
require_live_property GameHistory match_id
require_live_property GameHistory match_type
require_live_property GameHistory ranked
require_live_property GameRoom participant_user_ids
require_live_property GameRoom match_id
require_live_property GameRoom terminal_intent
require_live_property GameRoom game_started_event_id
require_live_property GameRoom game_finished_event_id
require_live_property GameRoom intro_started_at
require_live_property GameRoom game_paused_at
require_live_property GameRoom game_paused_total_seconds
require_live_property RoomInvite notification_event_id
require_live_property WordPack owner_user_id
require_live_property AppStoreAccount reservation_state
require_live_property Entitlement write_revision
require_live_property LiveActivityRegistration pending_force_end
require_live_property LiveActivityRegistration locale
require_live_property User rating
require_live_property User spy_id
require_live_property User spy_card_theme
require_live_property User spy_card_accent
require_live_property User spy_card_badge

require_live_user_admin_write() {
  field=$1
  jq -e --arg field "$field" '
    [.schemas[] | select(.entity_name == "User") |
      .entity_schema.properties[$field].rls.write.user_condition.role] == ["admin"]
  ' "$REMOTE" >/dev/null || {
    echo "Live User.$field is missing its additive admin-write boundary." >&2
    exit 65
  }
}

for field in \
  rating \
  games_played \
  games_won \
  ai_generations_today \
  last_ai_generation_date \
  spy_id
do
  require_live_user_admin_write "$field"
done

jq -e '
  [.schemas[] | select(.entity_name == "User") |
    .entity_schema.properties.language.enum] as $enums |
  ($enums | length) == 1 and
  (["ru", "en", "es"] | all(. as $language | $enums[0] | index($language) != null))
' "$REMOTE" >/dev/null || {
  echo "Live User.language is missing a release language." >&2
  exit 65
}

: > "$CHANGED_NAMES"
: > "$PROPERTY_DELTAS"
mkdir -p "$STAGE/diff"
for schema in "$STAGE"/base44/entities/*.jsonc; do
  name=$(jq -er '.name' "$schema")
  live_normalized="$WORK/live-$name.json"
  canonical_normalized="$WORK/canonical-$name.json"
  jq -S --arg name "$name" \
    '[.schemas[] | select(.entity_name == $name) | .entity_schema][0]' \
    "$REMOTE" > "$live_normalized"
  jq -S . "$schema" > "$canonical_normalized"
  jq -n \
    --arg entity "$name" \
    --slurpfile live "$live_normalized" \
    --slurpfile target "$canonical_normalized" '
      ($live[0].properties // {}) as $before |
      ($target[0].properties // {}) as $after |
      ($before | keys) as $before_keys |
      ($after | keys) as $after_keys |
      {
        entity:$entity,
        added:(($after_keys - $before_keys) | sort),
        removed:(($before_keys - $after_keys) | sort),
        changed:([($before_keys - ($before_keys - $after_keys))[] as $field |
          select($before[$field] != $after[$field]) | $field] | sort)
      }
    ' >> "$PROPERTY_DELTAS"
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
property_additions=$(jq -s '[.[] | .entity as $entity | .added[] | "\($entity).\(.)"]' "$PROPERTY_DELTAS")
property_removals=$(jq -s '[.[] | .entity as $entity | .removed[] | "\($entity).\(.)"]' "$PROPERTY_DELTAS")
property_changes=$(jq -s '[.[] | .entity as $entity | .changed[] | "\($entity).\(.)"]' "$PROPERTY_DELTAS")
if printf '%s' "$property_removals" | jq -e 'any(.[]; startswith("User."))' >/dev/null; then
  echo "Final schema target would remove a live User property; refusing the push plan." >&2
  printf '%s\n' "$property_removals" >&2
  exit 65
fi
entity_additions=$(comm -13 "$REMOTE_NAMES" "$CANONICAL_NAMES" | jq -Rsc 'split("\n") | map(select(length > 0))')
entity_deletions=$(comm -23 "$REMOTE_NAMES" "$CANONICAL_NAMES" | jq -Rsc 'split("\n") | map(select(length > 0))')
stage_bytes_digest=$(reviewed_payload_digest "$STAGE")
inputs_digest=$(local_inputs_digest)
plan_digest=$(printf '%s\n' \
  "$APP_ID" "$remote_digest" "$canonical_digest" "$changed_json" \
  "$property_additions" "$property_removals" "$property_changes" \
  "$platform_user_fields" "$stage_bytes_digest" "$inputs_digest" \
  | shasum -a 256 | awk '{print $1}')
jq -n \
  --arg app_id "$APP_ID" \
  --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg remote_digest "$remote_digest" \
  --arg canonical_digest "$canonical_digest" \
  --arg stage_bytes_digest "$stage_bytes_digest" \
  --arg local_inputs_digest "$inputs_digest" \
  --arg plan_digest "$plan_digest" \
  --argjson live_count "$remote_count" \
  --argjson canonical_count "$canonical_count" \
  --argjson changed_entities "$changed_json" \
  --argjson entity_additions "$entity_additions" \
  --argjson entity_deletions "$entity_deletions" \
  --argjson property_additions "$property_additions" \
  --argjson property_removals "$property_removals" \
  --argjson property_changes "$property_changes" \
  --argjson platform_user_fields "$platform_user_fields" \
  '{app_id:$app_id,prepared_at:$prepared_at,live_count:$live_count,canonical_count:$canonical_count,remote_digest:$remote_digest,canonical_digest:$canonical_digest,stage_bytes_digest:$stage_bytes_digest,local_inputs_digest:$local_inputs_digest,plan_digest:$plan_digest,changed_entities:$changed_entities,entity_additions:$entity_additions,entity_deletions:$entity_deletions,entity_add_count:($entity_additions|length),entity_delete_count:($entity_deletions|length),property_additions:$property_additions,property_removals:$property_removals,property_changes:$property_changes,platform_user_fields_preserved:$platform_user_fields,adds:($entity_additions|length),deletes:($entity_deletions|length),live_admin_write_boundary:true}' \
  > "$STAGE/manifest.json"

if [ "$MODE" = check ]; then
  rm -rf "$CHECK_STAGE"
  mv "$STAGE" "$CHECK_STAGE"
  echo "Checked fresh final Base44 schema state: $CHECK_STAGE"
  echo "Plan digest: $plan_digest"
  echo "No reviewed plan or remote state was changed."
  exit 0
fi

if [ "$MODE" = prepare ]; then
  preserve_reviewed_stage
  rm -rf "$FIXED_STAGE"
  mv "$STAGE" "$FIXED_STAGE"
  secure_private_tree_modes "$FIXED_STAGE"
  echo "Prepared final Base44 schema stage: $FIXED_STAGE"
  echo "App id: $APP_ID"
  echo "Entities: live=$remote_count target=$canonical_count entity-adds=0 entity-deletes=0 changes=$changed_count"
  echo "Property additions: $(printf '%s' "$property_additions" | jq 'length'); removals: $(printf '%s' "$property_removals" | jq 'length')"
  echo "Plan digest: $plan_digest"
  if [ "$changed_count" -gt 0 ]; then
    sed 's/^/  change: /' "$CHANGED_NAMES"
  fi
  echo "No remote change was made. Inspect the fresh diff and re-run with --push."
  exit 0
fi

reviewed_plan_digest=$(jq -er '.plan_digest' "$REVIEWED_MANIFEST")
reviewed_stage_bytes_digest=$(jq -er '.stage_bytes_digest' "$REVIEWED_MANIFEST")
reviewed_local_inputs_digest=$(jq -er '.local_inputs_digest' "$REVIEWED_MANIFEST")
reviewed_manifest_digest=$(shasum -a 256 "$REVIEWED_MANIFEST" | awk '{print $1}')

if [ "$plan_digest" != "$reviewed_plan_digest" ] || \
   [ "$stage_bytes_digest" != "$reviewed_stage_bytes_digest" ] || \
   [ "$inputs_digest" != "$reviewed_local_inputs_digest" ]; then
  echo "The JIT final schema plan or local inputs differ from the fixed reviewed stage." >&2
  echo "The preserved reviewed evidence remains at $FIXED_STAGE/manifest.json." >&2
  exit 77
fi
if ! diff -qr "$STAGE/base44" "$FIXED_STAGE/base44" >/dev/null || \
   ! diff -qr "$STAGE/diff" "$FIXED_STAGE/diff" >/dev/null; then
  echo "JIT final schema bytes differ from the fixed reviewed stage." >&2
  exit 77
fi

echo "Reproduced reviewed final Base44 schema stage: $FIXED_STAGE"
echo "App id: $APP_ID"
echo "Entities: live=$remote_count target=$canonical_count entity-adds=0 entity-deletes=0 changes=$changed_count"
echo "Property additions: $(printf '%s' "$property_additions" | jq 'length'); removals: $(printf '%s' "$property_removals" | jq 'length')"
echo "Plan digest: $plan_digest"

if [ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]; then
  echo "Set BASE44_CONFIRM_APP_ID=$APP_ID for the intentional final schema push." >&2
  exit 77
fi
if [ "${BASE44_CONFIRM_FINAL_PLAN_DIGEST:-}" != "$reviewed_plan_digest" ]; then
  echo "Fresh live/canonical plan differs from the inspected plan." >&2
  echo "Inspect $FIXED_STAGE/manifest.json and every diff, then set BASE44_CONFIRM_FINAL_PLAN_DIGEST to its plan_digest." >&2
  exit 77
fi
if [ "${BASE44_CONFIRM_ACTION:-}" != "SECURITY_CUTOVER_STEP_6_FINAL_SCHEMA" ]; then
  echo "Set BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_6_FINAL_SCHEMA for this exact cutover step." >&2
  exit 77
fi
if [ "$changed_count" -eq 0 ]; then
  echo "Live schema already matches the canonical final schema; no push was made."
  exit 0
fi

# Rehash the reviewed payload and all checked-in schema inputs immediately
# before the authoritative mutation. The operation lock stays held throughout.
fetch_remote_schema "$JIT_REMOTE" || {
  echo "Unable to refetch Production schema immediately before final push." >&2
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
  echo "Production schema changed after JIT plan reproduction; refusing final push." >&2
  exit 77
fi
fixed_stage_bytes_now=$(reviewed_payload_digest "$FIXED_STAGE")
local_inputs_now=$(local_inputs_digest)
if [ "$fixed_stage_bytes_now" != "$reviewed_stage_bytes_digest" ] || \
   [ "$local_inputs_now" != "$reviewed_local_inputs_digest" ]; then
  echo "Fixed final schema stage or local inputs changed immediately before push." >&2
  exit 77
fi
for evidence_destination in \
  "$EVIDENCE_DIR/latest-postflight.json" \
  "$FIXED_STAGE/postflight.json"
do
  if [ -e "$evidence_destination" ] || [ -L "$evidence_destination" ]; then
    secure_private_json_file "$evidence_destination" || {
      echo "Unsafe existing final-schema postflight destination: $evidence_destination" >&2
      exit 65
    }
  fi
done

# Preserve the complete reviewed target (manifest, payload and every diff) in a
# content-addressed private snapshot before the authoritative push boundary.
preserve_reviewed_stage
reviewed_tree_digest=$(tree_bytes_digest "$FIXED_STAGE")
reviewed_snapshot="$REVIEWED_SNAPSHOTS/$reviewed_tree_digest"
[ -d "$reviewed_snapshot" ] && [ ! -L "$reviewed_snapshot" ] || exit 70
[ "$(tree_bytes_digest "$reviewed_snapshot")" = "$reviewed_tree_digest" ] || exit 70

attempt_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
attempt_dir="$EVIDENCE_DIR/$attempt_id"
mkdir "$attempt_dir"
secure_private_directory "$attempt_dir"
cp "$REVIEWED_MANIFEST" "$attempt_dir/reviewed-manifest.json"
secure_private_json_file "$attempt_dir/reviewed-manifest.json"
cp -R "$reviewed_snapshot" "$attempt_dir/reviewed-stage"
secure_private_tree_modes "$attempt_dir/reviewed-stage"
[ "$(tree_bytes_digest "$attempt_dir/reviewed-stage")" = "$reviewed_tree_digest" ] || exit 70
attempt_tmp="$WORK/attempt.json"
jq -n \
  --arg attempted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg app_id "$APP_ID" \
  --arg action "SECURITY_CUTOVER_STEP_6_FINAL_SCHEMA" \
  --arg reviewed_manifest_digest "$reviewed_manifest_digest" \
  --arg reviewed_plan_digest "$reviewed_plan_digest" \
  --arg fixed_stage_bytes_digest "$fixed_stage_bytes_now" \
  --arg reviewed_tree_digest "$reviewed_tree_digest" \
  --arg local_inputs_digest "$local_inputs_now" \
  --arg jit_remote_digest "$jit_remote_digest" \
  '{attempted_at:$attempted_at,app_id:$app_id,action:$action,reviewed_manifest_digest:$reviewed_manifest_digest,reviewed_plan_digest:$reviewed_plan_digest,fixed_stage_bytes_digest:$fixed_stage_bytes_digest,reviewed_tree_digest:$reviewed_tree_digest,local_inputs_digest:$local_inputs_digest,jit_remote_digest:$jit_remote_digest,status:"mutation-started-postflight-required",postflight_required:true}' \
  > "$attempt_tmp"
chmod 600 "$attempt_tmp"
jq -e \
  --arg app_id "$APP_ID" \
  --arg action "SECURITY_CUTOVER_STEP_6_FINAL_SCHEMA" \
  --arg plan_digest "$reviewed_plan_digest" \
  --arg reviewed_tree_digest "$reviewed_tree_digest" '
    .app_id == $app_id and .action == $action and
    .reviewed_plan_digest == $plan_digest and
    .reviewed_tree_digest == $reviewed_tree_digest and
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

# Always re-read and classify Production after the attempt. This evidence is
# separate from, and never overwrites, the pre-attempt reviewed manifest/diffs.
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
   [ "$actual_count" -eq "$canonical_count" ] && \
   [ "$actual_schema_digest" = "$canonical_digest" ] && \
   [ "$admin_write_boundary" = true ]; then
  postflight_matches=true
fi

jq -n \
  --arg attempted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg app_id "$APP_ID" \
  --arg reviewed_manifest_digest "$reviewed_manifest_digest" \
  --arg reviewed_plan_digest "$reviewed_plan_digest" \
  --arg expected_schema_digest "$canonical_digest" \
  --arg actual_schema_digest "$actual_schema_digest" \
  --argjson expected_count "$canonical_count" \
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
  echo "Final schema push did not reach the fully reviewed Production state." >&2
  echo "Inspect $attempt_dir/postflight.json; the reviewed manifest and diffs were preserved." >&2
  exit 70
fi
echo "Final schema Production postflight verified."
