#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
GIT_COMMON_DIR=$(cd "$ROOT" && git rev-parse --path-format=absolute --git-common-dir)
CANONICAL_GIT_COMMON_DIR=$(CDPATH= cd -- "$GIT_COMMON_DIR" && pwd -P)
CANONICAL_REPOSITORY_ROOT=$(
  CDPATH= cd -- "$CANONICAL_GIT_COMMON_DIR/.." && pwd -P
)
EXPECTED_APP_ID=69a0e57fa939f578082f8091
EXPECTED_ACTION=PARTNER_NOTE_67_ASSIGN_RESERVED_SPY_ID_067_067
EXPECTED_POLICY_CONFIRMATION=COMMUNITY_ACTION_RESERVED_067_067_V1
APP_ID=$EXPECTED_APP_ID
MODE=dry-run
TARGET_USER_ID=
EXPECTED_CURRENT_SPY_ID=
SEEN_APP_ID=0
SEEN_TARGET=0
SEEN_EXPECTED=0
SEEN_APPLY=0

SCRIPT="$ROOT/scripts/assign-reserved-spy-id.ts"
LIFECYCLE_SCRIPT="$ROOT/base44/functions/communityAction/community-write-lifecycle.ts"
BILLING_LIFECYCLE_SCRIPT="$ROOT/base44/functions/communityAction/billing-identity-lifecycle.ts"
POLICY_SCRIPT="$ROOT/base44/functions/communityAction/community.ts"
PROFILE_SIGNAL_SCRIPT="$ROOT/base44/functions/communityAction/profile-signal.ts"
CUTOVER_DIR="$ROOT/.base44-cutover"
STAGE="$CUTOVER_DIR/reserved-spy-id-067-067"
MANIFEST="$STAGE/manifest.json"
COMPLETION="$STAGE/completion.json"
LAST_ATTEMPT="$STAGE/last-attempt.json"
CANONICAL_CUTOVER_DIR="$CANONICAL_REPOSITORY_ROOT/.base44-cutover"
PRODUCTION_LOCK_DIR="$CANONICAL_REPOSITORY_ROOT/.base44-cutover/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
WORK=
PRODUCTION_LOCK_LIST=
SOURCE_STAGE=
STAGED_SCRIPT=
STAGED_COMMUNITY_DIR=
STAGED_LIFECYCLE_SCRIPT=
STAGED_BILLING_LIFECYCLE_SCRIPT=
STAGED_POLICY_SCRIPT=
STAGED_PROFILE_SIGNAL_SCRIPT=
PRODUCTION_LOCK_HELD=0

usage() {
  echo "Usage: $0 --user-id USER_ID --expected-current-spy-id 000-000 [--app-id $EXPECTED_APP_ID] [--apply]" >&2
  exit 64
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-id)
      [ "$SEEN_APP_ID" -eq 0 ] && [ "$#" -ge 2 ] || usage
      APP_ID=$2
      SEEN_APP_ID=1
      shift 2
      ;;
    --user-id)
      [ "$SEEN_TARGET" -eq 0 ] && [ "$#" -ge 2 ] || usage
      TARGET_USER_ID=$2
      SEEN_TARGET=1
      shift 2
      ;;
    --expected-current-spy-id)
      [ "$SEEN_EXPECTED" -eq 0 ] && [ "$#" -ge 2 ] || usage
      EXPECTED_CURRENT_SPY_ID=$2
      SEEN_EXPECTED=1
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
case "$TARGET_USER_ID" in
  ""|*[!A-Za-z0-9_-]*)
    echo "A stable Base44 User ID is required." >&2
    exit 64
    ;;
esac
[ "${#TARGET_USER_ID}" -ge 6 ] && [ "${#TARGET_USER_ID}" -le 128 ] || {
  echo "The Base44 User ID length is invalid." >&2
  exit 64
}
case "$EXPECTED_CURRENT_SPY_ID" in
  [0-9][0-9][0-9]-[0-9][0-9][0-9]) ;;
  *)
    echo "Expected current SPY ID must use 000-000 format." >&2
    exit 64
    ;;
