#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
EXPECTED_APP_ID=69a0e57fa939f578082f8091
SECRET_NAME=SPYCLASH_PSEUDONYM_KEY
EXPECTED_ACTION=SECURITY_CUTOVER_STEP_2_PSEUDONYM_SECRET
APP_FILE="$ROOT/base44/.app.jsonc"
APP_ID=$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_FILE" | head -n 1)
CUTOVER_DIR="$ROOT/.base44-cutover"
STAGE="$CUTOVER_DIR/pseudonym-secret"
CANDIDATE_FILE="$STAGE/candidate.env"
MANIFEST="$STAGE/manifest.json"
POSTFLIGHT="$STAGE/postflight.json"
ATTEMPT="$STAGE/attempt.json"
LOCK_DIR="$CUTOVER_DIR/.pseudonym-secret.lock"
LOCK_PID_FILE="$LOCK_DIR/owner.pid"
PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
MODE=prepare
LOCK_HELD=0
PRODUCTION_LOCK_HELD=0

usage() {
  echo "Usage: $0 [--set]" >&2
  exit 64
}

case "${1:-}" in
  "") ;;
  --set) MODE=set ;;
  *) usage ;;
esac
[ "$#" -le 1 ] || usage

[ -n "$APP_ID" ] || {
  echo "Unable to read the Base44 app id from $APP_FILE." >&2
  exit 65
}
case "$APP_ID" in
  *[!A-Za-z0-9_-]*)
    echo "Invalid Base44 app id in $APP_FILE." >&2
    exit 65
    ;;
esac
[ "$APP_ID" = "$EXPECTED_APP_ID" ] || {
  echo "Repository app id $APP_ID is not the reviewed SpyClash app $EXPECTED_APP_ID." >&2
  exit 77
}
if [ "${BASE44_APP_ID+x}" = x ] && [ "$BASE44_APP_ID" != "$APP_ID" ]; then
  echo "BASE44_APP_ID targets $BASE44_APP_ID, not reviewed app $APP_ID." >&2
  exit 77
fi
if [ "${BASE44_PROJECTS_BASE44_APP_ID+x}" = x ] && \
  [ "$BASE44_PROJECTS_BASE44_APP_ID" != "$APP_ID" ]; then
  echo "BASE44_PROJECTS_BASE44_APP_ID targets another app." >&2
  exit 77
fi
if [ "${BASE44_PSEUDONYM_SECRET_STAGE_DIR+x}" = x ]; then
  echo "BASE44_PSEUDONYM_SECRET_STAGE_DIR is not supported; the stage path is fixed at $STAGE." >&2
  exit 64
fi
case "$ROOT" in
  ""|/)
    echo "Unsafe repository root." >&2
    exit 65
    ;;
esac
[ "$STAGE" = "$ROOT/.base44-cutover/pseudonym-secret" ] || exit 65
if [ -L "$CUTOVER_DIR" ] || [ -L "$STAGE" ]; then
  echo "Base44 pseudonym-secret cutover paths must not be symbolic links." >&2
  exit 65
fi

for command in awk chmod cmp cp date env git grep head id jq mkdir mktemp mv \
  npx openssl rm rmdir sed shasum sort stat sync uname wc; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 69
  }
done
for evidence_path in \
  ".base44-cutover/pseudonym-secret/candidate.env" \
  ".base44-cutover/pseudonym-secret/manifest.json" \
  ".base44-cutover/pseudonym-secret/postflight.json" \
  ".base44-cutover/pseudonym-secret/attempt.json"
do
  (cd "$ROOT" && git check-ignore -q -- "$evidence_path") || {
    echo "$evidence_path is not protected by repository ignore rules." >&2
    exit 65
  }
done

umask 077
WORK=$(mktemp -d /tmp/spyclash-pseudonym-secret.XXXXXX)
case "$WORK" in
  /tmp/spyclash-pseudonym-secret.*) ;;
  *)
    echo "Unsafe temporary path." >&2
    exit 65
    ;;
