#!/bin/bash

set -euo pipefail
umask 077

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
APP_FILE="$ROOT/base44/.app.jsonc"
EXPECTED_APP_ID="69a0e57fa939f578082f8091"
APP_ID="$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_FILE" | head -n 1)"
[[ -n "$APP_ID" ]] || {
    echo "Unable to read the Base44 app id from $APP_FILE" >&2
    exit 65
}
[[ "$APP_ID" =~ ^[A-Za-z0-9_-]+$ ]] || {
    echo "Invalid Base44 app id in $APP_FILE" >&2
    exit 65
}
[[ "$APP_ID" == "$EXPECTED_APP_ID" ]] || {
    echo "Repository app id $APP_ID is not the reviewed SpyClash app $EXPECTED_APP_ID." >&2
    exit 77
}

CUTOVER_DIR="$ROOT/.base44-cutover"
FIXED_STAGE="$CUTOVER_DIR/coordinated-functions"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spyclash-base44-functions.XXXXXX")"
STAGE="$WORK/candidate-stage"
DEPLOY_STAGE="$STAGE/deploy"
REMOTE_BEFORE="$STAGE/remote-before"
SCHEMA_MANIFEST="$CUTOVER_DIR/final-schema-check/manifest.json"
EVIDENCE_DIR="$CUTOVER_DIR/evidence/coordinated-functions"
REVIEWED_MANIFEST="$WORK/reviewed-manifest.json"
LOCK_DIR="$CUTOVER_DIR/.coordinated-functions.lock"
PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
LOCK_HELD=0
PRODUCTION_LOCK_HELD=0
MODE="prepare"

FUNCTIONS=(
    advanceRound
    app-store-entitlement
    appleAuthBroker
    appleAuthCallback
    autoRegisterUser
    checkSubscription
    communityAction
    createCheckout
    gameRoomAction
    generateWordPack
    googleAuthCallback
    mobileAuthCallback
    pushNotificationAction
    stripe-entitlement-webhook
    wordPackAction
)
ALL_FUNCTIONS=("${FUNCTIONS[@]}" deleteAccount)

cleanup() {
    case "$WORK" in
        "${TMPDIR:-/tmp}"/spyclash-base44-functions.*)
            rm -rf -- "$WORK"
            ;;
    esac
    if [[ "$LOCK_HELD" -eq 1 ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    if [[ "$PRODUCTION_LOCK_HELD" -eq 1 ]]; then
        if [[ -d "$PRODUCTION_LOCK_DIR" && ! -L "$PRODUCTION_LOCK_DIR" && \
              -O "$PRODUCTION_LOCK_DIR" ]]; then
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
    --deploy) MODE="deploy" ;;
    *)
        echo "Usage: $0 [--deploy]" >&2
        exit 64
        ;;
esac

if [[ -n "${BASE44_COORDINATED_STAGE_DIR+x}" ]]; then
    echo "BASE44_COORDINATED_STAGE_DIR is not supported; the stage path is fixed at $FIXED_STAGE." >&2
    exit 64
fi
if [[ -n "${BASE44_APP_ID+x}" && "$BASE44_APP_ID" != "$APP_ID" ]]; then
    echo "BASE44_APP_ID targets $BASE44_APP_ID, not reviewed app $APP_ID." >&2
    exit 77
fi
[[ "$ROOT" != "/" && -n "$ROOT" ]] || {
    echo "Unsafe repository root; refusing to prepare a function stage." >&2
    exit 65
}
[[ "$FIXED_STAGE" == "$ROOT/.base44-cutover/coordinated-functions" ]] || {
    echo "Unsafe coordinated-function stage path; refusing to continue." >&2
    exit 65
}
[[ ! -L "$CUTOVER_DIR" ]] || {
    echo "$CUTOVER_DIR must not be a symbolic link." >&2
    exit 65
}
[[ ! -L "$FIXED_STAGE" ]] || {
    echo "$FIXED_STAGE must not be a symbolic link." >&2
    exit 65
}

for command in awk basename chmod cmp cp date diff env find grep head id jq mkdir mktemp mv npx rm \
    rmdir sed shasum sort stat sync tr wc; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing required command: $command" >&2
        exit 69
    }
done

private_mode() {
    local path=$1
    stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path"
}

private_links() {
    local path=$1
    stat -f '%l' "$path" 2>/dev/null || stat -c '%h' "$path"
}

secure_private_directory() {
    local directory=$1
    [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] || return 65
    chmod 700 "$directory"
    [[ "$(private_mode "$directory")" == 700 ]] || return 65
}

secure_private_json_file() {
    local protected_file=$1
    [[ -f "$protected_file" && ! -L "$protected_file" && -O "$protected_file" ]] || return 65
    [[ "$(private_links "$protected_file")" == 1 ]] || return 65
    chmod 600 "$protected_file"
    [[ "$(private_mode "$protected_file")" == 600 ]] || return 65
    jq -e . "$protected_file" >/dev/null || return 65
}