esac

if [ "${BASE44_APP_ID+x}" = x ] && [ "$BASE44_APP_ID" != "$APP_ID" ]; then
  echo "BASE44_APP_ID targets another app." >&2
  exit 77
fi
if [ "${BASE44_PROJECTS_BASE44_APP_ID+x}" = x ] && \
  [ "$BASE44_PROJECTS_BASE44_APP_ID" != "$APP_ID" ]; then
  echo "BASE44_PROJECTS_BASE44_APP_ID targets another app." >&2
  exit 77
fi

for internal_name in \
  SPYCLASH_RESERVED_SPY_ID_APPLY \
  SPYCLASH_RESERVED_SPY_ID_TARGET_USER_ID \
  SPYCLASH_RESERVED_SPY_ID_EXPECTED_CURRENT \
  SPYCLASH_RESERVED_SPY_ID_SOURCE_SHA256 \
  SPYCLASH_RESERVED_SPY_ID_LIFECYCLE_SOURCE_SHA256 \
  SPYCLASH_RESERVED_SPY_ID_BILLING_LIFECYCLE_SOURCE_SHA256 \
  SPYCLASH_RESERVED_SPY_ID_POLICY_SOURCE_SHA256 \
  SPYCLASH_RESERVED_SPY_ID_PROFILE_SIGNAL_SOURCE_SHA256 \
  SPYCLASH_RESERVED_SPY_ID_LIFECYCLE_URL \
  SPYCLASH_RESERVED_SPY_ID_PROFILE_SIGNAL_URL \
  SPYCLASH_RESERVED_SPY_ID_EXPECTED_PLAN_DIGEST \
  SPYCLASH_RESERVED_SPY_ID_CONFIRM_ACTION \
  SPYCLASH_RESERVED_SPY_ID_CONFIRM_APP_ID \
  SPYCLASH_RESERVED_SPY_ID_CONFIRM_TARGET_USER_ID \
  SPYCLASH_RESERVED_SPY_ID_POLICY_DEPLOYED
do
  eval "internal_is_set=\${$internal_name+x}"
  if [ "$internal_is_set" = x ]; then
    echo "$internal_name is wrapper-owned and must not be set by the caller." >&2
    exit 64
  fi
done

case "$ROOT" in
  ""|/) echo "Unsafe repository root." >&2; exit 65 ;;
esac
case "$CANONICAL_REPOSITORY_ROOT" in
  ""|/) echo "Unsafe canonical repository root." >&2; exit 65 ;;
esac
[ "$CANONICAL_GIT_COMMON_DIR" = "$CANONICAL_REPOSITORY_ROOT/.git" ] || {
  echo "The canonical Git common directory is not a non-bare repository .git directory." >&2
  exit 65
}
[ "$STAGE" = "$ROOT/.base44-cutover/reserved-spy-id-067-067" ] || exit 65
[ "$PRODUCTION_LOCK_DIR" = "$CANONICAL_REPOSITORY_ROOT/.base44-cutover/.production-mutation.lock" ] || exit 65

for source_file in "$SCRIPT" "$LIFECYCLE_SCRIPT" "$BILLING_LIFECYCLE_SCRIPT" "$POLICY_SCRIPT" "$PROFILE_SIGNAL_SCRIPT"; do
  [ -f "$source_file" ] && [ ! -L "$source_file" ] || {
    echo "$source_file must be a regular non-symlink file." >&2
    exit 65
  }
done
if [ -L "$CUTOVER_DIR" ] || [ -L "$STAGE" ] || \
  [ -L "$MANIFEST" ] || [ -L "$COMPLETION" ] || \
  [ -L "$LAST_ATTEMPT" ] || [ -L "$CANONICAL_CUTOVER_DIR" ] || \
  [ -L "$PRODUCTION_LOCK_DIR" ] || [ -L "$PRODUCTION_LOCK_OWNER" ]; then
  echo "Reserved SPY ID evidence paths must not be symbolic links." >&2
  exit 65
fi

for command in awk chmod cmp cp date dirname git id jq mkdir mktemp mv npx rm rmdir sed shasum sort stat tail uname; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 69
  }
