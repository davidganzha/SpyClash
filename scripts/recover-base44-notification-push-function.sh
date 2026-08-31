#!/bin/bash

set -euo pipefail
umask 077

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
APP_FILE="$ROOT/base44/.app.jsonc"
EXPECTED_APP_ID="69a0e57fa939f578082f8091"
EXPECTED_SCHEMA_DIGEST="1be1657ecc65e54e918dd2361f913bd881471f53d0f3cb2f67afb8d2560b811e"
EXPECTED_FUNCTION_COUNT=17
APP_ID="$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_FILE" | head -n 1)"
[[ "$APP_ID" == "$EXPECTED_APP_ID" ]] || {
    echo "Repository app id is not the reviewed SpyClash app $EXPECTED_APP_ID." >&2
    exit 77
}

CUTOVER_DIR="$ROOT/.base44-cutover"
RECOVERY_DIR="$CUTOVER_DIR/notification-step-b-push-recovery"
PLAN_ROOT="$RECOVERY_DIR/plans"
EVIDENCE_DIR="$CUTOVER_DIR/evidence/notification-step-b-push-recovery"
LOCK_DIR="$CUTOVER_DIR/.notification-step-b-push-recovery.lock"
PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spyclash-notification-push-recovery.XXXXXX")"
REMOTE_BEFORE="$WORK/remote-before"
REMOTE_AFTER="$WORK/remote-after"
SCOPED_TARGET="$WORK/scoped-target"
SCHEMA_BEFORE="$WORK/schema-before.json"
SCHEMA_AFTER="$WORK/schema-after.json"
AUTH_FILE="$HOME/.base44/auth/auth.json"
TARGET_FUNCTION="pushNotificationAction"
ACTION="SPYCLASH_NOTIFICATION_STEP_B_PUSH_RECOVERY"
MODE="prepare"
EXPECTED_PLAN_DIGEST=""
LOCK_HELD=0
PRODUCTION_LOCK_HELD=0

FUNCTIONS=(
    advanceRound app-store-entitlement appleAuthBroker appleAuthCallback
    autoRegisterUser checkSubscription communityAction createCheckout
    deleteAccount gameRoomAction generateWordPack googleAuthCallback
    mobileAuthCallback notificationAction pushNotificationAction
    stripe-entitlement-webhook wordPackAction
)
NON_TARGET_FUNCTIONS=(
    advanceRound app-store-entitlement appleAuthBroker appleAuthCallback
    autoRegisterUser checkSubscription communityAction createCheckout
    deleteAccount gameRoomAction generateWordPack googleAuthCallback
    mobileAuthCallback notificationAction stripe-entitlement-webhook wordPackAction
)
TARGET_SCHEMA_ENTITIES=(
    AiGenerationQuota AiGenerationUsage AiWordPackCacheVariant AiWordPackRequestResult
    AppStoreAccount AppleSignInCredential BillingIdentityLifecycle CommunityReport
    Entitlement Friendship GameHistory GameRoom LiveActivityRegistration MembershipGrant
    NotificationAnnouncement NotificationReadReceipt ProfileComment PushDeviceRegistration
    PushNotificationEvent RoomInvite User WordPack
)

usage() {
    echo "Usage: $0 [--deploy --plan-digest <sha256>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy)
            MODE="deploy"
            shift
            ;;
        --plan-digest)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            EXPECTED_PLAN_DIGEST="$2"
            shift 2
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

if [[ "$MODE" == "prepare" && -n "$EXPECTED_PLAN_DIGEST" ]]; then
    echo "--plan-digest is accepted only together with --deploy." >&2
    exit 64
fi
if [[ "$MODE" == "deploy" && ! "$EXPECTED_PLAN_DIGEST" =~ ^[0-9a-f]{64}$ ]]; then
    echo "--deploy requires --plan-digest with the exact reviewed SHA-256 digest." >&2
    exit 64
fi
if [[ -n "${BASE44_APP_ID+x}" && "$BASE44_APP_ID" != "$APP_ID" ]]; then
    echo "BASE44_APP_ID targets another app; refusing to continue." >&2
    exit 77
fi
[[ "$ROOT" != "/" && "$RECOVERY_DIR" == "$ROOT/.base44-cutover/notification-step-b-push-recovery" ]] || exit 65
[[ ! -L "$CUTOVER_DIR" && ! -L "$RECOVERY_DIR" && ! -L "$PLAN_ROOT" && ! -L "$EVIDENCE_DIR" ]] || {
    echo "Recovery paths must not be symbolic links." >&2
    exit 65
}

for command in awk basename chmod cmp cp curl date diff env find grep head jq \
    mkdir mktemp mv npx rm rmdir sed shasum sort stat sync tr wc; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing required command: $command" >&2
        exit 69
    }
done

