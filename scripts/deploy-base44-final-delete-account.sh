#!/bin/bash

set -euo pipefail
umask 077

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
APP_FILE="$ROOT/base44/.app.jsonc"
EXPECTED_APP_ID="69a0e57fa939f578082f8091"
APP_ID="$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_FILE" | head -n 1)"
CUTOVER_DIR="$ROOT/.base44-cutover"
STAGE="$CUTOVER_DIR/final-delete-account"
DEPLOY_STAGE="$STAGE/deploy"
REMOTE_BEFORE="$STAGE/remote-before"
SCHEMA_MANIFEST="$CUTOVER_DIR/final-schema-check/manifest.json"
BACKFILL_STAGE="$CUTOVER_DIR/sensitive-owner-backfill"
BACKFILL_MANIFEST="$BACKFILL_STAGE/manifest.json"
BACKFILL_COMPLETION="$BACKFILL_STAGE/completion.json"
BACKFILL_LAST_ATTEMPT="$BACKFILL_STAGE/last-attempt.json"
BACKFILL_REVIEWED_ROOT="$BACKFILL_STAGE/reviewed-inputs"
BACKFILL_REVIEWED_POINTER="$BACKFILL_STAGE/reviewed-inputs-current.json"
BACKFILL_OPERATION_LOCK="$CUTOVER_DIR/sensitive-owner-backfill.operation.lock"
BACKFILL_ROOM_LIFECYCLE="$ROOT/base44/functions/gameRoomAction/room-write-lifecycle.ts"
BACKFILL_BILLING_LIFECYCLE="$ROOT/base44/functions/gameRoomAction/billing-identity-lifecycle.ts"
MANIFEST="$STAGE/manifest.json"
POSTFLIGHT="$STAGE/postflight.json"
ATTEMPT="$STAGE/attempt.json"
EVIDENCE_DIR="$CUTOVER_DIR/evidence/final-delete-account"
STAGE_SNAPSHOTS="$EVIDENCE_DIR/stage-snapshots"
LOCK_DIR="$CUTOVER_DIR/.final-delete-account.lock"
PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"
PRODUCTION_LOCK_OWNER="$PRODUCTION_LOCK_DIR/owner"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spyclash-final-delete-account.XXXXXX")"
LOCK_HELD=0
PRODUCTION_LOCK_HELD=0
BACKFILL_SNAPSHOT_LOCK_HELD=0
MODE="prepare"

