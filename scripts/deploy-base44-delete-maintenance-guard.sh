#!/bin/bash

set -euo pipefail
umask 077

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
APP_FILE="$ROOT/base44/.app.jsonc"
EXPECTED_APP_ID="69a0e57fa939f578082f8091"
APP_ID="$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_FILE" | head -n 1)"
LOCAL_GUARD="$ROOT/scripts/base44-maintenance/deleteAccount"
CUTOVER_DIR="$ROOT/.base44-cutover"
STAGE="$CUTOVER_DIR/delete-maintenance-guard"
DEPLOY_STAGE="$STAGE/deploy"
REMOTE_BEFORE="$STAGE/remote-before"
MANIFEST="$STAGE/manifest.json"
POSTFLIGHT="$STAGE/postflight.json"
ATTEMPT="$STAGE/attempt.json"
EVIDENCE_DIR="$CUTOVER_DIR/evidence/delete-maintenance-guard"
STAGE_SNAPSHOTS="$EVIDENCE_DIR/stage-snapshots"
LOCK_DIR="$CUTOVER_DIR/.delete-maintenance-guard.lock"
PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spyclash-delete-guard.XXXXXX")"
LOCK_HELD=0
PRODUCTION_LOCK_HELD=0
MODE="prepare"

EXPECTED_REMOTE_FUNCTIONS=(
    advanceRound
    app-store-entitlement
    appleAuthBroker
    appleAuthCallback
    autoRegisterUser
    checkSubscription
    communityAction
    createCheckout
    deleteAccount
    gameRoomAction
    generateWordPack
    googleAuthCallback
    mobileAuthCallback
    pushNotificationAction
    stripe-entitlement-webhook
    wordPackAction
)

cleanup() {
    case "$WORK" in
        "${TMPDIR:-/tmp}"/spyclash-delete-guard.*)
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
if [[ -n "${BASE44_APP_ID+x}" && "$BASE44_APP_ID" != "$APP_ID" ]]; then
    echo "BASE44_APP_ID targets $BASE44_APP_ID, not reviewed app $APP_ID." >&2
    exit 77
fi
if [[ -n "${BASE44_DELETE_GUARD_STAGE_DIR+x}" ]]; then
    echo "BASE44_DELETE_GUARD_STAGE_DIR is not supported; the stage path is fixed at $STAGE." >&2
    exit 64
fi
[[ -n "$ROOT" && "$ROOT" != "/" ]] || {
    echo "Unsafe repository root; refusing to prepare the deleteAccount guard." >&2
    exit 65
}
[[ "$STAGE" == "$ROOT/.base44-cutover/delete-maintenance-guard" ]] || {
    echo "Unsafe deleteAccount guard stage path; refusing to continue." >&2
    exit 65
}
[[ "$STAGE_SNAPSHOTS" == "$ROOT/.base44-cutover/evidence/delete-maintenance-guard/stage-snapshots" ]] || {
    echo "Unsafe deleteAccount guard evidence path; refusing to continue." >&2
    exit 65
}
[[ ! -L "$CUTOVER_DIR" ]] || {
    echo "$CUTOVER_DIR must not be a symbolic link." >&2
    exit 65
}
[[ ! -L "$STAGE" ]] || {
    echo "$STAGE must not be a symbolic link." >&2
    exit 65
}
for evidence_path in "$CUTOVER_DIR/evidence" "$EVIDENCE_DIR" "$STAGE_SNAPSHOTS"; do
    [[ ! -L "$evidence_path" ]] || {
        echo "$evidence_path must not be a symbolic link." >&2
        exit 65
    }
done

for command in awk basename chmod cmp cp date env find grep head jq mkdir mktemp mv npx rm \
    rmdir sed shasum sort stat sync tr wc; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "Missing required command: $command" >&2
        exit 69
    }
done

private_mode() {
    local path=$1
    local mode

    if mode="$(stat -f '%Lp' "$path" 2>/dev/null)"; then
        printf '%s\n' "$mode"
        return 0
    fi
    stat -c '%a' "$path" 2>/dev/null
}

