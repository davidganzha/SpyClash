#!/bin/bash

set -euo pipefail
umask 077

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
APP_FILE="$ROOT/base44/.app.jsonc"
EXPECTED_APP_ID="69a0e57fa939f578082f8091"
APP_ID="$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_FILE" | head -n 1)"
[[ "$APP_ID" == "$EXPECTED_APP_ID" ]] || {
    echo "Repository app id is not the reviewed SpyClash app $EXPECTED_APP_ID." >&2
    exit 77
}

CUTOVER_DIR="$ROOT/.base44-cutover"
FIXED_STAGE="$CUTOVER_DIR/notification-step-b-functions"
EVIDENCE_DIR="$CUTOVER_DIR/evidence/notification-step-b-functions"
SCHEMA_STAGE="$CUTOVER_DIR/notification-step-a-schema"
SCHEMA_MANIFEST="$SCHEMA_STAGE/manifest.json"
SCHEMA_POSTFLIGHT="$CUTOVER_DIR/evidence/notification-step-a-schema/latest-postflight.json"
LOCK_DIR="$CUTOVER_DIR/.notification-step-b-functions.lock"
PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spyclash-notification-functions.XXXXXX")"
STAGE="$WORK/candidate-stage"
DEPLOY_STAGE="$STAGE/deploy"
REMOTE_BEFORE="$WORK/remote-before"
REMOTE_JIT="$WORK/remote-jit"
REMOTE_AFTER="$WORK/remote-after"
SCHEMA_REMOTE="$WORK/schema-remote.json"
SCHEMA_JIT="$WORK/schema-jit.json"
SCHEMA_POST="$WORK/schema-post.json"
REVIEWED_MANIFEST="$WORK/reviewed-manifest.json"
AUTH_FILE="$HOME/.base44/auth/auth.json"
LOCK_HELD=0
PRODUCTION_LOCK_HELD=0
MODE="prepare"
EXPECTED_PLAN_DIGEST=""
EXPECTED_LIVE_FUNCTION_COUNT=16
EXPECTED_TARGET_FUNCTION_COUNT=17
EXPECTED_SCHEMA_COUNT=22
ACTION="SPYCLASH_NOTIFICATION_STEP_B_FUNCTIONS"

LIVE_FUNCTIONS=(
    advanceRound app-store-entitlement appleAuthBroker appleAuthCallback
    autoRegisterUser checkSubscription communityAction createCheckout
    deleteAccount gameRoomAction generateWordPack googleAuthCallback
    mobileAuthCallback pushNotificationAction stripe-entitlement-webhook
    wordPackAction
)
TARGET_FUNCTIONS=(
    advanceRound app-store-entitlement appleAuthBroker appleAuthCallback
    autoRegisterUser checkSubscription communityAction createCheckout
    deleteAccount gameRoomAction generateWordPack googleAuthCallback
    mobileAuthCallback notificationAction pushNotificationAction
    stripe-entitlement-webhook wordPackAction
)
ADDED_FUNCTIONS=(notificationAction)
CHANGED_FUNCTIONS=(communityAction deleteAccount gameRoomAction pushNotificationAction)
DEPLOY_FUNCTIONS=(notificationAction communityAction gameRoomAction deleteAccount pushNotificationAction)
UNCHANGED_FUNCTIONS=(
    advanceRound app-store-entitlement appleAuthBroker appleAuthCallback
    autoRegisterUser checkSubscription createCheckout generateWordPack
    googleAuthCallback mobileAuthCallback stripe-entitlement-webhook wordPackAction
)
TARGET_SCHEMA_ENTITIES=(
    AiGenerationQuota AiWordPackCacheVariant AiWordPackRequestResult
    AppleSignInCredential BillingIdentityLifecycle CommunityReport Entitlement
    Friendship GameHistory GameRoom LiveActivityRegistration MembershipGrant
    NotificationAnnouncement NotificationReadReceipt ProfileComment
    PushDeviceRegistration PushNotificationEvent RoomInvite User WordPack
    AiGenerationUsage AppStoreAccount
)