done
for evidence_path in \
  ".base44-cutover/reserved-spy-id-067-067/manifest.json" \
  ".base44-cutover/reserved-spy-id-067-067/completion.json" \
  ".base44-cutover/reserved-spy-id-067-067/last-attempt.json"
do
  (cd "$ROOT" && git check-ignore -q -- "$evidence_path") || {
    echo "$evidence_path is not protected by repository ignore rules." >&2
    exit 65
  }
done
(cd "$CANONICAL_REPOSITORY_ROOT" && \
  git check-ignore -q -- ".base44-cutover/.production-mutation.lock/owner") || {
  echo "The shared production lock is not protected by canonical repository ignore rules." >&2
  exit 65
}

mkdir -p "$CUTOVER_DIR" "$STAGE"
chmod 700 "$CUTOVER_DIR" "$STAGE"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/spyclash-reserved-spy-id.XXXXXX")
case "$WORK" in
  "${TMPDIR:-/tmp}"/spyclash-reserved-spy-id.*) ;;
  *) echo "Unsafe temporary directory." >&2; exit 65 ;;
esac
chmod 700 "$WORK"
PRODUCTION_LOCK_LIST="$WORK/production-locks"
: > "$PRODUCTION_LOCK_LIST"
chmod 600 "$PRODUCTION_LOCK_LIST"

SOURCE_STAGE="$WORK/source-stage"
STAGED_SCRIPT="$SOURCE_STAGE/assign-reserved-spy-id.ts"
STAGED_COMMUNITY_DIR="$SOURCE_STAGE/communityAction"
STAGED_LIFECYCLE_SCRIPT="$STAGED_COMMUNITY_DIR/community-write-lifecycle.ts"
STAGED_BILLING_LIFECYCLE_SCRIPT="$STAGED_COMMUNITY_DIR/billing-identity-lifecycle.ts"
STAGED_POLICY_SCRIPT="$STAGED_COMMUNITY_DIR/community.ts"
STAGED_PROFILE_SIGNAL_SCRIPT="$STAGED_COMMUNITY_DIR/profile-signal.ts"
mkdir -p "$SOURCE_STAGE" "$STAGED_COMMUNITY_DIR"
chmod 700 "$SOURCE_STAGE" "$STAGED_COMMUNITY_DIR"

stage_exact_source() {
  stage_source=$1
  stage_destination=$2
  cp "$stage_source" "$stage_destination"
  [ -f "$stage_destination" ] && [ ! -L "$stage_destination" ] && \
    cmp -s "$stage_source" "$stage_destination" || {
    echo "Could not stage exact source bytes for $stage_source." >&2
    exit 65
  }
  chmod 400 "$stage_destination"
}

cleanup() {
  if [ "$PRODUCTION_LOCK_HELD" -eq 1 ] && \
    [ -f "$PRODUCTION_LOCK_LIST" ] && [ ! -L "$PRODUCTION_LOCK_LIST" ]; then
    while IFS= read -r held_lock_dir; do
      [ -n "$held_lock_dir" ] || continue
      held_lock_owner="$held_lock_dir/owner"
      if [ -f "$held_lock_owner" ] && [ ! -L "$held_lock_owner" ] && \
        [ "$(sed -n '1p' "$held_lock_owner")" = "$$" ] && \
        [ "$(sed -n '2p' "$held_lock_owner")" = "$ROOT" ]; then
        rm -f -- "$held_lock_owner"
      fi
      if [ -d "$held_lock_dir" ] && [ ! -L "$held_lock_dir" ]; then
        rmdir "$held_lock_dir" 2>/dev/null || {
          echo "Could not release shared Base44 Production lock: $held_lock_dir" >&2
        }
      fi
    done < "$PRODUCTION_LOCK_LIST"
  fi
  case "$WORK" in
    "${TMPDIR:-/tmp}"/spyclash-reserved-spy-id.*)
      if [ -d "$WORK" ] && [ ! -L "$WORK" ]; then
        if [ -d "$SOURCE_STAGE" ] && [ ! -L "$SOURCE_STAGE" ]; then
          chmod 700 "$SOURCE_STAGE" "$STAGED_COMMUNITY_DIR" 2>/dev/null || true
        fi
        rm -rf -- "$WORK"
      fi
      ;;
  esac
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