secure_private_tree_modes() {
    local tree=$1
    [[ -d "$tree" && ! -L "$tree" && -O "$tree" ]] || return 65
    if find "$tree" -type l -print | grep -q .; then
        return 65
    fi
    find "$tree" -type d -exec chmod 700 {} +
    find "$tree" -type f -exec chmod 600 {} +
    secure_private_directory "$tree"
}

install_durable_json() {
    local source=$1
    local destination=$2
    local directory=$3
    local label=$4
    local temporary

    case "$destination" in
        "$directory/attempt.json"|"$directory/postflight.json"|"$EVIDENCE_DIR/latest-postflight.json") ;;
        *) echo "Refusing unsafe coordinated-function evidence destination." >&2; return 65 ;;
    esac
    [[ "$label" =~ ^[A-Za-z0-9_-]+$ ]] || return 65
    secure_private_directory "$directory" || return $?
    secure_private_json_file "$source" || return $?
    if [[ -e "$destination" || -L "$destination" ]]; then
        secure_private_json_file "$destination" || {
            echo "Unsafe coordinated-function evidence destination: $destination" >&2
            return 65
        }
    fi
    temporary="$(mktemp "$directory/.${label}.XXXXXX")" || return 70
    chmod 600 "$temporary" || { rm -f -- "$temporary"; return 70; }
    cp "$source" "$temporary" && cmp -s "$source" "$temporary" || {
        rm -f -- "$temporary"
        return 70
    }
    secure_private_json_file "$temporary" || {
        rm -f -- "$temporary"
        return 70
    }
    mv "$temporary" "$destination" || {
        rm -f -- "$temporary"
        return 70
    }
    secure_private_json_file "$destination" || return 70
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
    printf 'SECURITY_CUTOVER_STEP_4_DEPLOY_15:%s\n' "$$" > "$PRODUCTION_LOCK_OWNER"
    chmod 600 "$PRODUCTION_LOCK_OWNER"
    [[ -f "$PRODUCTION_LOCK_OWNER" && ! -L "$PRODUCTION_LOCK_OWNER" && \
       -O "$PRODUCTION_LOCK_OWNER" && "$(private_links "$PRODUCTION_LOCK_OWNER")" == 1 ]] || return 65
}

mkdir -p "$CUTOVER_DIR"
if [[ -L "$CUTOVER_DIR/evidence" || -L "$EVIDENCE_DIR" ]]; then
    echo "Coordinated-function evidence paths must not be symbolic links." >&2
    exit 65
fi
secure_private_directory "$CUTOVER_DIR"
if [[ "$MODE" == "deploy" ]]; then
    acquire_production_lock
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another coordinated Base44 function audit/deploy is already active: $LOCK_DIR" >&2
    exit 75
fi
LOCK_HELD=1
mkdir -p "$EVIDENCE_DIR"
secure_private_directory "$LOCK_DIR"
secure_private_directory "$CUTOVER_DIR/evidence"
secure_private_directory "$EVIDENCE_DIR"

if [[ "$MODE" == "deploy" ]]; then
    if [[ ! -f "$FIXED_STAGE/manifest.json" || -L "$FIXED_STAGE" || \
          -L "$FIXED_STAGE/manifest.json" ]]; then
        echo "No fixed reviewed coordinated-function stage exists; run prepare first." >&2
        exit 77
    fi
    secure_private_tree_modes "$FIXED_STAGE" || exit 65
    secure_private_json_file "$FIXED_STAGE/manifest.json" || {
        echo "Reviewed coordinated-function manifest must be a private, owned regular JSON file." >&2
        exit 65
    }
    cp "$FIXED_STAGE/manifest.json" "$REVIEWED_MANIFEST"
    secure_private_json_file "$REVIEWED_MANIFEST"
    cmp -s "$FIXED_STAGE/manifest.json" "$REVIEWED_MANIFEST" || exit 70
fi

base44_cli() {
    env -u BASE44_APP_ID npx --yes base44@0.1.4 \
        --app-id "$APP_ID" "$@"
}

expected_names_file() {
    local output=$1
    shift
    printf '%s\n' "$@" | LC_ALL=C sort > "$output"
}