esac

cleanup() {
  rm -rf -- "$WORK"
  if [ "$LOCK_HELD" -eq 1 ]; then
    rm -f -- "$LOCK_PID_FILE"
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

base44_cli() {
  env -u BASE44_APP_ID -u BASE44_PROJECTS_BASE44_APP_ID \
    npx --yes base44@0.1.4 --app-id "$APP_ID" "$@"
}

check_mode_600() {
  checked_file=$1
  [ -f "$checked_file" ] && [ ! -L "$checked_file" ] || return 1
  case "$(uname -s)" in
    Darwin)
      checked_mode=$(stat -f '%Lp' "$checked_file")
      checked_owner=$(stat -f '%u' "$checked_file")
      checked_links=$(stat -f '%l' "$checked_file")
      ;;
    *)
      checked_mode=$(stat -c '%a' "$checked_file")
      checked_owner=$(stat -c '%u' "$checked_file")
      checked_links=$(stat -c '%h' "$checked_file")
      ;;
  esac
  [ "$checked_mode" = 600 ] && \
    [ "$checked_owner" = "$(id -u)" ] && \
    [ "$checked_links" = 1 ]
}

ensure_safe_stage() {
  mkdir -p "$STAGE"
  [ -d "$STAGE" ] && [ ! -L "$STAGE" ] || {
    echo "Pseudonym-secret stage is not a safe directory." >&2
    return 65
  }
  chmod 700 "$STAGE"
  case "$(uname -s)" in
    Darwin) safe_stage_owner=$(stat -f '%u' "$STAGE") ;;
    *) safe_stage_owner=$(stat -c '%u' "$STAGE") ;;
  esac
  [ "$safe_stage_owner" = "$(id -u)" ] || {
    echo "Pseudonym-secret stage is not owned by the current user." >&2
    return 65
  }
}

secure_private_directory() {
  safe_directory=$1
  [ -d "$safe_directory" ] && [ ! -L "$safe_directory" ] || return 65
  case "$(uname -s)" in
    Darwin) safe_directory_owner=$(stat -f '%u' "$safe_directory") ;;
    *) safe_directory_owner=$(stat -c '%u' "$safe_directory") ;;
  esac
  [ "$safe_directory_owner" = "$(id -u)" ] || return 65
  chmod 700 "$safe_directory"
}

acquire_production_lock() {
  if ! mkdir "$PRODUCTION_LOCK_DIR" 2>/dev/null; then
    echo "Another Base44 Production mutation holds $PRODUCTION_LOCK_DIR." >&2
    echo "A stale lock must be reclaimed only after manual PID/path verification." >&2
    return 75
  fi
  PRODUCTION_LOCK_HELD=1
  secure_private_directory "$PRODUCTION_LOCK_DIR" || return $?
  printf 'SECURITY_CUTOVER_STEP_2_PSEUDONYM_SECRET:%s\n' "$$" > "$PRODUCTION_LOCK_OWNER"
  chmod 600 "$PRODUCTION_LOCK_OWNER"
  check_mode_600 "$PRODUCTION_LOCK_OWNER" || return 65
}