stage_exact_source "$SCRIPT" "$STAGED_SCRIPT"
stage_exact_source "$LIFECYCLE_SCRIPT" "$STAGED_LIFECYCLE_SCRIPT"
stage_exact_source "$BILLING_LIFECYCLE_SCRIPT" "$STAGED_BILLING_LIFECYCLE_SCRIPT"
stage_exact_source "$POLICY_SCRIPT" "$STAGED_POLICY_SCRIPT"
stage_exact_source "$PROFILE_SIGNAL_SCRIPT" "$STAGED_PROFILE_SIGNAL_SCRIPT"
chmod 500 "$SOURCE_STAGE" "$STAGED_COMMUNITY_DIR"

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

SOURCE_SHA256=$(hash_file "$STAGED_SCRIPT")
LIFECYCLE_SOURCE_SHA256=$(hash_file "$STAGED_LIFECYCLE_SCRIPT")
BILLING_LIFECYCLE_SOURCE_SHA256=$(hash_file "$STAGED_BILLING_LIFECYCLE_SCRIPT")
POLICY_SOURCE_SHA256=$(hash_file "$STAGED_POLICY_SCRIPT")
PROFILE_SIGNAL_SOURCE_SHA256=$(hash_file "$STAGED_PROFILE_SIGNAL_SCRIPT")
LIFECYCLE_URL="file://$STAGED_LIFECYCLE_SCRIPT"
PROFILE_SIGNAL_URL="file://$STAGED_PROFILE_SIGNAL_SCRIPT"

path_owner() {
  case "$(uname -s)" in
    Darwin) stat -f '%u' "$1" ;;
    *) stat -c '%u' "$1" ;;
  esac
}