COORDINATED_FUNCTIONS=(
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
EXPECTED_REMOTE_FUNCTIONS=("${COORDINATED_FUNCTIONS[@]}" deleteAccount)

cleanup() {
    case "$WORK" in
        "${TMPDIR:-/tmp}"/spyclash-final-delete-account.*)
            rm -rf -- "$WORK"
            ;;
    esac
    if [[ "$BACKFILL_SNAPSHOT_LOCK_HELD" -eq 1 ]]; then
        if [[ -d "$BACKFILL_OPERATION_LOCK" && ! -L "$BACKFILL_OPERATION_LOCK" && \
              -O "$BACKFILL_OPERATION_LOCK" ]]; then
            rm -f -- "$BACKFILL_OPERATION_LOCK/owner"
            rmdir "$BACKFILL_OPERATION_LOCK" 2>/dev/null || true
        else
            echo "Refusing unsafe Step 8 backfill snapshot-lock cleanup." >&2
        fi
        BACKFILL_SNAPSHOT_LOCK_HELD=0
    fi
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
if [[ -n "${BASE44_PROJECTS_BASE44_APP_ID+x}" && \
      "$BASE44_PROJECTS_BASE44_APP_ID" != "$APP_ID" ]]; then
    echo "BASE44_PROJECTS_BASE44_APP_ID targets another app." >&2
    exit 77
fi
if [[ -n "${BASE44_FINAL_DELETE_ACCOUNT_STAGE_DIR+x}" ]]; then
    echo "BASE44_FINAL_DELETE_ACCOUNT_STAGE_DIR is not supported; the stage path is fixed at $STAGE." >&2
    exit 64
fi
[[ -n "$ROOT" && "$ROOT" != "/" ]] || {
    echo "Unsafe repository root; refusing to prepare final deleteAccount." >&2
    exit 65
}
[[ "$STAGE" == "$ROOT/.base44-cutover/final-delete-account" ]] || {
    echo "Unsafe final deleteAccount stage path; refusing to continue." >&2
    exit 65
}
[[ "$STAGE_SNAPSHOTS" == "$ROOT/.base44-cutover/evidence/final-delete-account/stage-snapshots" ]] || {
    echo "Unsafe final deleteAccount evidence path; refusing to continue." >&2
    exit 65
}
[[ "$BACKFILL_REVIEWED_POINTER" == "$ROOT/.base44-cutover/sensitive-owner-backfill/reviewed-inputs-current.json" && \
   "$BACKFILL_LAST_ATTEMPT" == "$ROOT/.base44-cutover/sensitive-owner-backfill/last-attempt.json" && \
   "$BACKFILL_REVIEWED_ROOT" == "$ROOT/.base44-cutover/sensitive-owner-backfill/reviewed-inputs" && \
   "$BACKFILL_OPERATION_LOCK" == "$ROOT/.base44-cutover/sensitive-owner-backfill.operation.lock" ]] || {
    echo "Unsafe Step 7 evidence paths; refusing final deleteAccount preparation." >&2
    exit 65
}
[[ ! -L "$CUTOVER_DIR" ]] || {
    echo "$CUTOVER_DIR must not be a symbolic link." >&2
    exit 65
}
for evidence_path in "$CUTOVER_DIR/evidence" "$EVIDENCE_DIR" "$STAGE_SNAPSHOTS"; do
    [[ ! -L "$evidence_path" ]] || {
        echo "$evidence_path must not be a symbolic link." >&2
        exit 65
    }
done
for backfill_evidence_path in \
    "$BACKFILL_STAGE" \
    "$BACKFILL_REVIEWED_ROOT" \
    "$BACKFILL_REVIEWED_POINTER" \
    "$BACKFILL_LAST_ATTEMPT" \
    "$BACKFILL_OPERATION_LOCK"
do
    [[ ! -L "$backfill_evidence_path" ]] || {
        echo "Step 7 evidence path must not be a symbolic link: $backfill_evidence_path" >&2
        exit 65
    }
done
[[ ! -L "$STAGE" ]] || {
    echo "$STAGE must not be a symbolic link." >&2
    exit 65
}
for backfill_source in \
    "$ROOT/scripts/backfill-sensitive-entity-owners.ts" \
    "$BACKFILL_ROOM_LIFECYCLE" \
    "$BACKFILL_BILLING_LIFECYCLE"
do
    [[ -f "$backfill_source" && ! -L "$backfill_source" ]] || {
        echo "Backfill source is missing or unsafe: $backfill_source" >&2
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
            echo "Refusing unsafe final deleteAccount evidence destination." >&2
            return 65
            ;;
    esac
    [[ "$label" =~ ^[A-Za-z0-9_-]+$ ]] || return 65
    [[ -f "$source" && ! -L "$source" && -O "$source" ]] || return 65
    jq -e . "$source" >/dev/null || return 65
    if [[ -e "$destination" || -L "$destination" ]]; then
        [[ -f "$destination" && ! -L "$destination" && -O "$destination" ]] || {
            echo "Final deleteAccount evidence destination is unsafe: $destination" >&2
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
    printf 'SECURITY_CUTOVER_STEP_8_FINAL_DELETE_ACCOUNT:%s\n' "$$" > "$PRODUCTION_LOCK_OWNER"
    chmod 600 "$PRODUCTION_LOCK_OWNER"
    [[ -f "$PRODUCTION_LOCK_OWNER" && ! -L "$PRODUCTION_LOCK_OWNER" && \
       -O "$PRODUCTION_LOCK_OWNER" ]] || return 65
}

acquire_backfill_snapshot_lock() {
    if ! mkdir "$BACKFILL_OPERATION_LOCK" 2>/dev/null; then
        echo "Another Step 7 operation started before Step 8 could snapshot evidence." >&2
        return 75
    fi
    BACKFILL_SNAPSHOT_LOCK_HELD=1
    secure_private_directory "$BACKFILL_OPERATION_LOCK" "Step 7 snapshot lock"
    printf 'step8-snapshot:%s\n' "$$" > "$BACKFILL_OPERATION_LOCK/owner"
    secure_private_tree "$BACKFILL_OPERATION_LOCK" "Step 7 snapshot lock"
}

release_backfill_snapshot_lock() {
    [[ "$BACKFILL_SNAPSHOT_LOCK_HELD" -eq 1 && \
       -d "$BACKFILL_OPERATION_LOCK" && ! -L "$BACKFILL_OPERATION_LOCK" && \
       -O "$BACKFILL_OPERATION_LOCK" && \
       -f "$BACKFILL_OPERATION_LOCK/owner" && ! -L "$BACKFILL_OPERATION_LOCK/owner" && \
       -O "$BACKFILL_OPERATION_LOCK/owner" ]] || {
        echo "Step 8 backfill snapshot lock changed unexpectedly." >&2
        return 65
    }
    rm -f -- "$BACKFILL_OPERATION_LOCK/owner" || return 65
    rmdir "$BACKFILL_OPERATION_LOCK" || return 65
    BACKFILL_SNAPSHOT_LOCK_HELD=0
}

base44_cli() {
    env -u BASE44_APP_ID -u BASE44_PROJECTS_BASE44_APP_ID \
        npx --yes base44@0.1.4 \
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
    local records="$WORK/semantic-$function_name-$RANDOM-files.txt"
    local config="$WORK/semantic-$function_name-$RANDOM-config.json"
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
    shift 2
    local objects="$WORK/semantic-objects-$RANDOM.jsonl"
    local object function_name

    : > "$objects"
    for function_name in "$@"; do
        object="$WORK/semantic-object-$function_name-$RANDOM.json"
        function_semantic_object "$functions_root" "$function_name" "$object"
        jq -c . "$object" >> "$objects"
    done
    jq -s 'sort_by(.name)' "$objects" > "$output"
}

semantic_manifest_digest() {
    local manifest=$1
    local projection="$WORK/semantic-projection-$RANDOM.json"

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
    write_semantic_manifest "$destination/base44/functions" "$semantic_manifest" \
        "${EXPECTED_REMOTE_FUNCTIONS[@]}"
}

copy_final_delete_account() {
    mkdir -p "$DEPLOY_STAGE/base44/functions"
    cp "$ROOT/base44/config.jsonc" "$DEPLOY_STAGE/base44/config.jsonc"
    cp "$APP_FILE" "$DEPLOY_STAGE/base44/.app.jsonc"
    cp -R "$ROOT/base44/functions/deleteAccount" \
        "$DEPLOY_STAGE/base44/functions/deleteAccount"
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
        echo "Existing final deleteAccount stage is unsafe." >&2
        return 65
    }
    secure_private_tree "$STAGE" "existing final deleteAccount stage"

    local has_attempt_evidence=false
    local evidence_source=""
    local evidence_digest digest_prefix snapshot_id snapshot_dir
    local evidence_file
    for evidence_file in "$ATTEMPT" "$POSTFLIGHT"; do
        if [[ -e "$evidence_file" || -L "$evidence_file" ]]; then
            [[ -f "$evidence_file" && ! -L "$evidence_file" ]] || {
                echo "Unsafe final deleteAccount attempt evidence: $evidence_file" >&2
                return 65
            }
            has_attempt_evidence=true
            evidence_source="$evidence_file"
        fi
    done
    if [[ -e "$MANIFEST" || -L "$MANIFEST" ]]; then
        [[ -f "$MANIFEST" && ! -L "$MANIFEST" ]] || {
            echo "Unsafe final deleteAccount manifest evidence: $MANIFEST" >&2
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
    secure_private_tree "$EVIDENCE_DIR" "final deleteAccount evidence"
    secure_private_directory "$STAGE_SNAPSHOTS" "final deleteAccount stage snapshots"
    evidence_digest="$(shasum -a 256 "$evidence_source" | awk '{print $1}')"
    digest_prefix="$(printf '%s\n' "$evidence_digest" | sed 's/^\(.\{12\}\).*/\1/')"
    snapshot_id="$(date -u +%Y%m%dT%H%M%SZ)-$digest_prefix-$$"
    snapshot_dir="$STAGE_SNAPSHOTS/$snapshot_id"
    [[ ! -e "$snapshot_dir" && ! -L "$snapshot_dir" ]] || {
        echo "Final deleteAccount evidence snapshot already exists: $snapshot_dir" >&2
        return 75
    }
    mv "$STAGE" "$snapshot_dir"
    secure_private_tree "$snapshot_dir" "final deleteAccount evidence snapshot"
    echo "Preserved previous final deleteAccount attempt evidence: $snapshot_dir"
}

refresh_schema_boundary() {
    local output=$1
    local log="$WORK/final-schema-$RANDOM.log"

    if ! env \
        -u BASE44_APP_ID \
        -u BASE44_PROJECTS_BASE44_APP_ID \
        -u BASE44_CONFIRM_ACTION \
        -u BASE44_CONFIRM_APP_ID \
        -u BASE44_CONFIRM_FINAL_PLAN_DIGEST \
        -u BASE44_FINAL_STAGE_DIR \
        "$ROOT/scripts/push-base44-final-schema.sh" --check > "$log" 2>&1; then
        sed 's/^/  /' "$log" >&2
        echo "Fresh read-only final-schema prerequisite failed; no function was deployed." >&2
        return 65
    fi
    [[ -f "$SCHEMA_MANIFEST" && ! -L "$SCHEMA_MANIFEST" ]] || {
        echo "Fresh final-schema manifest is missing or unsafe." >&2
        return 65
    }
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
    ' "$SCHEMA_MANIFEST" >/dev/null || {
        echo "Final-schema manifest does not prove live=20, canonical=20, changed=0 and the admin boundary." >&2
        return 65
    }
    jq -S '{
      app_id,
      live_count,
      canonical_count,
      adds,
      deletes,
      changed_entities_count:(.changed_entities | length),
      live_admin_write_boundary,
      remote_digest,
      canonical_digest,
      plan_digest
    }' "$SCHEMA_MANIFEST" > "$output"
}