validate_function() {
    local functions_root=$1
    local function_name=$2
    local function_dir="$functions_root/$function_name"
    local declared_name entry payload_count

    [[ -d "$function_dir" && ! -L "$function_dir" ]] || {
        echo "Missing or unsafe function directory: $function_dir" >&2
        return 65
    }
    if find "$function_dir" -type l -print | grep -q .; then
        echo "Function $function_name contains a symbolic link." >&2
        return 65
    fi
    [[ -f "$function_dir/function.jsonc" ]] || {
        echo "Function $function_name is missing function.jsonc." >&2
        return 65
    }
    declared_name="$(jq -er '.name' "$function_dir/function.jsonc")"
    [[ "$declared_name" == "$function_name" ]] || {
        echo "Function directory/name mismatch: $function_name != $declared_name" >&2
        return 65
    }
    entry="$(jq -er '.entry' "$function_dir/function.jsonc")"
    [[ "$entry" =~ ^[A-Za-z0-9._-]+$ && -f "$function_dir/$entry" ]] || {
        echo "Function $function_name has an unsafe or missing entry file: $entry" >&2
        return 65
    }
    payload_count="$(find "$function_dir" -type f \
        \( -name '*.js' -o -name '*.ts' -o -name '*.json' -o -name '*.jsonc' \) \
        | wc -l | tr -d ' ')"
    [[ "$payload_count" -gt 1 ]] || {
        echo "Function $function_name has no deployable source beside its config." >&2
        return 65
    }
    if find "$function_dir" -type f \
        ! \( -name '*.js' -o -name '*.ts' -o -name '*.json' -o -name '*.jsonc' \) \
        -print | grep -q .; then
        echo "Function $function_name contains a file outside the Base44 CLI payload glob." >&2
        return 65
    fi
    if [[ "$(find "$function_dir" -name function.jsonc -type f | wc -l | tr -d ' ')" -ne 1 ]]; then
        echo "Function $function_name contains a nested or duplicate function.jsonc." >&2
        return 65
    fi
}

validate_inventory() {
    local functions_root=$1
    local label=$2
    shift 2
    local expected="$WORK/$label-expected-names.txt"
    local actual="$WORK/$label-actual-names.txt"
    local function_name

    [[ -d "$functions_root" && ! -L "$functions_root" ]] || {
        echo "Missing or unsafe $label function root: $functions_root" >&2
        return 65
    }
    if find "$functions_root" -mindepth 1 -maxdepth 1 ! -type d -print | \
        grep -q .; then
        echo "$label function root contains a non-function top-level entry." >&2
        return 65
    fi
    expected_names_file "$expected" "$@"
    find "$functions_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
        | LC_ALL=C sort > "$actual"
    if ! cmp -s "$expected" "$actual"; then
        echo "$label function inventory differs from the reviewed exact set." >&2
        echo "Expected:" >&2
        sed 's/^/  /' "$expected" >&2
        echo "Actual:" >&2
        sed 's/^/  /' "$actual" >&2
        return 65
    fi
    for function_name in "$@"; do
        validate_function "$functions_root" "$function_name" || return $?
    done
    return 0
}