cleanup() {
    case "$WORK" in
        "${TMPDIR:-/tmp}"/spyclash-notification-push-recovery.*) rm -rf -- "$WORK" ;;
    esac
    if [[ "$LOCK_HELD" -eq 1 ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    if [[ "$PRODUCTION_LOCK_HELD" -eq 1 ]]; then
        if [[ -d "$PRODUCTION_LOCK_DIR" && ! -L "$PRODUCTION_LOCK_DIR" && -O "$PRODUCTION_LOCK_DIR" ]]; then
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

private_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"; }
private_links() { stat -f '%l' "$1" 2>/dev/null || stat -c '%h' "$1"; }

secure_private_directory() {
    local directory=$1
    [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] || return 65
    chmod 700 "$directory"
    [[ "$(private_mode "$directory")" == 700 ]] || return 65
}

secure_private_json_file() {
    local file=$1
    [[ -f "$file" && ! -L "$file" && -O "$file" ]] || return 65
    [[ "$(private_links "$file")" == 1 ]] || return 65
    chmod 600 "$file"
    [[ "$(private_mode "$file")" == 600 ]] || return 65
    jq -e . "$file" >/dev/null || return 65
}

secure_private_tree() {
    local tree=$1
    [[ -d "$tree" && ! -L "$tree" && -O "$tree" ]] || return 65
    ! find "$tree" -type l -print | grep -q . || return 65
    find "$tree" -type d -exec chmod 700 {} +
    find "$tree" -type f -exec chmod 600 {} +
}

install_durable_json() {
    local source=$1 destination=$2 directory=$3 label=$4 temporary
    case "$destination" in
        "$RECOVERY_DIR/latest-plan.json"|"$EVIDENCE_DIR/latest-postflight.json"|\
        "$EVIDENCE_DIR"/*/attempt.json|"$EVIDENCE_DIR"/*/postflight.json) ;;
        *)
            echo "Unsafe evidence destination: $destination" >&2
            return 65
            ;;
    esac
    secure_private_directory "$directory" || return $?
    secure_private_json_file "$source" || return $?
    if [[ -e "$destination" || -L "$destination" ]]; then
        secure_private_json_file "$destination" || return 65
    fi
    temporary="$(mktemp "$directory/.${label}.XXXXXX")"
    chmod 600 "$temporary"
    cp "$source" "$temporary"
    cmp -s "$source" "$temporary" || { rm -f -- "$temporary"; return 70; }
    mv "$temporary" "$destination"
    secure_private_json_file "$destination" || return 70
    sync
}

acquire_production_lock() {
    if ! mkdir "$PRODUCTION_LOCK_DIR" 2>/dev/null; then
        echo "Another Base44 Production mutation holds $PRODUCTION_LOCK_DIR." >&2
        return 75
    fi
    PRODUCTION_LOCK_HELD=1
    secure_private_directory "$PRODUCTION_LOCK_DIR"
    printf '%s:%s\n' "$ACTION" "$$" > "$PRODUCTION_LOCK_OWNER"
    chmod 600 "$PRODUCTION_LOCK_OWNER"
}

base44_cli() {
    env -u BASE44_APP_ID npx --yes base44@0.1.4 --app-id "$APP_ID" "$@"
}

check_auth_file() {
    [[ -f "$AUTH_FILE" && ! -L "$AUTH_FILE" && -O "$AUTH_FILE" ]] || return 77
    [[ "$(private_mode "$AUTH_FILE")" == 600 ]] || return 77
}

fetch_remote_schema() {
    local output=$1 curl_config="$WORK/curl.$RANDOM.conf" access_token status
    check_auth_file || return $?
    base44_cli whoami >/dev/null || return $?
    check_auth_file || return $?
    access_token="$(jq -er '.accessToken' "$AUTH_FILE")" || return $?
    printf 'header = "Authorization: Bearer %s"\n' "$access_token" > "$curl_config"
    unset access_token
    curl -fsS --connect-timeout 10 --max-time 60 --retry 2 --config "$curl_config" \
        "https://app.base44.com/api/apps/$APP_ID/entity-schemas" > "$output"
    status=$?
    rm -f -- "$curl_config"
    return "$status"
}

schema_set_digest() {
    jq -S '[.schemas[].entity_schema] | sort_by(.name)' "$1" |
        shasum -a 256 | awk '{print $1}'
}

write_expected_names() {
    local output=$1
    shift
    printf '%s\n' "$@" | LC_ALL=C sort > "$output"
}

verify_schema_boundary() {
    local remote=$1 expected="$WORK/schema-expected-$RANDOM.txt" actual="$WORK/schema-actual-$RANDOM.txt"
    jq -e '
      .total == 22 and .total == (.schemas | length) and
      ([.schemas[].entity_name] | unique | length) == 22 and
      all(.schemas[]; (.entity_schema | type == "object") and
        .entity_schema.name == .entity_name)
    ' "$remote" >/dev/null || {
        echo "Production schema response is incomplete or malformed." >&2
        return 65
    }
    write_expected_names "$expected" "${TARGET_SCHEMA_ENTITIES[@]}"
    jq -r '.schemas[].entity_name' "$remote" | LC_ALL=C sort > "$actual"
    cmp -s "$expected" "$actual" || {
        echo "Production schema inventory differs from the exact Notification Step A target." >&2
        diff -u "$expected" "$actual" >&2 || true
        return 77
    }
    [[ "$(schema_set_digest "$remote")" == "$EXPECTED_SCHEMA_DIGEST" ]] || {
        echo "Production schema digest differs from $EXPECTED_SCHEMA_DIGEST." >&2
        return 77
    }
}