atomic_stage_file() {
  atomic_source=$1
  atomic_destination=$2
  atomic_label=$3
  case "$atomic_destination" in
    "$MANIFEST"|"$POSTFLIGHT"|"$ATTEMPT") ;;
    *)
      echo "Refusing unsafe pseudonym-secret evidence destination." >&2
      return 65
      ;;
  esac
  check_mode_600 "$atomic_source" || {
    echo "Pseudonym-secret evidence source is not protected." >&2
    return 65
  }
  jq -e . "$atomic_source" >/dev/null || {
    echo "Pseudonym-secret evidence source is not valid JSON." >&2
    return 65
  }
  if [ -e "$atomic_destination" ] || [ -L "$atomic_destination" ]; then
    check_mode_600 "$atomic_destination" || {
      echo "Pseudonym-secret evidence destination is unsafe." >&2
      return 65
    }
  fi
  atomic_temporary=$(mktemp "$STAGE/.${atomic_label}.XXXXXX") || {
    echo "Unable to allocate pseudonym-secret evidence staging file." >&2
    return 70
  }
  chmod 600 "$atomic_temporary" || {
    rm -f -- "$atomic_temporary"
    echo "Unable to protect pseudonym-secret evidence staging file." >&2
    return 70
  }
  if ! cp "$atomic_source" "$atomic_temporary" || \
    ! cmp -s "$atomic_source" "$atomic_temporary"; then
    rm -f -- "$atomic_temporary"
    echo "Unable to stage durable pseudonym-secret evidence." >&2
    return 70
  fi
  chmod 600 "$atomic_temporary" || {
    rm -f -- "$atomic_temporary"
    echo "Unable to protect staged pseudonym-secret evidence." >&2
    return 70
  }
  if ! mv "$atomic_temporary" "$atomic_destination"; then
    rm -f -- "$atomic_temporary"
    echo "Unable to atomically install pseudonym-secret evidence." >&2
    return 70
  fi
  check_mode_600 "$atomic_destination" || {
    echo "Installed pseudonym-secret evidence is not protected." >&2
    return 70
  }
  # The marker must survive a process crash after the remote mutation. Flush
  # the atomically replaced file and its containing filesystem first.
  sync || {
    echo "Unable to flush durable pseudonym-secret evidence." >&2
    return 70
  }
}

validate_attempt_record() {
  check_mode_600 "$ATTEMPT" || return 1
  jq -e \
    --arg app_id "$APP_ID" \
    --arg action "$EXPECTED_ACTION" \
    --arg secret_name "$SECRET_NAME" \
    '
      .protocol == "spyclash-pseudonym-secret-attempt-v1" and
      .app_id == $app_id and
      .action == $action and
      .secret_name == $secret_name and
      (.attempt_id | type == "string") and
      (.attempt_id | test("^[0-9a-f]{64}$")) and
      (.plan_digest | type == "string") and
      (.plan_digest | test("^[0-9a-f]{64}$")) and
      (.candidate_value_sha256 | type == "string") and
      (.candidate_value_sha256 | test("^[0-9a-f]{64}$")) and
      (.initial_secret_inventory_sha256 | type == "string") and
      (.initial_secret_inventory_sha256 | test("^[0-9a-f]{64}$")) and
      (.jit_secret_inventory_sha256 | type == "string") and
      (.jit_secret_inventory_sha256 | test("^[0-9a-f]{64}$")) and
      (
        (.status == "mutation-started-postflight-required" and
          .postflight_required == true) or
        (.status == "completed-postflight-verified" and
          .postflight_required == false)
      )
    ' "$ATTEMPT" >/dev/null 2>&1
}

successful_postflight_matches_attempt() {
  validate_attempt_record || return 1
  check_mode_600 "$POSTFLIGHT" || return 1
  jq -e --slurpfile attempt "$ATTEMPT" '
    ($attempt[0]) as $a |
    .protocol == "spyclash-pseudonym-secret-postflight-v1" and
    .attempt_id == $a.attempt_id and
    .app_id == $a.app_id and
    .action == $a.action and
    .secret_name == $a.secret_name and
    .plan_digest == $a.plan_digest and
    .candidate_value_sha256 == $a.candidate_value_sha256 and
    .initial_secret_inventory_sha256 ==
      $a.initial_secret_inventory_sha256 and
    .jit_secret_inventory_sha256 == $a.jit_secret_inventory_sha256 and
    .status == "completed-postflight-verified" and
    .postflight_required == false and
    .set_status == 0 and
    .post_list_status == 0 and
    .secret_present == true and
    .matches == true
  ' "$POSTFLIGHT" >/dev/null 2>&1
}

