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
FIXED_STAGE="$CUTOVER_DIR/notification-step-0-schema-repair"
EVIDENCE_DIR="$CUTOVER_DIR/evidence/notification-step-0-schema-repair"
HISTORICAL_ATTEMPT="$CUTOVER_DIR/evidence/final-schema/20260726T191333Z-27231"
HISTORICAL_STAGE="$HISTORICAL_ATTEMPT/reviewed-stage"
HISTORICAL_POSTFLIGHT="$CUTOVER_DIR/evidence/final-schema/latest-postflight.json"
LOCK_DIR="$CUTOVER_DIR/.notification-step-0-schema-repair.lock"
PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spyclash-notification-schema-repair.XXXXXX")"
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
EXPECTED_ENTITY_COUNT=20
EXPECTED_CUSTOM_ENTITY_COUNT=19
ACTION="SPYCLASH_NOTIFICATION_STEP_0_SCHEMA_REPAIR"

# These are independent facts. The first is the exact read-only Production
# snapshot observed on 2026-07-27. The second is the exact schema set proven by
# the successful, approved Step 6 postflight on 2026-07-26. Any later drift
# causes a hard stop and requires a new plan instead of reusing this repair.
EXPECTED_DRIFTED_LIVE_SCHEMA_DIGEST="038cd5a3f0989826ac92580272da099979549b15cdfa70353feafed3c20525fb"
EXPECTED_FINAL_SCHEMA_DIGEST="f09988b0e0b5c5e93a55c4738e47ba20b160bd536ee0cacd65337fa05fd674af"
EXPECTED_HISTORICAL_PLAN_DIGEST="a55997ac76faa1c166fc3d68b4df644a961d4f41c04ad9cfd16ef345e4b4127a"
EXPECTED_HISTORICAL_POSTFLIGHT_DIGEST="cc4bb510a212c890b913fa590a7d3c2ac70eaf3a9c10be3213806cae17dca736"

ENTITIES=(
    AiGenerationQuota AiGenerationUsage AiWordPackCacheVariant
    AiWordPackRequestResult AppleSignInCredential AppStoreAccount
    BillingIdentityLifecycle CommunityReport Entitlement Friendship GameHistory
    GameRoom LiveActivityRegistration MembershipGrant ProfileComment
    PushDeviceRegistration PushNotificationEvent RoomInvite User WordPack
)
EXPECTED_CHANGED_ENTITIES=(
    AiGenerationQuota Entitlement GameHistory GameRoom LiveActivityRegistration
    MembershipGrant User WordPack
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
if [[ -n "${BASE44_NOTIFICATION_SCHEMA_REPAIR_STAGE_DIR+x}" ]]; then
    echo "The schema repair stage path is fixed at $FIXED_STAGE." >&2
    exit 64
fi
[[ "$ROOT" != "/" && "$FIXED_STAGE" == "$ROOT/.base44-cutover/notification-step-0-schema-repair" ]] || exit 65
for path in "$CUTOVER_DIR" "$FIXED_STAGE" "$HISTORICAL_ATTEMPT" "$HISTORICAL_STAGE"; do
    [[ ! -L "$path" ]] || {
        echo "Cutover and historical evidence paths must not be symbolic links: $path" >&2
        exit 65
    }
done

for command in awk basename chmod cmp comm cp curl date diff env find grep head id jq \
    mkdir mktemp mv npx rm rmdir sed shasum sort stat sync tr uname wc; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing required command: $command" >&2
        exit 69
    }
done

cleanup() {
    case "$WORK" in
        "${TMPDIR:-/tmp}"/spyclash-notification-schema-repair.*) rm -rf -- "$WORK" ;;
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
        (.entity_name | type == "string" and test("^[A-Za-z0-9]+$")) and
        (.entity_schema | type == "object") and
        .entity_schema.name == .entity_name)
    ' "$1" >/dev/null
}

schema_remote_set_digest() {
    jq -S '[.schemas[].entity_schema] | sort_by(.name)' "$1" |
        shasum -a 256 | awk '{print $1}'
}