sha256_file() {
    local path=$1
    local label=$2
    local digest

    [[ -f "$path" && ! -L "$path" ]] || {
        echo "Missing or unsafe $label: $path" >&2
        return 65
    }
    digest="$(shasum -a 256 "$path" | awk '{print $1}')"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || {
        echo "Unable to hash $label: $path" >&2
        return 65
    }
    printf '%s\n' "$digest"
}

copy_stable_backfill_file() {
    local source=$1
    local destination=$2
    local label=$3

    [[ -f "$source" && ! -L "$source" && -O "$source" ]] || {
        echo "Missing, unowned, or unsafe Step 7 $label: $source" >&2
        return 65
    }
    cp "$source" "$destination"
    [[ -f "$destination" && ! -L "$destination" && -O "$destination" ]] || return 65
    cmp -s "$source" "$destination" || {
        echo "Step 7 $label changed while it was being snapshotted." >&2
        return 75
    }
}

validate_backfill_completion() {
    local manifest=$1
    local require_completion_timestamp=${2:-true}

    [[ -f "$manifest" && ! -L "$manifest" ]] || {
        echo "Step 7 completion evidence is missing or unsafe: $manifest" >&2
        return 65
    }
    jq -e \
      --arg app_id "$APP_ID" \
      --argjson require_completion_timestamp "$require_completion_timestamp" '
      .protocol == "spyclash-sensitive-owner-backfill-wrapper-v2" and
      .app_id == $app_id and
      .mode == "apply" and
      .stable_snapshots == true and
      .success == true and
      .completion_verified == true and
      (.input_set_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.source_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.lifecycle_source_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.reviewed_inputs | keys) == [
        "billing_identity_lifecycle_sha256",
        "input_set_sha256",
        "lifecycle_source_sha256",
        "protocol",
        "room_write_lifecycle_sha256",
        "source_sha256"
      ] and
      .reviewed_inputs.protocol == "spyclash-sensitive-owner-backfill-inputs-v1" and
      .reviewed_inputs.input_set_sha256 == .input_set_sha256 and
      .reviewed_inputs.source_sha256 == .source_sha256 and
      .reviewed_inputs.lifecycle_source_sha256 == .lifecycle_source_sha256 and
      (.reviewed_inputs.room_write_lifecycle_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.reviewed_inputs.billing_identity_lifecycle_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.attempt | keys) == [
        "attempt_id",
        "postflight_required",
        "protocol",
        "started_at",
        "state"
      ] and
      .attempt.protocol == "spyclash-sensitive-owner-backfill-attempt-v1" and
      (.attempt.attempt_id | type == "string" and test("^[0-9a-f]{64}$")) and
      (.attempt.started_at | type == "string" and length > 0) and
      .attempt.state == "completed-postflight-verified" and
      .attempt.postflight_required == false and
      .final_schema.verified == true and
      .final_schema.app_id == $app_id and
      .final_schema.live_count == 20 and
      .final_schema.canonical_count == 20 and
      .final_schema.adds == 0 and
      .final_schema.deletes == 0 and
      .final_schema.changed_entities_count == 0 and
      .final_schema.live_admin_write_boundary == true and
      (.final_schema.remote_digest | type == "string" and test("^[0-9a-f]{64}$")) and
      (.preflight_snapshot_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.requested_plan_digest | type == "string" and test("^[0-9a-f]{64}$")) and
      .requested_plan_digest == .plan_digest and
      .requested_plan_digest == .apply.report.plan_digest and
      .apply.status == 0 and
      .apply.report_status == 0 and
      .apply.report.phase == "completed" and
      .apply.report.applied_room_updates == .preflight.room_updates and
      .apply.report.applied_word_pack_updates == .preflight.word_pack_updates and
      .postflight.status == 0 and
      (.postflight.snapshot_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .postflight.report.plan_digest == .plan_digest and
      .postflight.report.unresolved_total == 0 and
      .postflight.report.mismatch_total == 0 and
      .postflight.report.room_updates == 0 and
      .postflight.report.word_pack_updates == 0 and
      (.postflight.report.operator.identity_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .postflight.report.operator.role == "admin" and
      .postflight.report.operator == .preflight.operator and
      .postflight.report.source_sha256 == .source_sha256 and
      .postflight.report.lifecycle_source_sha256 == .lifecycle_source_sha256 and
      .postflight.report.final_schema_remote_digest == .final_schema.remote_digest and
      ($require_completion_timestamp == false or
        (.completion_verified_at | type == "string" and length > 0))
    ' "$manifest" >/dev/null || {
        echo "Step 7 completion/attempt evidence is not fully postflight-verified." >&2
        return 65
    }
}

validate_backfill_last_attempt() {
    local last_attempt=$1
    local completion=$2

    validate_backfill_completion "$last_attempt" false
    jq -e --slurpfile completion "$completion" '
      .attempt == $completion[0].attempt and
      .success == $completion[0].success and
      .completion_verified == $completion[0].completion_verified and
      .input_set_sha256 == $completion[0].input_set_sha256 and
      .source_sha256 == $completion[0].source_sha256 and
      .lifecycle_source_sha256 == $completion[0].lifecycle_source_sha256 and
      .reviewed_inputs == $completion[0].reviewed_inputs and
      .plan_digest == $completion[0].plan_digest and
      .postflight.snapshot_sha256 == $completion[0].postflight.snapshot_sha256
    ' "$last_attempt" >/dev/null || {
        echo "Step 7 last-attempt is pending, ambiguous, or differs from verified completion." >&2
        return 65
    }
}