manifest_matches_attempt() {
  check_mode_600 "$MANIFEST" || return 1
  jq -e --slurpfile attempt "$ATTEMPT" '
    ($attempt[0]) as $a |
    .app_id == $a.app_id and
    .secret_name == $a.secret_name and
    .plan_digest == $a.plan_digest and
    .candidate_value_sha256 == $a.candidate_value_sha256 and
    .initial_secret_inventory_sha256 ==
      $a.initial_secret_inventory_sha256
  ' "$MANIFEST" >/dev/null 2>&1
}

reconcile_verified_attempt() {
  successful_postflight_matches_attempt || return 1
  reconciliation_candidate_digest=$(jq -er '.candidate_value_sha256' "$ATTEMPT") || \
    return 1
  if [ -e "$CANDIDATE_FILE" ] || [ -L "$CANDIDATE_FILE" ]; then
    validate_candidate_file "$CANDIDATE_FILE" || return 1
    [ "$(candidate_value_sha256 "$CANDIDATE_FILE")" = \
      "$reconciliation_candidate_digest" ] || {
      echo "Protected candidate does not match the durable attempt marker." >&2
      return 1
    }
  fi
  if [ -e "$MANIFEST" ] || [ -L "$MANIFEST" ]; then
    manifest_matches_attempt || {
      echo "Manifest does not match the durable attempt marker." >&2
      return 1
    }
  fi

  reconciliation_verified_at=$(jq -er '.audited_at' "$POSTFLIGHT") || return 1
  if ! jq --arg verified_at "$reconciliation_verified_at" '
    . + {
      status:"completed-postflight-verified",
      postflight_required:false,
      postflight_verified_at:$verified_at
    }
  ' "$ATTEMPT" > "$WORK/attempt.reconciled.json"; then
    return 1
  fi
  chmod 600 "$WORK/attempt.reconciled.json" || return 1
  atomic_stage_file "$WORK/attempt.reconciled.json" "$ATTEMPT" attempt || \
    return 1

  if [ -e "$MANIFEST" ]; then
    if ! jq --arg verified_at "$reconciliation_verified_at" '
      . + {configured_at:$verified_at,postflight_verified_at:$verified_at}
    ' "$MANIFEST" > "$WORK/manifest.reconciled.json"; then
      return 1
    fi
    chmod 600 "$WORK/manifest.reconciled.json" || return 1
    atomic_stage_file "$WORK/manifest.reconciled.json" "$MANIFEST" manifest || \
      return 1
  fi
  if [ -e "$CANDIDATE_FILE" ]; then
    rm -f -- "$CANDIDATE_FILE" || return 1
    sync || return 1
  fi
  echo "$SECRET_NAME is configured and its durable name-only postflight is verified."
}

validate_candidate_file() {
  candidate=$1
  check_mode_600 "$candidate" || {
    echo "Pseudonym candidate must be a mode-600, single-link regular file owned by the current user." >&2
    return 65
  }
  awk -v key="$SECRET_NAME" '
    BEGIN { valid = 1; unique = 0 }
    NR == 1 {
      prefix = key "="
      if (index($0, prefix) != 1) valid = 0
      value = substr($0, length(prefix) + 1)
      if (length(value) != 96 || value !~ /^[0-9a-f]+$/) valid = 0
      for (i = 1; i <= length(value); i++) {
        character = substr(value, i, 1)
        if (!(character in seen)) {
          seen[character] = 1
          unique++
        }
      }
    }
    NR > 1 { valid = 0 }
    END {
      if (NR != 1 || unique < 12) valid = 0
      exit(valid ? 0 : 1)
    }
  ' "$candidate" || {
    echo "Pseudonym candidate is empty, malformed, or does not meet the 384-bit generation contract." >&2
    return 65
  }
}

candidate_value_sha256() {
  sed "s/^$SECRET_NAME=//" "$1" | shasum -a 256 | awk '{print $1}'
}

normalize_secret_names() {
  input=$1
  output=$2
  awk '/^[A-Za-z_][A-Za-z0-9_]*$/ { print }' "$input" | \
    LC_ALL=C sort -u > "$output"
}