secure_private_directory() {
    local directory=$1
    local label=$2
    local mode

    [[ -d "$directory" && ! -L "$directory" && -O "$directory" ]] || {
        echo "Unsafe $label directory (must be owned by the current user and not a symlink): $directory" >&2
        return 65
    }
    chmod 700 "$directory"
    mode="$(private_mode "$directory")" || {
        echo "Unable to verify permissions for $label directory: $directory" >&2
        return 65
    }
    [[ "$mode" == "700" ]] || {
        echo "$label directory is not private (mode $mode): $directory" >&2
        return 65
    }
}

secure_private_tree() {
    local tree=$1
    local label=$2
    local entry expected_mode mode

    secure_private_directory "$tree" "$label"
    while IFS= read -r -d '' entry; do
        [[ ! -L "$entry" && -O "$entry" ]] || {
            echo "Unsafe $label entry (must be owned by the current user and not a symlink): $entry" >&2
            return 65
        }
        if [[ -d "$entry" ]]; then
            expected_mode=700
        elif [[ -f "$entry" ]]; then
            expected_mode=600
        else
            echo "Unsafe non-file entry in $label tree: $entry" >&2
            return 65
        fi
        chmod "$expected_mode" "$entry"
        mode="$(private_mode "$entry")" || {
            echo "Unable to verify permissions for $label entry: $entry" >&2
            return 65
        }
        [[ "$mode" == "$expected_mode" ]] || {
            echo "$label entry has mode $mode, expected $expected_mode: $entry" >&2
            return 65
        }
    done < <(find "$tree" -print0)
}

atomic_private_json_file() {
    local source=$1
    local destination=$2
    local label=$3
    local temporary links

    case "$destination" in
        "$ATTEMPT"|"$POSTFLIGHT"|"$MANIFEST") ;;
        *)
            echo "Refusing unsafe deleteAccount guard evidence destination." >&2
            return 65
            ;;
    esac
    [[ "$label" =~ ^[A-Za-z0-9_-]+$ ]] || return 65
    [[ -f "$source" && ! -L "$source" && -O "$source" ]] || return 65
    jq -e . "$source" >/dev/null || return 65
    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" && -O "$destination" ]] || {
            echo "DeleteAccount guard evidence destination is unsafe: $destination" >&2
            return 65
        }
    fi
    temporary="$(mktemp "$STAGE/.${label}.XXXXXX")" || return 70
    chmod 600 "$temporary" || { rm -f -- "$temporary"; return 70; }
    cp "$source" "$temporary" && cmp -s "$source" "$temporary" || {
        rm -f -- "$temporary"
        return 70
    }
    links="$(stat -f '%l' "$temporary" 2>/dev/null || stat -c '%h' "$temporary")"
    [[ -f "$temporary" && ! -L "$temporary" && -O "$temporary" && \
       "$(private_mode "$temporary")" == 600 && "$links" == 1 ]] || {
        rm -f -- "$temporary"
        return 70
    }
    mv "$temporary" "$destination" || { rm -f -- "$temporary"; return 70; }
    links="$(stat -f '%l' "$destination" 2>/dev/null || stat -c '%h' "$destination")"
    [[ -f "$destination" && ! -L "$destination" && -O "$destination" && \
       "$(private_mode "$destination")" == 600 && "$links" == 1 ]] || return 70
    sync || return 70
}

acquire_production_lock() {
    if ! mkdir "$PRODUCTION_LOCK_DIR" 2>/dev/null; then
        echo "Another Base44 Production mutation holds $PRODUCTION_LOCK_DIR." >&2
        echo "A stale lock must be reclaimed only after manual PID/path verification." >&2
        return 75
    fi
    PRODUCTION_LOCK_HELD=1
    secure_private_directory "$PRODUCTION_LOCK_DIR" "shared Base44 Production lock"
    printf 'SECURITY_CUTOVER_STEP_3_DELETE_ACCOUNT_GUARD:%s\n' "$$" > "$PRODUCTION_LOCK_OWNER"
    chmod 600 "$PRODUCTION_LOCK_OWNER"
    [[ -f "$PRODUCTION_LOCK_OWNER" && ! -L "$PRODUCTION_LOCK_OWNER" && \
       -O "$PRODUCTION_LOCK_OWNER" ]] || return 65
}

base44_cli() {
    env -u BASE44_APP_ID npx --yes base44@0.1.4 \
        --app-id "$APP_ID" "$@"
}