validate_fresh_backfill_manifest() {
    local manifest=$1
    local completion=$2
    local input_set=$3
    local source_digest=$4
    local room_digest=$5
    local billing_digest=$6
    local lifecycle_digest=$7

    jq -e \
      --arg app_id "$APP_ID" \
      --arg input_set "$input_set" \
      --arg source "$source_digest" \
      --arg room "$room_digest" \
      --arg billing "$billing_digest" \
      --arg lifecycle "$lifecycle_digest" \
      --slurpfile completion "$completion" '
      .protocol == "spyclash-sensitive-owner-backfill-wrapper-v2" and
      .app_id == $app_id and
      .mode == "dry-run" and
      .stable_snapshots == true and
      .final_schema.verified == true and
      .final_schema.app_id == $app_id and
      .final_schema.live_count == 20 and
      .final_schema.canonical_count == 20 and
      .final_schema.adds == 0 and
      .final_schema.deletes == 0 and
      .final_schema.changed_entities_count == 0 and
      .final_schema.live_admin_write_boundary == true and
      (.final_schema.remote_digest | type == "string" and test("^[0-9a-f]{64}$")) and
      .completion_verified == true and
      .postflight.status == 0 and
      .postflight.report.unresolved_total == 0 and
      .postflight.report.mismatch_total == 0 and
      .postflight.report.room_updates == 0 and
      .postflight.report.word_pack_updates == 0 and
      .input_set_sha256 == $input_set and
      .source_sha256 == $source and
      .lifecycle_source_sha256 == $lifecycle and
      .reviewed_inputs == {
        protocol:"spyclash-sensitive-owner-backfill-inputs-v1",
        input_set_sha256:$input_set,
        source_sha256:$source,
        lifecycle_source_sha256:$lifecycle,
        room_write_lifecycle_sha256:$room,
        billing_identity_lifecycle_sha256:$billing
      } and
      (.postflight.snapshot_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      (.plan_digest | type == "string" and test("^[0-9a-f]{64}$")) and
      .plan_digest == .postflight.report.plan_digest and
      (.postflight.report.operator.identity_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
      .postflight.report.operator.role == "admin" and
      .postflight.report.operator == .preflight.operator and
      .postflight.report.source_sha256 == $source and
      .postflight.report.lifecycle_source_sha256 == $lifecycle and
      .postflight.report.final_schema_remote_digest == .final_schema.remote_digest and
      .app_id == $completion[0].app_id and
      .input_set_sha256 == $completion[0].input_set_sha256 and
      .reviewed_inputs == $completion[0].reviewed_inputs and
      .final_schema.remote_digest == $completion[0].final_schema.remote_digest and
      .postflight.report.operator == $completion[0].postflight.report.operator
    ' "$manifest" >/dev/null || {
        echo "Fresh Step 7 manifest does not match verified immutable inputs and completion." >&2
        return 65
    }
}

snapshot_backfill_evidence() {
    local snapshot_dir=$1
    local completion_copy=$2
    local fresh_copy=$3
    local output=$4
    local pointer_copy="$snapshot_dir/reviewed-inputs-current.json"
    local last_attempt_copy="$snapshot_dir/last-attempt.json"
    local reviewed_root_copy="$snapshot_dir/reviewed-inputs"
    local input_set reviewed_stage reviewed_copy
    local source_copy room_copy billing_copy inputs_copy
    local source_digest room_digest billing_digest lifecycle_digest derived_input_set
    local inputs_digest pointer_digest completion_digest last_attempt_digest
    local current_source current_room current_billing entry_count

    [[ ! -e "$snapshot_dir" && ! -L "$snapshot_dir" ]] || return 65
    mkdir -p "$snapshot_dir" "$reviewed_root_copy"
    copy_stable_backfill_file "$BACKFILL_COMPLETION" "$completion_copy" completion
    copy_stable_backfill_file "$BACKFILL_LAST_ATTEMPT" "$last_attempt_copy" last-attempt
    copy_stable_backfill_file "$BACKFILL_REVIEWED_POINTER" "$pointer_copy" reviewed-input-pointer
    copy_stable_backfill_file "$BACKFILL_MANIFEST" "$fresh_copy" fresh-manifest

    input_set="$(jq -er '.input_set_sha256 | select(test("^[0-9a-f]{64}$"))' \
      "$pointer_copy")" || {
        echo "Step 7 reviewed-input pointer has an invalid input_set_sha256." >&2
        return 65
    }
    reviewed_stage="$BACKFILL_REVIEWED_ROOT/$input_set"
    reviewed_copy="$reviewed_root_copy/$input_set"
    [[ "$reviewed_stage" == "$ROOT/.base44-cutover/sensitive-owner-backfill/reviewed-inputs/$input_set" && \
       -d "$BACKFILL_REVIEWED_ROOT" && ! -L "$BACKFILL_REVIEWED_ROOT" && -O "$BACKFILL_REVIEWED_ROOT" && \
       -d "$reviewed_stage" && ! -L "$reviewed_stage" && -O "$reviewed_stage" && \
       -d "$reviewed_stage/gameRoomAction" && ! -L "$reviewed_stage/gameRoomAction" && \
       -O "$reviewed_stage/gameRoomAction" ]] || {
        echo "Step 7 content-addressed reviewed-input stage is missing or unsafe." >&2
        return 65
    }
    if find "$reviewed_stage" -type l -print | grep -q .; then
        echo "Step 7 reviewed-input stage contains a symbolic link." >&2
        return 65
    fi
    entry_count="$(find "$reviewed_stage" -mindepth 1 -print | wc -l | tr -d ' ')"
    [[ "$entry_count" -eq 5 ]] || {
        echo "Step 7 reviewed-input stage contains an unexpected entry." >&2
        return 65
    }

    mkdir -p "$reviewed_copy/gameRoomAction"
    source_copy="$reviewed_copy/backfill-sensitive-entity-owners.ts"
    room_copy="$reviewed_copy/gameRoomAction/room-write-lifecycle.ts"
    billing_copy="$reviewed_copy/gameRoomAction/billing-identity-lifecycle.ts"
    inputs_copy="$reviewed_copy/inputs.json"
    copy_stable_backfill_file \
      "$reviewed_stage/backfill-sensitive-entity-owners.ts" "$source_copy" reviewed-source
    copy_stable_backfill_file \
      "$reviewed_stage/gameRoomAction/room-write-lifecycle.ts" "$room_copy" room-lifecycle
    copy_stable_backfill_file \
      "$reviewed_stage/gameRoomAction/billing-identity-lifecycle.ts" "$billing_copy" billing-lifecycle
    copy_stable_backfill_file "$reviewed_stage/inputs.json" "$inputs_copy" reviewed-input-manifest

    cmp -s "$pointer_copy" "$inputs_copy" && \
      cmp -s "$BACKFILL_REVIEWED_POINTER" "$pointer_copy" && \
      cmp -s "$BACKFILL_COMPLETION" "$completion_copy" && \
      cmp -s "$BACKFILL_LAST_ATTEMPT" "$last_attempt_copy" && \
      cmp -s "$BACKFILL_MANIFEST" "$fresh_copy" || {
        echo "Step 7 evidence changed during the Step 8 snapshot." >&2
        return 75
      }
    [[ "$BACKFILL_SNAPSHOT_LOCK_HELD" -eq 1 && \
       -d "$BACKFILL_OPERATION_LOCK" && ! -L "$BACKFILL_OPERATION_LOCK" && \
       -O "$BACKFILL_OPERATION_LOCK" ]] || {
        echo "Step 8 lost the Step 7 evidence snapshot lock." >&2
        return 75
    }

    source_digest="$(sha256_file "$source_copy" "staged owner-backfill source")"
    room_digest="$(sha256_file "$room_copy" "staged room lifecycle")"
    billing_digest="$(sha256_file "$billing_copy" "staged billing lifecycle")"
    lifecycle_digest="$(printf '%s\n%s\n' "$room_digest" "$billing_digest" \
      | shasum -a 256 | awk '{print $1}')"
    derived_input_set="$(printf '%s=%s\n%s=%s\n%s=%s\n' \
      "backfill-sensitive-entity-owners.ts" "$source_digest" \
      "gameRoomAction/room-write-lifecycle.ts" "$room_digest" \
      "gameRoomAction/billing-identity-lifecycle.ts" "$billing_digest" \
      | shasum -a 256 | awk '{print $1}')"
    [[ "$lifecycle_digest" =~ ^[0-9a-f]{64}$ && \
       "$derived_input_set" == "$input_set" ]] || {
        echo "Step 7 staged source bytes do not match the reviewed input_set." >&2
        return 65
    }
    inputs_digest="$(sha256_file "$inputs_copy" "reviewed inputs manifest")"
    pointer_digest="$(sha256_file "$pointer_copy" "reviewed inputs pointer")"
    [[ "$inputs_digest" == "$pointer_digest" ]] || return 65

    jq -e \
      --arg app_id "$APP_ID" \
      --arg input_set "$input_set" \
      --arg source "$source_digest" \
      --arg room "$room_digest" \
      --arg billing "$billing_digest" \
      --arg lifecycle "$lifecycle_digest" '
      . == {
        protocol:"spyclash-sensitive-owner-backfill-inputs-v1",
        app_id:$app_id,
        input_set_sha256:$input_set,
        source_sha256:$source,
        lifecycle_source_sha256:$lifecycle,
        files:{
          "backfill-sensitive-entity-owners.ts":$source,
          "gameRoomAction/room-write-lifecycle.ts":$room,
          "gameRoomAction/billing-identity-lifecycle.ts":$billing
        }
      }
    ' "$inputs_copy" >/dev/null || {
        echo "Step 7 reviewed-input manifest does not match staged bytes." >&2
        return 65
    }

    validate_backfill_completion "$completion_copy" true
    validate_backfill_last_attempt "$last_attempt_copy" "$completion_copy"
    validate_fresh_backfill_manifest \
      "$fresh_copy" "$completion_copy" "$input_set" "$source_digest" \
      "$room_digest" "$billing_digest" "$lifecycle_digest"

    current_source="$(sha256_file "$ROOT/scripts/backfill-sensitive-entity-owners.ts" \
      "current owner-backfill source")"
    current_room="$(sha256_file "$BACKFILL_ROOM_LIFECYCLE" \
      "current room lifecycle")"
    current_billing="$(sha256_file "$BACKFILL_BILLING_LIFECYCLE" \
      "current billing lifecycle")"
    [[ "$current_source" == "$source_digest" && \
       "$current_room" == "$room_digest" && \
       "$current_billing" == "$billing_digest" ]] || {
        echo "Current Step 7 sources differ from the immutable reviewed stage." >&2
        return 65
    }

    completion_digest="$(sha256_file "$completion_copy" "verified completion")"
    last_attempt_digest="$(sha256_file "$last_attempt_copy" "verified last attempt")"
    jq -n -S \
      --arg protocol "spyclash-final-delete-account-backfill-boundary-v2" \
      --arg input_set_sha256 "$input_set" \
      --arg source_sha256 "$source_digest" \
      --arg room_write_lifecycle_sha256 "$room_digest" \
      --arg billing_identity_lifecycle_sha256 "$billing_digest" \
      --arg lifecycle_source_sha256 "$lifecycle_digest" \
      --arg reviewed_inputs_manifest_sha256 "$inputs_digest" \
      --arg reviewed_inputs_pointer_sha256 "$pointer_digest" \
      --arg completion_sha256 "$completion_digest" \
      --arg last_attempt_sha256 "$last_attempt_digest" \
      --arg completion_attempt_id "$(jq -er '.attempt.attempt_id' "$completion_copy")" \
      --arg completion_plan_digest "$(jq -er '.plan_digest' "$completion_copy")" \
      --arg completion_postflight_snapshot_sha256 \
        "$(jq -er '.postflight.snapshot_sha256' "$completion_copy")" \
      --arg fresh_plan_digest "$(jq -er '.plan_digest' "$fresh_copy")" \
      --arg fresh_postflight_snapshot_sha256 \
        "$(jq -er '.postflight.snapshot_sha256' "$fresh_copy")" \
      --arg final_schema_remote_digest \
        "$(jq -er '.final_schema.remote_digest' "$fresh_copy")" \
      --arg operator_identity_sha256 \
        "$(jq -er '.postflight.report.operator.identity_sha256' "$fresh_copy")" \
      '{
        protocol:$protocol,
        input_set_sha256:$input_set_sha256,
        source_sha256:$source_sha256,
        room_write_lifecycle_sha256:$room_write_lifecycle_sha256,
        billing_identity_lifecycle_sha256:$billing_identity_lifecycle_sha256,
        lifecycle_source_sha256:$lifecycle_source_sha256,
        reviewed_inputs_manifest_sha256:$reviewed_inputs_manifest_sha256,
        reviewed_inputs_pointer_sha256:$reviewed_inputs_pointer_sha256,
        completion_sha256:$completion_sha256,
        last_attempt_sha256:$last_attempt_sha256,
        completion_attempt:{
          protocol:"spyclash-sensitive-owner-backfill-attempt-v1",
          attempt_id:$completion_attempt_id,
          state:"completed-postflight-verified",
          postflight_required:false,
          success:true,
          completion_verified:true
        },
        completion_plan_digest:$completion_plan_digest,
        completion_postflight_snapshot_sha256:$completion_postflight_snapshot_sha256,
        fresh_plan_digest:$fresh_plan_digest,
        fresh_postflight_snapshot_sha256:$fresh_postflight_snapshot_sha256,
        final_schema_remote_digest:$final_schema_remote_digest,
        operator_identity_sha256:$operator_identity_sha256,
        operator_role:"admin",
        room_updates:0,
        word_pack_updates:0,
        unresolved_total:0,
        mismatch_total:0
      }' > "$output"
}