usage() {
    echo "Usage: $0 [--deploy --plan-digest <sha256>]" >&2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --deploy) MODE="deploy"; shift ;;
        --plan-digest)
            [[ $# -ge 2 ]] || { usage; exit 64; }
            EXPECTED_PLAN_DIGEST="$2"
            shift 2
            ;;
        *) usage; exit 64 ;;
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
if [[ -n "${BASE44_NOTIFICATION_FUNCTION_STAGE_DIR+x}" ]]; then
    echo "The notification function stage path is fixed at $FIXED_STAGE." >&2
    exit 64
fi
[[ "$ROOT" != "/" && "$FIXED_STAGE" == "$ROOT/.base44-cutover/notification-step-b-functions" ]] || exit 65
[[ ! -L "$CUTOVER_DIR" && ! -L "$FIXED_STAGE" ]] || {
    echo "Cutover paths must not be symbolic links." >&2
    exit 65
}

for command in awk basename chmod cmp cp curl date diff env find grep head id jq \
    mkdir mktemp mv npx rm rmdir sed shasum sort stat sync tr uname wc; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing required command: $command" >&2
        exit 69
    }
done

cleanup() {
    case "$WORK" in
        "${TMPDIR:-/tmp}"/spyclash-notification-functions.*) rm -rf -- "$WORK" ;;
    esac
    if [[ "$LOCK_HELD" -eq 1 ]]; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
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
        "$directory/attempt.json"|"$directory/postflight.json"|"$EVIDENCE_DIR/latest-postflight.json") ;;
        *) echo "Unsafe evidence destination: $destination" >&2; return 65 ;;
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

validate_remote_schema() {
    jq -e '
      .total == (.schemas | length) and .total > 0 and
      ([.schemas[].entity_name] | unique | length) == .total and
      all(.schemas[]; (.entity_schema | type == "object") and
        .entity_schema.name == .entity_name)
    ' "$1" >/dev/null
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
    local expected_digest
    [[ -f "$SCHEMA_MANIFEST" && -f "$SCHEMA_POSTFLIGHT" &&
       ! -L "$SCHEMA_MANIFEST" && ! -L "$SCHEMA_POSTFLIGHT" ]] || {
        echo "Step B requires verified Step A schema evidence." >&2
        return 77
    }
    secure_private_json_file "$SCHEMA_MANIFEST" || return 65
    secure_private_json_file "$SCHEMA_POSTFLIGHT" || return 65
    expected_digest="$(jq -er --arg app_id "$APP_ID" '
      select(.app_id == $app_id and .step == "A" and .live_count == 20 and .target_count == 22 and
        .delta.additions == ["NotificationAnnouncement","NotificationReadReceipt"] and
        .delta.deletions == [] and
        .delta.changes == ["PushDeviceRegistration","PushNotificationEvent","User"] and
        (.target_schema_digest | test("^[0-9a-f]{64}$"))) |
      .target_schema_digest' "$SCHEMA_MANIFEST")" || return 77
    jq -e --arg app_id "$APP_ID" --arg digest "$expected_digest" '
      .app_id == $app_id and .expected_count == 22 and .actual_count == 22 and
      .expected_schema_digest == $digest and .actual_schema_digest == $digest and
      .names_match == true and .matches_reviewed_stage == true
    ' "$SCHEMA_POSTFLIGHT" >/dev/null || {
        echo "Step A postflight is absent or does not prove the reviewed schema." >&2
        return 77
    }
    validate_remote_schema "$remote" || return 65
    [[ "$(jq -r '.total' "$remote")" -eq "$EXPECTED_SCHEMA_COUNT" ]] || return 77
    write_expected_names "$expected" "${TARGET_SCHEMA_ENTITIES[@]}"
    jq -r '.schemas[].entity_name' "$remote" | LC_ALL=C sort > "$actual"
    cmp -s "$expected" "$actual" || {
        echo "Current schema inventory differs from the exact Step A target." >&2
        return 77
    }
    [[ "$(schema_set_digest "$remote")" == "$expected_digest" ]] || {
        echo "Current schema bytes differ from verified Step A." >&2
        return 77
    }
    printf '%s\n' "$expected_digest"
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
    local root=$1 name=$2 directory="$root/$name" declared entry count
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
    local root=$1 label=$2
    shift 2
    local expected="$WORK/$label-expected.txt" actual="$WORK/$label-actual.txt" name
    [[ -d "$root" && ! -L "$root" ]] || return 65
    ! find "$root" -mindepth 1 -maxdepth 1 ! -type d -print | grep -q . || return 65
    write_expected_names "$expected" "$@"
    find "$root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | LC_ALL=C sort > "$actual"
    cmp -s "$expected" "$actual" || {
        echo "$label function inventory differs from the exact reviewed set." >&2
        diff -u "$expected" "$actual" >&2 || true
        return 65
    }
    for name in "$@"; do validate_function "$root" "$name" || return $?; done
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
    local root=$1 name=$2 directory="$root/$name" records="$WORK/source-$name-$RANDOM.txt"
    local config="$WORK/config-$name-$RANDOM.json" relative source_digest config_digest effective_digest count
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
    local root=$1 output=$2
    shift 2
    local objects="$WORK/function-objects-$RANDOM.jsonl" name
    : > "$objects"
    for name in "$@"; do function_object "$root" "$name" >> "$objects"; done
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