acquire_production_locks() {
  worktree_roots="$WORK/registered-worktrees"
  git -C "$ROOT" worktree list --porcelain |
    awk '/^worktree / { sub(/^worktree /, ""); print }' |
    sort -u > "$worktree_roots"
  [ -s "$worktree_roots" ] || {
    echo "Could not enumerate registered Git worktrees." >&2
    exit 65
  }

  found_current=0
  found_canonical=0
  lock_index=0
  while IFS= read -r registered_root; do
    case "$registered_root" in
      /*) ;;
      *) echo "Unsafe registered Git worktree root." >&2; exit 65 ;;
    esac
    physical_root=$(CDPATH= cd -- "$registered_root" && pwd -P) || {
      echo "Registered Git worktree is unavailable: $registered_root" >&2
      exit 65
    }
    case "$physical_root" in
      ""|/) echo "Unsafe physical Git worktree root." >&2; exit 65 ;;
    esac
    registered_common=$(git -C "$physical_root" rev-parse --path-format=absolute --git-common-dir)
    physical_common=$(CDPATH= cd -- "$registered_common" && pwd -P) || exit 65
    [ "$physical_common" = "$CANONICAL_GIT_COMMON_DIR" ] || {
      echo "Registered worktree does not share the reviewed Git common directory." >&2
      exit 65
    }
    [ "$physical_root" = "$ROOT" ] && found_current=1
    [ "$physical_root" = "$CANONICAL_REPOSITORY_ROOT" ] && found_canonical=1

    worktree_cutover_dir="$physical_root/.base44-cutover"
    worktree_lock_dir="$worktree_cutover_dir/.production-mutation.lock"
    worktree_lock_owner="$worktree_lock_dir/owner"
    if [ -L "$worktree_cutover_dir" ] || [ -L "$worktree_lock_dir" ] || \
      [ -L "$worktree_lock_owner" ]; then
      echo "A registered worktree has an unsafe Base44 lock path." >&2
      exit 65
    fi
    (cd "$physical_root" && \
      git check-ignore -q -- ".base44-cutover/.production-mutation.lock/owner") || {
      echo "A registered worktree does not ignore the shared production lock." >&2
      exit 65
    }
    mkdir -p "$worktree_cutover_dir"
    [ -d "$worktree_cutover_dir" ] && [ ! -L "$worktree_cutover_dir" ] && \
      [ "$(path_owner "$worktree_cutover_dir")" = "$(id -u)" ] || {
      echo "Could not prepare a registered worktree Base44 cutover directory." >&2
      exit 65
    }
    chmod 700 "$worktree_cutover_dir"
    if ! mkdir "$worktree_lock_dir" 2>/dev/null; then
      echo "Another Base44 Production mutation is active or needs manual stale-lock review." >&2
      exit 75
    fi
    PRODUCTION_LOCK_HELD=1
    if ! printf '%s\n' "$worktree_lock_dir" >> "$PRODUCTION_LOCK_LIST"; then
      rmdir "$worktree_lock_dir" 2>/dev/null || true
      echo "Could not record an acquired Base44 Production lock." >&2
      exit 65
    fi
    [ -d "$worktree_lock_dir" ] && [ ! -L "$worktree_lock_dir" ] && \
      [ "$(path_owner "$worktree_lock_dir")" = "$(id -u)" ] || exit 65
    chmod 700 "$worktree_lock_dir"
    lock_index=$((lock_index + 1))
    lock_owner_source="$WORK/production-lock-owner.$lock_index"
    {
      echo "$$"
      echo "$ROOT"
      echo "$EXPECTED_ACTION"
      date -u +%Y-%m-%dT%H:%M:%SZ
    } > "$lock_owner_source"
    chmod 600 "$lock_owner_source"
    mv "$lock_owner_source" "$worktree_lock_owner"
  done < "$worktree_roots"

  [ "$found_current" -eq 1 ] && [ "$found_canonical" -eq 1 ] || {
    echo "Registered worktree inventory omitted a required lock root." >&2
    exit 65
  }
}

run_assignment() {
  run_mode=$1
  run_digest=$2
  run_output=$3
  if [ "$run_mode" = apply ]; then
    env -u BASE44_APP_ID -u BASE44_PROJECTS_BASE44_APP_ID \
      SPYCLASH_RESERVED_SPY_ID_APPLY=1 \
      SPYCLASH_RESERVED_SPY_ID_TARGET_USER_ID="$TARGET_USER_ID" \
      SPYCLASH_RESERVED_SPY_ID_EXPECTED_CURRENT="$EXPECTED_CURRENT_SPY_ID" \
      SPYCLASH_RESERVED_SPY_ID_SOURCE_SHA256="$SOURCE_SHA256" \
      SPYCLASH_RESERVED_SPY_ID_LIFECYCLE_SOURCE_SHA256="$LIFECYCLE_SOURCE_SHA256" \
      SPYCLASH_RESERVED_SPY_ID_BILLING_LIFECYCLE_SOURCE_SHA256="$BILLING_LIFECYCLE_SOURCE_SHA256" \
      SPYCLASH_RESERVED_SPY_ID_POLICY_SOURCE_SHA256="$POLICY_SOURCE_SHA256" \
      SPYCLASH_RESERVED_SPY_ID_PROFILE_SIGNAL_SOURCE_SHA256="$PROFILE_SIGNAL_SOURCE_SHA256" \
      SPYCLASH_RESERVED_SPY_ID_LIFECYCLE_URL="$LIFECYCLE_URL" \
      SPYCLASH_RESERVED_SPY_ID_PROFILE_SIGNAL_URL="$PROFILE_SIGNAL_URL" \
      SPYCLASH_RESERVED_SPY_ID_EXPECTED_PLAN_DIGEST="$run_digest" \
      SPYCLASH_RESERVED_SPY_ID_CONFIRM_ACTION="$EXPECTED_ACTION" \
      SPYCLASH_RESERVED_SPY_ID_CONFIRM_APP_ID="$APP_ID" \
      SPYCLASH_RESERVED_SPY_ID_CONFIRM_TARGET_USER_ID="$TARGET_USER_ID" \
      SPYCLASH_RESERVED_SPY_ID_POLICY_DEPLOYED="$EXPECTED_POLICY_CONFIRMATION" \
      npx --yes -p deno@2.9.5 -p base44@0.1.4 -c \
      "base44 --app-id \"$APP_ID\" exec" \
      < "$STAGED_SCRIPT" > "$run_output" 2>&1
  else
    env -u BASE44_APP_ID -u BASE44_PROJECTS_BASE44_APP_ID \
      SPYCLASH_RESERVED_SPY_ID_APPLY=0 \
      SPYCLASH_RESERVED_SPY_ID_TARGET_USER_ID="$TARGET_USER_ID" \
      SPYCLASH_RESERVED_SPY_ID_EXPECTED_CURRENT="$EXPECTED_CURRENT_SPY_ID" \
      SPYCLASH_RESERVED_SPY_ID_SOURCE_SHA256="$SOURCE_SHA256" \
      SPYCLASH_RESERVED_SPY_ID_LIFECYCLE_SOURCE_SHA256="$LIFECYCLE_SOURCE_SHA256" \
      SPYCLASH_RESERVED_SPY_ID_BILLING_LIFECYCLE_SOURCE_SHA256="$BILLING_LIFECYCLE_SOURCE_SHA256" \
      SPYCLASH_RESERVED_SPY_ID_POLICY_SOURCE_SHA256="$POLICY_SOURCE_SHA256" \
      SPYCLASH_RESERVED_SPY_ID_PROFILE_SIGNAL_SOURCE_SHA256="$PROFILE_SIGNAL_SOURCE_SHA256" \
      SPYCLASH_RESERVED_SPY_ID_LIFECYCLE_URL="$LIFECYCLE_URL" \
      SPYCLASH_RESERVED_SPY_ID_PROFILE_SIGNAL_URL="$PROFILE_SIGNAL_URL" \
      npx --yes -p deno@2.9.5 -p base44@0.1.4 -c \
      "base44 --app-id \"$APP_ID\" exec" \
      < "$STAGED_SCRIPT" > "$run_output" 2>&1
  fi
}

extract_report() {
  raw=$1
  report=$2
  sed -n 's/^SPYCLASH_RESERVED_SPY_ID_REPORT=//p' "$raw" | tail -n 1 > "$report"
  jq -e \
    --arg app_id "$APP_ID" \
    --arg source "$SOURCE_SHA256" \
    --arg lifecycle "$LIFECYCLE_SOURCE_SHA256" \
    --arg billing_lifecycle "$BILLING_LIFECYCLE_SOURCE_SHA256" \
    --arg policy "$POLICY_SOURCE_SHA256" \
    --arg profile_signal "$PROFILE_SIGNAL_SOURCE_SHA256" '
      .app_id == $app_id and
      .source_sha256 == $source and
      .lifecycle_source_sha256 == $lifecycle and
      .billing_lifecycle_source_sha256 == $billing_lifecycle and
      .policy_source_sha256 == $policy and
      .profile_signal_source_sha256 == $profile_signal and
      .reserved_spy_id == "067-067" and
      (.operator_identity_sha256 | test("^[0-9a-f]{64}$")) and
      (.target_identity_sha256 | test("^[0-9a-f]{64}$")) and
      (.plan_digest | test("^[0-9a-f]{64}$")) and
      (.friendship_projection_sha256 | test("^[0-9a-f]{64}$")) and
      (.friendship_rows | type == "number" and . >= 0 and floor == .) and
      (.friendship_updates | type == "number" and . >= 0 and floor == .) and
      (.blocker_total | type == "number" and . >= 0 and floor == .)
    ' "$report" >/dev/null || return 1
  if jq -e '.. | objects | keys[]? | select(test("email|display_name|full_name"; "i"))' \
    "$report" >/dev/null; then
    echo "Refusing a report containing private profile fields." >&2
    return 1
  fi
  jq -S . "$report" > "$report.sorted"
  mv "$report.sorted" "$report"
}

atomic_json() {
  source=$1
  destination=$2
  chmod 600 "$source"
  mv "$source" "$destination"
  chmod 600 "$destination"
}

write_attempt() {
  phase=$1
  status=$2
  jq -n \
    --arg app_id "$APP_ID" \
    --arg phase "$phase" \
    --arg mode "$MODE" \
    --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg target_user_id "$TARGET_USER_ID" \
    --arg expected_current_spy_id "$EXPECTED_CURRENT_SPY_ID" \
    --arg source_sha256 "$SOURCE_SHA256" \
    --arg lifecycle_source_sha256 "$LIFECYCLE_SOURCE_SHA256" \
    --arg billing_lifecycle_source_sha256 "$BILLING_LIFECYCLE_SOURCE_SHA256" \
    --arg policy_source_sha256 "$POLICY_SOURCE_SHA256" \
    --arg profile_signal_source_sha256 "$PROFILE_SIGNAL_SOURCE_SHA256" \
    --argjson status "$status" '{
      protocol:"spyclash-reserved-spy-id-wrapper-v1",
      app_id:$app_id,
      mode:$mode,
      phase:$phase,
      status:$status,
      prepared_at:$prepared_at,
      target_user_id:$target_user_id,
      expected_current_spy_id:$expected_current_spy_id,
      reserved_spy_id:"067-067",
      source_sha256:$source_sha256,
      lifecycle_source_sha256:$lifecycle_source_sha256,
      billing_lifecycle_source_sha256:$billing_lifecycle_source_sha256,
      policy_source_sha256:$policy_source_sha256,
      profile_signal_source_sha256:$profile_signal_source_sha256
    }' > "$WORK/attempt.json"
  atomic_json "$WORK/attempt.json" "$LAST_ATTEMPT"
}

if [ "$MODE" = dry-run ]; then
  if ! run_assignment dry-run "" "$WORK/dry-run.raw"; then
    write_attempt dry-run-exec-failed 1
    echo "Reserved SPY ID dry-run failed; no records were changed." >&2
    exit 1
  fi
  extract_report "$WORK/dry-run.raw" "$WORK/report.json" || {
    write_attempt dry-run-report-invalid 1
    echo "Reserved SPY ID dry-run returned an invalid report." >&2
    exit 1
  }
  jq -n \
    --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg target_user_id "$TARGET_USER_ID" \
    --arg expected_current_spy_id "$EXPECTED_CURRENT_SPY_ID" \
    --slurpfile report "$WORK/report.json" '{
      protocol:"spyclash-reserved-spy-id-wrapper-v1",
      prepared_at:$prepared_at,
      target_user_id:$target_user_id,
      expected_current_spy_id:$expected_current_spy_id,
      report:$report[0]
    }' > "$WORK/manifest.json"
  atomic_json "$WORK/manifest.json" "$MANIFEST"
  jq . "$WORK/report.json"
  if [ "$(jq -r '.phase' "$WORK/report.json")" != planned ]; then
    echo "Dry-run found blockers; inspect $MANIFEST. No records were changed." >&2
    exit 2
  fi
  echo "Read-only plan saved to $MANIFEST"
  echo "No Base44 records were changed."
  exit 0
fi

[ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] || {
  echo "Apply requires a reviewed dry-run manifest at $MANIFEST." >&2
  exit 77
}
PLAN_DIGEST=$(jq -r '.report.plan_digest // empty' "$MANIFEST")
case "$PLAN_DIGEST" in
  *[!0-9a-f]*|"") echo "The reviewed plan digest is invalid." >&2; exit 65 ;;
esac
[ "${#PLAN_DIGEST}" -eq 64 ] || exit 65
jq -e \
  --arg app_id "$APP_ID" \
  --arg target "$TARGET_USER_ID" \
  --arg expected "$EXPECTED_CURRENT_SPY_ID" \
  --arg source "$SOURCE_SHA256" \
  --arg lifecycle "$LIFECYCLE_SOURCE_SHA256" \
  --arg billing_lifecycle "$BILLING_LIFECYCLE_SOURCE_SHA256" \
  --arg policy "$POLICY_SOURCE_SHA256" \
  --arg signal "$PROFILE_SIGNAL_SOURCE_SHA256" '
    .target_user_id == $target and
    .expected_current_spy_id == $expected and
    .report.phase == "planned" and
    .report.blocker_total == 0 and
    .report.app_id == $app_id and
    .report.source_sha256 == $source and
    .report.lifecycle_source_sha256 == $lifecycle and
    .report.billing_lifecycle_source_sha256 == $billing_lifecycle and
    .report.policy_source_sha256 == $policy and
    .report.profile_signal_source_sha256 == $signal
  ' "$MANIFEST" >/dev/null || {
  echo "Apply inputs differ from the reviewed dry-run." >&2
  exit 77
}

[ "${BASE44_CONFIRM_APP_ID:-}" = "$APP_ID" ] || {
  echo "Set BASE44_CONFIRM_APP_ID=$APP_ID after fresh production approval." >&2
  exit 77
}
[ "${BASE44_CONFIRM_ACTION:-}" = "$EXPECTED_ACTION" ] || {
  echo "Set BASE44_CONFIRM_ACTION=$EXPECTED_ACTION after fresh production approval." >&2
  exit 77
}
[ "${BASE44_CONFIRM_RESERVED_SPY_ID_TARGET_USER_ID:-}" = "$TARGET_USER_ID" ] || {
  echo "Confirm the exact stable target User ID." >&2
  exit 77
}
[ "${BASE44_CONFIRM_RESERVED_SPY_ID_PLAN_DIGEST:-}" = "$PLAN_DIGEST" ] || {
  echo "Confirm the exact reviewed plan digest." >&2
  exit 77
}
[ "${BASE44_CONFIRM_RESERVED_SPY_ID_POLICY_DEPLOYED:-}" = "$EXPECTED_POLICY_CONFIRMATION" ] || {
  echo "Confirm that the reserved allocator policy is deployed first." >&2
  exit 77
}

acquire_production_locks
if ! run_assignment dry-run "" "$WORK/preflight.raw"; then
  write_attempt apply-preflight-failed 1
  echo "Fresh read-only preflight failed; no records were changed." >&2
  exit 1
fi
extract_report "$WORK/preflight.raw" "$WORK/preflight.json" || {
  write_attempt apply-preflight-invalid 1
  exit 1
}
[ "$(jq -r '.phase' "$WORK/preflight.json")" = planned ] && \
  [ "$(jq -r '.plan_digest' "$WORK/preflight.json")" = "$PLAN_DIGEST" ] || {
  write_attempt apply-preflight-drifted 1
  echo "Live state changed after review; run a new dry-run." >&2
  exit 75
}

write_attempt mutation-started-postflight-required 0
set +e
run_assignment apply "$PLAN_DIGEST" "$WORK/apply.raw"
APPLY_STATUS=$?
set -e
if [ "$APPLY_STATUS" -ne 0 ]; then
  write_attempt apply-failed-postflight-required "$APPLY_STATUS"
  echo "Assignment did not complete; inspect protected live state before retrying." >&2
  exit "$APPLY_STATUS"
fi
extract_report "$WORK/apply.raw" "$WORK/completed-report.json" || {
  write_attempt apply-report-invalid-postflight-required 1
  exit 1
}
jq -e '
  .mode == "apply" and
  .phase == "completed" and
  .blocker_total == 0 and
  .postflight_unique_owner == true and
  .postflight_friendship_projection == true
' "$WORK/completed-report.json" >/dev/null || {
  write_attempt apply-postflight-invalid 1
  exit 1
}
jq -n \
  --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg target_user_id "$TARGET_USER_ID" \
  --slurpfile report "$WORK/completed-report.json" '{
    protocol:"spyclash-reserved-spy-id-wrapper-v1",
    state:"completed-postflight-verified",
    completed_at:$completed_at,
    target_user_id:$target_user_id,
    report:$report[0]
  }' > "$WORK/completion.json"
atomic_json "$WORK/completion.json" "$COMPLETION"
write_attempt completed-postflight-verified 0
jq . "$WORK/completed-report.json"
echo "Assignment completed and verified. Evidence: $COMPLETION"