pull_remote_functions() {
    local destination=$1
    mkdir -p "$destination/base44"
    cp "$ROOT/base44/config.jsonc" "$destination/base44/config.jsonc"
    cp "$APP_FILE" "$destination/base44/.app.jsonc"
    (cd "$destination" && base44_cli functions pull) || {
        echo "Unable to pull fresh Production functions." >&2
        return 70
    }
    [[ -d "$destination/base44/functions" ]] || return 65
}

validate_function() {
    local root=$1 name=$2 directory declared entry count
    directory="$root/$name"
    [[ -d "$directory" && ! -L "$directory" ]] || return 65
    ! find "$directory" -type l -print | grep -q . || return 65
    [[ -f "$directory/function.jsonc" && ! -L "$directory/function.jsonc" ]] || return 65
    declared="$(jq -er '.name' "$directory/function.jsonc")"
    entry="$(jq -er '.entry' "$directory/function.jsonc")"
    [[ "$declared" == "$name" && "$entry" =~ ^[A-Za-z0-9._-]+$ && -f "$directory/$entry" ]] || return 65
    count="$(find "$directory" -type f \( -name '*.js' -o -name '*.ts' -o -name '*.json' -o -name '*.jsonc' \) | wc -l | tr -d ' ')"
    [[ "$count" -gt 1 ]] || return 65
    ! find "$directory" -type f ! \( -name '*.js' -o -name '*.ts' -o -name '*.json' -o -name '*.jsonc' \) -print | grep -q . || return 65
    [[ "$(find "$directory" -name function.jsonc -type f | wc -l | tr -d ' ')" -eq 1 ]] || return 65
}

validate_inventory() {
    local root=$1 label=$2 expected actual name
    shift 2
    expected="$WORK/$label-expected.txt"
    actual="$WORK/$label-actual.txt"
    [[ -d "$root" && ! -L "$root" ]] || return 65
    ! find "$root" -mindepth 1 -maxdepth 1 ! -type d -print | grep -q . || return 65
    write_expected_names "$expected" "$@"
    find "$root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort > "$actual"
    cmp -s "$expected" "$actual" || {
        echo "$label function inventory differs from the exact $EXPECTED_FUNCTION_COUNT-function set." >&2
        diff -u "$expected" "$actual" >&2 || true
        return 77
    }
    for name in "$@"; do
        validate_function "$root" "$name" || return $?
    done
}

validate_push_target_policy() {
    local config=$1
    jq -e '
      .name == "pushNotificationAction" and .entry == "main.ts" and
      (.automations | type == "array" and length == 1) and
      .automations[0].type == "scheduled" and
      .automations[0].name == "drain_push_delivery_retries" and
      .automations[0].is_active == true and
      .automations[0].schedule_mode == "recurring" and
      .automations[0].schedule_type == "simple" and
      .automations[0].repeat_unit == "minutes" and
      .automations[0].repeat_interval == 15 and
      .automations[0].ends_type == "never" and
      .automations[0].function_args.action == "drain" and
      .automations[0].function_args.limit == 64
    ' "$config" >/dev/null || {
        echo "Local pushNotificationAction must use the reviewed 15-minute retry schedule." >&2
        return 77
    }
}