copy_deploy_functions() {
    local destination=$1 name
    mkdir -p "$destination/base44/functions"
    cp "$ROOT/base44/config.jsonc" "$destination/base44/config.jsonc"
    cp "$APP_FILE" "$destination/base44/.app.jsonc"
    for name in "${DEPLOY_FUNCTIONS[@]}"; do
        cp -R "$ROOT/base44/functions/$name" "$destination/base44/functions/$name"
    done
}

assert_delta_contract() {
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
    jq -e '
      .additions == ["notificationAction"] and .deletions == [] and
      .changes == ["communityAction","deleteAccount","gameRoomAction","pushNotificationAction"] and
      (.unchanged | length) == 12
    ' "$output" >/dev/null || {
        echo "Function plan contains an unreviewed addition or deletion." >&2
        return 65
    }
}

mkdir -p "$CUTOVER_DIR"
secure_private_directory "$CUTOVER_DIR"
if [[ "$MODE" == "deploy" ]]; then acquire_production_lock; fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another notification function prepare/deploy is active." >&2
    exit 75
fi
LOCK_HELD=1
mkdir -p "$CUTOVER_DIR/evidence" "$EVIDENCE_DIR"
secure_private_directory "$LOCK_DIR"
secure_private_directory "$CUTOVER_DIR/evidence"
secure_private_directory "$EVIDENCE_DIR"

if [[ "$MODE" == "deploy" ]]; then
    [[ -f "$FIXED_STAGE/manifest.json" && ! -L "$FIXED_STAGE/manifest.json" ]] || {
        echo "No fixed reviewed Step B stage exists; run the read-only prepare first." >&2
        exit 77
    }
    secure_private_tree "$FIXED_STAGE"
    secure_private_json_file "$FIXED_STAGE/manifest.json"
    cp "$FIXED_STAGE/manifest.json" "$REVIEWED_MANIFEST"
    secure_private_json_file "$REVIEWED_MANIFEST"
fi

