#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
EXPECTED_APP_ID=69a0e57fa939f578082f8091
EXPECTED_ACTION=SECURITY_CUTOVER_STEP_7_STABLE_OWNER_BACKFILL
APP_ID=$EXPECTED_APP_ID
MODE=dry-run
SEEN_APP_ID=0
SEEN_APPLY=0
SCRIPT="$ROOT/scripts/backfill-sensitive-entity-owners.ts"
ROOM_WRITE_LIFECYCLE_SCRIPT="$ROOT/base44/functions/gameRoomAction/room-write-lifecycle.ts"
BILLING_LIFECYCLE_SCRIPT="$ROOT/base44/functions/gameRoomAction/billing-identity-lifecycle.ts"
CUTOVER_DIR="$ROOT/.base44-cutover"
STAGE="$CUTOVER_DIR/sensitive-owner-backfill"
REVIEWED_ROOT="$STAGE/reviewed-inputs"
REVIEWED_POINTER="$STAGE/reviewed-inputs-current.json"
OPERATION_LOCK="$CUTOVER_DIR/sensitive-owner-backfill.operation.lock"
PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
MANIFEST="$STAGE/manifest.json"
COMPLETION="$STAGE/completion.json"
LAST_ATTEMPT="$STAGE/last-attempt.json"
FINAL_SCHEMA_SCRIPT="$ROOT/scripts/push-base44-final-schema.sh"
FINAL_SCHEMA_MANIFEST="$CUTOVER_DIR/final-schema-check/manifest.json"
WORK=
CANDIDATE_STAGE=
ATOMIC_STAGE_TMP=
REVIEWED_STAGE=
LOCK_HELD=0
PRODUCTION_LOCK_HELD=0

usage() {
  echo "Usage: $0 [--app-id $EXPECTED_APP_ID] [--apply]" >&2
  exit 64
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-id)
      [ "$SEEN_APP_ID" -eq 0 ] || usage
      [ "$#" -ge 2 ] || usage
      APP_ID=$2
      SEEN_APP_ID=1
      shift 2
      ;;
    --apply)
      [ "$SEEN_APPLY" -eq 0 ] || usage
      MODE=apply
      SEEN_APPLY=1
      shift
      ;;
    *) usage ;;
  esac
done

[ "$APP_ID" = "$EXPECTED_APP_ID" ] || {
  echo "Only reviewed SpyClash app $EXPECTED_APP_ID is supported." >&2
  exit 77
}
case "$APP_ID" in
  *[!A-Za-z0-9_-]*)
    echo "Invalid Base44 app id." >&2
    exit 65
    ;;
esac

if [ "${BASE44_APP_ID+x}" = x ] && [ "$BASE44_APP_ID" != "$APP_ID" ]; then
  echo "BASE44_APP_ID targets $BASE44_APP_ID, not reviewed app $APP_ID." >&2
  exit 77
fi
if [ "${BASE44_PROJECTS_BASE44_APP_ID+x}" = x ] && \
  [ "$BASE44_PROJECTS_BASE44_APP_ID" != "$APP_ID" ]; then
  echo "BASE44_PROJECTS_BASE44_APP_ID targets another app." >&2
  exit 77
fi
if [ "${BASE44_CONFIRM_APP_ID+x}" = x ] && \
  [ "$BASE44_CONFIRM_APP_ID" != "$APP_ID" ]; then
  echo "BASE44_CONFIRM_APP_ID targets another app." >&2
  exit 77
fi
if [ "${BASE44_CONFIRM_ACTION+x}" = x ] && \
  [ "$BASE44_CONFIRM_ACTION" != "$EXPECTED_ACTION" ]; then
  echo "BASE44_CONFIRM_ACTION targets another cutover step." >&2
  exit 77
fi
for internal_name in \
  SPYCLASH_BACKFILL_APPLY \
  SPYCLASH_BACKFILL_SOURCE_SHA256 \
  SPYCLASH_BACKFILL_LIFECYCLE_SOURCE_SHA256 \
  SPYCLASH_BACKFILL_ROOM_WRITE_LIFECYCLE_URL \
  SPYCLASH_BACKFILL_FINAL_SCHEMA_REMOTE_DIGEST \
  SPYCLASH_BACKFILL_FINAL_SCHEMA_VERIFIED \
  SPYCLASH_BACKFILL_EXPECTED_PLAN_DIGEST \
  SPYCLASH_BACKFILL_CONFIRM_ACTION \
  SPYCLASH_BACKFILL_CONFIRM_APP_ID \
  BASE44_SENSITIVE_OWNER_BACKFILL_STAGE_DIR
do
  eval "internal_is_set=\${$internal_name+x}"
  if [ "$internal_is_set" = x ]; then
    echo "$internal_name is wrapper-owned and must not be set by the caller." >&2
    exit 64
  fi
done

case "$ROOT" in
  ""|/)
    echo "Unsafe repository root." >&2
    exit 65
    ;;
esac
[ "$STAGE" = "$ROOT/.base44-cutover/sensitive-owner-backfill" ] || exit 65
[ "$REVIEWED_ROOT" = "$STAGE/reviewed-inputs" ] || exit 65
[ "$REVIEWED_POINTER" = "$STAGE/reviewed-inputs-current.json" ] || exit 65
[ "$OPERATION_LOCK" = "$ROOT/.base44-cutover/sensitive-owner-backfill.operation.lock" ] || exit 65
[ "$PRODUCTION_LOCK_DIR" = "$ROOT/.base44-cutover/.production-mutation.lock" ] || exit 65
[ -f "$SCRIPT" ] && [ ! -L "$SCRIPT" ] || {
  echo "$SCRIPT must be a regular non-symlink file." >&2
  exit 65
}
for lifecycle_script in \
  "$ROOM_WRITE_LIFECYCLE_SCRIPT" \
  "$BILLING_LIFECYCLE_SCRIPT"
do
  [ -f "$lifecycle_script" ] && [ ! -L "$lifecycle_script" ] || {
    echo "$lifecycle_script must be a regular non-symlink file." >&2
    exit 65
  }
done
[ -x "$FINAL_SCHEMA_SCRIPT" ] && [ ! -L "$FINAL_SCHEMA_SCRIPT" ] || {
  echo "$FINAL_SCHEMA_SCRIPT must be an executable non-symlink file." >&2
  exit 65
}
if [ -L "$CUTOVER_DIR" ] || [ -L "$STAGE" ] || [ -L "$REVIEWED_ROOT" ] || \
  [ -L "$REVIEWED_POINTER" ] || [ -L "$OPERATION_LOCK" ] || \
  [ -L "$PRODUCTION_LOCK_DIR" ]; then
  echo "Base44 cutover stage directories must not be symbolic links." >&2
  exit 65
fi

for command in chmod cmp cp date find git id jq mkdir mktemp mv npx rm rmdir sed shasum stat sync tail uname wc; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 69
  }
done
for evidence_path in \
  ".base44-cutover/sensitive-owner-backfill/manifest.json" \
  ".base44-cutover/sensitive-owner-backfill/completion.json" \
  ".base44-cutover/sensitive-owner-backfill/last-attempt.json" \
  ".base44-cutover/sensitive-owner-backfill/reviewed-inputs-current.json" \
  ".base44-cutover/sensitive-owner-backfill/reviewed-inputs/example/inputs.json" \
  ".base44-cutover/sensitive-owner-backfill.operation.lock/owner" \
  ".base44-cutover/.production-mutation.lock/owner"
do
  (cd "$ROOT" && git check-ignore -q -- "$evidence_path") || {
    echo "$evidence_path is not protected by repository ignore rules." >&2
    exit 65
  }
done

