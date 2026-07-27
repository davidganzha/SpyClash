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
FIXED_STAGE="$CUTOVER_DIR/notification-step-a-schema"
EVIDENCE_DIR="$CUTOVER_DIR/evidence/notification-step-a-schema"
STEP_ZERO_STAGE="$CUTOVER_DIR/notification-step-0-schema-repair"
STEP_ZERO_MANIFEST="$STEP_ZERO_STAGE/manifest.json"
STEP_ZERO_POSTFLIGHT="$CUTOVER_DIR/evidence/notification-step-0-schema-repair/latest-postflight.json"
LOCK_DIR="$CUTOVER_DIR/.notification-step-a-schema.lock"
PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spyclash-notification-schema.XXXXXX")"
STAGE="$WORK/candidate-stage"
REMOTE="$WORK/remote.json"
JIT_REMOTE="$WORK/jit-remote.json"
POST_REMOTE="$WORK/postflight-remote.json"
REVIEWED_MANIFEST="$WORK/reviewed-manifest.json"
AUTH_FILE="$HOME/.base44/auth/auth.json"
LOCK_HELD=0
PRODUCTION_LOCK_HELD=0
MODE="prepare"
EXPECTED_PLAN_DIGEST=""
EXPECTED_LIVE_COUNT=20
EXPECTED_TARGET_COUNT=22
EXPECTED_CUSTOM_ENTITY_COUNT=21
ACTION="SPYCLASH_NOTIFICATION_STEP_A_SCHEMA"
EXPECTED_STEP_ZERO_ACTION="SPYCLASH_NOTIFICATION_STEP_0_SCHEMA_REPAIR"
EXPECTED_STEP_ZERO_SCHEMA_DIGEST="f09988b0e0b5c5e93a55c4738e47ba20b160bd536ee0cacd65337fa05fd674af"
STEP_ZERO_PLAN_DIGEST=""
STEP_ZERO_POSTFLIGHT_DIGEST=""

LIVE_ENTITIES=(
    AiGenerationQuota AiWordPackCacheVariant AiWordPackRequestResult
    AppleSignInCredential BillingIdentityLifecycle CommunityReport Entitlement
    Friendship GameHistory GameRoom LiveActivityRegistration MembershipGrant
    ProfileComment PushDeviceRegistration PushNotificationEvent RoomInvite User
    WordPack AiGenerationUsage AppStoreAccount
)
TARGET_ENTITIES=(
    AiGenerationQuota AiWordPackCacheVariant AiWordPackRequestResult
    AppleSignInCredential BillingIdentityLifecycle CommunityReport Entitlement
    Friendship GameHistory GameRoom LiveActivityRegistration MembershipGrant
    NotificationAnnouncement NotificationReadReceipt ProfileComment
    PushDeviceRegistration PushNotificationEvent RoomInvite User WordPack
    AiGenerationUsage AppStoreAccount
)
ADDED_ENTITIES=(NotificationAnnouncement NotificationReadReceipt)
CHANGED_ENTITIES=(PushDeviceRegistration PushNotificationEvent User)

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
if [[ -n "${BASE44_NOTIFICATION_SCHEMA_STAGE_DIR+x}" ]]; then
    echo "The notification schema stage path is fixed at $FIXED_STAGE." >&2
    exit 64
fi
[[ "$ROOT" != "/" && "$FIXED_STAGE" == "$ROOT/.base44-cutover/notification-step-a-schema" ]] || exit 65
[[ ! -L "$CUTOVER_DIR" && ! -L "$FIXED_STAGE" ]] || {
    echo "Cutover paths must not be symbolic links." >&2
    exit 65
}

for command in awk basename chmod cmp comm cp curl date diff env find grep head id jq \
    mkdir mktemp mv npx rm rmdir sed shasum sort stat sync tr uname wc; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing required command: $command" >&2
        exit 69
    }
done