list_secret_names() {
  raw_output=$1
  normalized_output=$2
  if ! base44_cli secrets list > "$raw_output" 2>&1; then
    echo "Unable to verify Base44 secret names; refusing to create or rotate any secret." >&2
    return 70
  fi
  normalize_secret_names "$raw_output" "$normalized_output"
}

generate_candidate() {
  raw_candidate=$(mktemp "$STAGE/.candidate.raw.XXXXXX")
  env_candidate=$(mktemp "$STAGE/.candidate.env.XXXXXX")
  if ! openssl rand -hex 48 > "$raw_candidate"; then
    rm -f -- "$raw_candidate" "$env_candidate"
    echo "OpenSSL failed to generate the pseudonym key; no candidate was retained." >&2
    return 70
  fi
  chmod 600 "$raw_candidate" "$env_candidate"
  if ! awk '
    BEGIN { valid = 1; unique = 0 }
    NR == 1 {
      if (length($0) != 96 || $0 !~ /^[0-9a-f]+$/) valid = 0
      for (i = 1; i <= length($0); i++) {
        character = substr($0, i, 1)
        if (!(character in seen)) { seen[character] = 1; unique++ }
      }
    }
    NR > 1 { valid = 0 }
    END { if (NR != 1 || unique < 12) valid = 0; exit(valid ? 0 : 1) }
  ' "$raw_candidate"; then
    rm -f -- "$raw_candidate" "$env_candidate"
    echo "OpenSSL output failed the nonempty 384-bit candidate validation." >&2
    return 70
  fi
  {
    printf '%s=' "$SECRET_NAME"
    sed -n '1p' "$raw_candidate"
  } > "$env_candidate"
  rm -f -- "$raw_candidate"
  if ! validate_candidate_file "$env_candidate"; then
    rm -f -- "$env_candidate"
    return 70
  fi
  if ! mv "$env_candidate" "$CANDIDATE_FILE"; then
    rm -f -- "$env_candidate"
    echo "Unable to install the protected local pseudonym candidate." >&2
    return 70
  fi
  check_mode_600 "$CANDIDATE_FILE" || {
    echo "Unable to install a protected local pseudonym candidate." >&2
    return 70
  }
}

mkdir -p "$CUTOVER_DIR"
secure_private_directory "$CUTOVER_DIR" || exit $?
if [ "$MODE" = set ]; then
  acquire_production_lock
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  stale_lock_pid=""
  if [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] && \
    check_mode_600 "$LOCK_PID_FILE" 2>/dev/null; then
    stale_lock_pid=$(sed -n '1p' "$LOCK_PID_FILE")
    case "$stale_lock_pid" in
      *[!0-9]*|""|0|1) stale_lock_pid="" ;;
    esac
  fi
  if [ -n "$stale_lock_pid" ] && ! kill -0 "$stale_lock_pid" 2>/dev/null; then
    rm -f -- "$LOCK_PID_FILE"
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another pseudonym-secret audit/set is already active: $LOCK_DIR" >&2
    exit 75
  fi
fi
LOCK_HELD=1
chmod 700 "$LOCK_DIR"
printf '%s\n' "$$" > "$LOCK_PID_FILE"
chmod 600 "$LOCK_PID_FILE"
sync

if [ -e "$STAGE" ] || [ -L "$STAGE" ]; then
  ensure_safe_stage
  for existing_evidence in "$MANIFEST" "$POSTFLIGHT" "$ATTEMPT"; do
    if [ -e "$existing_evidence" ] || [ -L "$existing_evidence" ]; then
      [ -f "$existing_evidence" ] && [ ! -L "$existing_evidence" ] || {
        echo "Unsafe pseudonym-secret evidence path: $existing_evidence" >&2
        exit 65
      }
    fi
  done
fi