cleanup() {
  if [ -n "$REVIEWED_STAGE" ]; then
    case "$REVIEWED_STAGE" in
      "$REVIEWED_ROOT"/[0-9a-f]*)
        if [ -d "$REVIEWED_STAGE" ] && [ ! -L "$REVIEWED_STAGE" ] && \
          [ -d "$REVIEWED_STAGE/gameRoomAction" ] && \
          [ ! -L "$REVIEWED_STAGE/gameRoomAction" ]; then
          chmod 400 "$REVIEWED_STAGE"/*.ts "$REVIEWED_STAGE"/inputs.json \
            "$REVIEWED_STAGE/gameRoomAction"/*.ts 2>/dev/null || :
          chmod 500 "$REVIEWED_STAGE/gameRoomAction" "$REVIEWED_STAGE" \
            2>/dev/null || :
        fi
        ;;
      *) echo "Refusing unsafe reviewed-stage permission repair: $REVIEWED_STAGE" >&2 ;;
    esac
  fi
  if [ -n "$ATOMIC_STAGE_TMP" ]; then
    case "$ATOMIC_STAGE_TMP" in
      "$STAGE"/.*)
        if [ -f "$ATOMIC_STAGE_TMP" ] && [ ! -L "$ATOMIC_STAGE_TMP" ]; then
          rm -f -- "$ATOMIC_STAGE_TMP"
        elif [ -e "$ATOMIC_STAGE_TMP" ]; then
          echo "Refusing unsafe atomic-file cleanup: $ATOMIC_STAGE_TMP" >&2
        fi
        ;;
      *) echo "Refusing unsafe atomic-file cleanup: $ATOMIC_STAGE_TMP" >&2 ;;
    esac
  fi
  if [ -n "$CANDIDATE_STAGE" ]; then
    case "$CANDIDATE_STAGE" in
      "$REVIEWED_ROOT"/.candidate.*)
        if [ -d "$CANDIDATE_STAGE" ] && [ ! -L "$CANDIDATE_STAGE" ]; then
          chmod -R u+w "$CANDIDATE_STAGE" 2>/dev/null || :
          rm -rf -- "$CANDIDATE_STAGE"
        elif [ -e "$CANDIDATE_STAGE" ]; then
          echo "Refusing unsafe reviewed-stage cleanup: $CANDIDATE_STAGE" >&2
        fi
        ;;
      *) echo "Refusing unsafe reviewed-stage cleanup: $CANDIDATE_STAGE" >&2 ;;
    esac
  fi
  if [ -n "$WORK" ]; then
    case "$WORK" in
      /tmp/spyclash-owner-backfill.*)
        if [ ! -e "$WORK" ]; then
          :
        elif [ -d "$WORK" ] && [ ! -L "$WORK" ]; then
          chmod -R u+w "$WORK" 2>/dev/null || :
          rm -rf -- "$WORK"
        else
          echo "Refusing unsafe temporary cleanup: $WORK" >&2
        fi
        ;;
      *) echo "Refusing unsafe temporary cleanup: $WORK" >&2 ;;
    esac
  fi
  if [ "$LOCK_HELD" -eq 1 ]; then
    if [ -d "$OPERATION_LOCK" ] && [ ! -L "$OPERATION_LOCK" ]; then
      rm -f -- "$OPERATION_LOCK/owner"
      rmdir -- "$OPERATION_LOCK" 2>/dev/null || \
        echo "Could not release owner-backfill operation lock: $OPERATION_LOCK" >&2
    else
      echo "Refusing unsafe operation-lock cleanup: $OPERATION_LOCK" >&2
    fi
    LOCK_HELD=0
  fi
  if [ "$PRODUCTION_LOCK_HELD" -eq 1 ]; then
    if [ -d "$PRODUCTION_LOCK_DIR" ] && [ ! -L "$PRODUCTION_LOCK_DIR" ]; then
      rm -f -- "$PRODUCTION_LOCK_OWNER"
      rmdir -- "$PRODUCTION_LOCK_DIR" 2>/dev/null || \
        echo "Could not release shared Base44 Production lock: $PRODUCTION_LOCK_DIR" >&2
    else
      echo "Refusing unsafe shared Production-lock cleanup." >&2
    fi
    PRODUCTION_LOCK_HELD=0
  fi
}

acquire_production_lock() {
  if ! mkdir "$PRODUCTION_LOCK_DIR" 2>/dev/null; then
    echo "Another Base44 Production mutation holds $PRODUCTION_LOCK_DIR." >&2
    echo "A stale lock must be reclaimed only after manual PID/path verification." >&2
    return 75
  fi
  PRODUCTION_LOCK_HELD=1
  [ -d "$PRODUCTION_LOCK_DIR" ] && [ ! -L "$PRODUCTION_LOCK_DIR" ] || return 65
  case "$(uname -s)" in
    Darwin) production_lock_owner=$(stat -f '%u' "$PRODUCTION_LOCK_DIR") ;;
    *) production_lock_owner=$(stat -c '%u' "$PRODUCTION_LOCK_DIR") ;;
  esac
  [ "$production_lock_owner" = "$(id -u)" ] || return 65
  chmod 700 "$PRODUCTION_LOCK_DIR"
  printf 'SECURITY_CUTOVER_STEP_7_STABLE_OWNER_BACKFILL:%s\n' "$$" > "$PRODUCTION_LOCK_OWNER"
  chmod 600 "$PRODUCTION_LOCK_OWNER"
  [ -f "$PRODUCTION_LOCK_OWNER" ] && [ ! -L "$PRODUCTION_LOCK_OWNER" ] || return 65
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

umask 077
mkdir -p "$CUTOVER_DIR"
[ -d "$CUTOVER_DIR" ] && [ ! -L "$CUTOVER_DIR" ] || {
  echo "Base44 cutover root must be a non-symlink directory." >&2
  exit 65
}
if [ "$MODE" = apply ]; then
  acquire_production_lock
fi
if ! mkdir "$OPERATION_LOCK" 2>/dev/null; then
  echo "Another owner-backfill prepare/apply operation holds $OPERATION_LOCK." >&2
  exit 75
fi
LOCK_HELD=1
[ -d "$OPERATION_LOCK" ] && [ ! -L "$OPERATION_LOCK" ] || {
  echo "Owner-backfill operation lock is unsafe." >&2
  exit 65
}
printf '%s\n' "$$" > "$OPERATION_LOCK/owner"

mkdir -p "$STAGE" "$REVIEWED_ROOT"
for protected_directory in "$STAGE" "$REVIEWED_ROOT"; do
  [ -d "$protected_directory" ] && [ ! -L "$protected_directory" ] || {
    echo "Unsafe owner-backfill stage directory: $protected_directory" >&2
    exit 65
  }
done
WORK=$(mktemp -d /tmp/spyclash-owner-backfill.XXXXXX)
case "$WORK" in
  /tmp/spyclash-owner-backfill.*) ;;
  *) echo "Unsafe temporary path." >&2; exit 65 ;;
esac
[ -d "$WORK" ] && [ ! -L "$WORK" ] || {
  echo "Temporary workspace must be a non-symlink directory." >&2
  exit 65
}

atomic_stage_file() {
  atomic_source=$1
  atomic_destination=$2
  atomic_label=$3
  [ -f "$atomic_source" ] && [ ! -L "$atomic_source" ] || return 65
  jq -e . "$atomic_source" >/dev/null || {
    echo "Refusing invalid JSON evidence source: $atomic_source" >&2
    return 65
  }
  case "$atomic_destination" in
    "$MANIFEST"|"$COMPLETION"|"$LAST_ATTEMPT"|"$REVIEWED_POINTER") ;;
    *) echo "Refusing an unreviewed atomic evidence destination." >&2; return 65 ;;
  esac
  if [ -e "$atomic_destination" ] || [ -L "$atomic_destination" ]; then
    [ -f "$atomic_destination" ] && [ ! -L "$atomic_destination" ] || {
      echo "Atomic evidence destination must be a regular non-symlink file: $atomic_destination" >&2
      return 65
    }
  fi
  case "$atomic_label" in
    ""|*[!A-Za-z0-9_-]*) return 65 ;;
  esac
  ATOMIC_STAGE_TMP=$(mktemp "$STAGE/.$atomic_label.XXXXXX")
  case "$ATOMIC_STAGE_TMP" in
    "$STAGE"/.*) ;;
    *) echo "Unsafe atomic evidence path." >&2; return 65 ;;
  esac
  [ -f "$ATOMIC_STAGE_TMP" ] && [ ! -L "$ATOMIC_STAGE_TMP" ] || return 65
  cp "$atomic_source" "$ATOMIC_STAGE_TMP"
  chmod 600 "$ATOMIC_STAGE_TMP"
  cmp -s "$atomic_source" "$ATOMIC_STAGE_TMP" || return 65
  case "$(uname -s)" in
    Darwin)
      [ "$(stat -f '%Lp:%u:%l' "$ATOMIC_STAGE_TMP")" = "600:$(id -u):1" ] || return 65
      ;;
    *)
      [ "$(stat -c '%a:%u:%h' "$ATOMIC_STAGE_TMP")" = "600:$(id -u):1" ] || return 65
      ;;
  esac
  mv "$ATOMIC_STAGE_TMP" "$atomic_destination"
  ATOMIC_STAGE_TMP=
  [ -f "$atomic_destination" ] && [ ! -L "$atomic_destination" ] || return 65
  case "$(uname -s)" in
    Darwin)
      [ "$(stat -f '%Lp:%u:%l' "$atomic_destination")" = "600:$(id -u):1" ] || return 65
      ;;
    *)
      [ "$(stat -c '%a:%u:%h' "$atomic_destination")" = "600:$(id -u):1" ] || return 65
      ;;
  esac
  sync
}

hash_file() {
  hash_path=$1
  hash_label=$2
  hash_value=$(shasum -a 256 "$hash_path" | sed 's/[[:space:]].*$//')
  case "$hash_value" in
    ""|*[!0-9a-f]*)
      echo "Unable to hash $hash_label." >&2
      return 65
      ;;
  esac
  [ "${#hash_value}" -eq 64 ] || return 65
  printf '%s\n' "$hash_value"
}

validate_reviewed_stage() {
  reviewed_stage=$1
  expected_input_set=$2
  expected_source=$3
  expected_room_lifecycle=$4
  expected_billing_lifecycle=$5
  expected_lifecycle_set=$6

  case "$reviewed_stage" in
    "$REVIEWED_ROOT"/*) ;;
    *) echo "Reviewed input stage escaped its fixed root." >&2; return 65 ;;
  esac
  [ -d "$reviewed_stage" ] && [ ! -L "$reviewed_stage" ] || return 65
  [ -d "$reviewed_stage/gameRoomAction" ] && \
    [ ! -L "$reviewed_stage/gameRoomAction" ] || return 65
  for reviewed_file in \
    "$reviewed_stage/backfill-sensitive-entity-owners.ts" \
    "$reviewed_stage/gameRoomAction/room-write-lifecycle.ts" \
    "$reviewed_stage/gameRoomAction/billing-identity-lifecycle.ts" \
    "$reviewed_stage/inputs.json"
  do
    [ -f "$reviewed_file" ] && [ ! -L "$reviewed_file" ] || return 65
  done
  reviewed_entry_count=$(find "$reviewed_stage" -mindepth 1 -print \
    | wc -l | sed 's/[[:space:]]//g')
  [ "$reviewed_entry_count" = 5 ] || {
    echo "Reviewed input stage contains unexpected entries." >&2
    return 65
  }
  [ -z "$(find "$reviewed_stage" -type l -print)" ] || return 65

  reviewed_source=$(hash_file \
    "$reviewed_stage/backfill-sensitive-entity-owners.ts" \
    "staged owner-backfill source") || return 65
  reviewed_room=$(hash_file \
    "$reviewed_stage/gameRoomAction/room-write-lifecycle.ts" \
    "staged room lifecycle source") || return 65
  reviewed_billing=$(hash_file \
    "$reviewed_stage/gameRoomAction/billing-identity-lifecycle.ts" \
    "staged billing lifecycle source") || return 65
  reviewed_lifecycle_set=$(printf '%s\n%s\n' \
    "$reviewed_room" "$reviewed_billing" \
    | shasum -a 256 | sed 's/[[:space:]].*$//')
  reviewed_input_set=$(printf '%s=%s\n%s=%s\n%s=%s\n' \
    "backfill-sensitive-entity-owners.ts" "$reviewed_source" \
    "gameRoomAction/room-write-lifecycle.ts" "$reviewed_room" \
    "gameRoomAction/billing-identity-lifecycle.ts" "$reviewed_billing" \
    | shasum -a 256 | sed 's/[[:space:]].*$//')

  [ "$reviewed_source" = "$expected_source" ] && \
    [ "$reviewed_room" = "$expected_room_lifecycle" ] && \
    [ "$reviewed_billing" = "$expected_billing_lifecycle" ] && \
    [ "$reviewed_lifecycle_set" = "$expected_lifecycle_set" ] && \
    [ "$reviewed_input_set" = "$expected_input_set" ] || {
      echo "Reviewed input stage bytes do not match their expected digests." >&2
      return 65
    }
  jq -e \
    --arg app_id "$APP_ID" \
    --arg input_set "$expected_input_set" \
    --arg source "$expected_source" \
    --arg room "$expected_room_lifecycle" \
    --arg billing "$expected_billing_lifecycle" \
    --arg lifecycle_set "$expected_lifecycle_set" '
    .protocol == "spyclash-sensitive-owner-backfill-inputs-v1" and
    .app_id == $app_id and
    .input_set_sha256 == $input_set and
    .source_sha256 == $source and
    .lifecycle_source_sha256 == $lifecycle_set and
    .files["backfill-sensitive-entity-owners.ts"] == $source and
    .files["gameRoomAction/room-write-lifecycle.ts"] == $room and
    .files["gameRoomAction/billing-identity-lifecycle.ts"] == $billing
  ' "$reviewed_stage/inputs.json" >/dev/null || return 65
}

# Build a byte-exact candidate from the fixed repository inputs. Dry-run may
# atomically register it as a content-addressed reviewed stage; apply may only
# consume a stage and pointer that a prior dry-run already created.
CANDIDATE_STAGE=$(mktemp -d "$REVIEWED_ROOT/.candidate.XXXXXX")
case "$CANDIDATE_STAGE" in
  "$REVIEWED_ROOT"/.candidate.*) ;;
  *) echo "Unsafe reviewed-stage candidate path." >&2; exit 65 ;;
esac
[ -d "$CANDIDATE_STAGE" ] && [ ! -L "$CANDIDATE_STAGE" ] || exit 65
mkdir -p "$CANDIDATE_STAGE/gameRoomAction"
cp "$SCRIPT" "$CANDIDATE_STAGE/backfill-sensitive-entity-owners.ts"
cp "$ROOM_WRITE_LIFECYCLE_SCRIPT" \
  "$CANDIDATE_STAGE/gameRoomAction/room-write-lifecycle.ts"
cp "$BILLING_LIFECYCLE_SCRIPT" \
  "$CANDIDATE_STAGE/gameRoomAction/billing-identity-lifecycle.ts"
cmp -s "$SCRIPT" "$CANDIDATE_STAGE/backfill-sensitive-entity-owners.ts" && \
  cmp -s "$ROOM_WRITE_LIFECYCLE_SCRIPT" \
    "$CANDIDATE_STAGE/gameRoomAction/room-write-lifecycle.ts" && \
  cmp -s "$BILLING_LIFECYCLE_SCRIPT" \
    "$CANDIDATE_STAGE/gameRoomAction/billing-identity-lifecycle.ts" || {
      echo "Repository inputs changed while creating the reviewed stage." >&2
      exit 75
    }

SOURCE_SHA256=$(hash_file \
  "$CANDIDATE_STAGE/backfill-sensitive-entity-owners.ts" \
  "owner-backfill source")
ROOM_WRITE_LIFECYCLE_SHA256=$(hash_file \
  "$CANDIDATE_STAGE/gameRoomAction/room-write-lifecycle.ts" \
  "room lifecycle source")
BILLING_LIFECYCLE_SHA256=$(hash_file \
  "$CANDIDATE_STAGE/gameRoomAction/billing-identity-lifecycle.ts" \
  "billing lifecycle source")
LIFECYCLE_SOURCE_SHA256=$(printf '%s\n%s\n' \
  "$ROOM_WRITE_LIFECYCLE_SHA256" "$BILLING_LIFECYCLE_SHA256" \
  | shasum -a 256 | sed 's/[[:space:]].*$//')
INPUT_SET_SHA256=$(printf '%s=%s\n%s=%s\n%s=%s\n' \
  "backfill-sensitive-entity-owners.ts" "$SOURCE_SHA256" \
  "gameRoomAction/room-write-lifecycle.ts" "$ROOM_WRITE_LIFECYCLE_SHA256" \
  "gameRoomAction/billing-identity-lifecycle.ts" "$BILLING_LIFECYCLE_SHA256" \
  | shasum -a 256 | sed 's/[[:space:]].*$//')
for input_digest in "$SOURCE_SHA256" "$ROOM_WRITE_LIFECYCLE_SHA256" \
  "$BILLING_LIFECYCLE_SHA256" "$LIFECYCLE_SOURCE_SHA256" "$INPUT_SET_SHA256"
do
  case "$input_digest" in
    ""|*[!0-9a-f]*) echo "Invalid owner-backfill input digest." >&2; exit 65 ;;
  esac
  [ "${#input_digest}" -eq 64 ] || exit 65
done

jq -n -S \
  --arg app_id "$APP_ID" \
  --arg input_set "$INPUT_SET_SHA256" \
  --arg source "$SOURCE_SHA256" \
  --arg room "$ROOM_WRITE_LIFECYCLE_SHA256" \
  --arg billing "$BILLING_LIFECYCLE_SHA256" \
  --arg lifecycle_set "$LIFECYCLE_SOURCE_SHA256" '
  {
    protocol:"spyclash-sensitive-owner-backfill-inputs-v1",
    app_id:$app_id,
    input_set_sha256:$input_set,
    source_sha256:$source,
    lifecycle_source_sha256:$lifecycle_set,
    files:{
      "backfill-sensitive-entity-owners.ts":$source,
      "gameRoomAction/room-write-lifecycle.ts":$room,
      "gameRoomAction/billing-identity-lifecycle.ts":$billing
    }
  }
' > "$CANDIDATE_STAGE/inputs.json"

REVIEWED_STAGE="$REVIEWED_ROOT/$INPUT_SET_SHA256"
case "$REVIEWED_STAGE" in
  "$REVIEWED_ROOT"/[0-9a-f][0-9a-f]*) ;;
  *) echo "Invalid content-addressed owner-backfill stage path." >&2; exit 65 ;;
esac

if [ "$MODE" = dry-run ]; then
  if [ -e "$REVIEWED_STAGE" ]; then
    validate_reviewed_stage "$REVIEWED_STAGE" "$INPUT_SET_SHA256" \
      "$SOURCE_SHA256" "$ROOM_WRITE_LIFECYCLE_SHA256" \
      "$BILLING_LIFECYCLE_SHA256" "$LIFECYCLE_SOURCE_SHA256" || exit 65
    cmp -s "$CANDIDATE_STAGE/inputs.json" "$REVIEWED_STAGE/inputs.json" && \
      cmp -s "$CANDIDATE_STAGE/backfill-sensitive-entity-owners.ts" \
        "$REVIEWED_STAGE/backfill-sensitive-entity-owners.ts" && \
      cmp -s "$CANDIDATE_STAGE/gameRoomAction/room-write-lifecycle.ts" \
        "$REVIEWED_STAGE/gameRoomAction/room-write-lifecycle.ts" && \
      cmp -s "$CANDIDATE_STAGE/gameRoomAction/billing-identity-lifecycle.ts" \
        "$REVIEWED_STAGE/gameRoomAction/billing-identity-lifecycle.ts" || exit 65
  else
    chmod 400 "$CANDIDATE_STAGE"/*.ts "$CANDIDATE_STAGE"/inputs.json \
      "$CANDIDATE_STAGE/gameRoomAction"/*.ts
    chmod 500 "$CANDIDATE_STAGE/gameRoomAction" "$CANDIDATE_STAGE"
    mv "$CANDIDATE_STAGE" "$REVIEWED_STAGE"
  fi
  atomic_stage_file "$REVIEWED_STAGE/inputs.json" "$REVIEWED_POINTER" \
    reviewed-inputs-current
else
  [ -f "$REVIEWED_POINTER" ] && [ ! -L "$REVIEWED_POINTER" ] || {
    echo "Apply requires a reviewed-input pointer created by a prior dry-run." >&2
    exit 77
  }
  POINTER_INPUT_SET=$(jq -er '.input_set_sha256' "$REVIEWED_POINTER")
  [ "$POINTER_INPUT_SET" = "$INPUT_SET_SHA256" ] || {
    echo "Repository inputs differ from the previously reviewed dry-run stage." >&2
    exit 77
  }
fi

validate_reviewed_stage "$REVIEWED_STAGE" "$INPUT_SET_SHA256" \
  "$SOURCE_SHA256" "$ROOM_WRITE_LIFECYCLE_SHA256" \
  "$BILLING_LIFECYCLE_SHA256" "$LIFECYCLE_SOURCE_SHA256" || exit 65
chmod 500 "$REVIEWED_STAGE/gameRoomAction" "$REVIEWED_STAGE"
cmp -s "$REVIEWED_POINTER" "$REVIEWED_STAGE/inputs.json" || {
  echo "Reviewed-input pointer does not match the immutable stage manifest." >&2
  exit 77
}

# Every Base44 exec receives an isolated private copy. The dynamic lifecycle
# import points into this copy, where the reviewed relative billing import is
# present beside room-write-lifecycle.ts; mutable repository paths are never
# executed or imported.
EXECUTION_STAGE="$WORK/execution-inputs"
mkdir -p "$EXECUTION_STAGE/gameRoomAction"
cp "$REVIEWED_STAGE/backfill-sensitive-entity-owners.ts" \
  "$EXECUTION_STAGE/backfill-sensitive-entity-owners.ts"
cp "$REVIEWED_STAGE/gameRoomAction/room-write-lifecycle.ts" \
  "$EXECUTION_STAGE/gameRoomAction/room-write-lifecycle.ts"
cp "$REVIEWED_STAGE/gameRoomAction/billing-identity-lifecycle.ts" \
  "$EXECUTION_STAGE/gameRoomAction/billing-identity-lifecycle.ts"
cp "$REVIEWED_STAGE/inputs.json" "$EXECUTION_STAGE/inputs.json"
chmod 400 "$EXECUTION_STAGE"/*.ts "$EXECUTION_STAGE"/inputs.json \
  "$EXECUTION_STAGE/gameRoomAction"/*.ts
chmod 500 "$EXECUTION_STAGE/gameRoomAction" "$EXECUTION_STAGE"
EXECUTION_SCRIPT="$EXECUTION_STAGE/backfill-sensitive-entity-owners.ts"
EXECUTION_ROOM_WRITE_LIFECYCLE_SCRIPT=\
"$EXECUTION_STAGE/gameRoomAction/room-write-lifecycle.ts"
ROOM_WRITE_LIFECYCLE_URL="file://$EXECUTION_ROOM_WRITE_LIFECYCLE_SCRIPT"

verify_reviewed_execution_inputs() {
  validate_reviewed_stage "$REVIEWED_STAGE" "$INPUT_SET_SHA256" \
    "$SOURCE_SHA256" "$ROOM_WRITE_LIFECYCLE_SHA256" \
    "$BILLING_LIFECYCLE_SHA256" "$LIFECYCLE_SOURCE_SHA256" || return 65
  [ -f "$REVIEWED_POINTER" ] && [ ! -L "$REVIEWED_POINTER" ] && \
    cmp -s "$REVIEWED_POINTER" "$REVIEWED_STAGE/inputs.json" || return 65
  cmp -s "$SCRIPT" "$REVIEWED_STAGE/backfill-sensitive-entity-owners.ts" && \
    cmp -s "$ROOM_WRITE_LIFECYCLE_SCRIPT" \
      "$REVIEWED_STAGE/gameRoomAction/room-write-lifecycle.ts" && \
    cmp -s "$BILLING_LIFECYCLE_SCRIPT" \
      "$REVIEWED_STAGE/gameRoomAction/billing-identity-lifecycle.ts" || {
        echo "Repository inputs changed after reviewed-stage preparation." >&2
        return 75
      }
  cmp -s "$EXECUTION_SCRIPT" \
      "$REVIEWED_STAGE/backfill-sensitive-entity-owners.ts" && \
    cmp -s "$EXECUTION_ROOM_WRITE_LIFECYCLE_SCRIPT" \
      "$REVIEWED_STAGE/gameRoomAction/room-write-lifecycle.ts" && \
    cmp -s "$EXECUTION_STAGE/gameRoomAction/billing-identity-lifecycle.ts" \
      "$REVIEWED_STAGE/gameRoomAction/billing-identity-lifecycle.ts" && \
    cmp -s "$EXECUTION_STAGE/inputs.json" "$REVIEWED_STAGE/inputs.json" || {
      echo "Private execution inputs differ from the reviewed stage." >&2
      return 65
    }
  chmod 400 "$REVIEWED_STAGE"/*.ts "$REVIEWED_STAGE"/inputs.json \
    "$REVIEWED_STAGE/gameRoomAction"/*.ts || return 65
  chmod 500 "$REVIEWED_STAGE/gameRoomAction" "$REVIEWED_STAGE" || return 65
}
verify_reviewed_execution_inputs || exit $?

FINAL_SCHEMA_STATUS=1
FINAL_SCHEMA_VERIFIED=false
FINAL_SCHEMA_REMOTE_DIGEST=
FINAL_SCHEMA_SUMMARY="$WORK/final-schema.json"

set +e
env -u BASE44_APP_ID \
  -u BASE44_PROJECTS_BASE44_APP_ID \
  -u BASE44_CONFIRM_ACTION \
  -u BASE44_CONFIRM_APP_ID \
  -u BASE44_CONFIRM_FINAL_PLAN_DIGEST \
  -u BASE44_FINAL_STAGE_DIR \
  "$FINAL_SCHEMA_SCRIPT" --check > "$WORK/final-schema.log" 2>&1
FINAL_SCHEMA_STATUS=$?
set -e

if [ "$FINAL_SCHEMA_STATUS" -eq 0 ] && [ -f "$FINAL_SCHEMA_MANIFEST" ] && \
  jq -e --arg app_id "$APP_ID" '
    .app_id == $app_id and
    (.remote_digest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.canonical_digest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.plan_digest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.live_count | type == "number") and
    (.canonical_count | type == "number") and
    (.changed_entities | type == "array")
  ' "$FINAL_SCHEMA_MANIFEST" >/dev/null; then
  FINAL_SCHEMA_REMOTE_DIGEST=$(jq -er '.remote_digest' "$FINAL_SCHEMA_MANIFEST")
  if jq -e --arg app_id "$APP_ID" '
    .app_id == $app_id and
    .live_count == 20 and
    .canonical_count == 20 and
    .adds == 0 and
    .deletes == 0 and
    .live_admin_write_boundary == true and
    (.changed_entities | length) == 0
  ' "$FINAL_SCHEMA_MANIFEST" >/dev/null; then
    FINAL_SCHEMA_VERIFIED=true
  fi
  jq --argjson verified "$FINAL_SCHEMA_VERIFIED" \
    '{
      verified:$verified,
      app_id,
      live_count,
      canonical_count,
      adds,
      deletes,
      changed_entities_count:(.changed_entities | length),
      remote_digest,
      canonical_digest,
      plan_digest,
      live_admin_write_boundary
    }' "$FINAL_SCHEMA_MANIFEST" > "$FINAL_SCHEMA_SUMMARY"
else
  jq -n --argjson status "$FINAL_SCHEMA_STATUS" \
    '{verified:false,read_only_check_status:$status,remote_digest:null}' \
    > "$FINAL_SCHEMA_SUMMARY"
fi

refresh_verified_final_schema() {
  refresh_output=$1
  refresh_log=$2
  if ! env -u BASE44_APP_ID \
    -u BASE44_PROJECTS_BASE44_APP_ID \
    -u BASE44_CONFIRM_ACTION \
    -u BASE44_CONFIRM_APP_ID \
    -u BASE44_CONFIRM_FINAL_PLAN_DIGEST \
    -u BASE44_FINAL_STAGE_DIR \
    "$FINAL_SCHEMA_SCRIPT" --check > "$refresh_log" 2>&1
  then
    sed 's/^/  /' "$refresh_log" >&2
    return 1
  fi
  [ -f "$FINAL_SCHEMA_MANIFEST" ] && [ ! -L "$FINAL_SCHEMA_MANIFEST" ] || return 1
  jq -e --arg app_id "$APP_ID" '
    .app_id == $app_id and
    .live_count == 20 and
    .canonical_count == 20 and
    .adds == 0 and
    .deletes == 0 and
    .live_admin_write_boundary == true and
    (.changed_entities | type == "array" and length == 0) and
    (.remote_digest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.canonical_digest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.plan_digest | type == "string" and test("^[0-9a-f]{64}$"))
  ' "$FINAL_SCHEMA_MANIFEST" >/dev/null || return 1
  jq '{
    verified:true,
    app_id,
    live_count,
    canonical_count,
    adds,
    deletes,
    changed_entities_count:(.changed_entities | length),
    remote_digest,
    canonical_digest,
    plan_digest,
    live_admin_write_boundary
  }' "$FINAL_SCHEMA_MANIFEST" > "$refresh_output"
}

run_backfill() {
  run_mode=$1
  run_expected_digest=$2
  run_output=$3
  verify_reviewed_execution_inputs || return $?
  if [ "$run_mode" = apply ]; then
    env -u BASE44_APP_ID \
      -u BASE44_PROJECTS_BASE44_APP_ID \
      SPYCLASH_BACKFILL_APPLY=1 \
      SPYCLASH_BACKFILL_SOURCE_SHA256="$SOURCE_SHA256" \
      SPYCLASH_BACKFILL_LIFECYCLE_SOURCE_SHA256="$LIFECYCLE_SOURCE_SHA256" \
      SPYCLASH_BACKFILL_ROOM_WRITE_LIFECYCLE_URL="$ROOM_WRITE_LIFECYCLE_URL" \
      SPYCLASH_BACKFILL_FINAL_SCHEMA_REMOTE_DIGEST="$FINAL_SCHEMA_REMOTE_DIGEST" \
      SPYCLASH_BACKFILL_FINAL_SCHEMA_VERIFIED=1 \
      SPYCLASH_BACKFILL_EXPECTED_PLAN_DIGEST="$run_expected_digest" \
      SPYCLASH_BACKFILL_CONFIRM_ACTION="$EXPECTED_ACTION" \
      SPYCLASH_BACKFILL_CONFIRM_APP_ID="$APP_ID" \
      npx --yes -p deno -p base44@0.1.4 -c \
      "base44 --app-id \"$APP_ID\" exec" \
      < "$EXECUTION_SCRIPT" > "$run_output" 2>&1
  else
    if [ "$FINAL_SCHEMA_VERIFIED" = true ]; then
      run_schema_verified=1
    else
      run_schema_verified=0
    fi
    env -u BASE44_APP_ID \
      -u BASE44_PROJECTS_BASE44_APP_ID \
      SPYCLASH_BACKFILL_APPLY=0 \
      SPYCLASH_BACKFILL_SOURCE_SHA256="$SOURCE_SHA256" \
      SPYCLASH_BACKFILL_LIFECYCLE_SOURCE_SHA256="$LIFECYCLE_SOURCE_SHA256" \
      SPYCLASH_BACKFILL_ROOM_WRITE_LIFECYCLE_URL="$ROOM_WRITE_LIFECYCLE_URL" \
      SPYCLASH_BACKFILL_FINAL_SCHEMA_REMOTE_DIGEST="$FINAL_SCHEMA_REMOTE_DIGEST" \
      SPYCLASH_BACKFILL_FINAL_SCHEMA_VERIFIED="$run_schema_verified" \
      npx --yes -p deno -p base44@0.1.4 -c \
      "base44 --app-id \"$APP_ID\" exec" \
      < "$EXECUTION_SCRIPT" > "$run_output" 2>&1
  fi
}

extract_report() {
  extract_raw=$1
  extract_json=$2
  sed -n 's/^SPYCLASH_SENSITIVE_OWNER_BACKFILL_REPORT=//p' \
    "$extract_raw" | tail -n 1 > "$extract_json"
  jq -e \
    --arg app_id "$APP_ID" \
    --arg source "$SOURCE_SHA256" \
    --arg lifecycle_source "$LIFECYCLE_SOURCE_SHA256" \
    --arg final_schema_digest "$FINAL_SCHEMA_REMOTE_DIGEST" \
    --argjson final_schema_verified "$FINAL_SCHEMA_VERIFIED" '
    .app_id == $app_id and
    .source_sha256 == $source and
    .lifecycle_source_sha256 == $lifecycle_source and
    .final_schema_verified == $final_schema_verified and
    (if $final_schema_digest == "" then
      .final_schema_remote_digest == null
    else
      .final_schema_remote_digest == $final_schema_digest
    end) and
    (.plan_digest | type == "string" and test("^[0-9a-f]{64}$")) and
    (.operator.identity_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    .operator.role == "admin" and
    (.room_updates | type == "number" and . >= 0 and floor == .) and
    (.word_pack_updates | type == "number" and . >= 0 and floor == .) and
    (.unresolved_total | type == "number" and . >= 0 and floor == .) and
    (.mismatch_total | type == "number" and . >= 0 and floor == .) and
    (.cas_plan.game_rooms | type == "array") and
    (.cas_plan.word_packs | type == "array") and
    (.cas_plan.game_rooms | length) == .room_updates and
    (.cas_plan.word_packs | length) == .word_pack_updates and
    ([.cas_plan.game_rooms[].id] | unique | length) == .room_updates and
    ([.cas_plan.word_packs[].id] | unique | length) == .word_pack_updates and
    ([.cas_plan.game_rooms[]] | all(
      (.id | type == "string" and length > 0) and
      (.updated_date | type == "string" and length > 0) and
      (.set.participant_user_ids | type == "array")
    )) and
    ([.cas_plan.word_packs[]] | all(
      (.id | type == "string" and length > 0) and
      (.updated_date | type == "string" and length > 0) and
      (.set.owner_user_id | type == "string" and length > 0)
    ))
  ' "$extract_json" >/dev/null || return 1
  if jq -e '.. | objects | keys[]? | select(test("email"; "i"))' \
    "$extract_json" >/dev/null; then
    echo "Refusing to persist a report containing email fields." >&2
    return 1
  fi
  jq -S . "$extract_json" > "$extract_json.sorted"
  mv "$extract_json.sorted" "$extract_json"
}

write_failure_manifest() {
  failure_phase=$1
  failure_status=$2
  jq -n \
    --arg app_id "$APP_ID" \
    --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg input_set_sha256 "$INPUT_SET_SHA256" \
    --arg source_sha256 "$SOURCE_SHA256" \
    --arg lifecycle_source_sha256 "$LIFECYCLE_SOURCE_SHA256" \
    --arg room_lifecycle_sha256 "$ROOM_WRITE_LIFECYCLE_SHA256" \
    --arg billing_lifecycle_sha256 "$BILLING_LIFECYCLE_SHA256" \
    --arg mode "$MODE" \
    --arg phase "$failure_phase" \
    --argjson status "$failure_status" \
    --slurpfile final_schema "$FINAL_SCHEMA_SUMMARY" \
    '{
      protocol:"spyclash-sensitive-owner-backfill-wrapper-v2",
      app_id:$app_id,
      mode:$mode,
      prepared_at:$prepared_at,
      input_set_sha256:$input_set_sha256,
      source_sha256:$source_sha256,
      lifecycle_source_sha256:$lifecycle_source_sha256,
      reviewed_inputs:{
        protocol:"spyclash-sensitive-owner-backfill-inputs-v1",
        input_set_sha256:$input_set_sha256,
        source_sha256:$source_sha256,
        lifecycle_source_sha256:$lifecycle_source_sha256,
        room_write_lifecycle_sha256:$room_lifecycle_sha256,
        billing_identity_lifecycle_sha256:$billing_lifecycle_sha256
      },
      final_schema:$final_schema[0],
      stable_snapshots:false,
      failure:{phase:$phase,status:$status},
      success:false,
      completion_verified:false
    }' > "$WORK/manifest.json"
  atomic_stage_file "$WORK/manifest.json" "$MANIFEST" manifest
}

run_stable_dry_pair() {
  pair_prefix=$1
  if run_backfill dry-run "" "$WORK/$pair_prefix-a.raw"; then
    pair_status_a=0
  else
    pair_status_a=$?
  fi
  if run_backfill dry-run "" "$WORK/$pair_prefix-b.raw"; then
    pair_status_b=0
  else
    pair_status_b=$?
  fi
  [ "$pair_status_a" -eq 0 ] && [ "$pair_status_b" -eq 0 ] || return 1
  extract_report "$WORK/$pair_prefix-a.raw" "$WORK/$pair_prefix-a.json" || return 1
  extract_report "$WORK/$pair_prefix-b.raw" "$WORK/$pair_prefix-b.json" || return 1
  cmp -s "$WORK/$pair_prefix-a.json" "$WORK/$pair_prefix-b.json" || {
    echo "Two consecutive Base44 dry snapshots differ; refusing the plan." >&2
    return 1
  }
  shasum -a 256 "$WORK/$pair_prefix-a.json" | sed 's/[[:space:]].*$//' \
    > "$WORK/$pair_prefix.snapshot-sha256"
}

if ! run_stable_dry_pair preflight; then
  write_failure_manifest preflight 70
  echo "Stable Base44 owner-backfill preflight could not be prepared." >&2
  exit 70
fi

PREFLIGHT_REPORT="$WORK/preflight-a.json"
PREFLIGHT_SNAPSHOT_SHA256=$(sed -n '1p' "$WORK/preflight.snapshot-sha256")
PLAN_DIGEST=$(jq -er '.plan_digest' "$PREFLIGHT_REPORT")
UNRESOLVED_TOTAL=$(jq -er '.unresolved_total' "$PREFLIGHT_REPORT")
MISMATCH_TOTAL=$(jq -er '.mismatch_total' "$PREFLIGHT_REPORT")

if [ "$MODE" = dry-run ]; then
  jq -n \
    --arg app_id "$APP_ID" \
    --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg input_set_sha256 "$INPUT_SET_SHA256" \
    --arg source_sha256 "$SOURCE_SHA256" \
    --arg lifecycle_source_sha256 "$LIFECYCLE_SOURCE_SHA256" \
    --arg room_lifecycle_sha256 "$ROOM_WRITE_LIFECYCLE_SHA256" \
    --arg billing_lifecycle_sha256 "$BILLING_LIFECYCLE_SHA256" \
    --arg snapshot_sha256 "$PREFLIGHT_SNAPSHOT_SHA256" \
    --slurpfile final_schema "$FINAL_SCHEMA_SUMMARY" \
    --slurpfile preflight "$PREFLIGHT_REPORT" \
    '{
      protocol:"spyclash-sensitive-owner-backfill-wrapper-v2",
      app_id:$app_id,
      mode:"dry-run",
      prepared_at:$prepared_at,
      input_set_sha256:$input_set_sha256,
      source_sha256:$source_sha256,
      lifecycle_source_sha256:$lifecycle_source_sha256,
      reviewed_inputs:{
        protocol:"spyclash-sensitive-owner-backfill-inputs-v1",
        input_set_sha256:$input_set_sha256,
        source_sha256:$source_sha256,
        lifecycle_source_sha256:$lifecycle_source_sha256,
        room_write_lifecycle_sha256:$room_lifecycle_sha256,
        billing_identity_lifecycle_sha256:$billing_lifecycle_sha256
      },
      final_schema:$final_schema[0],
      stable_snapshots:true,
      preflight_snapshot_sha256:$snapshot_sha256,
      plan_digest:$preflight[0].plan_digest,
      preflight:$preflight[0],
      postflight:{status:0,snapshot_sha256:$snapshot_sha256,report:$preflight[0]},
      eligible_for_apply:(
        $final_schema[0].verified == true and
        $preflight[0].unresolved_total == 0 and
        $preflight[0].mismatch_total == 0
      ),
      success:false,
      completion_verified:(
        $final_schema[0].verified == true and
        $preflight[0].unresolved_total == 0 and
        $preflight[0].mismatch_total == 0 and
        $preflight[0].room_updates == 0 and
        $preflight[0].word_pack_updates == 0
      )
    }' > "$WORK/manifest.json"
  atomic_stage_file "$WORK/manifest.json" "$MANIFEST" manifest
  echo "Prepared stable read-only owner-backfill manifest: $MANIFEST"
  echo "Plan digest: $PLAN_DIGEST"
  echo "Updates: rooms=$(jq -r '.room_updates' "$PREFLIGHT_REPORT") word_packs=$(jq -r '.word_pack_updates' "$PREFLIGHT_REPORT")"
  echo "Blockers: unresolved=$UNRESOLVED_TOTAL mismatch=$MISMATCH_TOTAL"
  echo "Final schema verified: $FINAL_SCHEMA_VERIFIED"
  if [ "$UNRESOLVED_TOTAL" -ne 0 ] || [ "$MISMATCH_TOTAL" -ne 0 ]; then
    exit 70
  fi
  exit 0
fi

if [ "${BASE44_CONFIRM_ACTION:-}" != "$EXPECTED_ACTION" ]; then
  echo "Set BASE44_CONFIRM_ACTION=$EXPECTED_ACTION for this exact cutover step." >&2
  exit 77
fi
if [ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]; then
  echo "Set BASE44_CONFIRM_APP_ID=$APP_ID for the intentional owner backfill." >&2
  exit 77
fi
case "${BASE44_CONFIRM_SENSITIVE_OWNER_PLAN_DIGEST:-}" in
  ""|*[!0-9a-f]*)
    echo "Set BASE44_CONFIRM_SENSITIVE_OWNER_PLAN_DIGEST to the exact 64-character plan digest." >&2
    exit 77
    ;;
esac
[ "${#BASE44_CONFIRM_SENSITIVE_OWNER_PLAN_DIGEST}" -eq 64 ] || exit 77
[ "$FINAL_SCHEMA_VERIFIED" = true ] || {
  echo "Fresh final-schema check is not live=20/canonical=20/changed=0." >&2
  exit 77
}
[ "$UNRESOLVED_TOTAL" -eq 0 ] && [ "$MISMATCH_TOTAL" -eq 0 ] || {
  echo "Fresh owner-backfill plan contains unresolved or mismatched ownership." >&2
  exit 70
}
if [ "$BASE44_CONFIRM_SENSITIVE_OWNER_PLAN_DIGEST" != "$PLAN_DIGEST" ]; then
  echo "Fresh JIT plan differs from the explicitly confirmed plan." >&2
  echo "Inspect $MANIFEST after a new dry-run before retrying." >&2
  exit 77
fi

# Close the schema/RLS TOCTOU window after the two data snapshots and exact
# confirmation. The apply plan already binds the remote schema digest; any
# schema change since preflight invalidates this attempt before the first
# lifecycle lease or entity write.
JIT_FINAL_SCHEMA_SUMMARY="$WORK/final-schema-jit.json"
if ! refresh_verified_final_schema \
  "$JIT_FINAL_SCHEMA_SUMMARY" \
  "$WORK/final-schema-jit.log"
then
  echo "Fresh final-schema verification failed immediately before backfill apply." >&2
  exit 77
fi
if ! cmp -s "$FINAL_SCHEMA_SUMMARY" "$JIT_FINAL_SCHEMA_SUMMARY"; then
  echo "Final schema changed after owner-backfill plan preparation." >&2
  exit 77
fi

# Recompare mutable repository inputs, the content-addressed reviewed stage,
# and the private execution copy after the JIT schema check. Only staged bytes
# are executed, so later repository edits cannot change this apply process.
if ! verify_reviewed_execution_inputs; then
  echo "Owner-backfill inputs changed immediately before apply." >&2
  exit 77
fi

# Persist a non-PII forensic marker before the first possible entity write.
# A crash or SIGKILL during apply/postflight leaves an explicit requirement to
# complete a fresh postflight; ordinary dry-run preparation never overwrites it.
ATTEMPT_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
ATTEMPT_ID=$(printf '%s\n%s\n%s\n%s\n%s\n%s\n' \
  "$APP_ID" "$PLAN_DIGEST" "$INPUT_SET_SHA256" \
  "$FINAL_SCHEMA_REMOTE_DIGEST" "$ATTEMPT_STARTED_AT" "$$" \
  | shasum -a 256 | sed 's/[[:space:]].*$//')
case "$ATTEMPT_ID" in
  ""|*[!0-9a-f]*) echo "Unable to create a safe attempt id." >&2; exit 65 ;;
esac
[ "${#ATTEMPT_ID}" -eq 64 ] || exit 65
jq -n -S \
  --arg app_id "$APP_ID" \
  --arg attempt_id "$ATTEMPT_ID" \
  --arg started_at "$ATTEMPT_STARTED_AT" \
  --arg input_set_sha256 "$INPUT_SET_SHA256" \
  --arg source_sha256 "$SOURCE_SHA256" \
  --arg lifecycle_source_sha256 "$LIFECYCLE_SOURCE_SHA256" \
  --arg requested_plan_digest "$BASE44_CONFIRM_SENSITIVE_OWNER_PLAN_DIGEST" \
  --arg preflight_snapshot_sha256 "$PREFLIGHT_SNAPSHOT_SHA256" \
  --slurpfile final_schema "$FINAL_SCHEMA_SUMMARY" '
  {
    protocol:"spyclash-sensitive-owner-backfill-attempt-v1",
    app_id:$app_id,
    mode:"apply",
    attempt_id:$attempt_id,
    state:"mutation-started-postflight-required",
    postflight_required:true,
    started_at:$started_at,
    input_set_sha256:$input_set_sha256,
    source_sha256:$source_sha256,
    lifecycle_source_sha256:$lifecycle_source_sha256,
    requested_plan_digest:$requested_plan_digest,
    plan_digest:$requested_plan_digest,
    preflight_snapshot_sha256:$preflight_snapshot_sha256,
    final_schema:$final_schema[0],
    success:false,
    completion_verified:false
  }
' > "$WORK/attempt-started.json"
atomic_stage_file "$WORK/attempt-started.json" "$LAST_ATTEMPT" last-attempt
sync

# The apply status is captured, and postflight is deliberately outside its
# success branch: a failed or partially applied lifecycle-serialized sequence must still be
# followed by a fresh read-only snapshot.
if run_backfill apply "$PLAN_DIGEST" "$WORK/apply.raw"; then
  APPLY_STATUS=0
else
  APPLY_STATUS=$?
fi
if extract_report "$WORK/apply.raw" "$WORK/apply.json"; then
  APPLY_REPORT_STATUS=0
else
  APPLY_REPORT_STATUS=$?
fi
if run_stable_dry_pair postflight; then
  POSTFLIGHT_STATUS=0
else
  POSTFLIGHT_STATUS=$?
fi

if [ "$APPLY_REPORT_STATUS" -ne 0 ]; then
  echo 'null' > "$WORK/apply.json"
fi
if [ "$POSTFLIGHT_STATUS" -ne 0 ]; then
  echo 'null' > "$WORK/postflight-a.json"
  echo 'null' > "$WORK/postflight.snapshot-sha256"
fi
POSTFLIGHT_SNAPSHOT_SHA256=$(sed -n '1p' "$WORK/postflight.snapshot-sha256")

jq -n \
  --arg app_id "$APP_ID" \
  --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg attempt_id "$ATTEMPT_ID" \
  --arg attempt_started_at "$ATTEMPT_STARTED_AT" \
  --arg input_set_sha256 "$INPUT_SET_SHA256" \
  --arg source_sha256 "$SOURCE_SHA256" \
  --arg lifecycle_source_sha256 "$LIFECYCLE_SOURCE_SHA256" \
  --arg room_lifecycle_sha256 "$ROOM_WRITE_LIFECYCLE_SHA256" \
  --arg billing_lifecycle_sha256 "$BILLING_LIFECYCLE_SHA256" \
  --arg requested_plan_digest "$BASE44_CONFIRM_SENSITIVE_OWNER_PLAN_DIGEST" \
  --arg preflight_snapshot_sha256 "$PREFLIGHT_SNAPSHOT_SHA256" \
  --arg postflight_snapshot_sha256 "$POSTFLIGHT_SNAPSHOT_SHA256" \
  --argjson apply_status "$APPLY_STATUS" \
  --argjson apply_report_status "$APPLY_REPORT_STATUS" \
  --argjson postflight_status "$POSTFLIGHT_STATUS" \
  --slurpfile final_schema "$FINAL_SCHEMA_SUMMARY" \
  --slurpfile preflight "$PREFLIGHT_REPORT" \
  --slurpfile apply_report "$WORK/apply.json" \
  --slurpfile postflight "$WORK/postflight-a.json" \
  '{
    protocol:"spyclash-sensitive-owner-backfill-wrapper-v2",
    app_id:$app_id,
    mode:"apply",
    prepared_at:$prepared_at,
    input_set_sha256:$input_set_sha256,
    source_sha256:$source_sha256,
    lifecycle_source_sha256:$lifecycle_source_sha256,
    reviewed_inputs:{
      protocol:"spyclash-sensitive-owner-backfill-inputs-v1",
      input_set_sha256:$input_set_sha256,
      source_sha256:$source_sha256,
      lifecycle_source_sha256:$lifecycle_source_sha256,
      room_write_lifecycle_sha256:$room_lifecycle_sha256,
      billing_identity_lifecycle_sha256:$billing_lifecycle_sha256
    },
    attempt:{
      protocol:"spyclash-sensitive-owner-backfill-attempt-v1",
      attempt_id:$attempt_id,
      started_at:$attempt_started_at
    },
    final_schema:$final_schema[0],
    stable_snapshots:($postflight_status == 0),
    preflight_snapshot_sha256:$preflight_snapshot_sha256,
    requested_plan_digest:$requested_plan_digest,
    plan_digest:$preflight[0].plan_digest,
    preflight:$preflight[0],
    apply:{status:$apply_status,report_status:$apply_report_status,report:$apply_report[0]},
    postflight:{
      status:$postflight_status,
      snapshot_sha256:$postflight_snapshot_sha256,
      report:$postflight[0]
    },
    success:(
      $apply_status == 0 and
      $apply_report_status == 0 and
      $postflight_status == 0 and
      $apply_report[0] != null and
      $apply_report[0].phase == "completed" and
      $apply_report[0].plan_digest == $preflight[0].plan_digest and
      $apply_report[0].applied_room_updates == $preflight[0].room_updates and
      $apply_report[0].applied_word_pack_updates == $preflight[0].word_pack_updates and
      $postflight[0] != null and
      $postflight[0].source_sha256 == $source_sha256 and
      $postflight[0].lifecycle_source_sha256 == $lifecycle_source_sha256 and
      $postflight[0].final_schema_remote_digest == $final_schema[0].remote_digest and
      $postflight[0].operator == $preflight[0].operator and
      $postflight[0].unresolved_total == 0 and
      $postflight[0].mismatch_total == 0 and
      $postflight[0].room_updates == 0 and
      $postflight[0].word_pack_updates == 0
    ),
    completion_verified:(
      $apply_status == 0 and
      $apply_report_status == 0 and
      $postflight_status == 0 and
      $requested_plan_digest == $preflight[0].plan_digest and
      $apply_report[0] != null and
      $apply_report[0].phase == "completed" and
      $apply_report[0].plan_digest == $preflight[0].plan_digest and
      $apply_report[0].applied_room_updates == $preflight[0].room_updates and
      $apply_report[0].applied_word_pack_updates == $preflight[0].word_pack_updates and
      $postflight[0] != null and
      $postflight[0].source_sha256 == $source_sha256 and
      $postflight[0].lifecycle_source_sha256 == $lifecycle_source_sha256 and
      $postflight[0].final_schema_remote_digest == $final_schema[0].remote_digest and
      $postflight[0].operator == $preflight[0].operator and
      $postflight[0].unresolved_total == 0 and
      $postflight[0].mismatch_total == 0 and
      $postflight[0].room_updates == 0 and
      $postflight[0].word_pack_updates == 0
    )
  }' > "$WORK/manifest.base.json"
jq -S '
  .attempt.state = (
    if .success == true then
      "completed-postflight-verified"
    else
      "postflight-failed-or-incomplete"
    end
  ) |
  .attempt.postflight_required = (.success != true)
' "$WORK/manifest.base.json" > "$WORK/manifest.json"
atomic_stage_file "$WORK/manifest.json" "$MANIFEST" manifest
atomic_stage_file "$MANIFEST" "$LAST_ATTEMPT" last-attempt
sync

if ! jq -e '
  .success == true and
  .completion_verified == true and
  .mode == "apply" and
  .requested_plan_digest == .plan_digest and
  .apply.report.phase == "completed" and
  .apply.report.plan_digest == .plan_digest and
  .apply.report.applied_room_updates == .preflight.room_updates and
  .apply.report.applied_word_pack_updates == .preflight.word_pack_updates and
  .postflight.report.unresolved_total == 0 and
  .postflight.report.mismatch_total == 0 and
  .postflight.report.room_updates == 0 and
  .postflight.report.word_pack_updates == 0
' "$MANIFEST" >/dev/null; then
  echo "Owner backfill failed or its mandatory postflight is not clean." >&2
  echo "Inspect $MANIFEST; do not continue to the next cutover step." >&2
  exit 70
fi

# Preserve successful Step 7 evidence across later default dry-runs. This
# file is replaced atomically only after the full apply/postflight predicate
# above succeeds; a failed retry cannot erase prior verified completion.
jq --arg completion_verified_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '. + {completion_verified_at:$completion_verified_at}' "$MANIFEST" \
  | jq -S . > "$WORK/completion.json"
atomic_stage_file "$WORK/completion.json" "$COMPLETION" completion
echo "Owner backfill and mandatory zero-update postflight verified."