refresh_backfill_boundary() {
    local output=$1
    local completion_copy=$2
    local fresh_copy=$3
    local evidence_snapshot=$4
    local log="$WORK/backfill-$RANDOM.log"
    local snapshot_status release_status

    # The wrapper owns sensitive-owner-backfill.operation.lock for its entire
    # dry-run. Step 8 must never pre-acquire that lock or it would deadlock.
    if ! env \
        -u BASE44_APP_ID \
        -u BASE44_PROJECTS_BASE44_APP_ID \
        -u BASE44_CONFIRM_ACTION \
        -u BASE44_CONFIRM_APP_ID \
        -u BASE44_CONFIRM_SENSITIVE_OWNER_PLAN_DIGEST \
        -u BASE44_CONFIRM_FINAL_DELETE_ACCOUNT_PLAN_DIGEST \
        "$ROOT/scripts/run-base44-sensitive-owner-backfill.sh" \
          --app-id "$APP_ID" > "$log" 2>&1; then
        sed 's/^/  /' "$log" >&2
        echo "Fresh read-only Step 7 postflight failed; no function was deployed." >&2
        return 65
    fi
    [[ ! -e "$BACKFILL_OPERATION_LOCK" && ! -L "$BACKFILL_OPERATION_LOCK" ]] || {
        echo "Step 7 operation lock remained active after its dry-run." >&2
        return 75
    }
    acquire_backfill_snapshot_lock
    set +e
    (set -e; snapshot_backfill_evidence \
      "$evidence_snapshot" "$completion_copy" "$fresh_copy" "$output")
    snapshot_status=$?
    set -e
    release_status=0
    release_backfill_snapshot_lock || release_status=$?
    [[ "$snapshot_status" -eq 0 ]] || return "$snapshot_status"
    [[ "$release_status" -eq 0 ]] || return "$release_status"
}