base44_cli whoami >/dev/null
validate_inventory "$ROOT/base44/functions" local-target "${TARGET_FUNCTIONS[@]}"
fetch_remote_schema "$SCHEMA_REMOTE" || { echo "Unable to fetch Step B schema prerequisite." >&2; exit 70; }
schema_digest="$(verify_schema_boundary "$SCHEMA_REMOTE")"
pull_remote_functions "$REMOTE_BEFORE"
validate_inventory "$REMOTE_BEFORE/base44/functions" remote-before "${LIVE_FUNCTIONS[@]}"

rm -rf -- "$STAGE"
copy_deploy_functions "$DEPLOY_STAGE"
validate_inventory "$DEPLOY_STAGE/base44/functions" deploy-target "${DEPLOY_FUNCTIONS[@]}"
remote_manifest="$STAGE/remote-functions-before.json"
local_full_manifest="$STAGE/local-functions-all.json"
local_deploy_manifest="$STAGE/local-functions-deploy.json"
unchanged_before_manifest="$STAGE/unchanged-functions-before.json"
delta="$STAGE/function-delta.json"
write_function_manifest "$REMOTE_BEFORE/base44/functions" "$remote_manifest" "${LIVE_FUNCTIONS[@]}"
write_function_manifest "$ROOT/base44/functions" "$local_full_manifest" "${TARGET_FUNCTIONS[@]}"
write_function_manifest "$DEPLOY_STAGE/base44/functions" "$local_deploy_manifest" "${DEPLOY_FUNCTIONS[@]}"
write_function_manifest "$REMOTE_BEFORE/base44/functions" "$unchanged_before_manifest" "${UNCHANGED_FUNCTIONS[@]}"
assert_delta_contract "$remote_manifest" "$local_full_manifest" "$delta"

local_deploy_direct="$WORK/local-deploy-direct.json"
write_function_manifest "$ROOT/base44/functions" "$local_deploy_direct" "${DEPLOY_FUNCTIONS[@]}"
cmp -s "$local_deploy_manifest" "$local_deploy_direct" || {
    echo "Staged function payload differs from checked-in sources." >&2
    exit 65
}

remote_digest="$(json_digest "$remote_manifest")"
local_full_digest="$(json_digest "$local_full_manifest")"
local_deploy_digest="$(json_digest "$local_deploy_manifest")"
unchanged_before_digest="$(json_digest "$unchanged_before_manifest")"
delta_digest="$(json_digest "$delta")"
stage_bytes_digest="$(tree_bytes_digest "$DEPLOY_STAGE/base44")"
schema_manifest_digest="$(json_digest "$SCHEMA_MANIFEST")"
schema_postflight_digest="$(json_digest "$SCHEMA_POSTFLIGHT")"
plan_input="$STAGE/plan-input.json"
jq -S -n --arg step "B" --arg action "$ACTION" --arg app_id "$APP_ID" \
    --arg schema_digest "$schema_digest" --arg schema_manifest_digest "$schema_manifest_digest" \
    --arg schema_postflight_digest "$schema_postflight_digest" --arg remote_digest "$remote_digest" \
    --arg local_full_digest "$local_full_digest" --arg local_deploy_digest "$local_deploy_digest" \
    --arg unchanged_before_digest "$unchanged_before_digest" --arg delta_digest "$delta_digest" \
    --arg stage_bytes_digest "$stage_bytes_digest" \
    --argjson live_count "$EXPECTED_LIVE_FUNCTION_COUNT" --argjson target_count "$EXPECTED_TARGET_FUNCTION_COUNT" \
    --slurpfile delta "$delta" --slurpfile remote "$remote_manifest" \
    --slurpfile deploy "$local_deploy_manifest" --slurpfile unchanged "$unchanged_before_manifest" \
    '{step:$step,action:$action,app_id:$app_id,schema_count:22,schema_digest:$schema_digest,
      schema_manifest_digest:$schema_manifest_digest,schema_postflight_digest:$schema_postflight_digest,
      live_function_count:$live_count,target_function_count:$target_count,
      remote_function_digest:$remote_digest,local_full_function_digest:$local_full_digest,
      local_deploy_function_digest:$local_deploy_digest,unchanged_before_digest:$unchanged_before_digest,
      function_delta_digest:$delta_digest,stage_bytes_digest:$stage_bytes_digest,
      delta:$delta[0],remote_functions:$remote[0],deploy_functions:$deploy[0],
      unchanged_functions_before:$unchanged[0]}' > "$plan_input"