INITIAL_RAW="$WORK/secrets-initial.raw"
INITIAL_NAMES="$WORK/secrets-initial.names"
base44_cli whoami >/dev/null
list_secret_names "$INITIAL_RAW" "$INITIAL_NAMES"
if grep -qx "$SECRET_NAME" "$INITIAL_NAMES"; then
  if [ -e "$ATTEMPT" ] || [ -L "$ATTEMPT" ]; then
    if reconcile_verified_attempt; then
      exit 0
    fi
    echo "The Production secret is present, but a pending or ambiguous durable attempt requires postflight reconciliation." >&2
    echo "The protected candidate and evidence were preserved; refusing a silent no-op or rotation." >&2
    exit 70
  fi
  if [ -e "$CANDIDATE_FILE" ] || [ -L "$CANDIDATE_FILE" ]; then
    if validate_candidate_file "$CANDIDATE_FILE"; then
      rm -f -- "$CANDIDATE_FILE"
      sync
    else
      echo "Configured Production secret is stable, but the local candidate path is unsafe." >&2
      exit 65
    fi
  fi
  echo "$SECRET_NAME is already configured; keeping it stable."
  exit 0
fi

ensure_safe_stage
for evidence_file in "$MANIFEST" "$POSTFLIGHT" "$ATTEMPT"; do
  if [ -e "$evidence_file" ] || [ -L "$evidence_file" ]; then
    [ -f "$evidence_file" ] && [ ! -L "$evidence_file" ] || {
      echo "Unsafe pseudonym-secret evidence path: $evidence_file" >&2
      exit 65
    }
  fi
done
if [ -e "$ATTEMPT" ]; then
  echo "A durable pseudonym-secret mutation attempt already exists while the remote secret is absent." >&2
  echo "Refusing a second mutation until the earlier attempt is manually reconciled." >&2
  exit 70
fi

if [ -e "$MANIFEST" ] && [ ! -e "$CANDIDATE_FILE" ]; then
  echo "A pseudonym-secret manifest exists without its protected candidate; refusing silent regeneration." >&2
  exit 65
fi
if [ ! -e "$CANDIDATE_FILE" ]; then
  if [ -L "$CANDIDATE_FILE" ]; then
    echo "Pseudonym candidate path must not be a symbolic link." >&2
    exit 65
  fi
  generate_candidate
fi
validate_candidate_file "$CANDIDATE_FILE"

candidate_digest=$(candidate_value_sha256 "$CANDIDATE_FILE")
case "$candidate_digest" in
  *[!0-9a-f]*|"") exit 65 ;;
esac
[ "${#candidate_digest}" -eq 64 ] || exit 65
initial_inventory_digest=$(shasum -a 256 "$INITIAL_NAMES" | awk '{print $1}')

plan_input="$WORK/plan-input.json"
jq -n -S \
  --arg step "$EXPECTED_ACTION" \
  --arg app_id "$APP_ID" \
  --arg secret_name "$SECRET_NAME" \
  --arg candidate_value_sha256 "$candidate_digest" \
  --arg initial_secret_inventory_sha256 "$initial_inventory_digest" \
  '{
    step:$step,
    app_id:$app_id,
    secret_name:$secret_name,
    candidate_value_sha256:$candidate_value_sha256,
    initial_secret_inventory_sha256:$initial_secret_inventory_sha256
  }' > "$plan_input"
plan_digest=$(shasum -a 256 "$plan_input" | awk '{print $1}')

mkdir -p "$STAGE"
manifest_tmp="$WORK/manifest.json"
jq -n \
  --arg app_id "$APP_ID" \
  --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg secret_name "$SECRET_NAME" \
  --arg candidate_value_sha256 "$candidate_digest" \
  --arg initial_secret_inventory_sha256 "$initial_inventory_digest" \
  --arg plan_digest "$plan_digest" \
  '{
    protocol:"spyclash-pseudonym-secret-v2",
    app_id:$app_id,
    prepared_at:$prepared_at,
    secret_name:$secret_name,
    candidate_value_sha256:$candidate_value_sha256,
    initial_secret_inventory_sha256:$initial_secret_inventory_sha256,
    remote_secret_present:false,
    plan_digest:$plan_digest
  }' > "$manifest_tmp"