base44_cli whoami >/dev/null
validate_exact_directory_inventory "$ROOT/base44/functions" local-release

mkdir -p "$CUTOVER_DIR"
secure_private_directory "$CUTOVER_DIR" "Base44 cutover"
if [[ "$MODE" == "deploy" ]]; then
    acquire_production_lock
fi
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another final deleteAccount audit/deploy is already active: $LOCK_DIR" >&2
    exit 75
fi
LOCK_HELD=1
secure_private_directory "$LOCK_DIR" "final deleteAccount lock"
mkdir -p "$STAGE_SNAPSHOTS"
secure_private_directory "$CUTOVER_DIR/evidence" "Base44 evidence root"
secure_private_tree "$EVIDENCE_DIR" "final deleteAccount evidence"
secure_private_directory "$STAGE_SNAPSHOTS" "final deleteAccount stage snapshots"

schema_boundary_work="$WORK/schema-boundary.json"
backfill_boundary_work="$WORK/backfill-boundary.json"
backfill_completion_work="$WORK/backfill-completion.json"
backfill_fresh_work="$WORK/backfill-fresh.json"
backfill_evidence_work="$WORK/backfill-reviewed-evidence"

# Step 8 is not eligible until final schema is live with zero diff and Step 7
# has both successful apply evidence and a fresh stable zero-update dry-run.
refresh_schema_boundary "$schema_boundary_work"
refresh_backfill_boundary \
    "$backfill_boundary_work" \
    "$backfill_completion_work" \
    "$backfill_fresh_work" \
    "$backfill_evidence_work"

[[ ! -L "$CUTOVER_DIR" && ! -L "$STAGE" ]] || {
    echo "Base44 cutover paths changed during preparation; refusing stage replacement." >&2
    exit 65
}
preserve_previous_stage_evidence
mkdir -p "$DEPLOY_STAGE/base44/functions"
secure_private_directory "$STAGE" "final deleteAccount stage"
secure_private_directory "$DEPLOY_STAGE" "final deleteAccount deploy stage"
secure_private_directory "$DEPLOY_STAGE/base44" "final deleteAccount Base44 stage"
secure_private_directory "$DEPLOY_STAGE/base44/functions" "final deleteAccount function stage"
copy_final_delete_account
secure_private_tree "$STAGE" "final deleteAccount stage"

schema_boundary="$STAGE/schema-boundary.json"
backfill_boundary="$STAGE/backfill-boundary.json"
backfill_completion="$STAGE/backfill-completion.json"
backfill_fresh="$STAGE/backfill-fresh.json"
backfill_reviewed_evidence="$STAGE/backfill-reviewed-evidence"
cp "$schema_boundary_work" "$schema_boundary"
cp "$backfill_boundary_work" "$backfill_boundary"
cp "$backfill_completion_work" "$backfill_completion"
cp "$backfill_fresh_work" "$backfill_fresh"
cp -R "$backfill_evidence_work" "$backfill_reviewed_evidence"

local_coordinated_manifest="$STAGE/local-coordinated-functions.json"
local_final_object="$STAGE/local-final-delete-account.json"
reviewed_guard_object="$STAGE/reviewed-maintenance-guard.json"
remote_before_manifest="$STAGE/remote-functions-before.json"
remote_coordinated_manifest="$STAGE/remote-coordinated-functions-before.json"

write_semantic_manifest "$ROOT/base44/functions" "$local_coordinated_manifest" \
    "${COORDINATED_FUNCTIONS[@]}"
function_semantic_object "$DEPLOY_STAGE/base44/functions" deleteAccount \
    "$local_final_object"
function_semantic_object "$ROOT/scripts/base44-maintenance" deleteAccount \
    "$reviewed_guard_object"

pull_remote_snapshot "$REMOTE_BEFORE" remote-before "$remote_before_manifest"
jq '[.[] | select(.name != "deleteAccount")]' "$remote_before_manifest" \
    > "$remote_coordinated_manifest"

remote_guard_digest="$(jq -er '.[] | select(.name == "deleteAccount") | .semantic_digest' \
    "$remote_before_manifest")"
reviewed_guard_digest="$(jq -er '.semantic_digest' "$reviewed_guard_object")"
[[ "$remote_guard_digest" == "$reviewed_guard_digest" ]] || {
    echo "Production deleteAccount is not the reviewed Step 3 maintenance guard." >&2
    exit 65
}
if ! cmp -s "$remote_coordinated_manifest" "$local_coordinated_manifest"; then
    echo "The other 15 Production functions do not match the current coordinated release payload." >&2
    exit 65
fi

remote_inventory_digest="$(semantic_manifest_digest "$remote_before_manifest")"
remote_coordinated_digest="$(semantic_manifest_digest "$remote_coordinated_manifest")"
local_coordinated_digest="$(semantic_manifest_digest "$local_coordinated_manifest")"
local_final_digest="$(jq -er '.semantic_digest' "$local_final_object")"
schema_boundary_digest="$(shasum -a 256 "$schema_boundary" | awk '{print $1}')"
backfill_boundary_digest="$(shasum -a 256 "$backfill_boundary" | awk '{print $1}')"
expected_names_json="$(printf '%s\n' "${EXPECTED_REMOTE_FUNCTIONS[@]}" \
    | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')"