cleanup() {
    case "$WORK" in
        "${TMPDIR:-/tmp}"/spyclash-notification-schema.*) rm -rf -- "$WORK" ;;
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

private_mode() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

private_links() {
    stat -f '%l' "$1" 2>/dev/null || stat -c '%h' "$1"
}

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
    [[ -f "$AUTH_FILE" && ! -L "$AUTH_FILE" && -O "$AUTH_FILE" ]] || {
        echo "Base44 authentication must be a regular user-owned file." >&2
        return 77
    }
    [[ "$(private_mode "$AUTH_FILE")" == 600 ]] || {
        echo "Base44 authentication must have mode 600." >&2
        return 77
    }
}

fetch_remote_schema() {
    local output=$1 curl_config="$WORK/curl.$RANDOM.conf" access_token status
    check_auth_file || return $?
    base44_cli whoami >/dev/null || return $?
    check_auth_file || return $?
    access_token="$(jq -er '.accessToken' "$AUTH_FILE")" || return $?
    printf 'header = "Authorization: Bearer %s"\n' "$access_token" > "$curl_config"
    unset access_token
    curl -fsS --connect-timeout 10 --max-time 60 --retry 2 \
        --config "$curl_config" \
        "https://app.base44.com/api/apps/$APP_ID/entity-schemas" > "$output"
    status=$?
    rm -f -- "$curl_config"
    return "$status"
}

validate_remote_schema() {
    jq -e '
      .total == (.schemas | length) and .total > 0 and
      ([.schemas[].entity_name] | unique | length) == .total and
      all(.schemas[];
        (.entity_name | type == "string" and test("^[A-Za-z0-9-]+$")) and
        (.entity_schema | type == "object") and
        .entity_schema.name == .entity_name)
    ' "$1" >/dev/null
}

write_expected_names() {
    local output=$1
    shift
    printf '%s\n' "$@" | LC_ALL=C sort > "$output"
}

remote_names() {
    jq -r '.schemas[].entity_name' "$1" | LC_ALL=C sort > "$2"
}