plan_digest="$(json_digest "$plan_input")"
jq -S --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg plan_digest "$plan_digest" \
    '. + {prepared_at:$prepared_at,plan_digest:$plan_digest}' "$plan_input" > "$STAGE/manifest.json"

if [[ "$MODE" == "prepare" ]]; then
    rm -rf -- "$FIXED_STAGE"
    mv "$STAGE" "$FIXED_STAGE"
    secure_private_tree "$FIXED_STAGE"
    echo "Prepared read-only notification Step B function plan: $FIXED_STAGE"
    echo "Live functions: $EXPECTED_LIVE_FUNCTION_COUNT; target functions: $EXPECTED_TARGET_FUNCTION_COUNT"
    echo "Plan digest: $plan_digest"
    echo "No Base44 mutation was made."
    exit 0
fi

reviewed_plan_digest="$(jq -er '.plan_digest' "$REVIEWED_MANIFEST")"
reviewed_remote_digest="$(jq -er '.remote_function_digest' "$REVIEWED_MANIFEST")"
reviewed_local_full_digest="$(jq -er '.local_full_function_digest' "$REVIEWED_MANIFEST")"
reviewed_local_deploy_digest="$(jq -er '.local_deploy_function_digest' "$REVIEWED_MANIFEST")"
reviewed_unchanged_digest="$(jq -er '.unchanged_before_digest' "$REVIEWED_MANIFEST")"
reviewed_stage_digest="$(jq -er '.stage_bytes_digest' "$REVIEWED_MANIFEST")"
reviewed_schema_digest="$(jq -er '.schema_digest' "$REVIEWED_MANIFEST")"
reviewed_schema_manifest_digest="$(jq -er '.schema_manifest_digest' "$REVIEWED_MANIFEST")"
reviewed_schema_postflight_digest="$(jq -er '.schema_postflight_digest' "$REVIEWED_MANIFEST")"
reviewed_manifest_digest="$(json_digest "$REVIEWED_MANIFEST")"
if [[ "$EXPECTED_PLAN_DIGEST" != "$reviewed_plan_digest" || "$plan_digest" != "$reviewed_plan_digest" ||
      "$remote_digest" != "$reviewed_remote_digest" || "$local_full_digest" != "$reviewed_local_full_digest" ||
      "$local_deploy_digest" != "$reviewed_local_deploy_digest" ||
      "$unchanged_before_digest" != "$reviewed_unchanged_digest" ||
      "$stage_bytes_digest" != "$reviewed_stage_digest" || "$schema_digest" != "$reviewed_schema_digest" ]]; then
    echo "Step B no longer reproduces the exact reviewed plan." >&2
    exit 77
fi
diff -qr "$STAGE/deploy/base44" "$FIXED_STAGE/deploy/base44" >/dev/null || {
    echo "Step B candidate bytes differ from the reviewed fixed stage." >&2
    exit 77
}
[[ "${BASE44_CONFIRM_APP_ID:-}" == "$APP_ID" ]] || { echo "Set BASE44_CONFIRM_APP_ID=$APP_ID." >&2; exit 77; }
[[ "${BASE44_CONFIRM_ACTION:-}" == "$ACTION" ]] || { echo "Set BASE44_CONFIRM_ACTION=$ACTION." >&2; exit 77; }
[[ "${BASE44_CONFIRM_NOTIFICATION_FUNCTION_PLAN_DIGEST:-}" == "$reviewed_plan_digest" ]] || {
    echo "Set BASE44_CONFIRM_NOTIFICATION_FUNCTION_PLAN_DIGEST to the reviewed plan digest." >&2
    exit 77
}