plan_input="$WORK/plan-input.json"
jq -n -S \
    --arg step "SECURITY_CUTOVER_STEP_8_FINAL_DELETE_ACCOUNT" \
    --arg app_id "$APP_ID" \
    --arg remote_inventory_digest "$remote_inventory_digest" \
    --arg remote_guard_digest "$remote_guard_digest" \
    --arg local_coordinated_digest "$local_coordinated_digest" \
    --arg local_final_delete_account_digest "$local_final_digest" \
    --arg schema_boundary_digest "$schema_boundary_digest" \
    --arg schema_remote_digest "$(jq -er '.remote_digest' "$schema_boundary")" \
    --arg schema_canonical_digest "$(jq -er '.canonical_digest' "$schema_boundary")" \
    --arg schema_plan_digest "$(jq -er '.plan_digest' "$schema_boundary")" \
    --arg backfill_boundary_digest "$backfill_boundary_digest" \
    --arg backfill_source_sha256 "$(jq -er '.source_sha256' "$backfill_boundary")" \
    --arg backfill_completion_plan_digest \
      "$(jq -er '.completion_plan_digest' "$backfill_boundary")" \
    --arg backfill_completion_postflight_snapshot_sha256 \
      "$(jq -er '.completion_postflight_snapshot_sha256' "$backfill_boundary")" \
    --arg backfill_fresh_plan_digest \
      "$(jq -er '.fresh_plan_digest' "$backfill_boundary")" \
    --arg backfill_fresh_postflight_snapshot_sha256 \
      "$(jq -er '.fresh_postflight_snapshot_sha256' "$backfill_boundary")" \
    --argjson expected_remote_functions "$expected_names_json" \
    '{
      step:$step,
      app_id:$app_id,
      expected_remote_functions:$expected_remote_functions,
      remote_inventory_digest:$remote_inventory_digest,
      remote_guard_digest:$remote_guard_digest,
      local_coordinated_digest:$local_coordinated_digest,
      local_final_delete_account_digest:$local_final_delete_account_digest,
      schema_boundary_digest:$schema_boundary_digest,
      schema_remote_digest:$schema_remote_digest,
      schema_canonical_digest:$schema_canonical_digest,
      schema_plan_digest:$schema_plan_digest,
      backfill_boundary_digest:$backfill_boundary_digest,
      backfill_source_sha256:$backfill_source_sha256,
      backfill_completion_plan_digest:$backfill_completion_plan_digest,
      backfill_completion_postflight_snapshot_sha256:$backfill_completion_postflight_snapshot_sha256,
      backfill_fresh_plan_digest:$backfill_fresh_plan_digest,
      backfill_fresh_postflight_snapshot_sha256:$backfill_fresh_postflight_snapshot_sha256
    }' > "$plan_input"
plan_digest="$(shasum -a 256 "$plan_input" | awk '{print $1}')"

jq -n \
    --arg app_id "$APP_ID" \
    --arg prepared_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg remote_inventory_digest "$remote_inventory_digest" \
    --arg remote_delete_account_semantic_digest "$remote_guard_digest" \
    --arg reviewed_maintenance_guard_digest "$reviewed_guard_digest" \
    --arg remote_coordinated_digest "$remote_coordinated_digest" \
    --arg local_coordinated_digest "$local_coordinated_digest" \
    --arg desired_delete_account_semantic_digest "$local_final_digest" \
    --arg schema_boundary_digest "$schema_boundary_digest" \
    --arg backfill_boundary_digest "$backfill_boundary_digest" \
    --arg plan_digest "$plan_digest" \
    --argjson expected_remote_functions "$expected_names_json" \
    --slurpfile remote_functions "$remote_before_manifest" \
    --slurpfile local_coordinated "$local_coordinated_manifest" \
    --slurpfile desired_delete_account "$local_final_object" \
    --slurpfile schema "$schema_boundary" \
    --slurpfile backfill "$backfill_boundary" \
    '{
      app_id:$app_id,
      prepared_at:$prepared_at,
      expected_remote_function_count:($expected_remote_functions | length),
      expected_remote_functions:$expected_remote_functions,
      remote_inventory_digest:$remote_inventory_digest,
      remote_delete_account_semantic_digest:$remote_delete_account_semantic_digest,
      reviewed_maintenance_guard_digest:$reviewed_maintenance_guard_digest,
      remote_coordinated_digest:$remote_coordinated_digest,
      local_coordinated_digest:$local_coordinated_digest,
      desired_delete_account_semantic_digest:$desired_delete_account_semantic_digest,
      remote_functions:$remote_functions[0],
      local_coordinated_functions:$local_coordinated[0],
      desired_delete_account:$desired_delete_account[0],
      schema_boundary_digest:$schema_boundary_digest,
      schema:$schema[0],
      backfill_boundary_digest:$backfill_boundary_digest,
      backfill:$backfill[0],
      plan_digest:$plan_digest
    }' > "$MANIFEST"
secure_private_tree "$STAGE" "final deleteAccount stage"

echo "Prepared final Base44 deleteAccount stage: $STAGE"
echo "App id: $APP_ID"
echo "Remote inventory: ${#EXPECTED_REMOTE_FUNCTIONS[@]} functions (exact)"
echo "Maintenance guard digest: $remote_guard_digest"
echo "Final deleteAccount digest: $local_final_digest"
echo "Plan digest: $plan_digest"

if [[ "$MODE" == "prepare" ]]; then
    echo "No remote change was made. Inspect $MANIFEST, then obtain the exact Step 8 confirmation before --deploy."
    exit 0
fi

if [[ "${BASE44_CONFIRM_ACTION:-}" != "SECURITY_CUTOVER_STEP_8_FINAL_DELETE_ACCOUNT" ]]; then
    echo "Set BASE44_CONFIRM_ACTION=SECURITY_CUTOVER_STEP_8_FINAL_DELETE_ACCOUNT for this exact cutover step." >&2
    exit 77
fi
if [[ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]]; then
    echo "Set BASE44_CONFIRM_APP_ID=$APP_ID for the intentional final deleteAccount deployment." >&2
    exit 77
fi
if [[ "${BASE44_CONFIRM_FINAL_DELETE_ACCOUNT_PLAN_DIGEST:-}" != "$plan_digest" ]]; then
    echo "Fresh Step 8 plan differs from the inspected plan." >&2
    echo "Inspect $MANIFEST, then set BASE44_CONFIRM_FINAL_DELETE_ACCOUNT_PLAN_DIGEST to its plan_digest." >&2
    exit 77
fi

# Re-run every remote and local prerequisite immediately before the sole
# Production mutation. Any schema, data, operator, source, function or guard
# drift invalidates the reviewed plan.
jit_schema="$WORK/jit-schema.json"
jit_backfill="$WORK/jit-backfill.json"
jit_completion="$WORK/jit-backfill-completion.json"
jit_fresh="$WORK/jit-backfill-fresh.json"
jit_backfill_evidence="$WORK/jit-backfill-reviewed-evidence"
refresh_schema_boundary "$jit_schema"
refresh_backfill_boundary \
    "$jit_backfill" "$jit_completion" "$jit_fresh" "$jit_backfill_evidence"
cmp -s "$schema_boundary" "$jit_schema" || {
    echo "Final schema changed after Step 8 plan preparation." >&2
    exit 77
}
cmp -s "$backfill_boundary" "$jit_backfill" || {
    echo "Step 7 completion/current postflight changed after Step 8 plan preparation." >&2
    exit 77
}

REMOTE_JIT="$WORK/remote-jit"
jit_remote_manifest="$WORK/remote-jit-functions.json"
jit_remote_coordinated="$WORK/remote-jit-coordinated.json"
pull_remote_snapshot "$REMOTE_JIT" remote-jit "$jit_remote_manifest"
jq '[.[] | select(.name != "deleteAccount")]' "$jit_remote_manifest" \
    > "$jit_remote_coordinated"