local_entity_file() {
    local wanted=$1 file name
    for file in "$ROOT"/base44/entities/*.jsonc; do
        name="$(jq -er '.name' "$file")"
        if [[ "$name" == "$wanted" ]]; then
            printf '%s\n' "$file"
            return 0
        fi
    done
    echo "Missing local entity schema: $wanted" >&2
    return 66
}

validate_local_inventory() {
    local expected="$WORK/local-expected.txt" actual="$WORK/local-actual.txt" file
    write_expected_names "$expected" "${TARGET_ENTITIES[@]}"
    : > "$actual"
    for file in "$ROOT"/base44/entities/*.jsonc; do
        jq -er '.name' "$file" >> "$actual"
    done
    LC_ALL=C sort -o "$actual" "$actual"
    [[ "$(wc -l < "$actual" | tr -d ' ')" -eq "$EXPECTED_TARGET_COUNT" ]] || return 65
    cmp -s "$expected" "$actual" || {
        echo "Local entity inventory is not the exact reviewed 22-entity set." >&2
        diff -u "$expected" "$actual" >&2 || true
        return 65
    }
}

schema_remote_digest() {
    jq -S '[.schemas | sort_by(.entity_name)[] | {entity_name,entity_schema}]' "$1" |
        shasum -a 256 | awk '{print $1}'
}

schema_remote_set_digest() {
    jq -S '[.schemas[].entity_schema] | sort_by(.name)' "$1" |
        shasum -a 256 | awk '{print $1}'
}

schema_stage_digest() {
    jq -S -s 'sort_by(.name)' "$1"/base44/entities/*.jsonc |
        shasum -a 256 | awk '{print $1}'
}

verify_step_zero_boundary() {
    local remote=$1 expected="$WORK/step-zero-expected.txt" actual="$WORK/step-zero-actual.txt"
    local plan_digest current_digest
    [[ -f "$STEP_ZERO_MANIFEST" && -f "$STEP_ZERO_POSTFLIGHT" &&
       ! -L "$STEP_ZERO_MANIFEST" && ! -L "$STEP_ZERO_POSTFLIGHT" ]] || {
        echo "Step A requires a verified Step 0 schema repair postflight." >&2
        return 77
    }
    secure_private_json_file "$STEP_ZERO_MANIFEST" || return 65
    secure_private_json_file "$STEP_ZERO_POSTFLIGHT" || return 65
    plan_digest="$(jq -er --arg app_id "$APP_ID" --arg action "$EXPECTED_STEP_ZERO_ACTION" \
        --arg digest "$EXPECTED_STEP_ZERO_SCHEMA_DIGEST" '
      select(.app_id == $app_id and .action == $action and .step == "0" and
        .live_count == 20 and .target_count == 20 and .target_custom_entity_count == 19 and
        .target_schema_digest == $digest and
        .delta.entity_additions == [] and .delta.entity_deletions == [] and
        .delta.property_removals == [] and
        .delta.rls_changes == ["AiGenerationQuota","GameHistory","GameRoom","WordPack"] and
        (.plan_digest | test("^[0-9a-f]{64}$"))) |
      .plan_digest' "$STEP_ZERO_MANIFEST")" || {
        echo "Step 0 manifest does not prove the reviewed final baseline." >&2
        return 77
    }
    jq -e --arg app_id "$APP_ID" --arg plan_digest "$plan_digest" \
        --arg digest "$EXPECTED_STEP_ZERO_SCHEMA_DIGEST" '
      .app_id == $app_id and .reviewed_plan_digest == $plan_digest and
      .expected_schema_digest == $digest and .actual_schema_digest == $digest and
      .expected_count == 20 and .actual_count == 20 and .push_status == 0 and
      .postflight_fetch_status == 0 and .postflight_schema_status == 0 and
      .admin_write_boundary == true and .matches_reviewed_stage == true
    ' "$STEP_ZERO_POSTFLIGHT" >/dev/null || {
        echo "Step 0 postflight does not prove the reviewed final baseline." >&2
        return 77
    }
    validate_remote_schema "$remote" || return 65
    [[ "$(jq -r '.total' "$remote")" -eq "$EXPECTED_LIVE_COUNT" ]] || return 77
    write_expected_names "$expected" "${LIVE_ENTITIES[@]}"
    remote_names "$remote" "$actual"
    cmp -s "$expected" "$actual" || {
        echo "Current schema inventory differs from the verified Step 0 baseline." >&2
        return 77
    }
    current_digest="$(schema_remote_set_digest "$remote")"
    [[ "$current_digest" == "$EXPECTED_STEP_ZERO_SCHEMA_DIGEST" ]] || {
        echo "Current schema bytes differ from the verified Step 0 baseline." >&2
        return 77
    }
    STEP_ZERO_PLAN_DIGEST="$plan_digest"
    STEP_ZERO_POSTFLIGHT_DIGEST="$(shasum -a 256 "$STEP_ZERO_POSTFLIGHT" | awk '{print $1}')"
}

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

local_inputs_digest() {
    local records="$WORK/local-inputs-$RANDOM.txt" name file
    : > "$records"
    for name in "${ADDED_ENTITIES[@]}" "${CHANGED_ENTITIES[@]}"; do
        file="$(local_entity_file "$name")"
        printf '%s\t%s\n' "$name" "$(shasum -a 256 "$file" | awk '{print $1}')" >> "$records"
    done
    printf 'config\t%s\n' "$(shasum -a 256 "$ROOT/base44/config.jsonc" | awk '{print $1}')" >> "$records"
    LC_ALL=C sort -o "$records" "$records"
    shasum -a 256 "$records" | awk '{print $1}'
}

copy_remote_to_stage() {
    local remote=$1 row name
    mkdir -p "$STAGE/base44/entities"
    cp "$ROOT/base44/config.jsonc" "$STAGE/base44/config.jsonc"
    cp "$APP_FILE" "$STAGE/base44/.app.jsonc"
    while IFS= read -r row; do
        name="$(printf '%s' "$row" | jq -er '.entity_name')"
        printf '%s' "$row" | jq '.entity_schema' > "$STAGE/base44/entities/$name.jsonc"
    done < <(jq -c '.schemas[]' "$remote")
}

add_property_from_local() {
    local entity=$1 property=$2 staged local_file expected next
    staged="$STAGE/base44/entities/$entity.jsonc"
    local_file="$(local_entity_file "$entity")"
    expected="$(jq -c --arg property "$property" '.properties[$property] // empty' "$local_file")"
    [[ -n "$expected" ]] || { echo "Missing canonical property $entity.$property" >&2; return 66; }
    if jq -e --arg property "$property" '.properties | has($property)' "$staged" >/dev/null; then
        jq -e --arg property "$property" --argjson expected "$expected" \
            '.properties[$property] == $expected' "$staged" >/dev/null || {
            echo "Live property $entity.$property conflicts with the reviewed target." >&2
            return 65
        }
        return 0
    fi
    next="$WORK/$entity-$property.json"
    jq --arg property "$property" --argjson expected "$expected" \
        '.properties[$property] = $expected' "$staged" > "$next"
    mv "$next" "$staged"
}

extend_enum_from_local() {
    local entity=$1 property=$2 value=$3 staged local_file next
    staged="$STAGE/base44/entities/$entity.jsonc"
    local_file="$(local_entity_file "$entity")"
    jq -e --arg property "$property" --arg value "$value" \
        '.properties[$property].enum | index($value) != null' "$local_file" >/dev/null || {
        echo "Canonical enum does not contain $entity.$property=$value" >&2
        return 66
    }
    jq -e --arg property "$property" '.properties[$property].enum | type == "array"' "$staged" >/dev/null || {
        echo "Live enum is missing for $entity.$property" >&2
        return 65
    }
    if jq -e --arg property "$property" --arg value "$value" \
        '.properties[$property].enum | index($value) != null' "$staged" >/dev/null; then
        return 0
    fi
    next="$WORK/$entity-$property-enum.json"
    jq --arg property "$property" --arg value "$value" \
        '.properties[$property].enum += [$value]' "$staged" > "$next"
    mv "$next" "$staged"
}

prepare_candidate() {
    local remote=$1 expected_live="$WORK/expected-live.txt" actual_live="$WORK/actual-live.txt"
    local expected_target="$WORK/expected-target.txt" actual_target="$WORK/actual-target.txt"
    local name source

    validate_remote_schema "$remote" || {
        echo "Remote schema response is incomplete or ambiguous." >&2
        return 65
    }
    remote_names "$remote" "$actual_live"
    write_expected_names "$expected_live" "${LIVE_ENTITIES[@]}"
    [[ "$(jq -r '.total' "$remote")" -eq "$EXPECTED_LIVE_COUNT" ]] && cmp -s "$expected_live" "$actual_live" || {
        echo "Production schema is not the exact reviewed 20-entity baseline." >&2
        diff -u "$expected_live" "$actual_live" >&2 || true
        return 77
    }
    validate_local_inventory || return $?
    rm -rf -- "$STAGE"
    copy_remote_to_stage "$remote"

    for name in "${ADDED_ENTITIES[@]}"; do
        source="$(local_entity_file "$name")"
        jq -e '.rls.create.user_condition.role == "admin" and
          .rls.update.user_condition.role == "admin" and
          .rls.delete.user_condition.role == "admin"' "$source" >/dev/null || {
            echo "New entity $name is not admin-write-only." >&2
            return 65
        }
        cp "$source" "$STAGE/base44/entities/$name.jsonc"
    done

    add_property_from_local PushDeviceRegistration announcements_enabled
    extend_enum_from_local PushNotificationEvent event_type global_announcement
    extend_enum_from_local PushNotificationEvent source_type notification_announcement
    for name in announcement_id inbox_kind inbox_importance inbox_title_en inbox_body_en \
        inbox_title_ru inbox_body_ru inbox_title_es inbox_body_es inbox_action_deep_link \
        inbox_published_at inbox_projection_version inbox_visible inbox_committed_at; do
        add_property_from_local PushNotificationEvent "$name"
    done
    add_property_from_local User radar_invite_policy

    write_expected_names "$expected_target" "${TARGET_ENTITIES[@]}"
    for source in "$STAGE"/base44/entities/*.jsonc; do jq -er '.name' "$source"; done |
        LC_ALL=C sort > "$actual_target"
    [[ "$(wc -l < "$actual_target" | tr -d ' ')" -eq "$EXPECTED_TARGET_COUNT" ]] &&
        cmp -s "$expected_target" "$actual_target" || {
        echo "Candidate is not the exact reviewed 22-entity target." >&2
        diff -u "$expected_target" "$actual_target" >&2 || true
        return 65
    }
    jq -s -e --argjson expected "$EXPECTED_CUSTOM_ENTITY_COUNT" '
      [.[] | select(.name != "User") |
        (.rls.create.user_condition.role == "admin" and
         .rls.update.user_condition.role == "admin" and
         .rls.delete.user_condition.role == "admin")
      ] as $checks |
      ($checks | length) == $expected and all($checks[]; . == true)
    ' "$STAGE"/base44/entities/*.jsonc >/dev/null || {
        echo "Candidate does not retain the admin-only direct-write boundary for all 21 custom entities." >&2
        jq -s -r '
          .[] | select(.name != "User") |
          select((.rls.create.user_condition.role == "admin" and
            .rls.update.user_condition.role == "admin" and
            .rls.delete.user_condition.role == "admin") | not) |
          "Non-admin direct-write boundary: \(.name)"
        ' "$STAGE"/base44/entities/*.jsonc >&2
        return 65
    }
}

write_delta_and_assert() {
    local remote=$1 staged="$WORK/staged-schemas.json" output=$2
    jq -S -s 'sort_by(.name)' "$STAGE"/base44/entities/*.jsonc > "$staged"
    jq -S -n --slurpfile remote "$remote" --slurpfile staged "$staged" '
      ($remote[0].schemas | map({key:.entity_name,value:.entity_schema}) | from_entries) as $live |
      ($staged[0] | map({key:.name,value:.}) | from_entries) as $target |
      {
        additions: [($target | keys[]) as $name | select($live[$name] == null) | $name],
        deletions: [($live | keys[]) as $name | select($target[$name] == null) | $name],
        changes: [($target | keys[]) as $name |
          select($live[$name] != null and $live[$name] != $target[$name]) | $name],
        unchanged: [($target | keys[]) as $name |
          select($live[$name] != null and $live[$name] == $target[$name]) | $name],
        details: [($target | keys[]) as $name | ($live[$name] // null) as $before |
          select($before == null or $before != $target[$name]) |
          {
            entity:$name,
            operation:(if $before == null then "add" else "change" end),
            property_additions:(if $before == null then ($target[$name].properties // {} | keys)
              else (($target[$name].properties // {} | keys) - ($before.properties // {} | keys)) end),
            property_removals:(if $before == null then []
              else (($before.properties // {} | keys) - ($target[$name].properties // {} | keys)) end),
            changed_existing_properties:(if $before == null then [] else
              [($target[$name].properties // {} | keys[]) as $key |
                select(($before.properties // {} | has($key)) and
                  $before.properties[$key] != $target[$name].properties[$key]) | $key] end),
            rls_changed:(if $before == null then false else
              (($before.rls // null) != ($target[$name].rls // null)) end)
          }]
      }
    ' > "$output"
    jq -e '
      .additions == ["NotificationAnnouncement","NotificationReadReceipt"] and
      .deletions == [] and
      .changes == ["PushDeviceRegistration","PushNotificationEvent","User"] and
      (.unchanged | length) == 17 and
      all(.details[]; (.property_removals | length) == 0) and
      all(.details[]; .rls_changed == false) and
      ([.details[] | select(.entity == "PushDeviceRegistration") |
        .changed_existing_properties] == [[]]) and
      ([.details[] | select(.entity == "PushNotificationEvent") |
        (.changed_existing_properties - ["event_type","source_type"])] == [[]]) and
      ([.details[] | select(.entity == "User") |
        .property_additions] == [["radar_invite_policy"]]) and
      ([.details[] | select(.entity == "User") |
        .changed_existing_properties] == [[]])
    ' "$output" >/dev/null || {
        echo "Candidate contains a deletion, an unreviewed entity change, or a non-additive property change." >&2
        return 65
    }
}

mkdir -p "$CUTOVER_DIR"
secure_private_directory "$CUTOVER_DIR"
if [[ "$MODE" == "deploy" ]]; then
    acquire_production_lock
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another notification schema prepare/deploy is active." >&2
    exit 75
fi
LOCK_HELD=1
mkdir -p "$CUTOVER_DIR/evidence" "$EVIDENCE_DIR"
secure_private_directory "$LOCK_DIR"
secure_private_directory "$CUTOVER_DIR/evidence"
secure_private_directory "$EVIDENCE_DIR"

if [[ "$MODE" == "deploy" ]]; then
    [[ -f "$FIXED_STAGE/manifest.json" && ! -L "$FIXED_STAGE/manifest.json" ]] || {
        echo "No fixed reviewed Step A stage exists; run the read-only prepare first." >&2
        exit 77
    }
    secure_private_tree "$FIXED_STAGE"
    secure_private_json_file "$FIXED_STAGE/manifest.json"
    cp "$FIXED_STAGE/manifest.json" "$REVIEWED_MANIFEST"
    secure_private_json_file "$REVIEWED_MANIFEST"
fi

fetch_remote_schema "$REMOTE" || { echo "Unable to fetch Production schema." >&2; exit 70; }
verify_step_zero_boundary "$REMOTE" || exit $?
prepare_candidate "$REMOTE"
DELTA="$STAGE/schema-delta.json"
write_delta_and_assert "$REMOTE" "$DELTA"
remote_digest="$(schema_remote_digest "$REMOTE")"
target_digest="$(schema_stage_digest "$STAGE")"
stage_bytes_digest="$(tree_bytes_digest "$STAGE/base44")"
inputs_digest="$(local_inputs_digest)"
delta_digest="$(shasum -a 256 "$DELTA" | awk '{print $1}')"
plan_input="$STAGE/plan-input.json"
jq -S -n \
    --arg step "A" --arg action "$ACTION" --arg app_id "$APP_ID" \
    --arg remote_digest "$remote_digest" --arg target_digest "$target_digest" \
    --arg step_zero_plan_digest "$STEP_ZERO_PLAN_DIGEST" \
    --arg step_zero_postflight_digest "$STEP_ZERO_POSTFLIGHT_DIGEST" \
    --arg step_zero_schema_digest "$EXPECTED_STEP_ZERO_SCHEMA_DIGEST" \
    --arg stage_bytes_digest "$stage_bytes_digest" --arg local_inputs_digest "$inputs_digest" \
    --arg delta_digest "$delta_digest" \
    --argjson live_count "$EXPECTED_LIVE_COUNT" --argjson target_count "$EXPECTED_TARGET_COUNT" \
    --argjson custom_count "$EXPECTED_CUSTOM_ENTITY_COUNT" \
    --slurpfile delta "$DELTA" \
    '{step:$step,action:$action,app_id:$app_id,live_count:$live_count,target_count:$target_count,
      target_custom_entity_count:$custom_count,
      step_zero_plan_digest:$step_zero_plan_digest,
      step_zero_postflight_digest:$step_zero_postflight_digest,
      step_zero_schema_digest:$step_zero_schema_digest,
      remote_digest:$remote_digest,target_schema_digest:$target_digest,
      stage_bytes_digest:$stage_bytes_digest,local_inputs_digest:$local_inputs_digest,
      schema_delta_digest:$delta_digest,delta:$delta[0]}' > "$plan_input"
plan_digest="$(shasum -a 256 "$plan_input" | awk '{print $1}')"
jq -S --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg plan_digest "$plan_digest" \
    '. + {prepared_at:$prepared_at,plan_digest:$plan_digest}' "$plan_input" > "$STAGE/manifest.json"

if [[ "$MODE" == "prepare" ]]; then
    rm -rf -- "$FIXED_STAGE"
    mv "$STAGE" "$FIXED_STAGE"
    secure_private_tree "$FIXED_STAGE"
    echo "Prepared read-only notification Step A schema plan: $FIXED_STAGE"
    echo "Live entities: $EXPECTED_LIVE_COUNT; target entities: $EXPECTED_TARGET_COUNT"
    echo "Plan digest: $plan_digest"
    echo "No Base44 mutation was made."
    exit 0
fi

reviewed_plan_digest="$(jq -er '.plan_digest' "$REVIEWED_MANIFEST")"
reviewed_stage_digest="$(jq -er '.stage_bytes_digest' "$REVIEWED_MANIFEST")"
reviewed_inputs_digest="$(jq -er '.local_inputs_digest' "$REVIEWED_MANIFEST")"
reviewed_remote_digest="$(jq -er '.remote_digest' "$REVIEWED_MANIFEST")"
reviewed_step_zero_plan_digest="$(jq -er '.step_zero_plan_digest' "$REVIEWED_MANIFEST")"
reviewed_step_zero_postflight_digest="$(jq -er '.step_zero_postflight_digest' "$REVIEWED_MANIFEST")"
reviewed_manifest_digest="$(shasum -a 256 "$REVIEWED_MANIFEST" | awk '{print $1}')"
if [[ "$EXPECTED_PLAN_DIGEST" != "$reviewed_plan_digest" || "$plan_digest" != "$reviewed_plan_digest" ||
      "$stage_bytes_digest" != "$reviewed_stage_digest" || "$inputs_digest" != "$reviewed_inputs_digest" ||
      "$remote_digest" != "$reviewed_remote_digest" ]]; then
    echo "Step A no longer reproduces the exact reviewed plan." >&2
    exit 77
fi
diff -qr "$STAGE/base44" "$FIXED_STAGE/base44" >/dev/null || {
    echo "Step A candidate bytes differ from the reviewed fixed stage." >&2
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
[[ "${BASE44_CONFIRM_NOTIFICATION_SCHEMA_PLAN_DIGEST:-}" == "$reviewed_plan_digest" ]] || {
    echo "Set BASE44_CONFIRM_NOTIFICATION_SCHEMA_PLAN_DIGEST to the reviewed plan digest." >&2
    exit 77
}

fetch_remote_schema "$JIT_REMOTE" || exit 70
verify_step_zero_boundary "$JIT_REMOTE" || exit $?
[[ "$STEP_ZERO_PLAN_DIGEST" == "$reviewed_step_zero_plan_digest" &&
    "$STEP_ZERO_POSTFLIGHT_DIGEST" == "$reviewed_step_zero_postflight_digest" ]] || {
    echo "Verified Step 0 evidence changed after Step A review." >&2
    exit 77
}
[[ "$(schema_remote_digest "$JIT_REMOTE")" == "$reviewed_remote_digest" ]] || {
    echo "Production schema changed after review; refusing Step A." >&2
    exit 77
}
[[ "$(tree_bytes_digest "$FIXED_STAGE/base44")" == "$reviewed_stage_digest" &&
    "$(local_inputs_digest)" == "$reviewed_inputs_digest" ]] || {
    echo "Reviewed stage or source inputs changed immediately before Step A." >&2
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
    --arg jit_remote_digest "$reviewed_remote_digest" \
    '{attempted_at:$attempted_at,app_id:$app_id,action:$action,
      reviewed_plan_digest:$reviewed_plan_digest,reviewed_manifest_digest:$reviewed_manifest_digest,
      jit_remote_digest:$jit_remote_digest,status:"mutation-started-postflight-required",
      postflight_required:true}' > "$WORK/attempt.json"
chmod 600 "$WORK/attempt.json"
install_durable_json "$WORK/attempt.json" "$attempt_dir/attempt.json" "$attempt_dir" attempt

push_status=0
set +e
(cd "$FIXED_STAGE" && base44_cli entities push)
push_status=$?
set -e

postflight_fetch_status=0
postflight_schema_status=0
actual_count=0
actual_digest=""
actual_names_match=false
set +e
fetch_remote_schema "$POST_REMOTE"
postflight_fetch_status=$?
if [[ "$postflight_fetch_status" -eq 0 ]]; then
    validate_remote_schema "$POST_REMOTE"
    postflight_schema_status=$?
    if [[ "$postflight_schema_status" -eq 0 ]]; then
        actual_count="$(jq -r '.total' "$POST_REMOTE")"
        actual_digest="$(schema_remote_set_digest "$POST_REMOTE")"
        remote_names "$POST_REMOTE" "$WORK/post-names.txt"
        write_expected_names "$WORK/expected-post-names.txt" "${TARGET_ENTITIES[@]}"
        cmp -s "$WORK/expected-post-names.txt" "$WORK/post-names.txt" && actual_names_match=true
    fi
fi
set -e
matches_reviewed_stage=false
if [[ "$push_status" -eq 0 && "$postflight_fetch_status" -eq 0 && "$postflight_schema_status" -eq 0 &&
      "$actual_count" -eq "$EXPECTED_TARGET_COUNT" && "$actual_digest" == "$target_digest" &&
      "$actual_names_match" == true ]]; then
    matches_reviewed_stage=true
fi
jq -n --arg audited_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg app_id "$APP_ID" \
    --arg reviewed_plan_digest "$reviewed_plan_digest" --arg expected_schema_digest "$target_digest" \
    --arg actual_schema_digest "$actual_digest" --argjson expected_count "$EXPECTED_TARGET_COUNT" \
    --argjson actual_count "$actual_count" --argjson push_status "$push_status" \
    --argjson postflight_fetch_status "$postflight_fetch_status" \
    --argjson postflight_schema_status "$postflight_schema_status" \
    --argjson names_match "$actual_names_match" --argjson matches_reviewed_stage "$matches_reviewed_stage" \
    '{audited_at:$audited_at,app_id:$app_id,reviewed_plan_digest:$reviewed_plan_digest,
      expected_schema_digest:$expected_schema_digest,
      actual_schema_digest:(if ($actual_schema_digest|length)==0 then null else $actual_schema_digest end),
      expected_count:$expected_count,actual_count:$actual_count,push_status:$push_status,
      postflight_fetch_status:$postflight_fetch_status,postflight_schema_status:$postflight_schema_status,
      names_match:$names_match,matches_reviewed_stage:$matches_reviewed_stage}' > "$WORK/postflight.json"
chmod 600 "$WORK/postflight.json"
install_durable_json "$WORK/postflight.json" "$attempt_dir/postflight.json" "$attempt_dir" postflight
install_durable_json "$WORK/postflight.json" "$EVIDENCE_DIR/latest-postflight.json" "$EVIDENCE_DIR" latest-postflight

[[ "$matches_reviewed_stage" == true ]] || {
    echo "Step A did not reach the fully verified state; inspect $attempt_dir/postflight.json." >&2
    exit 70
}
echo "Notification Step A schema deployment verified."