normalized_config() {
    jq -S '
      walk(
        if type == "object" then
          with_entries(select(.value != null))
        else . end
      ) |
      .automations = ((.automations // []) | map(
        .is_active = (.is_active // true) |
        if .type == "scheduled" and .schedule_mode == "recurring" then
          .ends_type = (.ends_type // "never")
        else . end
      ))
    ' "$1"
}

function_payload_object() {
    local functions_root=$1
    local function_name=$2
    local function_dir="$functions_root/$function_name"
    local records="$WORK/payload-$function_name-$RANDOM.txt"
    local config="$WORK/config-$function_name-$RANDOM.json"
    local relative source_count raw_config_digest effective_config_digest
    local source_digest cli_input_digest effective_digest

    : > "$records"
    while IFS= read -r relative; do
        printf '%s\t%s\n' "$relative" \
            "$(shasum -a 256 "$function_dir/$relative" | awk '{print $1}')" \
            >> "$records"
    done < <(
        cd "$function_dir"
        find . -type f \
            \( -name '*.js' -o -name '*.ts' -o -name '*.json' -o -name '*.jsonc' \) \
            ! -name 'function.jsonc' -print | sed 's#^\./##' | LC_ALL=C sort
    )
    source_count="$(wc -l < "$records" | tr -d ' ')"
    [[ "$source_count" -gt 0 ]] || {
        echo "Function $function_name has an empty CLI payload." >&2
        return 65
    }
    normalized_config "$function_dir/function.jsonc" > "$config"
    raw_config_digest="$(shasum -a 256 "$function_dir/function.jsonc" | awk '{print $1}')"
    effective_config_digest="$(shasum -a 256 "$config" | awk '{print $1}')"
    source_digest="$(shasum -a 256 "$records" | awk '{print $1}')"
    cli_input_digest="$(printf '%s\n' "$function_name" "$raw_config_digest" "$source_digest" \
        | shasum -a 256 | awk '{print $1}')"
    effective_digest="$(printf '%s\n' "$function_name" "$effective_config_digest" "$source_digest" \
        | shasum -a 256 | awk '{print $1}')"
    jq -n \
        --arg name "$function_name" \
        --arg raw_config_digest "$raw_config_digest" \
        --arg effective_config_digest "$effective_config_digest" \
        --arg source_digest "$source_digest" \
        --arg cli_input_digest "$cli_input_digest" \
        --arg effective_digest "$effective_digest" \
        --argjson cli_file_count "$((source_count + 1))" \
        '{name:$name,raw_config_digest:$raw_config_digest,effective_config_digest:$effective_config_digest,source_digest:$source_digest,cli_input_digest:$cli_input_digest,effective_digest:$effective_digest,cli_file_count:$cli_file_count}'
}

write_payload_manifest() {
    local functions_root=$1
    local output=$2
    shift 2
    local objects="$WORK/payload-objects-$RANDOM.jsonl"
    local function_name

    : > "$objects"
    for function_name in "$@"; do
        function_payload_object "$functions_root" "$function_name" >> "$objects"
    done
    jq -s 'sort_by(.name)' "$objects" > "$output"
}

manifest_projection_digest() {
    local manifest=$1
    local field=$2
    local projection="$WORK/manifest-projection-$RANDOM.json"
    jq -S --arg field "$field" \
        'map({name, digest: .[$field]})' "$manifest" > "$projection"
    shasum -a 256 "$projection" | awk '{print $1}'
}

tree_bytes_digest() {
    local tree=$1
    local records="$WORK/tree-bytes-$RANDOM.txt"
    [[ -d "$tree" && ! -L "$tree" ]] || return 65
    if find "$tree" -type l -print | grep -q .; then
        return 65
    fi
    : > "$records"
    while IFS= read -r relative; do
        printf '%s\t%s\n' "$relative" \
            "$(shasum -a 256 "$tree/$relative" | awk '{print $1}')" \
            >> "$records"
    done < <(
        cd "$tree"
        find . -type f -print | sed 's#^\./##' | LC_ALL=C sort
    )
    shasum -a 256 "$records" | awk '{print $1}'
}

guard_digest() {
    local remote_functions_root=$1
    local remote_object="$WORK/remote-guard-$RANDOM.json"
    local local_object="$WORK/local-guard-$RANDOM.json"
    local remote_digest local_digest

    function_payload_object "$remote_functions_root" deleteAccount > "$remote_object"
    function_payload_object "$ROOT/scripts/base44-maintenance" deleteAccount \
        > "$local_object"
    remote_digest="$(jq -er '.effective_digest' "$remote_object")"
    local_digest="$(jq -er '.effective_digest' "$local_object")"
    [[ "$remote_digest" == "$local_digest" ]] || {
        echo "Production deleteAccount is not the reviewed maintenance guard." >&2
        return 65
    }
    printf '%s\n' "$remote_digest"
}

copy_target_functions() {
    local source=$1
    local destination=$2
    local function_name

    mkdir -p "$destination"
    for function_name in "${FUNCTIONS[@]}"; do
        cp -R "$source/$function_name" "$destination/$function_name"
    done
}

pull_remote_functions() {
    local destination=$1
    mkdir -p "$destination/base44"
    cp "$ROOT/base44/config.jsonc" "$destination/base44/config.jsonc"
    cp "$APP_FILE" "$destination/base44/.app.jsonc"
    if ! (cd "$destination" && base44_cli functions pull); then
        echo "Unable to pull the fresh Production function inventory." >&2
        return 70
    fi
    [[ -d "$destination/base44/functions" ]] || {
        echo "Remote function pull produced no function directory." >&2
        return 65
    }
}

# These checks are intentionally repeated for --deploy. A previously green
# local run is not authority to deploy a different checkout or secret set.
base44_cli whoami >/dev/null
"$ROOT/scripts/sync-base44-billing-lifecycle.sh" --check
"$ROOT/scripts/sync-base44-apple-coordination.sh" --check
"$ROOT/scripts/sync-base44-apple-sign-in-credential.sh" --check
"$ROOT/scripts/check-apple-migration.sh"
"$ROOT/scripts/check-base44-release-secrets.sh"
"$ROOT/scripts/check-base44-entity-rls.sh"
"$ROOT/scripts/check-base44-function-bundles.sh"
"$ROOT/scripts/check-client-entity-boundaries.sh"
TMPDIR=/tmp npx --yes deno test --allow-env --allow-net --allow-read \
    --allow-run --allow-write=/tmp \
    $(find "$ROOT/base44/functions" -name '*_test.ts' -print | LC_ALL=C sort) \
    "$ROOT"/base44/tests/*.ts

validate_inventory "$ROOT/base44/functions" local-full "${ALL_FUNCTIONS[@]}"

# This read-only preparation proves that the additive schema and its temporary
# admin-only write boundary are live. It records the exact Production schema
# digest against which this function plan was reviewed.
"$ROOT/scripts/push-base44-final-schema.sh" --check
jq -e --arg app_id "$APP_ID" '
    .app_id == $app_id and
    .live_count == 20 and
    .canonical_count == 20 and
    .adds == 0 and
    .deletes == 0 and
    .live_admin_write_boundary == true and
    (.remote_digest | type == "string" and length == 64) and
    (.plan_digest | type == "string" and length == 64)
' "$SCHEMA_MANIFEST" >/dev/null || {
    echo "Fresh final-schema manifest does not prove the additive prerequisite." >&2
    exit 65
}

mkdir -p "$CUTOVER_DIR"
rm -rf -- "$STAGE"
mkdir -p "$DEPLOY_STAGE/base44/functions"
cp "$ROOT/base44/config.jsonc" "$DEPLOY_STAGE/base44/config.jsonc"
cp "$APP_FILE" "$DEPLOY_STAGE/base44/.app.jsonc"
copy_target_functions "$ROOT/base44/functions" "$DEPLOY_STAGE/base44/functions"
validate_inventory "$DEPLOY_STAGE/base44/functions" local-targets "${FUNCTIONS[@]}"

pull_remote_functions "$REMOTE_BEFORE"
validate_inventory "$REMOTE_BEFORE/base44/functions" remote-before "${ALL_FUNCTIONS[@]}"

local_functions_manifest="$STAGE/local-functions.json"
local_source_manifest="$STAGE/local-source-functions.json"
remote_functions_manifest="$STAGE/remote-functions-before.json"
write_payload_manifest "$DEPLOY_STAGE/base44/functions" \
    "$local_functions_manifest" "${FUNCTIONS[@]}"
write_payload_manifest "$ROOT/base44/functions" \
    "$local_source_manifest" "${FUNCTIONS[@]}"
write_payload_manifest "$REMOTE_BEFORE/base44/functions" \
    "$remote_functions_manifest" "${ALL_FUNCTIONS[@]}"

cmp -s "$local_functions_manifest" "$local_source_manifest" || {
    echo "Copied deploy payload differs from the checked-in local function sources." >&2
    exit 65
}

delete_guard_digest="$(guard_digest "$REMOTE_BEFORE/base44/functions")"
local_cli_input_digest="$(manifest_projection_digest "$local_functions_manifest" cli_input_digest)"
local_function_digest="$(manifest_projection_digest "$local_functions_manifest" effective_digest)"
local_source_cli_input_digest="$(manifest_projection_digest "$local_source_manifest" cli_input_digest)"
local_source_function_digest="$(manifest_projection_digest "$local_source_manifest" effective_digest)"
remote_cli_input_digest="$(manifest_projection_digest "$remote_functions_manifest" cli_input_digest)"
remote_function_digest="$(manifest_projection_digest "$remote_functions_manifest" effective_digest)"
schema_remote_digest="$(jq -er '.remote_digest' "$SCHEMA_MANIFEST")"
schema_plan_digest="$(jq -er '.plan_digest' "$SCHEMA_MANIFEST")"
functions_json="$(printf '%s\n' "${FUNCTIONS[@]}" | \
    jq -Rsc 'split("\n") | map(select(length > 0))')"
deploy_stage_bytes_digest="$(tree_bytes_digest "$DEPLOY_STAGE/base44")"
plan_digest="$(printf '%s\n' \
    "$APP_ID" \
    "$schema_remote_digest" \
    "$schema_plan_digest" \
    "$remote_cli_input_digest" \
    "$remote_function_digest" \
    "$local_cli_input_digest" \
    "$local_function_digest" \
    "$local_source_cli_input_digest" \
    "$local_source_function_digest" \
    "$deploy_stage_bytes_digest" \
    "$delete_guard_digest" \
    "$functions_json" | shasum -a 256 | awk '{print $1}')"

jq -n \
    --arg app_id "$APP_ID" \
    --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg schema_remote_digest "$schema_remote_digest" \
    --arg schema_plan_digest "$schema_plan_digest" \
    --arg remote_cli_input_digest "$remote_cli_input_digest" \
    --arg remote_function_digest "$remote_function_digest" \
    --arg local_cli_input_digest "$local_cli_input_digest" \
    --arg local_function_digest "$local_function_digest" \
    --arg local_source_cli_input_digest "$local_source_cli_input_digest" \
    --arg local_source_function_digest "$local_source_function_digest" \
    --arg deploy_stage_bytes_digest "$deploy_stage_bytes_digest" \
    --arg delete_guard_digest "$delete_guard_digest" \
    --arg plan_digest "$plan_digest" \
    --argjson functions "$functions_json" \
    --slurpfile local_functions "$local_functions_manifest" \
    --slurpfile local_source_functions "$local_source_manifest" \
    --slurpfile remote_functions "$remote_functions_manifest" \
    '{
      app_id:$app_id,
      prepared_at:$prepared_at,
      schema_remote_digest:$schema_remote_digest,
      schema_plan_digest:$schema_plan_digest,
      remote_cli_input_digest:$remote_cli_input_digest,
      remote_function_digest:$remote_function_digest,
      remote_function_count:($remote_functions[0] | length),
      remote_functions:$remote_functions[0],
      local_cli_input_digest:$local_cli_input_digest,
      local_function_digest:$local_function_digest,
      local_functions:$local_functions[0],
      local_source_cli_input_digest:$local_source_cli_input_digest,
      local_source_function_digest:$local_source_function_digest,
      local_source_functions:$local_source_functions[0],
      deploy_stage_bytes_digest:$deploy_stage_bytes_digest,
      delete_guard_digest:$delete_guard_digest,
      functions:$functions,
      function_count:($functions | length),
      plan_digest:$plan_digest
    }' > "$STAGE/manifest.json"

if [[ "$MODE" == "prepare" ]]; then
    if [[ -f "$FIXED_STAGE/postflight.json" && \
          ! -L "$FIXED_STAGE/postflight.json" ]]; then
        cp "$FIXED_STAGE/postflight.json" \
            "$EVIDENCE_DIR/legacy-postflight-$(date -u +%Y%m%dT%H%M%SZ)-$$.json"
    fi
    rm -rf -- "$FIXED_STAGE"
    mv "$STAGE" "$FIXED_STAGE"
    secure_private_tree_modes "$FIXED_STAGE"
    echo "Prepared coordinated Base44 function stage: $FIXED_STAGE"
    echo "App id: $APP_ID"
    echo "Functions: ${#FUNCTIONS[@]} targeted; remote inventory: ${#ALL_FUNCTIONS[@]} exact"
    echo "Plan digest: $plan_digest"
    echo "No remote change was made. Inspect the manifest and staged function set, then re-run with --deploy."
    exit 0
fi

reviewed_plan_digest="$(jq -er '.plan_digest' "$REVIEWED_MANIFEST")"
reviewed_deploy_stage_bytes_digest="$(jq -er '.deploy_stage_bytes_digest' "$REVIEWED_MANIFEST")"
reviewed_local_source_cli_input_digest="$(jq -er '.local_source_cli_input_digest' "$REVIEWED_MANIFEST")"
reviewed_local_source_function_digest="$(jq -er '.local_source_function_digest' "$REVIEWED_MANIFEST")"
reviewed_manifest_digest="$(shasum -a 256 "$REVIEWED_MANIFEST" | awk '{print $1}')"

if [[ "$plan_digest" != "$reviewed_plan_digest" || \
      "$deploy_stage_bytes_digest" != "$reviewed_deploy_stage_bytes_digest" || \
      "$local_source_cli_input_digest" != "$reviewed_local_source_cli_input_digest" || \
      "$local_source_function_digest" != "$reviewed_local_source_function_digest" ]]; then
    echo "The JIT coordinated-function plan, fixed payload, or local sources differ from review." >&2
    echo "The reviewed manifest remains at $FIXED_STAGE/manifest.json." >&2
    exit 77
fi
if ! diff -qr "$DEPLOY_STAGE/base44" "$FIXED_STAGE/deploy/base44" >/dev/null; then
    echo "JIT deploy payload bytes differ from the fixed reviewed stage." >&2
    exit 77
fi

echo "Reproduced reviewed coordinated Base44 function stage: $FIXED_STAGE"
echo "App id: $APP_ID"
echo "Functions: ${#FUNCTIONS[@]} targeted; remote inventory: ${#ALL_FUNCTIONS[@]} exact"
echo "Plan digest: $plan_digest"

if [[ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]]; then
    echo "Set BASE44_CONFIRM_APP_ID=$APP_ID for the intentional coordinated deployment." >&2
    exit 77
fi
if [[ "${BASE44_CONFIRM_COORDINATED_FUNCTION_PLAN_DIGEST:-}" != "$reviewed_plan_digest" ]]; then
    echo "Fresh schema/function plan differs from the inspected plan." >&2
    echo "Inspect $FIXED_STAGE/manifest.json, then set BASE44_CONFIRM_COORDINATED_FUNCTION_PLAN_DIGEST to its plan_digest." >&2
    exit 77
fi
if [[ "${BASE44_CONFIRM_ACTION:-}" != "SECURITY_CUTOVER_STEP_4_DEPLOY_15" ]]; then
    echo "Set BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_4_DEPLOY_15 for this exact cutover step." >&2
    exit 77
fi

# Pull once more immediately before the first mutation. A changed inventory,
# payload, maintenance guard, or schema invalidates the reviewed plan.
REMOTE_JIT="$WORK/remote-jit"
JIT_MANIFEST="$WORK/remote-jit.json"
pull_remote_functions "$REMOTE_JIT"
validate_inventory "$REMOTE_JIT/base44/functions" remote-jit "${ALL_FUNCTIONS[@]}"
write_payload_manifest "$REMOTE_JIT/base44/functions" \
    "$JIT_MANIFEST" "${ALL_FUNCTIONS[@]}"
[[ "$(manifest_projection_digest "$JIT_MANIFEST" cli_input_digest)" == "$remote_cli_input_digest" ]] || {
    echo "Production functions changed after plan preparation; refusing deployment." >&2
    exit 77
}
[[ "$(guard_digest "$REMOTE_JIT/base44/functions")" == "$delete_guard_digest" ]] || {
    echo "Production deleteAccount guard changed after plan preparation." >&2
    exit 77
}

"$ROOT/scripts/push-base44-final-schema.sh" --check
jit_schema_remote_digest="$(jq -er '.remote_digest' "$SCHEMA_MANIFEST")"
jit_schema_plan_digest="$(jq -er '.plan_digest' "$SCHEMA_MANIFEST")"
reviewed_schema_remote_digest="$(jq -er '.schema_remote_digest' "$REVIEWED_MANIFEST")"
reviewed_schema_plan_digest="$(jq -er '.schema_plan_digest' "$REVIEWED_MANIFEST")"
if [[ "$jit_schema_remote_digest" != "$reviewed_schema_remote_digest" || \
      "$jit_schema_plan_digest" != "$reviewed_schema_plan_digest" ]]; then
    echo "Production schema changed after coordinated-function review." >&2
    exit 77
fi

# Re-read the checked-in sources and hash the exact fixed CLI stage at the last
# possible point before deployment. The candidate reproduction above is not
# sufficient if either tree changes while the confirmation is being checked.
LOCAL_SOURCE_JIT="$WORK/local-source-jit.json"
write_payload_manifest "$ROOT/base44/functions" \
    "$LOCAL_SOURCE_JIT" "${FUNCTIONS[@]}"
jit_local_cli_input_digest="$(manifest_projection_digest "$LOCAL_SOURCE_JIT" cli_input_digest)"
jit_local_function_digest="$(manifest_projection_digest "$LOCAL_SOURCE_JIT" effective_digest)"
jit_fixed_stage_bytes_digest="$(tree_bytes_digest "$FIXED_STAGE/deploy/base44")"
if [[ "$jit_local_cli_input_digest" != "$reviewed_local_source_cli_input_digest" || \
      "$jit_local_function_digest" != "$reviewed_local_source_function_digest" || \
      "$jit_fixed_stage_bytes_digest" != "$reviewed_deploy_stage_bytes_digest" ]]; then
    echo "Fixed deploy stage or checked-in function sources changed immediately before deploy." >&2
    exit 77
fi
cmp -s "$LOCAL_SOURCE_JIT" "$FIXED_STAGE/local-source-functions.json" || {
    echo "Checked-in function payload no longer matches the fixed reviewed source manifest." >&2
    exit 77
}
for evidence_destination in \
    "$EVIDENCE_DIR/latest-postflight.json" \
    "$FIXED_STAGE/postflight.json"
do
    if [[ -e "$evidence_destination" || -L "$evidence_destination" ]]; then
        secure_private_json_file "$evidence_destination" || {
            echo "Unsafe existing coordinated-function postflight destination: $evidence_destination" >&2
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
    --arg action "SECURITY_CUTOVER_STEP_4_DEPLOY_15" \
    --arg reviewed_manifest_digest "$reviewed_manifest_digest" \
    --arg reviewed_plan_digest "$reviewed_plan_digest" \
    --arg fixed_stage_bytes_digest "$jit_fixed_stage_bytes_digest" \
    --arg local_source_cli_input_digest "$jit_local_cli_input_digest" \
    --arg schema_remote_digest "$jit_schema_remote_digest" \
    --arg schema_plan_digest "$jit_schema_plan_digest" \
    '{attempted_at:$attempted_at,app_id:$app_id,action:$action,reviewed_manifest_digest:$reviewed_manifest_digest,reviewed_plan_digest:$reviewed_plan_digest,fixed_stage_bytes_digest:$fixed_stage_bytes_digest,local_source_cli_input_digest:$local_source_cli_input_digest,schema_remote_digest:$schema_remote_digest,schema_plan_digest:$schema_plan_digest,status:"mutation-started-postflight-required",postflight_required:true}' \
    > "$attempt_tmp"
chmod 600 "$attempt_tmp"
jq -e \
    --arg app_id "$APP_ID" \
    --arg action "SECURITY_CUTOVER_STEP_4_DEPLOY_15" \
    --arg plan_digest "$reviewed_plan_digest" '
      .app_id == $app_id and .action == $action and
      .reviewed_plan_digest == $plan_digest and
      .status == "mutation-started-postflight-required" and
      .postflight_required == true
    ' "$attempt_tmp" >/dev/null
install_durable_json "$attempt_tmp" "$attempt_dir/attempt.json" "$attempt_dir" attempt

# The Base44 CLI deploys this explicit list sequentially and is not atomic.
# Capture its status, then always pull and classify the resulting remote state.
deploy_status=0
set +e
(cd "$FIXED_STAGE/deploy" && base44_cli functions deploy "${FUNCTIONS[@]}")
deploy_status=$?
set -e

VERIFY_REMOTE="$WORK/verify-remote"
VERIFY_MANIFEST="$WORK/verify-targets.json"
printf '[]\n' > "$VERIFY_MANIFEST"
function_postflight_status=0
set +e
(
    set -e
    pull_remote_functions "$VERIFY_REMOTE"
    validate_inventory "$VERIFY_REMOTE/base44/functions" remote-after "${ALL_FUNCTIONS[@]}"
    write_payload_manifest "$VERIFY_REMOTE/base44/functions" \
        "$VERIFY_MANIFEST" "${FUNCTIONS[@]}"
    manifest_projection_digest "$VERIFY_MANIFEST" effective_digest \
        > "$WORK/verified-function-digest.txt"
    guard_digest "$VERIFY_REMOTE/base44/functions" \
        > "$WORK/verified-guard-digest.txt"
)
function_postflight_status=$?
set -e
verified_digest=""
verified_guard_digest=""
if [[ "$function_postflight_status" -eq 0 ]] && \
   jq -e 'type == "array"' "$VERIFY_MANIFEST" >/dev/null 2>&1; then
    verified_digest="$(sed -n '1p' "$WORK/verified-function-digest.txt")"
    verified_guard_digest="$(sed -n '1p' "$WORK/verified-guard-digest.txt")"
else
    printf '[]\n' > "$VERIFY_MANIFEST"
fi

# A function deploy can overlap an out-of-band schema edit. Re-run the complete
# read-only final-schema classifier after the deploy and bind success to the
# exact schema digest/plan that was checked immediately before mutation.
schema_postflight_status=0
set +e
(
    set -e
    "$ROOT/scripts/push-base44-final-schema.sh" --check \
        > "$WORK/schema-postflight.log" 2>&1
    secure_private_json_file "$SCHEMA_MANIFEST"
    jq -er '.remote_digest' "$SCHEMA_MANIFEST" > "$WORK/schema-postflight-remote.txt"
    jq -er '.plan_digest' "$SCHEMA_MANIFEST" > "$WORK/schema-postflight-plan.txt"
)
schema_postflight_status=$?
set -e
post_schema_remote_digest=""
post_schema_plan_digest=""
schema_postflight_matches=false
if [[ "$schema_postflight_status" -eq 0 ]]; then
    post_schema_remote_digest="$(sed -n '1p' "$WORK/schema-postflight-remote.txt")"
    post_schema_plan_digest="$(sed -n '1p' "$WORK/schema-postflight-plan.txt")"
    if [[ "$post_schema_remote_digest" == "$jit_schema_remote_digest" && \
          "$post_schema_plan_digest" == "$jit_schema_plan_digest" ]]; then
        schema_postflight_matches=true
    fi
fi

jq -n \
    --arg audited_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg reviewed_manifest_digest "$reviewed_manifest_digest" \
    --arg reviewed_plan_digest "$reviewed_plan_digest" \
    --arg jit_schema_remote_digest "$jit_schema_remote_digest" \
    --arg jit_schema_plan_digest "$jit_schema_plan_digest" \
    --arg post_schema_remote_digest "$post_schema_remote_digest" \
    --arg post_schema_plan_digest "$post_schema_plan_digest" \
    --argjson deploy_status "$deploy_status" \
    --argjson function_postflight_status "$function_postflight_status" \
    --argjson schema_postflight_status "$schema_postflight_status" \
    --argjson schema_postflight_matches "$schema_postflight_matches" \
    --arg expected_digest "$local_function_digest" \
    --arg verified_digest "$verified_digest" \
    --arg expected_guard_digest "$delete_guard_digest" \
    --arg verified_guard_digest "$verified_guard_digest" \
    --slurpfile expected "$local_functions_manifest" \
    --slurpfile actual "$VERIFY_MANIFEST" \
    '{
      audited_at:$audited_at,
      reviewed_manifest_digest:$reviewed_manifest_digest,
      reviewed_plan_digest:$reviewed_plan_digest,
      jit_schema_remote_digest:$jit_schema_remote_digest,
      jit_schema_plan_digest:$jit_schema_plan_digest,
      post_schema_remote_digest:(if ($post_schema_remote_digest|length) == 0 then null else $post_schema_remote_digest end),
      post_schema_plan_digest:(if ($post_schema_plan_digest|length) == 0 then null else $post_schema_plan_digest end),
      deploy_status:$deploy_status,
      function_postflight_status:$function_postflight_status,
      schema_postflight_status:$schema_postflight_status,
      schema_postflight_matches:$schema_postflight_matches,
      expected_digest:$expected_digest,
      verified_digest:$verified_digest,
      expected_guard_digest:$expected_guard_digest,
      verified_guard_digest:$verified_guard_digest,
      functions:[
        $expected[0][] as $wanted |
        ($actual[0] | map(select(.name == $wanted.name))[0] // null) as $found |
        {
          name:$wanted.name,
          expected_digest:$wanted.effective_digest,
          actual_digest:($found.effective_digest // null),
          matches:($found != null and $found.effective_digest == $wanted.effective_digest)
        }
      ]
    }' > "$WORK/postflight.json"
chmod 600 "$WORK/postflight.json"
install_durable_json "$WORK/postflight.json" "$attempt_dir/postflight.json" "$attempt_dir" postflight
install_durable_json "$WORK/postflight.json" "$EVIDENCE_DIR/latest-postflight.json" "$EVIDENCE_DIR" latest-postflight
if [[ ! -L "$FIXED_STAGE/postflight.json" ]]; then
    cp "$WORK/postflight.json" "$FIXED_STAGE/postflight.json" || true
    chmod 600 "$FIXED_STAGE/postflight.json" 2>/dev/null || true
fi

if [[ "$deploy_status" -ne 0 || "$function_postflight_status" -ne 0 || \
      "$schema_postflight_status" -ne 0 || "$schema_postflight_matches" != true || \
      "$verified_digest" != "$local_function_digest" || \
      "$verified_guard_digest" != "$delete_guard_digest" ]]; then
    echo "Coordinated deployment did not reach the fully verified state." >&2
    echo "Inspect $attempt_dir/postflight.json before any forward-fix." >&2
    exit 70
fi

echo "Coordinated Base44 function deployment verified: $verified_digest"