chmod 600 "$manifest_tmp"
atomic_stage_file "$manifest_tmp" "$MANIFEST" manifest

echo "$SECRET_NAME is missing."
echo "Prepared protected local candidate and digest-bound plan: $MANIFEST"
echo "Plan digest: $plan_digest"
if [ "$MODE" = prepare ]; then
  echo "No Production change was made. Obtain exact Step 2 confirmation before --set."
  exit 77
fi

if [ "${BASE44_CONFIRM_ACTION:-}" != "$EXPECTED_ACTION" ]; then
  echo "Set BASE44_CONFIRM_ACTION=$EXPECTED_ACTION for this exact cutover step." >&2
  exit 77
fi
if [ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]; then
  echo "Set BASE44_CONFIRM_APP_ID=$APP_ID for the intentional secret creation." >&2
  exit 77
fi
if [ "${BASE44_CONFIRM_PSEUDONYM_SECRET_PLAN_DIGEST:-}" != "$plan_digest" ]; then
  echo "Set BASE44_CONFIRM_PSEUDONYM_SECRET_PLAN_DIGEST to the exact inspected plan digest." >&2
  exit 77
fi

# Validate the same generated value before the final remote check. The next
# secrets list is intentionally JIT: if any actor created this name since the
# plan, the overwrite-capable `secrets set` command is never invoked.
validate_candidate_file "$CANDIDATE_FILE"
[ "$(candidate_value_sha256 "$CANDIDATE_FILE")" = "$candidate_digest" ] || {
  echo "Protected pseudonym candidate changed after plan preparation." >&2
  exit 77
}

JIT_RAW="$WORK/secrets-jit.raw"
JIT_NAMES="$WORK/secrets-jit.names"
list_secret_names "$JIT_RAW" "$JIT_NAMES"
if grep -qx "$SECRET_NAME" "$JIT_NAMES"; then
  echo "$SECRET_NAME appeared after plan preparation; refusing to overwrite or rotate it." >&2
  exit 77
fi
jit_inventory_digest=$(shasum -a 256 "$JIT_NAMES" | awk '{print $1}')
[ "$jit_inventory_digest" = "$initial_inventory_digest" ] || {
  echo "Base44 secret inventory changed after plan preparation; refusing mutation." >&2
  exit 77
}
validate_candidate_file "$CANDIDATE_FILE"
[ "$(candidate_value_sha256 "$CANDIDATE_FILE")" = "$candidate_digest" ] || {
  echo "Protected pseudonym candidate changed during JIT verification." >&2
  exit 77
}

# Persist the exact mutation intent before crossing the sole remote write
# boundary. A crash after `secrets set` must leave enough non-secret evidence
# to force a name-only postflight instead of treating the next run as a no-op.
attempt_started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
attempt_id=$(printf '%s\n' \
  "$APP_ID" \
  "$EXPECTED_ACTION" \
  "$plan_digest" \
  "$candidate_digest" \
  "$jit_inventory_digest" \
  "$attempt_started_at" \
  "$$" \
  "$WORK" | shasum -a 256 | awk '{print $1}')
case "$attempt_id" in
  *[!0-9a-f]*|"") exit 65 ;;
esac
[ "${#attempt_id}" -eq 64 ] || exit 65
attempt_tmp="$WORK/attempt.started.json"
jq -n \
  --arg attempt_id "$attempt_id" \
  --arg started_at "$attempt_started_at" \
  --arg app_id "$APP_ID" \
  --arg action "$EXPECTED_ACTION" \
  --arg secret_name "$SECRET_NAME" \
  --arg plan_digest "$plan_digest" \
  --arg candidate_value_sha256 "$candidate_digest" \
  --arg initial_secret_inventory_sha256 "$initial_inventory_digest" \
  --arg jit_secret_inventory_sha256 "$jit_inventory_digest" \
  '{
    protocol:"spyclash-pseudonym-secret-attempt-v1",
    attempt_id:$attempt_id,
    started_at:$started_at,
    app_id:$app_id,
    action:$action,
    secret_name:$secret_name,
    plan_digest:$plan_digest,
    candidate_value_sha256:$candidate_value_sha256,
    initial_secret_inventory_sha256:$initial_secret_inventory_sha256,
    jit_secret_inventory_sha256:$jit_secret_inventory_sha256,
    status:"mutation-started-postflight-required",
    postflight_required:true
  }' > "$attempt_tmp"