expected_names_file() {
    local output=$1
    printf '%s\n' "${EXPECTED_REMOTE_FUNCTIONS[@]}" | LC_ALL=C sort > "$output"
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
    [[ -f "$function_dir/function.jsonc" && ! -L "$function_dir/function.jsonc" ]] || {
        echo "Function $function_name is missing a safe function.jsonc." >&2
        return 65
    }
    declared_name="$(jq -er '.name' "$function_dir/function.jsonc")"
    [[ "$declared_name" == "$function_name" ]] || {
        echo "Function directory/name mismatch: $function_name != $declared_name" >&2
        return 65
    }
    entry="$(jq -er '.entry' "$function_dir/function.jsonc")"
    [[ "$entry" =~ ^[A-Za-z0-9._-]+$ && -f "$function_dir/$entry" && \
       ! -L "$function_dir/$entry" ]] || {
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

validate_exact_directory_inventory() {
    local functions_root=$1
    local label=$2
    local expected="$WORK/$label-expected-names.txt"
    local actual="$WORK/$label-actual-names.txt"
    local function_name

    [[ -d "$functions_root" && ! -L "$functions_root" ]] || {
        echo "Missing or unsafe $label function root: $functions_root" >&2
        return 65
    }
    if find "$functions_root" -mindepth 1 -maxdepth 1 ! -type d -print | grep -q .; then
        echo "$label function root contains a non-function top-level entry." >&2
        return 65
    fi
    expected_names_file "$expected"
    find "$functions_root" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
        | LC_ALL=C sort > "$actual"
    if ! cmp -s "$expected" "$actual"; then
        echo "$label function inventory differs from the reviewed exact 16-function set." >&2
        echo "Expected:" >&2
        sed 's/^/  /' "$expected" >&2
        echo "Actual:" >&2
        sed 's/^/  /' "$actual" >&2
        return 65
    fi
    for function_name in "${EXPECTED_REMOTE_FUNCTIONS[@]}"; do
        validate_function "$functions_root" "$function_name"
    done
}

validate_exact_list_output() {
    local list_output=$1
    local label=$2
    local expected="$WORK/$label-list-expected.txt"
    local actual="$WORK/$label-list-actual.txt"

    expected_names_file "$expected"
    sed -E -n \
        's/^[[:space:]]+([A-Za-z0-9_-]+)([[:space:]]+\([0-9]+ automation(s)?\))?[[:space:]]*$/\1/p' \
        "$list_output" | LC_ALL=C sort > "$actual"
    grep -Eq '^16 functions on remote[[:space:]]*$' "$list_output" || {
        echo "$label list output does not report exactly 16 remote functions." >&2
        return 65
    }
    if ! cmp -s "$expected" "$actual"; then
        echo "$label list output differs from the reviewed exact 16-function set." >&2
        echo "Expected:" >&2
        sed 's/^/  /' "$expected" >&2
        echo "Actual:" >&2
        sed 's/^/  /' "$actual" >&2
        return 65
    fi
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

function_semantic_object() {
    local functions_root=$1
    local function_name=$2
    local output=$3
    local function_dir="$functions_root/$function_name"
    local records="$WORK/semantic-$function_name-files.txt"
    local config="$WORK/semantic-$function_name-config.json"
    local config_digest source_digest semantic_digest source_count relative

    validate_function "$functions_root" "$function_name"
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
    config_digest="$(shasum -a 256 "$config" | awk '{print $1}')"
    source_digest="$(shasum -a 256 "$records" | awk '{print $1}')"
    semantic_digest="$(printf '%s\n' "$function_name" "$config_digest" "$source_digest" \
        | shasum -a 256 | awk '{print $1}')"
    jq -n \
        --arg name "$function_name" \
        --arg config_digest "$config_digest" \
        --arg source_digest "$source_digest" \
        --arg semantic_digest "$semantic_digest" \
        --argjson source_file_count "$source_count" \
        '{name:$name,config_digest:$config_digest,source_digest:$source_digest,semantic_digest:$semantic_digest,source_file_count:$source_file_count}' \
        > "$output"
}

write_semantic_manifest() {
    local functions_root=$1
    local output=$2
    local objects="$WORK/semantic-objects.jsonl"
    local object function_name

    : > "$objects"
    for function_name in "${EXPECTED_REMOTE_FUNCTIONS[@]}"; do
        object="$WORK/semantic-object-$function_name.json"
        function_semantic_object "$functions_root" "$function_name" "$object"
        jq -c . "$object" >> "$objects"
    done
    jq -s 'sort_by(.name)' "$objects" > "$output"
}

semantic_manifest_digest() {
    local manifest=$1
    local projection="$WORK/semantic-projection.json"

    jq -S 'map({name,semantic_digest})' "$manifest" > "$projection"
    shasum -a 256 "$projection" | awk '{print $1}'
}

pull_remote_snapshot() {
    local destination=$1
    local label=$2
    local semantic_manifest=$3
    local list_output="$destination/functions-list.txt"
    local pull_output="$destination/functions-pull.txt"

    mkdir -p "$destination/base44"
    cp "$ROOT/base44/config.jsonc" "$destination/base44/config.jsonc"
    cp "$APP_FILE" "$destination/base44/.app.jsonc"
    if ! base44_cli functions list > "$list_output" 2>&1; then
        sed 's/^/  /' "$list_output" >&2
        echo "Unable to list the fresh Production function inventory." >&2
        return 70
    fi
    validate_exact_list_output "$list_output" "$label"
    if ! (cd "$destination" && base44_cli functions pull) > "$pull_output" 2>&1; then
        sed 's/^/  /' "$pull_output" >&2
        echo "Unable to pull the fresh Production function inventory." >&2
        return 70
    fi
    validate_exact_directory_inventory "$destination/base44/functions" "$label"
    write_semantic_manifest "$destination/base44/functions" "$semantic_manifest"
}

copy_local_guard() {
    mkdir -p "$DEPLOY_STAGE/base44/functions"
    cp "$ROOT/base44/config.jsonc" "$DEPLOY_STAGE/base44/config.jsonc"
    cp "$APP_FILE" "$DEPLOY_STAGE/base44/.app.jsonc"
    cp -R "$LOCAL_GUARD" "$DEPLOY_STAGE/base44/functions/deleteAccount"
    validate_function "$DEPLOY_STAGE/base44/functions" deleteAccount
    if [[ "$(find "$DEPLOY_STAGE/base44/functions" -mindepth 1 -maxdepth 1 -type d \
        -exec basename {} \; | LC_ALL=C sort)" != "deleteAccount" ]]; then
        echo "Deployment stage must contain only deleteAccount." >&2
        return 65
    fi
}

preserve_previous_stage_evidence() {
    [[ -e "$STAGE" ]] || return 0
    [[ -d "$STAGE" && ! -L "$STAGE" ]] || {
        echo "Existing deleteAccount guard stage is unsafe." >&2
        return 65
    }
    secure_private_tree "$STAGE" "existing deleteAccount guard stage"

    local has_attempt_evidence=false
    local evidence_source=""
    local evidence_digest digest_prefix snapshot_id snapshot_dir
    local evidence_file
    for evidence_file in "$ATTEMPT" "$POSTFLIGHT"; do
        if [[ -e "$evidence_file" || -L "$evidence_file" ]]; then
            [[ -f "$evidence_file" && ! -L "$evidence_file" ]] || {
                echo "Unsafe deleteAccount guard attempt evidence: $evidence_file" >&2
                return 65
            }
            has_attempt_evidence=true
            evidence_source="$evidence_file"
        fi
    done
    if [[ -e "$MANIFEST" || -L "$MANIFEST" ]]; then
        [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || {
            echo "Unsafe deleteAccount guard manifest evidence: $MANIFEST" >&2
            return 65
        }
    fi
    if [[ -f "$MANIFEST" ]] && \
       jq -e '(.deployed_at // .verified_at // "") | length > 0' \
         "$MANIFEST" >/dev/null 2>&1; then
        has_attempt_evidence=true
        [[ -n "$evidence_source" ]] || evidence_source="$MANIFEST"
    fi

    if [[ "$has_attempt_evidence" != true ]]; then
        rm -rf -- "$STAGE"
        return 0
    fi

    mkdir -p "$STAGE_SNAPSHOTS"
    secure_private_directory "$CUTOVER_DIR/evidence" "Base44 evidence root"
    secure_private_tree "$EVIDENCE_DIR" "deleteAccount guard evidence"
    secure_private_directory "$STAGE_SNAPSHOTS" "deleteAccount guard stage snapshots"
    evidence_digest="$(shasum -a 256 "$evidence_source" | awk '{print $1}')"
    digest_prefix="$(printf '%s\n' "$evidence_digest" | sed 's/^\(.\{12\}\).*/\1/')"
    snapshot_id="$(date -u +%Y%m%dT%H%M%SZ)-$digest_prefix-$$"
    snapshot_dir="$STAGE_SNAPSHOTS/$snapshot_id"
    [[ ! -e "$snapshot_dir" && ! -L "$snapshot_dir" ]] || {
        echo "DeleteAccount guard evidence snapshot already exists: $snapshot_dir" >&2
        return 75
    }
    mv "$STAGE" "$snapshot_dir"
    secure_private_tree "$snapshot_dir" "deleteAccount guard evidence snapshot"
    echo "Preserved previous deleteAccount guard attempt evidence: $snapshot_dir"
}

base44_cli whoami >/dev/null

mkdir -p "$CUTOVER_DIR"
secure_private_directory "$CUTOVER_DIR" "Base44 cutover"
if [[ "$MODE" == "deploy" ]]; then
    acquire_production_lock
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another deleteAccount guard audit/deploy is already active: $LOCK_DIR" >&2
    exit 75
fi
LOCK_HELD=1
secure_private_directory "$LOCK_DIR" "deleteAccount guard lock"
mkdir -p "$STAGE_SNAPSHOTS"
secure_private_directory "$CUTOVER_DIR/evidence" "Base44 evidence root"
secure_private_tree "$EVIDENCE_DIR" "deleteAccount guard evidence"
secure_private_directory "$STAGE_SNAPSHOTS" "deleteAccount guard stage snapshots"

preserve_previous_stage_evidence
mkdir -p "$DEPLOY_STAGE/base44/functions"
secure_private_directory "$STAGE" "deleteAccount guard stage"
secure_private_directory "$DEPLOY_STAGE" "deleteAccount guard deploy stage"
secure_private_directory "$DEPLOY_STAGE/base44" "deleteAccount guard Base44 stage"
secure_private_directory "$DEPLOY_STAGE/base44/functions" "deleteAccount guard function stage"
copy_local_guard
secure_private_tree "$STAGE" "deleteAccount guard stage"

local_guard_object="$STAGE/local-guard.json"
function_semantic_object "$DEPLOY_STAGE/base44/functions" deleteAccount "$local_guard_object"
local_guard_digest="$(jq -er '.semantic_digest' "$local_guard_object")"

remote_before_manifest="$STAGE/remote-functions-before.json"
pull_remote_snapshot "$REMOTE_BEFORE" remote-before "$remote_before_manifest"
remote_inventory_digest="$(semantic_manifest_digest "$remote_before_manifest")"
remote_guard_digest="$(jq -er '.[] | select(.name == "deleteAccount") | .semantic_digest' \
    "$remote_before_manifest")"
expected_names_json="$(printf '%s\n' "${EXPECTED_REMOTE_FUNCTIONS[@]}" \
    | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')"
change_needed=true
if [[ "$remote_guard_digest" == "$local_guard_digest" ]]; then
    change_needed=false
fi

plan_input="$WORK/plan-input.json"
jq -n -S \
    --arg step "SECURITY_CUTOVER_STEP_3_DELETE_ACCOUNT_GUARD" \
    --arg app_id "$APP_ID" \
    --arg remote_inventory_digest "$remote_inventory_digest" \
    --arg remote_guard_digest "$remote_guard_digest" \
    --arg local_guard_digest "$local_guard_digest" \
    --argjson expected_remote_functions "$expected_names_json" \
    '{step:$step,app_id:$app_id,expected_remote_functions:$expected_remote_functions,remote_inventory_digest:$remote_inventory_digest,remote_guard_digest:$remote_guard_digest,local_guard_digest:$local_guard_digest}' \
    > "$plan_input"
plan_digest="$(shasum -a 256 "$plan_input" | awk '{print $1}')"

jq -n \
    --arg app_id "$APP_ID" \
    --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg remote_inventory_digest "$remote_inventory_digest" \
    --arg remote_delete_account_semantic_digest "$remote_guard_digest" \
    --arg desired_delete_account_semantic_digest "$local_guard_digest" \
    --arg plan_digest "$plan_digest" \
    --argjson change_needed "$change_needed" \
    --argjson expected_remote_functions "$expected_names_json" \
    --slurpfile remote_functions "$remote_before_manifest" \
    --slurpfile local_guard "$local_guard_object" \
    '{
      app_id:$app_id,
      prepared_at:$prepared_at,
      expected_remote_function_count:($expected_remote_functions | length),
      expected_remote_functions:$expected_remote_functions,
      remote_inventory_digest:$remote_inventory_digest,
      remote_delete_account_semantic_digest:$remote_delete_account_semantic_digest,
      desired_delete_account_semantic_digest:$desired_delete_account_semantic_digest,
      change_needed:$change_needed,
      remote_functions:$remote_functions[0],
      desired_delete_account:$local_guard[0],
      plan_digest:$plan_digest
    }' > "$MANIFEST"
secure_private_tree "$STAGE" "deleteAccount guard stage"

echo "Prepared Base44 deleteAccount maintenance-guard stage: $STAGE"
echo "App id: $APP_ID"
echo "Remote inventory: ${#EXPECTED_REMOTE_FUNCTIONS[@]} functions (exact)"
echo "Remote deleteAccount semantic digest: $remote_guard_digest"
echo "Desired maintenance-guard digest: $local_guard_digest"
echo "Change needed: $change_needed"
echo "Plan digest: $plan_digest"

if [[ "$MODE" == "prepare" ]]; then
    echo "No remote change was made. Inspect $MANIFEST, then request the exact Step 3 confirmation before --deploy."
    exit 0
fi

if [[ "${BASE44_CONFIRM_ACTION:-}" != "SECURITY_CUTOVER_STEP_3_DELETE_ACCOUNT_GUARD" ]]; then
    echo "Set BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_3_DELETE_ACCOUNT_GUARD for this exact cutover step." >&2
    exit 77
fi
if [[ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]]; then
    echo "Set BASE44_CONFIRM_APP_ID=$APP_ID for the intentional deleteAccount guard deployment." >&2
    exit 77
fi
if [[ "${BASE44_CONFIRM_DELETE_GUARD_PLAN_DIGEST:-}" != "$plan_digest" ]]; then
    echo "Fresh deleteAccount guard plan differs from the inspected plan." >&2
    echo "Inspect $MANIFEST, then set BASE44_CONFIRM_DELETE_GUARD_PLAN_DIGEST to its plan_digest." >&2
    exit 77
fi
if [[ "$change_needed" == false ]]; then
    echo "Production deleteAccount already matches the reviewed maintenance guard; no deployment was made."
    exit 0
fi

# Pull immediately before the sole Production mutation. Any remote function
# change invalidates the reviewed plan, even when deleteAccount itself is stable.
REMOTE_JIT="$WORK/remote-jit"
JIT_MANIFEST="$WORK/remote-jit-functions.json"
pull_remote_snapshot "$REMOTE_JIT" remote-jit "$JIT_MANIFEST"
jit_inventory_digest="$(semantic_manifest_digest "$JIT_MANIFEST")"
jit_guard_digest="$(jq -er '.[] | select(.name == "deleteAccount") | .semantic_digest' \
    "$JIT_MANIFEST")"
[[ "$jit_inventory_digest" == "$remote_inventory_digest" && \
   "$jit_guard_digest" == "$remote_guard_digest" ]] || {
    echo "Production functions changed after plan preparation; refusing deployment." >&2
    exit 77
}
stage_guard_object="$WORK/staged-local-guard.json"
function_semantic_object "$DEPLOY_STAGE/base44/functions" deleteAccount "$stage_guard_object"
[[ "$(jq -er '.semantic_digest' "$stage_guard_object")" == "$local_guard_digest" ]] || {
    echo "The staged maintenance guard changed after plan preparation; refusing deployment." >&2
    exit 77
}

# The Base44 CLI deploys only this explicit name. Capture the status, then
# always pull Production again and write a postflight report before returning.
attempt_tmp="$WORK/attempt.json"
jq -n \
    --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg app_id "$APP_ID" \
    --arg plan_digest "$plan_digest" \
    --arg expected_guard_digest "$local_guard_digest" \
    '{started_at:$started_at,app_id:$app_id,plan_digest:$plan_digest,expected_guard_digest:$expected_guard_digest,status:"mutation-started-postflight-required"}' \
    > "$attempt_tmp"
chmod 600 "$attempt_tmp"
jq -e \
    --arg app_id "$APP_ID" \
    --arg plan_digest "$plan_digest" '
      .app_id == $app_id and .plan_digest == $plan_digest and
      .status == "mutation-started-postflight-required"
    ' "$attempt_tmp" >/dev/null
atomic_private_json_file "$attempt_tmp" "$ATTEMPT" attempt
deploy_status=0
set +e
(cd "$DEPLOY_STAGE" && base44_cli functions deploy deleteAccount)
deploy_status=$?
set -e

REMOTE_AFTER="$STAGE/remote-after"
after_manifest="$STAGE/remote-functions-after.json"
after_pull_status=0
after_inventory_digest=""
after_guard_digest=""
postflight_matches=false
set +e
(set -e; pull_remote_snapshot "$REMOTE_AFTER" remote-after "$after_manifest")
after_pull_status=$?
set -e
if [[ "$after_pull_status" -eq 0 ]]; then
    after_inventory_digest="$(semantic_manifest_digest "$after_manifest")"
    after_guard_digest="$(jq -er '.[] | select(.name == "deleteAccount") | .semantic_digest' \
        "$after_manifest")"
    unchanged_non_guard_count="$(jq -n \
        --slurpfile before "$remote_before_manifest" \
        --slurpfile after "$after_manifest" '
          [
            $before[0][] |
            select(.name != "deleteAccount") as $wanted |
            $after[0][] |
            select(.name == $wanted.name and .semantic_digest == $wanted.semantic_digest)
          ] | length
        ')"
    if [[ "$after_guard_digest" == "$local_guard_digest" && \
          "$unchanged_non_guard_count" -eq 15 ]]; then
        postflight_matches=true
    fi
else
    unchanged_non_guard_count=0
    printf '[]\n' > "$after_manifest"
fi

jq -n \
    --arg audited_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson deploy_status "$deploy_status" \
    --argjson after_pull_status "$after_pull_status" \
    --arg before_inventory_digest "$remote_inventory_digest" \
    --arg after_inventory_digest "$after_inventory_digest" \
    --arg expected_guard_digest "$local_guard_digest" \
    --arg actual_guard_digest "$after_guard_digest" \
    --argjson unchanged_non_guard_count "$unchanged_non_guard_count" \
    --argjson matches "$postflight_matches" \
    --slurpfile before "$remote_before_manifest" \
    --slurpfile after "$after_manifest" \
    '{
      audited_at:$audited_at,
      deploy_status:$deploy_status,
      after_pull_status:$after_pull_status,
      before_inventory_digest:$before_inventory_digest,
      after_inventory_digest:$after_inventory_digest,
      expected_guard_digest:$expected_guard_digest,
      actual_guard_digest:$actual_guard_digest,
      unchanged_non_guard_count:$unchanged_non_guard_count,
      matches:$matches,
      functions:[
        $before[0][] as $wanted |
        ($after[0] | map(select(.name == $wanted.name))[0] // null) as $found |
        {
          name:$wanted.name,
          before_digest:$wanted.semantic_digest,
          after_digest:($found.semantic_digest // null),
          expected_digest:(if $wanted.name == "deleteAccount" then $expected_guard_digest else $wanted.semantic_digest end),
          matches:($found != null and $found.semantic_digest == (if $wanted.name == "deleteAccount" then $expected_guard_digest else $wanted.semantic_digest end))
        }
      ]
    }' > "$POSTFLIGHT"
secure_private_tree "$STAGE" "deleteAccount guard stage"

if [[ "$deploy_status" -ne 0 || "$after_pull_status" -ne 0 || \
      "$postflight_matches" != true ]]; then
    echo "deleteAccount guard deployment did not reach the fully verified state." >&2
    echo "Inspect $POSTFLIGHT before any forward-fix." >&2
    exit 70
fi

verified_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq \
    --arg deployed_at "$verified_at" \
    --arg verified_at "$verified_at" \
    '. + {deployed_at:$deployed_at,verified_at:$verified_at}' \
    "$MANIFEST" > "$WORK/manifest.verified.json"
cp "$WORK/manifest.verified.json" "$MANIFEST"
secure_private_tree "$STAGE" "deleteAccount guard stage"

echo "Base44 deleteAccount maintenance guard deployment verified: $after_guard_digest"