[[ "$(semantic_manifest_digest "$jit_remote_manifest")" == "$remote_inventory_digest" ]] || {
    echo "Production function inventory/payload changed after Step 8 plan preparation." >&2
    exit 77
}
cmp -s "$jit_remote_coordinated" "$local_coordinated_manifest" || {
    echo "The 15 coordinated Production functions drifted before Step 8 mutation." >&2
    exit 77
}
[[ "$(jq -er '.[] | select(.name == "deleteAccount") | .semantic_digest' \
    "$jit_remote_manifest")" == "$reviewed_guard_digest" ]] || {
    echo "Production deleteAccount is no longer the reviewed maintenance guard." >&2
    exit 77
}

jit_local_coordinated="$WORK/jit-local-coordinated.json"
jit_local_final="$WORK/jit-local-final-delete-account.json"
jit_reviewed_guard="$WORK/jit-reviewed-maintenance-guard.json"
write_semantic_manifest "$ROOT/base44/functions" "$jit_local_coordinated" \
    "${COORDINATED_FUNCTIONS[@]}"
function_semantic_object "$DEPLOY_STAGE/base44/functions" deleteAccount \
    "$jit_local_final"
function_semantic_object "$ROOT/scripts/base44-maintenance" deleteAccount \
    "$jit_reviewed_guard"
cmp -s "$local_coordinated_manifest" "$jit_local_coordinated" || {
    echo "Local coordinated release payload changed after plan preparation." >&2
    exit 77
}
cmp -s "$local_final_object" "$jit_local_final" || {
    echo "Staged final deleteAccount changed after plan preparation." >&2
    exit 77
}
cmp -s "$reviewed_guard_object" "$jit_reviewed_guard" || {
    echo "Reviewed maintenance guard changed after plan preparation." >&2
    exit 77
}

# The only mutating CLI command names deleteAccount explicitly. Capture its
# status and always pull Production again before classifying the outcome.
attempt_tmp="$WORK/attempt.json"
jq -n \
    --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg app_id "$APP_ID" \
    --arg plan_digest "$plan_digest" \
    --arg expected_final_digest "$local_final_digest" \
    '{started_at:$started_at,app_id:$app_id,plan_digest:$plan_digest,expected_final_digest:$expected_final_digest,status:"mutation-started-postflight-required"}' \
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
after_final_digest=""
unchanged_coordinated_count=0
after_matches=false
set +e
(set -e; pull_remote_snapshot "$REMOTE_AFTER" remote-after "$after_manifest")
after_pull_status=$?
set -e
if [[ "$after_pull_status" -eq 0 ]]; then
    after_final_digest="$(jq -er '.[] | select(.name == "deleteAccount") | .semantic_digest' \
        "$after_manifest")"
    unchanged_coordinated_count="$(jq -n \
        --slurpfile before "$remote_before_manifest" \
        --slurpfile after "$after_manifest" '
          [
            $before[0][] |
            select(.name != "deleteAccount") as $wanted |
            $after[0][] |
            select(.name == $wanted.name and .semantic_digest == $wanted.semantic_digest)
          ] | length
        ')"
    if [[ "$after_final_digest" == "$local_final_digest" && \
          "$unchanged_coordinated_count" -eq 15 ]]; then
        after_matches=true
    fi
else
    printf '[]\n' > "$after_manifest"
fi

# Schema and owner state are read again even if the CLI reported an error;
# postflight evidence is always written for safe forward recovery.
post_schema="$WORK/post-schema.json"
post_backfill="$WORK/post-backfill.json"
post_completion="$WORK/post-backfill-completion.json"
post_fresh="$WORK/post-backfill-fresh.json"
post_backfill_evidence="$WORK/post-backfill-reviewed-evidence"
set +e
(set -e; refresh_schema_boundary "$post_schema")
post_schema_status=$?
(set -e; refresh_backfill_boundary \
  "$post_backfill" "$post_completion" "$post_fresh" "$post_backfill_evidence")
post_backfill_status=$?
set -e

schema_matches=false
backfill_matches=false
if [[ "$post_schema_status" -eq 0 ]] && cmp -s "$schema_boundary" "$post_schema"; then
    schema_matches=true
fi
if [[ "$post_backfill_status" -eq 0 ]] && cmp -s "$backfill_boundary" "$post_backfill"; then
    backfill_matches=true
fi

jq -n \
    --arg audited_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson deploy_status "$deploy_status" \
    --argjson after_pull_status "$after_pull_status" \
    --arg expected_final_digest "$local_final_digest" \
    --arg actual_final_digest "$after_final_digest" \
    --argjson unchanged_coordinated_count "$unchanged_coordinated_count" \
    --argjson function_matches "$after_matches" \
    --argjson schema_status "$post_schema_status" \
    --argjson schema_matches "$schema_matches" \
    --argjson backfill_status "$post_backfill_status" \
    --argjson backfill_matches "$backfill_matches" \
    --slurpfile before "$remote_before_manifest" \
    --slurpfile after "$after_manifest" \
    '{
      audited_at:$audited_at,
      deploy_status:$deploy_status,
      after_pull_status:$after_pull_status,
      expected_final_digest:$expected_final_digest,
      actual_final_digest:$actual_final_digest,
      unchanged_coordinated_count:$unchanged_coordinated_count,
      function_matches:$function_matches,
      schema:{status:$schema_status,matches:$schema_matches},
      backfill:{status:$backfill_status,matches:$backfill_matches},
      functions:[
        $before[0][] as $wanted |
        ($after[0] | map(select(.name == $wanted.name))[0] // null) as $found |
        {
          name:$wanted.name,
          before_digest:$wanted.semantic_digest,
          after_digest:($found.semantic_digest // null),
          expected_digest:(if $wanted.name == "deleteAccount" then $expected_final_digest else $wanted.semantic_digest end),
          matches:($found != null and $found.semantic_digest == (if $wanted.name == "deleteAccount" then $expected_final_digest else $wanted.semantic_digest end))
        }
      ]
    }' > "$POSTFLIGHT"
secure_private_tree "$STAGE" "final deleteAccount stage"

if [[ "$deploy_status" -ne 0 || "$after_pull_status" -ne 0 || \
      "$after_matches" != true || "$post_schema_status" -ne 0 || \
      "$schema_matches" != true || "$post_backfill_status" -ne 0 || \
      "$backfill_matches" != true ]]; then
    echo "Final deleteAccount deployment did not reach the fully verified state." >&2
    echo "Inspect $POSTFLIGHT before any forward-fix." >&2
    exit 70
fi

verified_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
jq \
    --arg deployed_at "$verified_at" \
    --arg verified_at "$verified_at" \
    --arg verified_delete_account_digest "$after_final_digest" \
    '. + {
      deployed_at:$deployed_at,
      verified_at:$verified_at,
      verified_delete_account_digest:$verified_delete_account_digest
    }' "$MANIFEST" > "$WORK/manifest.verified.json"
cp "$WORK/manifest.verified.json" "$MANIFEST"
secure_private_tree "$STAGE" "final deleteAccount stage"

echo "Final Base44 deleteAccount deployment verified: $after_final_digest"