chmod 600 "$attempt_tmp"
atomic_stage_file "$attempt_tmp" "$ATTEMPT" attempt

SET_LOG="$WORK/secrets-set.log"
set_status=0
set +e
base44_cli secrets set --env-file "$CANDIDATE_FILE" > "$SET_LOG" 2>&1
set_status=$?
set -e

# Always perform a name-only postflight, even if the set command failed or its
# response was ambiguous. The secret value is never read back or logged.
POST_RAW="$WORK/secrets-postflight.raw"
POST_NAMES="$WORK/secrets-postflight.names"
post_list_status=0
set +e
list_secret_names "$POST_RAW" "$POST_NAMES"
post_list_status=$?
set -e
post_secret_present=false
post_inventory_digest=""
if [ "$post_list_status" -eq 0 ]; then
  post_inventory_digest=$(shasum -a 256 "$POST_NAMES" | awk '{print $1}')
  if grep -qx "$SECRET_NAME" "$POST_NAMES"; then
    post_secret_present=true
  fi
fi
postflight_matches=false
if [ "$set_status" -eq 0 ] && [ "$post_list_status" -eq 0 ] && \
  [ "$post_secret_present" = true ]; then
  postflight_matches=true
fi
postflight_status=postflight-failed-or-incomplete
postflight_required=true
if [ "$postflight_matches" = true ]; then
  postflight_status=completed-postflight-verified
  postflight_required=false
fi

postflight_tmp="$WORK/postflight.json"
jq -n \
  --arg attempt_id "$attempt_id" \
  --arg audited_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg app_id "$APP_ID" \
  --arg action "$EXPECTED_ACTION" \
  --arg secret_name "$SECRET_NAME" \
  --arg plan_digest "$plan_digest" \
  --arg candidate_value_sha256 "$candidate_digest" \
  --arg initial_secret_inventory_sha256 "$initial_inventory_digest" \
  --arg jit_secret_inventory_sha256 "$jit_inventory_digest" \
  --arg post_secret_inventory_sha256 "$post_inventory_digest" \
  --argjson set_status "$set_status" \
  --argjson post_list_status "$post_list_status" \
  --argjson secret_present "$post_secret_present" \
  --argjson matches "$postflight_matches" \
  --arg status "$postflight_status" \
  --argjson postflight_required "$postflight_required" \
  '{
    protocol:"spyclash-pseudonym-secret-postflight-v1",
    attempt_id:$attempt_id,
    audited_at:$audited_at,
    app_id:$app_id,
    action:$action,
    secret_name:$secret_name,
    plan_digest:$plan_digest,
    candidate_value_sha256:$candidate_value_sha256,
    initial_secret_inventory_sha256:$initial_secret_inventory_sha256,
    jit_secret_inventory_sha256:$jit_secret_inventory_sha256,
    post_secret_inventory_sha256:$post_secret_inventory_sha256,
    set_status:$set_status,
    post_list_status:$post_list_status,
    secret_present:$secret_present,
    matches:$matches,
    status:$status,
    postflight_required:$postflight_required
  }' > "$postflight_tmp"
chmod 600 "$postflight_tmp"
atomic_stage_file "$postflight_tmp" "$POSTFLIGHT" postflight

if [ "$postflight_matches" != true ]; then
  echo "Pseudonym-secret creation did not reach a verified state." >&2
  echo "Inspect $POSTFLIGHT; the candidate remains protected for a forward check." >&2
  exit 70
fi

reconcile_verified_attempt || {
  echo "Verified postflight could not be reconciled with its durable attempt; preserving evidence." >&2
  exit 70
}