fetch_remote_schema "$SCHEMA_JIT" || exit 70
[[ "$(verify_schema_boundary "$SCHEMA_JIT")" == "$reviewed_schema_digest" ]] || {
    echo "Step A schema changed after Step B review." >&2
    exit 77
}
[[ "$(json_digest "$SCHEMA_MANIFEST")" == "$reviewed_schema_manifest_digest" &&
    "$(json_digest "$SCHEMA_POSTFLIGHT")" == "$reviewed_schema_postflight_digest" ]] || {
    echo "Step A evidence changed after Step B review." >&2
    exit 77
}
pull_remote_functions "$REMOTE_JIT"
validate_inventory "$REMOTE_JIT/base44/functions" remote-jit "${LIVE_FUNCTIONS[@]}"
jit_remote_manifest="$WORK/remote-jit.json"
write_function_manifest "$REMOTE_JIT/base44/functions" "$jit_remote_manifest" "${LIVE_FUNCTIONS[@]}"
[[ "$(json_digest "$jit_remote_manifest")" == "$reviewed_remote_digest" ]] || {
    echo "Production functions changed after Step B review." >&2
    exit 77
}
jit_local_full="$WORK/local-full-jit.json"
jit_local_deploy="$WORK/local-deploy-jit.json"
write_function_manifest "$ROOT/base44/functions" "$jit_local_full" "${TARGET_FUNCTIONS[@]}"
write_function_manifest "$ROOT/base44/functions" "$jit_local_deploy" "${DEPLOY_FUNCTIONS[@]}"
[[ "$(json_digest "$jit_local_full")" == "$reviewed_local_full_digest" &&
    "$(json_digest "$jit_local_deploy")" == "$reviewed_local_deploy_digest" &&
    "$(tree_bytes_digest "$FIXED_STAGE/deploy/base44")" == "$reviewed_stage_digest" ]] || {
    echo "Reviewed Step B stage or checked-in sources changed immediately before deployment." >&2
    exit 77
}

attempt_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
attempt_dir="$EVIDENCE_DIR/$attempt_id"
mkdir "$attempt_dir"
secure_private_directory "$attempt_dir"
cp "$REVIEWED_MANIFEST" "$attempt_dir/reviewed-manifest.json"
secure_private_json_file "$attempt_dir/reviewed-manifest.json"
jq -n --arg attempted_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg app_id "$APP_ID" \
    --arg action "$ACTION" --arg reviewed_plan_digest "$reviewed_plan_digest" \
    --arg reviewed_manifest_digest "$reviewed_manifest_digest" \
    --arg jit_remote_function_digest "$reviewed_remote_digest" \
    --arg jit_schema_digest "$reviewed_schema_digest" \
    '{attempted_at:$attempted_at,app_id:$app_id,action:$action,
      reviewed_plan_digest:$reviewed_plan_digest,reviewed_manifest_digest:$reviewed_manifest_digest,
      jit_remote_function_digest:$jit_remote_function_digest,jit_schema_digest:$jit_schema_digest,
      status:"mutation-started-postflight-required",postflight_required:true}' > "$WORK/attempt.json"
chmod 600 "$WORK/attempt.json"
install_durable_json "$WORK/attempt.json" "$attempt_dir/attempt.json" "$attempt_dir" attempt

deploy_status=0
set +e
(cd "$FIXED_STAGE/deploy" && base44_cli functions deploy "${DEPLOY_FUNCTIONS[@]}")
deploy_status=$?
set -e