schema_stage_digest() {
    jq -S -s 'sort_by(.name)' "$1"/base44/entities/*.jsonc |
        shasum -a 256 | awk '{print $1}'
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

local_inputs_digest() {
    local records="$WORK/local-inputs-$RANDOM.txt" name file
    : > "$records"
    printf 'script\t%s\n' "$(shasum -a 256 "$ROOT/scripts/repair-base44-final-schema-before-notifications.sh" | awk '{print $1}')" >> "$records"
    printf 'app\t%s\n' "$(shasum -a 256 "$APP_FILE" | awk '{print $1}')" >> "$records"
    printf 'config\t%s\n' "$(shasum -a 256 "$ROOT/base44/config.jsonc" | awk '{print $1}')" >> "$records"
    printf 'historical-postflight\t%s\n' "$(shasum -a 256 "$HISTORICAL_POSTFLIGHT" | awk '{print $1}')" >> "$records"
    for name in "${ENTITIES[@]}"; do
        file="$(local_entity_file "$name")"
        printf '%s\t%s\n' "$name" "$(shasum -a 256 "$file" | awk '{print $1}')" >> "$records"
    done
    LC_ALL=C sort -o "$records" "$records"
    shasum -a 256 "$records" | awk '{print $1}'
}

write_expected_names() {
    local output=$1
    shift
    printf '%s\n' "$@" | LC_ALL=C sort > "$output"
}

validate_historical_evidence() {
    local historical_names="$WORK/historical-names.txt" expected_names="$WORK/expected-names.txt"
    [[ -d "$HISTORICAL_STAGE/base44/entities" && ! -L "$HISTORICAL_STAGE/base44/entities" ]] || {
        echo "The approved Step 6 reviewed stage is unavailable." >&2
        return 77
    }
    secure_private_tree "$HISTORICAL_STAGE" || {
        echo "The approved Step 6 reviewed stage contains an unsafe path." >&2
        return 65
    }
    secure_private_json_file "$HISTORICAL_POSTFLIGHT" || return $?
    [[ "$(shasum -a 256 "$HISTORICAL_POSTFLIGHT" | awk '{print $1}')" == "$EXPECTED_HISTORICAL_POSTFLIGHT_DIGEST" ]] || {
        echo "The approved Step 6 postflight bytes changed." >&2
        return 77
    }
    jq -e --arg app "$APP_ID" --arg plan "$EXPECTED_HISTORICAL_PLAN_DIGEST" \
        --arg digest "$EXPECTED_FINAL_SCHEMA_DIGEST" '
      .app_id == $app and .reviewed_plan_digest == $plan and
      .expected_schema_digest == $digest and .actual_schema_digest == $digest and
      .expected_count == 20 and .actual_count == 20 and
      .push_status == 0 and .postflight_fetch_status == 0 and
      .postflight_schema_status == 0 and .admin_write_boundary == true and
      .matches_reviewed_stage == true
    ' "$HISTORICAL_POSTFLIGHT" >/dev/null || {
        echo "The approved Step 6 postflight no longer proves the pinned final schema." >&2
        return 77
    }
    write_expected_names "$expected_names" "${ENTITIES[@]}"
    for file in "$HISTORICAL_STAGE"/base44/entities/*.jsonc; do jq -er '.name' "$file"; done |
        LC_ALL=C sort > "$historical_names"
    cmp -s "$expected_names" "$historical_names" || {
        echo "The approved Step 6 stage no longer has the exact 20-entity inventory." >&2
        return 77
    }
    [[ "$(schema_stage_digest "$HISTORICAL_STAGE")" == "$EXPECTED_FINAL_SCHEMA_DIGEST" ]] || {
        echo "The approved Step 6 reviewed stage digest changed." >&2
        return 77
    }
}

validate_live_precondition() {
    local remote=$1 actual_names="$WORK/live-names.txt" expected_names="$WORK/expected-live-names.txt"
    validate_remote_schema "$remote" || {
        echo "Remote schema response is incomplete or ambiguous." >&2
        return 65
    }
    [[ "$(jq -r '.total' "$remote")" -eq "$EXPECTED_ENTITY_COUNT" ]] || {
        echo "Production no longer has the pinned 20-entity inventory." >&2
        return 77
    }
    jq -r '.schemas[].entity_name' "$remote" | LC_ALL=C sort > "$actual_names"
    write_expected_names "$expected_names" "${ENTITIES[@]}"
    cmp -s "$expected_names" "$actual_names" || {
        echo "Production entity names changed after the repair incident was reviewed." >&2
        diff -u "$expected_names" "$actual_names" >&2 || true
        return 77
    }
    [[ "$(schema_remote_set_digest "$remote")" == "$EXPECTED_DRIFTED_LIVE_SCHEMA_DIGEST" ]] || {
        echo "Production schema bytes changed after the repair incident was reviewed." >&2
        return 77
    }
}

copy_local_final_baseline() {
    local name source
    mkdir -p "$STAGE/base44/entities"
    cp "$ROOT/base44/config.jsonc" "$STAGE/base44/config.jsonc"
    cp "$APP_FILE" "$STAGE/base44/.app.jsonc"
    for name in "${ENTITIES[@]}"; do
        source="$(local_entity_file "$name")"
        cp "$source" "$STAGE/base44/entities/$name.jsonc"
    done
}

strip_unreleased_notification_schema() {
    local registration="$STAGE/base44/entities/PushDeviceRegistration.jsonc"
    local event="$STAGE/base44/entities/PushNotificationEvent.jsonc"
    local next="$WORK/stripped.json"
    jq 'del(.properties.announcements_enabled)' "$registration" > "$next"
    mv "$next" "$registration"
    jq '
      (.properties.event_type.enum |= map(select(. != "global_announcement"))) |
      (.properties.source_type.enum |= map(select(. != "notification_announcement"))) |
      del(
        .properties.announcement_id,
        .properties.inbox_kind,
        .properties.inbox_importance,
        .properties.inbox_title_en,
        .properties.inbox_body_en,
        .properties.inbox_title_ru,
        .properties.inbox_body_ru,
        .properties.inbox_title_es,
        .properties.inbox_body_es,
        .properties.inbox_title_uk,
        .properties.inbox_body_uk,
        .properties.inbox_action_deep_link,
        .properties.inbox_published_at,
        .properties.inbox_projection_version,
        .properties.inbox_visible,
        .properties.inbox_committed_at
      )
    ' "$event" > "$next"
    mv "$next" "$event"
}

strip_unreleased_user_fields() {
    local user="$STAGE/base44/entities/User.jsonc"
    local next="$WORK/stripped-user.json"
    jq '
      del(.properties.radar_invite_policy) |
      (.properties.language.enum |= map(select(. != "uk")))
    ' "$user" > "$next"
    mv "$next" "$user"
}

merge_platform_user_boundary() {
    local remote=$1 live_user="$WORK/live-user.json" canonical_user
    local staged_user="$STAGE/base44/entities/User.jsonc" next="$WORK/staged-user.json"
    canonical_user="$(local_entity_file User)"
    jq '[.schemas[] | select(.entity_name == "User") | .entity_schema][0]' "$remote" > "$live_user"
    jq -e '.properties.role.type == "string"' "$live_user" >/dev/null || {
        echo "Live User no longer exposes the Base44 platform role field." >&2
        return 65
    }
    jq -e --slurpfile canonical "$canonical_user" '
      ((.properties | keys) - ($canonical[0].properties | keys)) == ["role"]
    ' "$live_user" >/dev/null || {
        echo "Live User platform/custom field boundary differs from the reviewed repair." >&2
        return 77
    }
    jq -n --slurpfile live "$live_user" --slurpfile canonical "$canonical_user" '
      $live[0] as $l | $canonical[0] as $c |
      ($l.properties | with_entries(select(.key as $key | ($c.properties | has($key) | not)))) as $platform |
      ($platform | keys) as $platform_names |
      ($l + $c) |
      .properties = ($platform + $c.properties) |
      .required = (((($c.required // []) +
        [($l.required // [])[] | select(. as $field | $platform_names | index($field))]) | unique)) |
      if (.required | length) == 0 then del(.required) else . end |
      if ($l | has("rls")) then .rls = $l.rls else del(.rls) end
    ' > "$next"
    mv "$next" "$staged_user"
}

prepare_candidate() {
    local remote=$1 target_names="$WORK/target-names.txt" expected_names="$WORK/expected-target-names.txt"
    local historical="$WORK/historical-target.json" candidate="$WORK/candidate-target.json"
    rm -rf -- "$STAGE"
    copy_local_final_baseline
    strip_unreleased_notification_schema
    merge_platform_user_boundary "$remote"
    strip_unreleased_user_fields
    for file in "$STAGE"/base44/entities/*.jsonc; do jq -er '.name' "$file"; done |
        LC_ALL=C sort > "$target_names"
    write_expected_names "$expected_names" "${ENTITIES[@]}"
    cmp -s "$expected_names" "$target_names" || {
        echo "Repair candidate is not the exact reviewed 20-entity inventory." >&2
        return 65
    }
    [[ "$(schema_stage_digest "$STAGE")" == "$EXPECTED_FINAL_SCHEMA_DIGEST" ]] || {
        echo "Local repair candidate no longer reproduces the approved Step 6 schema digest." >&2
        return 77
    }
    jq -S -s 'sort_by(.name)' "$HISTORICAL_STAGE"/base44/entities/*.jsonc > "$historical"
    jq -S -s 'sort_by(.name)' "$STAGE"/base44/entities/*.jsonc > "$candidate"
    cmp -s "$historical" "$candidate" || {
        echo "Repair candidate differs from the preserved approved Step 6 stage." >&2
        return 77
    }
    jq -s -e --argjson expected "$EXPECTED_CUSTOM_ENTITY_COUNT" '
      [.[] | select(.name != "User") |
        (.rls.create.user_condition.role == "admin" and
         .rls.update.user_condition.role == "admin" and
         .rls.delete.user_condition.role == "admin")
      ] as $checks |
      ($checks | length) == $expected and all($checks[]; . == true)
    ' "$STAGE"/base44/entities/*.jsonc >/dev/null || {
        echo "Repair candidate does not restore the 19-entity admin-write boundary." >&2
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
        entity_additions: [($target | keys[]) as $name | select($live[$name] == null) | $name],
        entity_deletions: [($live | keys[]) as $name | select($target[$name] == null) | $name],
        changed_entities: [($target | keys[]) as $name |
          select($live[$name] != null and $live[$name] != $target[$name]) | $name],
        unchanged_entities: [($target | keys[]) as $name |
          select($live[$name] != null and $live[$name] == $target[$name]) | $name],
        details: [($target | keys[]) as $name | ($live[$name] // null) as $before |
          select($before == null or $before != $target[$name]) |
          {
            entity:$name,
            property_additions:(if $before == null then ($target[$name].properties // {} | keys)
              else (($target[$name].properties // {} | keys) - ($before.properties // {} | keys)) end),
            property_removals:(if $before == null then []
              else (($before.properties // {} | keys) - ($target[$name].properties // {} | keys)) end),
            changed_existing_properties:(if $before == null then [] else
              [($target[$name].properties // {} | keys[]) as $key |
                select(($before.properties // {} | has($key)) and
                  $before.properties[$key] != $target[$name].properties[$key]) | $key] end),
            rls_changed:(if $before == null then false else
              (($before.rls // null) != ($target[$name].rls // null)) end),
            required_changed:(if $before == null then false else
              (($before.required // []) != ($target[$name].required // [])) end)
          }]
      } |
      .property_additions = [.details[] | .entity as $entity | .property_additions[] | "\($entity).\(.)"] |
      .property_removals = [.details[] | .entity as $entity | .property_removals[] | "\($entity).\(.)"] |
      .changed_existing_properties = [.details[] | .entity as $entity |
        .changed_existing_properties[] | "\($entity).\(.)"] |
      .rls_changes = [.details[] | select(.rls_changed) | .entity]
    ' > "$output"
    jq -e '
      .entity_additions == [] and .entity_deletions == [] and
      .changed_entities == [
        "AiGenerationQuota","Entitlement","GameHistory","GameRoom",
        "LiveActivityRegistration","MembershipGrant","User","WordPack"
      ] and (.unchanged_entities | length) == 12 and
      .property_additions == [
        "GameHistory.match_id","GameHistory.match_type","GameHistory.player_user_id","GameHistory.ranked",
        "GameRoom.game_finished_event_id","GameRoom.game_paused_at","GameRoom.game_paused_total_seconds",
        "GameRoom.game_started_event_id","GameRoom.intro_started_at","GameRoom.match_id",
        "GameRoom.participant_user_ids","GameRoom.terminal_intent",
        "LiveActivityRegistration.locale","LiveActivityRegistration.pending_force_end",
        "User.rating","User.spy_card_accent","User.spy_card_badge","User.spy_card_theme","User.spy_id",
        "WordPack.owner_user_id"
      ] and .property_removals == [] and
      .changed_existing_properties == [
        "Entitlement.status",
        "GameRoom.cards_read","GameRoom.countdown_started_at","GameRoom.detective_votes",
        "GameRoom.game_duration_seconds","GameRoom.game_mode","GameRoom.game_started_at",
        "GameRoom.player_feedback","GameRoom.players","GameRoom.ready_players",
        "GameRoom.roulette_target_email","GameRoom.spectators","GameRoom.vote_requests","GameRoom.word_pool",
        "MembershipGrant.active","MembershipGrant.label","MembershipGrant.user_id",
        "User.ai_generations_today","User.avatar","User.display_name","User.games_played",
        "User.games_won","User.language","User.last_ai_generation_date",
        "WordPack.is_public","WordPack.owner_email"
      ] and .rls_changes == ["AiGenerationQuota","GameHistory","GameRoom","WordPack"] and
      all(.details[]; .required_changed == false)
    ' "$output" >/dev/null || {
        echo "Repair delta differs from the exact reviewed additive/no-delete plan." >&2
        return 65
    }
}

mkdir -p "$CUTOVER_DIR"
secure_private_directory "$CUTOVER_DIR"
if [[ "$MODE" == "deploy" ]]; then
    acquire_production_lock
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another notification schema repair prepare/deploy is active." >&2
    exit 75
fi
LOCK_HELD=1
mkdir -p "$CUTOVER_DIR/evidence" "$EVIDENCE_DIR"
secure_private_directory "$LOCK_DIR"
secure_private_directory "$CUTOVER_DIR/evidence"
secure_private_directory "$EVIDENCE_DIR"

validate_historical_evidence

if [[ "$MODE" == "deploy" ]]; then
    [[ -f "$FIXED_STAGE/manifest.json" && ! -L "$FIXED_STAGE/manifest.json" ]] || {
        echo "No fixed reviewed Step 0 repair stage exists; run the read-only prepare first." >&2
        exit 77
    }
    secure_private_tree "$FIXED_STAGE"
    secure_private_json_file "$FIXED_STAGE/manifest.json"
    cp "$FIXED_STAGE/manifest.json" "$REVIEWED_MANIFEST"
    secure_private_json_file "$REVIEWED_MANIFEST"
fi

fetch_remote_schema "$REMOTE" || { echo "Unable to fetch Production schema." >&2; exit 70; }
validate_live_precondition "$REMOTE"
prepare_candidate "$REMOTE"
DELTA="$STAGE/schema-delta.json"
write_delta_and_assert "$REMOTE" "$DELTA"
remote_digest="$(schema_remote_set_digest "$REMOTE")"
target_digest="$(schema_stage_digest "$STAGE")"
stage_bytes_digest="$(tree_bytes_digest "$STAGE/base44")"
inputs_digest="$(local_inputs_digest)"
historical_evidence_digest="$(shasum -a 256 "$HISTORICAL_POSTFLIGHT" | awk '{print $1}')"
delta_digest="$(shasum -a 256 "$DELTA" | awk '{print $1}')"
plan_input="$STAGE/plan-input.json"
jq -S -n \
    --arg step "0" --arg action "$ACTION" --arg app_id "$APP_ID" \
    --arg remote_digest "$remote_digest" --arg target_digest "$target_digest" \
    --arg historical_plan_digest "$EXPECTED_HISTORICAL_PLAN_DIGEST" \
    --arg historical_evidence_digest "$historical_evidence_digest" \
    --arg stage_bytes_digest "$stage_bytes_digest" --arg local_inputs_digest "$inputs_digest" \
    --arg delta_digest "$delta_digest" --argjson entity_count "$EXPECTED_ENTITY_COUNT" \
    --argjson custom_count "$EXPECTED_CUSTOM_ENTITY_COUNT" --slurpfile delta "$DELTA" \
    '{step:$step,action:$action,app_id:$app_id,live_count:$entity_count,target_count:$entity_count,
      target_custom_entity_count:$custom_count,remote_digest:$remote_digest,
      target_schema_digest:$target_digest,historical_plan_digest:$historical_plan_digest,
      historical_evidence_digest:$historical_evidence_digest,
      stage_bytes_digest:$stage_bytes_digest,local_inputs_digest:$local_inputs_digest,
      schema_delta_digest:$delta_digest,delta:$delta[0]}' > "$plan_input"
plan_digest="$(shasum -a 256 "$plan_input" | awk '{print $1}')"
jq -S --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg plan_digest "$plan_digest" \
    '. + {prepared_at:$prepared_at,plan_digest:$plan_digest}' "$plan_input" > "$STAGE/manifest.json"

if [[ "$MODE" == "prepare" ]]; then
    rm -rf -- "$FIXED_STAGE"
    mv "$STAGE" "$FIXED_STAGE"
    secure_private_tree "$FIXED_STAGE"
    echo "Prepared read-only notification Step 0 schema repair plan: $FIXED_STAGE"
    echo "Live entities: $EXPECTED_ENTITY_COUNT; target entities: $EXPECTED_ENTITY_COUNT"
    echo "Changed entities: ${EXPECTED_CHANGED_ENTITIES[*]}"
    echo "Property additions: 20; property removals: 0; entity additions/deletions: 0/0"
    echo "Plan digest: $plan_digest"
    echo "No Base44 mutation was made."
    exit 0
fi

reviewed_plan_digest="$(jq -er '.plan_digest' "$REVIEWED_MANIFEST")"
reviewed_stage_digest="$(jq -er '.stage_bytes_digest' "$REVIEWED_MANIFEST")"
reviewed_inputs_digest="$(jq -er '.local_inputs_digest' "$REVIEWED_MANIFEST")"
reviewed_remote_digest="$(jq -er '.remote_digest' "$REVIEWED_MANIFEST")"
reviewed_target_digest="$(jq -er '.target_schema_digest' "$REVIEWED_MANIFEST")"
reviewed_manifest_digest="$(shasum -a 256 "$REVIEWED_MANIFEST" | awk '{print $1}')"
if [[ "$EXPECTED_PLAN_DIGEST" != "$reviewed_plan_digest" || "$plan_digest" != "$reviewed_plan_digest" ||
      "$stage_bytes_digest" != "$reviewed_stage_digest" || "$inputs_digest" != "$reviewed_inputs_digest" ||
      "$remote_digest" != "$reviewed_remote_digest" || "$target_digest" != "$reviewed_target_digest" ]]; then
    echo "Step 0 no longer reproduces the exact reviewed repair plan." >&2
    exit 77
fi
diff -qr "$STAGE/base44" "$FIXED_STAGE/base44" >/dev/null || {
    echo "Step 0 candidate bytes differ from the reviewed fixed stage." >&2
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
[[ "${BASE44_CONFIRM_NOTIFICATION_SCHEMA_REPAIR_PLAN_DIGEST:-}" == "$reviewed_plan_digest" ]] || {
    echo "Set BASE44_CONFIRM_NOTIFICATION_SCHEMA_REPAIR_PLAN_DIGEST to the reviewed plan digest." >&2
    exit 77
}

fetch_remote_schema "$JIT_REMOTE" || exit 70
validate_live_precondition "$JIT_REMOTE"
[[ "$(schema_remote_set_digest "$JIT_REMOTE")" == "$reviewed_remote_digest" ]] || {
    echo "Production schema changed after review; refusing Step 0." >&2
    exit 77
}
[[ "$(tree_bytes_digest "$FIXED_STAGE/base44")" == "$reviewed_stage_digest" &&
    "$(local_inputs_digest)" == "$reviewed_inputs_digest" ]] || {
    echo "Reviewed repair stage or source inputs changed immediately before Step 0." >&2
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
admin_write_boundary=false
matches_reviewed_stage=false
set +e
fetch_remote_schema "$POST_REMOTE"
postflight_fetch_status=$?
if [[ "$postflight_fetch_status" -eq 0 ]]; then
    validate_remote_schema "$POST_REMOTE"
    postflight_schema_status=$?
    if [[ "$postflight_schema_status" -eq 0 ]]; then
        actual_count="$(jq -r '.total' "$POST_REMOTE")"
        actual_digest="$(schema_remote_set_digest "$POST_REMOTE")"
        if jq -e --argjson expected "$EXPECTED_CUSTOM_ENTITY_COUNT" '
          [.schemas[] | select(.entity_name != "User") | .entity_schema.rls as $rls |
            ($rls.create.user_condition.role == "admin" and
             $rls.update.user_condition.role == "admin" and
             $rls.delete.user_condition.role == "admin")
          ] as $checks | ($checks | length) == $expected and all($checks[]; . == true)
        ' "$POST_REMOTE" >/dev/null; then
            admin_write_boundary=true
        fi
    fi
fi
set -e
if [[ "$push_status" -eq 0 && "$postflight_fetch_status" -eq 0 && "$postflight_schema_status" -eq 0 &&
      "$actual_count" -eq "$EXPECTED_ENTITY_COUNT" && "$actual_digest" == "$EXPECTED_FINAL_SCHEMA_DIGEST" &&
      "$admin_write_boundary" == true ]]; then
    matches_reviewed_stage=true
fi
jq -n --arg audited_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg app_id "$APP_ID" \
    --arg reviewed_plan_digest "$reviewed_plan_digest" \
    --arg expected_schema_digest "$EXPECTED_FINAL_SCHEMA_DIGEST" \
    --arg actual_schema_digest "$actual_digest" --argjson expected_count "$EXPECTED_ENTITY_COUNT" \
    --argjson actual_count "$actual_count" --argjson push_status "$push_status" \
    --argjson postflight_fetch_status "$postflight_fetch_status" \
    --argjson postflight_schema_status "$postflight_schema_status" \
    --argjson admin_write_boundary "$admin_write_boundary" \
    --argjson matches_reviewed_stage "$matches_reviewed_stage" \
    '{audited_at:$audited_at,app_id:$app_id,reviewed_plan_digest:$reviewed_plan_digest,
      expected_schema_digest:$expected_schema_digest,
      actual_schema_digest:(if ($actual_schema_digest|length)==0 then null else $actual_schema_digest end),
      expected_count:$expected_count,actual_count:$actual_count,push_status:$push_status,
      postflight_fetch_status:$postflight_fetch_status,postflight_schema_status:$postflight_schema_status,
      admin_write_boundary:$admin_write_boundary,matches_reviewed_stage:$matches_reviewed_stage}' \
    > "$WORK/postflight.json"
chmod 600 "$WORK/postflight.json"
install_durable_json "$WORK/postflight.json" "$attempt_dir/postflight.json" "$attempt_dir" postflight
install_durable_json "$WORK/postflight.json" "$EVIDENCE_DIR/latest-postflight.json" "$EVIDENCE_DIR" latest-postflight

[[ "$matches_reviewed_stage" == true ]] || {
    echo "Step 0 did not reach the fully verified state; inspect $attempt_dir/postflight.json." >&2
    exit 70
}
echo "Notification Step 0 schema repair verified."