normalized_config() {
    jq -S '
      walk(if type == "object" then with_entries(select(.value != null)) else . end) |
      .automations = ((.automations // []) | map(
        .is_active = (.is_active // true) |
        if .type == "scheduled" and .schedule_mode == "recurring" then
          .ends_type = (.ends_type // "never") else . end))
    ' "$1"
}

function_object() {
    local root=$1 name=$2 directory records config relative source_digest config_digest effective_digest count
    directory="$root/$name"
    records="$WORK/source-$name-$RANDOM.txt"
    config="$WORK/config-$name-$RANDOM.json"
    : > "$records"
    while IFS= read -r relative; do
        printf '%s\t%s\n' "$relative" "$(shasum -a 256 "$directory/$relative" | awk '{print $1}')" >> "$records"
    done < <(cd "$directory" && find . -type f \
        \( -name '*.js' -o -name '*.ts' -o -name '*.json' -o -name '*.jsonc' \) \
        ! -name function.jsonc -print | sed 's#^\./##' | LC_ALL=C sort)
    count="$(wc -l < "$records" | tr -d ' ')"
    [[ "$count" -gt 0 ]] || return 65
    normalized_config "$directory/function.jsonc" > "$config"
    source_digest="$(shasum -a 256 "$records" | awk '{print $1}')"
    config_digest="$(shasum -a 256 "$config" | awk '{print $1}')"
    effective_digest="$(printf '%s\n' "$name" "$config_digest" "$source_digest" | shasum -a 256 | awk '{print $1}')"
    jq -n --arg name "$name" --arg config_digest "$config_digest" \
        --arg source_digest "$source_digest" --arg effective_digest "$effective_digest" \
        --argjson source_file_count "$count" \
        '{name:$name,config_digest:$config_digest,source_digest:$source_digest,
          effective_digest:$effective_digest,source_file_count:$source_file_count}'
}

write_function_manifest() {
    local root=$1 output=$2 objects="$WORK/function-objects-$RANDOM.jsonl" name
    shift 2
    : > "$objects"
    for name in "$@"; do
        function_object "$root" "$name" >> "$objects"
    done
    jq -S -s 'sort_by(.name)' "$objects" > "$output"
}

json_digest() { shasum -a 256 "$1" | awk '{print $1}'; }

tree_bytes_digest() {
    local tree=$1 records="$WORK/tree-records-$RANDOM.txt" relative
    [[ -d "$tree" && ! -L "$tree" ]] || return 65
    ! find "$tree" -type l -print | grep -q . || return 65
    : > "$records"
    while IFS= read -r relative; do
        printf '%s\t%s\n' "$relative" "$(shasum -a 256 "$tree/$relative" | awk '{print $1}')" >> "$records"
    done < <(cd "$tree" && find . -type f -print | sed 's#^\./##' | LC_ALL=C sort)
    shasum -a 256 "$records" | awk '{print $1}'
}

function_set_bytes_digest() {
    local root=$1 records="$WORK/function-set-bytes-$RANDOM.txt" name relative
    shift
    : > "$records"
    for name in "$@"; do
        while IFS= read -r relative; do
            printf '%s\t%s\n' "$name/$relative" \
                "$(shasum -a 256 "$root/$name/$relative" | awk '{print $1}')" >> "$records"
        done < <(cd "$root/$name" && find . -type f -print | sed 's#^\./##' | LC_ALL=C sort)
    done
    shasum -a 256 "$records" | awk '{print $1}'
}

write_function_delta() {
    local before=$1 target=$2 output=$3
    jq -S -n --slurpfile before "$before" --slurpfile target "$target" '
      ($before[0] | map({key:.name,value:.effective_digest}) | from_entries) as $live |
      ($target[0] | map({key:.name,value:.effective_digest}) | from_entries) as $wanted |
      {
        additions:[($wanted | keys[]) as $name | select($live[$name] == null) | $name],
        deletions:[($live | keys[]) as $name | select($wanted[$name] == null) | $name],
        changes:[($wanted | keys[]) as $name |
          select($live[$name] != null and $live[$name] != $wanted[$name]) | $name],
        unchanged:[($wanted | keys[]) as $name |
          select($live[$name] != null and $live[$name] == $wanted[$name]) | $name]
      }
    ' > "$output"
}

assert_recovery_delta() {
    local before=$1 target=$2 output=$3
    write_function_delta "$before" "$target" "$output"
    jq -e '
      .additions == [] and .deletions == [] and
      .changes == ["pushNotificationAction"] and
      (.unchanged | length) == 16
    ' "$output" >/dev/null || {
        echo "Recovery plan must change only pushNotificationAction and preserve 16 functions." >&2
        return 77
    }
}

copy_push_payload() {
    local destination=$1 source_root=$2
    mkdir -p "$destination/base44/functions"
    cp "$ROOT/base44/config.jsonc" "$destination/base44/config.jsonc"
    cp "$APP_FILE" "$destination/base44/.app.jsonc"
    cp -R "$source_root/$TARGET_FUNCTION" "$destination/base44/functions/$TARGET_FUNCTION"
}

copy_scoped_target() {
    local destination=$1 remote_root=$2 name
    mkdir -p "$destination"
    for name in "${NON_TARGET_FUNCTIONS[@]}"; do
        cp -R "$remote_root/$name" "$destination/$name"
    done
    cp -R "$ROOT/base44/functions/$TARGET_FUNCTION" "$destination/$TARGET_FUNCTION"
}

prepare_plan() {
    local stage="$WORK/plan-stage" deploy_stage="$WORK/deploy-stage"
    local remote_manifest target_manifest local_target_manifest non_target_manifest delta
    local remote_digest target_digest local_target_digest non_target_digest non_target_bytes_digest
    local delta_digest payload_bytes_digest plan_input plan_digest plan_destination

    validate_function "$ROOT/base44/functions" "$TARGET_FUNCTION"
    validate_push_target_policy "$ROOT/base44/functions/$TARGET_FUNCTION/function.jsonc"
    fetch_remote_schema "$SCHEMA_BEFORE" || { echo "Unable to fetch Production schema." >&2; exit 70; }
    verify_schema_boundary "$SCHEMA_BEFORE"
    pull_remote_functions "$REMOTE_BEFORE"
    validate_inventory "$REMOTE_BEFORE/base44/functions" remote-before "${FUNCTIONS[@]}"

    copy_scoped_target "$SCOPED_TARGET" "$REMOTE_BEFORE/base44/functions"
    validate_inventory "$SCOPED_TARGET" scoped-target "${FUNCTIONS[@]}"
    copy_push_payload "$deploy_stage" "$ROOT/base44/functions"
    validate_inventory "$deploy_stage/base44/functions" deploy-target "$TARGET_FUNCTION"

    mkdir -p "$stage"
    remote_manifest="$stage/remote-functions-before.json"
    target_manifest="$stage/expected-target-functions-all.json"
    local_target_manifest="$stage/local-push-target.json"
    non_target_manifest="$stage/non-target-functions-before.json"
    delta="$stage/function-delta.json"
    write_function_manifest "$REMOTE_BEFORE/base44/functions" "$remote_manifest" "${FUNCTIONS[@]}"
    write_function_manifest "$SCOPED_TARGET" "$target_manifest" "${FUNCTIONS[@]}"
    write_function_manifest "$ROOT/base44/functions" "$local_target_manifest" "$TARGET_FUNCTION"
    write_function_manifest "$REMOTE_BEFORE/base44/functions" "$non_target_manifest" "${NON_TARGET_FUNCTIONS[@]}"
    assert_recovery_delta "$remote_manifest" "$target_manifest" "$delta"

    remote_digest="$(json_digest "$remote_manifest")"
    target_digest="$(json_digest "$target_manifest")"
    local_target_digest="$(json_digest "$local_target_manifest")"
    non_target_digest="$(json_digest "$non_target_manifest")"
    non_target_bytes_digest="$(function_set_bytes_digest "$REMOTE_BEFORE/base44/functions" "${NON_TARGET_FUNCTIONS[@]}")"
    delta_digest="$(json_digest "$delta")"
    payload_bytes_digest="$(tree_bytes_digest "$deploy_stage/base44")"
    cp -R "$deploy_stage" "$stage/deploy"

    plan_input="$stage/plan-input.json"
    jq -S -n --arg step "B-push-recovery" --arg action "$ACTION" --arg app_id "$APP_ID" \
        --arg target_function "$TARGET_FUNCTION" --arg schema_digest "$EXPECTED_SCHEMA_DIGEST" \
        --arg remote_digest "$remote_digest" --arg target_digest "$target_digest" \
        --arg local_target_digest "$local_target_digest" --arg non_target_digest "$non_target_digest" \
        --arg non_target_bytes_digest "$non_target_bytes_digest" --arg delta_digest "$delta_digest" \
        --arg payload_bytes_digest "$payload_bytes_digest" --slurpfile delta "$delta" \
        '{step:$step,action:$action,app_id:$app_id,target_function:$target_function,
          live_function_count:17,target_function_count:17,schema_count:22,schema_digest:$schema_digest,
          remote_function_digest:$remote_digest,expected_target_function_digest:$target_digest,
          local_target_function_digest:$local_target_digest,
          non_target_before_digest:$non_target_digest,
          non_target_before_bytes_digest:$non_target_bytes_digest,
          function_delta_digest:$delta_digest,payload_bytes_digest:$payload_bytes_digest,
          deploy_function_order:[$target_function],delta:$delta[0]}' > "$plan_input"
    plan_digest="$(json_digest "$plan_input")"
    jq -S --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg plan_digest "$plan_digest" \
        '. + {prepared_at:$prepared_at,plan_digest:$plan_digest}' "$plan_input" > "$stage/manifest.json"
    secure_private_tree "$stage"

    mkdir -p "$RECOVERY_DIR" "$PLAN_ROOT"
    secure_private_directory "$RECOVERY_DIR"
    secure_private_directory "$PLAN_ROOT"
    plan_destination="$PLAN_ROOT/$plan_digest"
    if [[ -e "$plan_destination" || -L "$plan_destination" ]]; then
        secure_private_tree "$plan_destination"
        cmp -s "$stage/plan-input.json" "$plan_destination/plan-input.json" &&
        cmp -s "$stage/remote-functions-before.json" "$plan_destination/remote-functions-before.json" &&
        cmp -s "$stage/expected-target-functions-all.json" "$plan_destination/expected-target-functions-all.json" &&
        cmp -s "$stage/local-push-target.json" "$plan_destination/local-push-target.json" &&
        cmp -s "$stage/non-target-functions-before.json" "$plan_destination/non-target-functions-before.json" &&
        cmp -s "$stage/function-delta.json" "$plan_destination/function-delta.json" &&
        diff -qr "$stage/deploy" "$plan_destination/deploy" >/dev/null || {
            echo "Existing recovery plan path contains different bytes." >&2
            exit 65
        }
    else
        mv "$stage" "$plan_destination"
        secure_private_tree "$plan_destination"
    fi
    install_durable_json "$plan_destination/manifest.json" "$RECOVERY_DIR/latest-plan.json" "$RECOVERY_DIR" latest-plan

    echo "Prepared read-only pushNotificationAction recovery plan: $plan_destination"
    echo "Production functions: 17; recovery changes: pushNotificationAction only"
    echo "Preserved Production functions: 16 raw-byte trees"
    echo "Required retry interval: 15 minutes"
    echo "Schema digest: $EXPECTED_SCHEMA_DIGEST"
    echo "Plan digest: $plan_digest"
    echo "No Base44 mutation was made."
}

deploy_reviewed_plan() {
    local plan_dir="$PLAN_ROOT/$EXPECTED_PLAN_DIGEST" manifest="$PLAN_ROOT/$EXPECTED_PLAN_DIGEST/manifest.json"
    local reviewed_plan_digest reviewed_remote_digest reviewed_target_digest reviewed_local_target_digest
    local reviewed_non_target_digest reviewed_non_target_bytes_digest reviewed_payload_bytes_digest
    local reviewed_manifest_digest reviewed_prepared_at reconstructed_manifest
    local jit_remote_manifest jit_remote_digest jit_target_root jit_target_manifest
    local jit_target_digest jit_local_target_manifest jit_local_target_digest jit_non_target_manifest
    local jit_non_target_digest jit_non_target_bytes_digest jit_delta deploy_status function_postflight_status
    local schema_postflight_status target_after_digest non_target_after_digest non_target_after_bytes_digest
    local schema_after_digest matches_reviewed_stage attempt_id attempt_dir post_remote_manifest post_target_manifest
    local post_non_target_manifest verified_deploy_root

    [[ -d "$plan_dir" && ! -L "$plan_dir" && -f "$manifest" && ! -L "$manifest" ]] || {
        echo "No reviewed recovery plan exists for digest $EXPECTED_PLAN_DIGEST." >&2
        exit 77
    }
    secure_private_tree "$plan_dir"
    secure_private_json_file "$manifest"
    reviewed_plan_digest="$(jq -er '.plan_digest' "$manifest")"
    [[ "$reviewed_plan_digest" == "$EXPECTED_PLAN_DIGEST" ]] || {
        echo "Reviewed recovery plan digest does not match its immutable plan path." >&2
        exit 77
    }
    [[ "$(json_digest "$plan_dir/plan-input.json")" == "$reviewed_plan_digest" ]] || {
        echo "Reviewed recovery plan input no longer matches its digest." >&2
        exit 77
    }
    reviewed_prepared_at="$(jq -er '.prepared_at | select(test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))' "$manifest")"
    reconstructed_manifest="$WORK/reconstructed-reviewed-manifest.json"
    jq -S --arg prepared_at "$reviewed_prepared_at" --arg plan_digest "$reviewed_plan_digest" \
        '. + {prepared_at:$prepared_at,plan_digest:$plan_digest}' "$plan_dir/plan-input.json" > "$reconstructed_manifest"
    cmp -s "$reconstructed_manifest" "$manifest" || {
        echo "Reviewed recovery manifest is not the exact signed plan-input envelope." >&2
        exit 77
    }
    jq -e --arg app_id "$APP_ID" --arg action "$ACTION" --arg schema "$EXPECTED_SCHEMA_DIGEST" '
      .step == "B-push-recovery" and .app_id == $app_id and .action == $action and
      .target_function == "pushNotificationAction" and .live_function_count == 17 and
      .target_function_count == 17 and .schema_count == 22 and .schema_digest == $schema and
      .deploy_function_order == ["pushNotificationAction"] and
      .delta.additions == [] and .delta.deletions == [] and
      .delta.changes == ["pushNotificationAction"] and (.delta.unchanged | length) == 16
    ' "$manifest" >/dev/null || {
        echo "Reviewed recovery manifest violates the one-function contract." >&2
        exit 77
    }
    reviewed_remote_digest="$(jq -er '.remote_function_digest' "$manifest")"
    reviewed_target_digest="$(jq -er '.expected_target_function_digest' "$manifest")"
    reviewed_local_target_digest="$(jq -er '.local_target_function_digest' "$manifest")"
    reviewed_non_target_digest="$(jq -er '.non_target_before_digest' "$manifest")"
    reviewed_non_target_bytes_digest="$(jq -er '.non_target_before_bytes_digest' "$manifest")"
    reviewed_payload_bytes_digest="$(jq -er '.payload_bytes_digest' "$manifest")"
    reviewed_manifest_digest="$(json_digest "$manifest")"

    validate_push_target_policy "$plan_dir/deploy/base44/functions/$TARGET_FUNCTION/function.jsonc"
    validate_push_target_policy "$ROOT/base44/functions/$TARGET_FUNCTION/function.jsonc"
    validate_inventory "$plan_dir/deploy/base44/functions" reviewed-deploy-target "$TARGET_FUNCTION"
    [[ "$(tree_bytes_digest "$plan_dir/deploy/base44")" == "$reviewed_payload_bytes_digest" ]] || {
        echo "Reviewed recovery payload bytes changed after review." >&2
        exit 77
    }
    jit_local_target_manifest="$WORK/jit-local-target.json"
    write_function_manifest "$ROOT/base44/functions" "$jit_local_target_manifest" "$TARGET_FUNCTION"
    jit_local_target_digest="$(json_digest "$jit_local_target_manifest")"
    [[ "$jit_local_target_digest" == "$reviewed_local_target_digest" ]] || {
        echo "Checked-in pushNotificationAction changed after recovery review." >&2
        exit 77
    }

    [[ "${BASE44_CONFIRM_APP_ID:-}" == "$APP_ID" ]] || {
        echo "Set BASE44_CONFIRM_APP_ID=$APP_ID." >&2
        exit 77
    }
    [[ "${BASE44_CONFIRM_ACTION:-}" == "$ACTION" ]] || {
        echo "Set BASE44_CONFIRM_ACTION=$ACTION." >&2
        exit 77
    }
    [[ "${BASE44_CONFIRM_NOTIFICATION_PUSH_RECOVERY_PLAN_DIGEST:-}" == "$reviewed_plan_digest" ]] || {
        echo "Set BASE44_CONFIRM_NOTIFICATION_PUSH_RECOVERY_PLAN_DIGEST to the reviewed plan digest." >&2
        exit 77
    }

    acquire_production_lock
    fetch_remote_schema "$SCHEMA_BEFORE" || { echo "Unable to fetch JIT Production schema." >&2; exit 70; }
    verify_schema_boundary "$SCHEMA_BEFORE"
    pull_remote_functions "$REMOTE_BEFORE"
    validate_inventory "$REMOTE_BEFORE/base44/functions" remote-jit "${FUNCTIONS[@]}"
    jit_remote_manifest="$WORK/jit-remote-functions.json"
    jit_non_target_manifest="$WORK/jit-non-target-functions.json"
    write_function_manifest "$REMOTE_BEFORE/base44/functions" "$jit_remote_manifest" "${FUNCTIONS[@]}"
    write_function_manifest "$REMOTE_BEFORE/base44/functions" "$jit_non_target_manifest" "${NON_TARGET_FUNCTIONS[@]}"
    jit_remote_digest="$(json_digest "$jit_remote_manifest")"
    jit_non_target_digest="$(json_digest "$jit_non_target_manifest")"
    jit_non_target_bytes_digest="$(function_set_bytes_digest "$REMOTE_BEFORE/base44/functions" "${NON_TARGET_FUNCTIONS[@]}")"
    [[ "$jit_remote_digest" == "$reviewed_remote_digest" &&
       "$jit_non_target_digest" == "$reviewed_non_target_digest" &&
       "$jit_non_target_bytes_digest" == "$reviewed_non_target_bytes_digest" ]] || {
        echo "Production functions changed after the recovery plan was reviewed." >&2
        exit 77
    }

    jit_target_root="$WORK/jit-target"
    copy_scoped_target "$jit_target_root" "$REMOTE_BEFORE/base44/functions"
    validate_inventory "$jit_target_root" jit-target "${FUNCTIONS[@]}"
    jit_target_manifest="$WORK/jit-target-functions.json"
    write_function_manifest "$jit_target_root" "$jit_target_manifest" "${FUNCTIONS[@]}"
    jit_target_digest="$(json_digest "$jit_target_manifest")"
    jit_delta="$WORK/jit-function-delta.json"
    assert_recovery_delta "$jit_remote_manifest" "$jit_target_manifest" "$jit_delta"
    [[ "$jit_target_digest" == "$reviewed_target_digest" ]] || {
        echo "JIT recovery target no longer matches the reviewed plan." >&2
        exit 77
    }

    mkdir -p "$EVIDENCE_DIR"
    secure_private_directory "$EVIDENCE_DIR"
    attempt_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
    attempt_dir="$EVIDENCE_DIR/$attempt_id"
    mkdir "$attempt_dir"
    secure_private_directory "$attempt_dir"
    cp "$manifest" "$attempt_dir/reviewed-manifest.json"
    secure_private_json_file "$attempt_dir/reviewed-manifest.json"
    jq -n --arg attempted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg app_id "$APP_ID" \
        --arg action "$ACTION" --arg reviewed_plan_digest "$reviewed_plan_digest" \
        --arg reviewed_manifest_digest "$reviewed_manifest_digest" \
        --arg jit_remote_function_digest "$jit_remote_digest" \
        --arg jit_non_target_bytes_digest "$jit_non_target_bytes_digest" \
        --arg jit_schema_digest "$EXPECTED_SCHEMA_DIGEST" \
        '{attempted_at:$attempted_at,app_id:$app_id,action:$action,
          target_function:"pushNotificationAction",reviewed_plan_digest:$reviewed_plan_digest,
          reviewed_manifest_digest:$reviewed_manifest_digest,
          jit_remote_function_digest:$jit_remote_function_digest,
          jit_non_target_bytes_digest:$jit_non_target_bytes_digest,
          jit_schema_digest:$jit_schema_digest,status:"mutation-started-postflight-required",
          postflight_required:true}' > "$WORK/attempt.json"
    chmod 600 "$WORK/attempt.json"
    install_durable_json "$WORK/attempt.json" "$attempt_dir/attempt.json" "$attempt_dir" attempt

    verified_deploy_root="$WORK/verified-deploy"
    mkdir "$verified_deploy_root"
    secure_private_directory "$verified_deploy_root"
    cp -R "$plan_dir/deploy"/. "$verified_deploy_root"/
    secure_private_tree "$verified_deploy_root"
    validate_inventory "$verified_deploy_root/base44/functions" verified-deploy-target "$TARGET_FUNCTION"
    validate_push_target_policy "$verified_deploy_root/base44/functions/$TARGET_FUNCTION/function.jsonc"
    [[ "$(tree_bytes_digest "$verified_deploy_root/base44")" == "$reviewed_payload_bytes_digest" ]] || {
        echo "Fresh private recovery payload no longer matches the reviewed bytes." >&2
        exit 77
    }

    deploy_status=0
    set +e
    (cd "$verified_deploy_root" && base44_cli functions deploy "$TARGET_FUNCTION")
    deploy_status=$?
    set -e

    function_postflight_status=0
    schema_postflight_status=0
    target_after_digest=""
    non_target_after_digest=""
    non_target_after_bytes_digest=""
    schema_after_digest=""
    post_remote_manifest="$WORK/post-remote-functions.json"
    post_target_manifest="$WORK/post-target-function.json"
    post_non_target_manifest="$WORK/post-non-target-functions.json"
    set +e
    (
        set -e
        pull_remote_functions "$REMOTE_AFTER"
        validate_inventory "$REMOTE_AFTER/base44/functions" remote-after "${FUNCTIONS[@]}"
        write_function_manifest "$REMOTE_AFTER/base44/functions" "$post_remote_manifest" "${FUNCTIONS[@]}"
        write_function_manifest "$REMOTE_AFTER/base44/functions" "$post_target_manifest" "$TARGET_FUNCTION"
        write_function_manifest "$REMOTE_AFTER/base44/functions" "$post_non_target_manifest" "${NON_TARGET_FUNCTIONS[@]}"
    )
    function_postflight_status=$?
    if [[ "$function_postflight_status" -eq 0 ]]; then
        target_after_digest="$(json_digest "$post_target_manifest")"
        non_target_after_digest="$(json_digest "$post_non_target_manifest")"
        non_target_after_bytes_digest="$(function_set_bytes_digest "$REMOTE_AFTER/base44/functions" "${NON_TARGET_FUNCTIONS[@]}")"
    fi
    fetch_remote_schema "$SCHEMA_AFTER"
    schema_postflight_status=$?
    if [[ "$schema_postflight_status" -eq 0 ]]; then
        verify_schema_boundary "$SCHEMA_AFTER"
        schema_postflight_status=$?
        if [[ "$schema_postflight_status" -eq 0 ]]; then
            schema_after_digest="$(schema_set_digest "$SCHEMA_AFTER")"
        fi
    fi
    set -e

    matches_reviewed_stage=false
    if [[ "$deploy_status" -eq 0 && "$function_postflight_status" -eq 0 && "$schema_postflight_status" -eq 0 &&
          "$target_after_digest" == "$reviewed_local_target_digest" &&
          "$non_target_after_digest" == "$reviewed_non_target_digest" &&
          "$non_target_after_bytes_digest" == "$reviewed_non_target_bytes_digest" &&
          "$schema_after_digest" == "$EXPECTED_SCHEMA_DIGEST" ]]; then
        matches_reviewed_stage=true
    fi

    jq -n --arg audited_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg app_id "$APP_ID" \
        --arg action "$ACTION" --arg reviewed_plan_digest "$reviewed_plan_digest" \
        --arg expected_target_digest "$reviewed_local_target_digest" --arg actual_target_digest "$target_after_digest" \
        --arg expected_non_target_digest "$reviewed_non_target_digest" --arg actual_non_target_digest "$non_target_after_digest" \
        --arg expected_non_target_bytes_digest "$reviewed_non_target_bytes_digest" \
        --arg actual_non_target_bytes_digest "$non_target_after_bytes_digest" \
        --arg expected_schema_digest "$EXPECTED_SCHEMA_DIGEST" --arg actual_schema_digest "$schema_after_digest" \
        --argjson deploy_status "$deploy_status" --argjson function_postflight_status "$function_postflight_status" \
        --argjson schema_postflight_status "$schema_postflight_status" \
        --argjson matches_reviewed_stage "$matches_reviewed_stage" \
        '{audited_at:$audited_at,app_id:$app_id,action:$action,target_function:"pushNotificationAction",
          reviewed_plan_digest:$reviewed_plan_digest,
          expected_target_digest:$expected_target_digest,
          actual_target_digest:(if ($actual_target_digest|length)==0 then null else $actual_target_digest end),
          expected_non_target_digest:$expected_non_target_digest,
          actual_non_target_digest:(if ($actual_non_target_digest|length)==0 then null else $actual_non_target_digest end),
          expected_non_target_bytes_digest:$expected_non_target_bytes_digest,
          actual_non_target_bytes_digest:(if ($actual_non_target_bytes_digest|length)==0 then null else $actual_non_target_bytes_digest end),
          expected_schema_digest:$expected_schema_digest,
          actual_schema_digest:(if ($actual_schema_digest|length)==0 then null else $actual_schema_digest end),
          deploy_status:$deploy_status,function_postflight_status:$function_postflight_status,
          schema_postflight_status:$schema_postflight_status,matches_reviewed_stage:$matches_reviewed_stage}' \
        > "$WORK/postflight.json"
    chmod 600 "$WORK/postflight.json"
    install_durable_json "$WORK/postflight.json" "$attempt_dir/postflight.json" "$attempt_dir" postflight
    install_durable_json "$WORK/postflight.json" "$EVIDENCE_DIR/latest-postflight.json" "$EVIDENCE_DIR" latest-postflight

    [[ "$matches_reviewed_stage" == true ]] || {
        echo "pushNotificationAction recovery did not reach the verified state; inspect $attempt_dir/postflight.json." >&2
        exit 70
    }
    echo "pushNotificationAction recovery deployment verified."
}

mkdir -p "$CUTOVER_DIR" "$RECOVERY_DIR" "$EVIDENCE_DIR"
secure_private_directory "$CUTOVER_DIR"
secure_private_directory "$RECOVERY_DIR"
secure_private_directory "$EVIDENCE_DIR"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another pushNotificationAction recovery prepare/deploy is active." >&2
    exit 75
fi
LOCK_HELD=1
secure_private_directory "$LOCK_DIR"
base44_cli whoami >/dev/null

if [[ "$MODE" == "prepare" ]]; then
    prepare_plan
else
    deploy_reviewed_plan
fi