function_postflight_status=0
schema_postflight_status=0
target_after_digest=""
unchanged_after_digest=""
schema_after_digest=""
set +e
(
    set -e
    pull_remote_functions "$REMOTE_AFTER"
    validate_inventory "$REMOTE_AFTER/base44/functions" remote-after "${TARGET_FUNCTIONS[@]}"
    write_function_manifest "$REMOTE_AFTER/base44/functions" "$WORK/target-after.json" "${DEPLOY_FUNCTIONS[@]}"
    write_function_manifest "$REMOTE_AFTER/base44/functions" "$WORK/unchanged-after.json" "${UNCHANGED_FUNCTIONS[@]}"
)
function_postflight_status=$?
if [[ "$function_postflight_status" -eq 0 ]]; then
    target_after_digest="$(json_digest "$WORK/target-after.json")"
    unchanged_after_digest="$(json_digest "$WORK/unchanged-after.json")"
fi
fetch_remote_schema "$SCHEMA_POST"
schema_postflight_status=$?
if [[ "$schema_postflight_status" -eq 0 ]]; then
    schema_after_digest="$(verify_schema_boundary "$SCHEMA_POST")"
    schema_postflight_status=$?
    if [[ "$schema_postflight_status" -eq 0 ]] &&
       [[ "$(json_digest "$SCHEMA_MANIFEST")" != "$reviewed_schema_manifest_digest" ||
          "$(json_digest "$SCHEMA_POSTFLIGHT")" != "$reviewed_schema_postflight_digest" ]]; then
        schema_postflight_status=77
    fi
fi
set -e

matches_reviewed_stage=false
if [[ "$deploy_status" -eq 0 && "$function_postflight_status" -eq 0 && "$schema_postflight_status" -eq 0 &&
      "$target_after_digest" == "$reviewed_local_deploy_digest" &&
      "$unchanged_after_digest" == "$reviewed_unchanged_digest" &&
      "$schema_after_digest" == "$reviewed_schema_digest" ]]; then
    matches_reviewed_stage=true
fi
jq -n --arg audited_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg app_id "$APP_ID" \
    --arg reviewed_plan_digest "$reviewed_plan_digest" \
    --arg expected_target_digest "$reviewed_local_deploy_digest" --arg actual_target_digest "$target_after_digest" \
    --arg expected_unchanged_digest "$reviewed_unchanged_digest" --arg actual_unchanged_digest "$unchanged_after_digest" \
    --arg expected_schema_digest "$reviewed_schema_digest" --arg actual_schema_digest "$schema_after_digest" \
    --argjson deploy_status "$deploy_status" --argjson function_postflight_status "$function_postflight_status" \
    --argjson schema_postflight_status "$schema_postflight_status" \
    --argjson matches_reviewed_stage "$matches_reviewed_stage" \
    '{audited_at:$audited_at,app_id:$app_id,reviewed_plan_digest:$reviewed_plan_digest,
      expected_target_digest:$expected_target_digest,
      actual_target_digest:(if ($actual_target_digest|length)==0 then null else $actual_target_digest end),
      expected_unchanged_digest:$expected_unchanged_digest,
      actual_unchanged_digest:(if ($actual_unchanged_digest|length)==0 then null else $actual_unchanged_digest end),
      expected_schema_digest:$expected_schema_digest,
      actual_schema_digest:(if ($actual_schema_digest|length)==0 then null else $actual_schema_digest end),
      deploy_status:$deploy_status,function_postflight_status:$function_postflight_status,
      schema_postflight_status:$schema_postflight_status,matches_reviewed_stage:$matches_reviewed_stage}' \
    > "$WORK/postflight.json"
chmod 600 "$WORK/postflight.json"
install_durable_json "$WORK/postflight.json" "$attempt_dir/postflight.json" "$attempt_dir" postflight
install_durable_json "$WORK/postflight.json" "$EVIDENCE_DIR/latest-postflight.json" "$EVIDENCE_DIR" latest-postflight

[[ "$matches_reviewed_stage" == true ]] || {
    echo "Step B did not reach the fully verified state; inspect $attempt_dir/postflight.json." >&2
    exit 70
}
echo "Notification Step B function deployment verified."
