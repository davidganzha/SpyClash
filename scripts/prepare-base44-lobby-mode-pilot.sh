#!/bin/bash

set -euo pipefail
umask 077

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
EXPECTED_APP_ID="69a0e57fa939f578082f8091"
EXPECTED_CLI_VERSION="0.0.56"
EXPECTED_FUNCTION_COUNT=17
EXPECTED_ENTITY_COUNT=24
EXPECTED_GAME_ROOM_ACTION_RUNTIME_COUNT=43
EXPECTED_GAME_ROOM_ACTION_HASH="61981ace27453bc04c013533519dbc49cd6a6d70bca85b68427ea75db2df1991"
EXPECTED_GAME_ROOM_SIGNAL_HASH="bdfe7d186dbc3fcb08b5a4da849c2eec674401af9332d986de44f600dfe4c953"
APP_FILE="$ROOT/base44/.app.jsonc"
CONFIG_FILE="$ROOT/base44/config.jsonc"
AUTH_FILE="${BASE44_AUTH_FILE:-$HOME/.base44/auth/auth.json}"
OVERLAY_ROOT="$ROOT/cutovers/lobby-mode-realtime-pilot/overlays"
PROJECTION_FIELDS="$OVERLAY_ROOT/game-room-signal-projection-fields.json"
PROJECTION_SAFE_SIGNAL="$OVERLAY_ROOT/projection-safe-game-room-signal.ts"
ENABLE_DIRECT_PATCH="$OVERLAY_ROOT/enable-direct-mode.patch"
FLATTEN_FUNCTION="$ROOT/scripts/flatten-base44-pulled-function.sh"
CUTOVER_ROOT="$ROOT/.base44-cutover/lobby-mode-realtime-pilot"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spyclash-lobby-mode-pilot.XXXXXX")"
REMOTE_SCHEMA="$WORK/remote-entities.json"
REMOTE_FUNCTIONS="$WORK/remote-functions"
CURL_CONFIG="$WORK/curl.conf"
FUNCTION_LIST="$WORK/functions-list.txt"
ENTITY_NAMES_ACTUAL="$WORK/entity-names-actual.txt"
ENTITY_NAMES_EXPECTED="$WORK/entity-names-expected.txt"
FUNCTION_NAMES_ACTUAL="$WORK/function-names-actual.txt"
FUNCTION_NAMES_EXPECTED="$WORK/function-names-expected.txt"
ENTITY_INVENTORY_JSONL="$WORK/entity-inventory.jsonl"
FUNCTION_INVENTORY_JSONL="$WORK/function-inventory.jsonl"

EXPECTED_ENTITIES=(
  AiGenerationQuota AiGenerationUsage AiWordPackCacheVariant
  AiWordPackRequestResult AppStoreAccount AppleSignInCredential
  BillingIdentityLifecycle CommunityProfileSignal CommunityReport Entitlement
  Friendship GameHistory GameRoom GameRoomSignal LiveActivityRegistration
  MembershipGrant NotificationAnnouncement NotificationReadReceipt
  ProfileComment PushDeviceRegistration PushNotificationEvent RoomInvite User
  WordPack
)

EXPECTED_FUNCTIONS=(
  advanceRound app-store-entitlement appleAuthBroker appleAuthCallback
  autoRegisterUser checkSubscription communityAction createCheckout
  deleteAccount gameRoomAction generateWordPack googleAuthCallback
  mobileAuthCallback notificationAction pushNotificationAction
  stripe-entitlement-webhook wordPackAction
)

cleanup() {
  if [[ -f "$CURL_CONFIG" && ! -L "$CURL_CONFIG" ]]; then
    : > "$CURL_CONFIG"
  fi
  case "$WORK" in
    "${TMPDIR:-/tmp}"/spyclash-lobby-mode-pilot.*) rm -rf -- "$WORK" ;;
  esac
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
  echo "$1" >&2
  exit "${2:-65}"
}

assert_no_find_match() {
  local message=$1 match
  shift
  match="$(find "$@" -print -quit)" || \
    fail "Unable to inspect filesystem: $message" 77
  [[ -z "$match" ]] || fail "$message" 77
}

hash_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

canonical_json_hash() {
  jq -S -c . "$1" | shasum -a 256 | awk '{print $1}'
}

private_mode() {
  stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

tree_hash() {
  local tree=$1
  (
    cd "$tree"
    find . -type f -print | LC_ALL=C sort | while IFS= read -r file; do
      local relative digest
      relative=${file#./}
      digest=$(shasum -a 256 "$file" | awk '{print $1}')
      printf '%s\t%s\n' "$relative" "$digest"
    done
  ) | shasum -a 256 | awk '{print $1}'
}

base44_cli() {
  env -u BASE44_APP_ID npx --yes "base44@$EXPECTED_CLI_VERSION" \
    --app-id "$EXPECTED_APP_ID" "$@"
}

for command in awk basename chmod cmp cp curl date diff env find git head jq mkdir \
  mktemp mv npx rm sed shasum sort stat tr wc; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing command: $command" 69
done

[[ -f "$APP_FILE" && ! -L "$APP_FILE" ]] || fail "Missing Base44 app link." 77
[[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || fail "Missing Base44 config." 77
[[ -f "$AUTH_FILE" && ! -L "$AUTH_FILE" && -O "$AUTH_FILE" ]] || \
  fail "Base44 authentication must be a user-owned regular file." 77
[[ "$(private_mode "$AUTH_FILE")" == 600 ]] || \
  fail "Base44 authentication must have mode 600." 77
[[ -f "$PROJECTION_FIELDS" && -f "$PROJECTION_SAFE_SIGNAL" && \
  -f "$ENABLE_DIRECT_PATCH" ]] || fail "Pilot overlays are incomplete."
[[ -x "$FLATTEN_FUNCTION" && ! -L "$FLATTEN_FUNCTION" ]] || \
  fail "Function flatten helper is missing or unsafe." 77
[[ "$ROOT" != "/" && ! -L "$CUTOVER_ROOT" ]] || \
  fail "Unsafe cutover root." 77

APP_ID="$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_FILE" | head -n 1)"
[[ "$APP_ID" == "$EXPECTED_APP_ID" ]] || \
  fail "Refusing non-canonical Base44 app: $APP_ID" 77
if [[ -n "${BASE44_APP_ID+x}" && "$BASE44_APP_ID" != "$EXPECTED_APP_ID" ]]; then
  fail "BASE44_APP_ID targets another app." 77
fi

[[ -z "$(git -C "$ROOT" status --porcelain=v1)" ]] || \
  fail "Commit the reviewed pilot preparation before sealing a cutover package." 77
GIT_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
GIT_BRANCH="$(git -C "$ROOT" symbolic-ref --short HEAD)"

CLI_VERSION="$(base44_cli --version | head -n 1 | tr -d '[:space:]')"
[[ "$CLI_VERSION" == "$EXPECTED_CLI_VERSION" ]] || \
  fail "Unexpected Base44 CLI version: $CLI_VERSION" 77
WHOAMI_OUTPUT="$(base44_cli whoami)"
OPERATOR="$(printf '%s\n' "$WHOAMI_OUTPUT" | sed -n 's/^Logged in as:[[:space:]]*//p' | head -n 1)"
[[ -n "$OPERATOR" ]] || fail "Unable to resolve the Base44 operator." 77

ACCESS_TOKEN="$(jq -er '.accessToken' "$AUTH_FILE")" || \
  fail "Unable to read Base44 access token." 77
printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" > "$CURL_CONFIG"
unset ACCESS_TOKEN
curl -fsS --connect-timeout 10 --max-time 60 --retry 2 \
  --config "$CURL_CONFIG" \
  "https://app.base44.com/api/apps/$EXPECTED_APP_ID/entity-schemas" \
  > "$REMOTE_SCHEMA"
: > "$CURL_CONFIG"
chmod 600 "$REMOTE_SCHEMA"

jq -e --argjson count "$EXPECTED_ENTITY_COUNT" '
  .total == $count and .total == (.schemas | length) and
  ([.schemas[].entity_name] | unique | length) == $count and
  all(.schemas[];
    (.entity_name | type == "string" and test("^[A-Za-z0-9-]+$")) and
    (.entity_schema | type == "object") and
    .entity_schema.name == .entity_name)
' "$REMOTE_SCHEMA" >/dev/null || fail "BLOCKED_INVALID_REMOTE_ENTITY_BASELINE" 77
printf '%s\n' "${EXPECTED_ENTITIES[@]}" | LC_ALL=C sort > "$ENTITY_NAMES_EXPECTED"
jq -r '.schemas[].entity_name' "$REMOTE_SCHEMA" | LC_ALL=C sort > "$ENTITY_NAMES_ACTUAL"
cmp -s "$ENTITY_NAMES_EXPECTED" "$ENTITY_NAMES_ACTUAL" || {
  diff -u "$ENTITY_NAMES_EXPECTED" "$ENTITY_NAMES_ACTUAL" >&2 || true
  fail "BLOCKED_REMOTE_ENTITY_INVENTORY_DRIFT" 77
}
REMOTE_GAME_ROOM_SIGNAL_HASH="$(
  jq -S -c '.schemas[] | select(.entity_name == "GameRoomSignal") | .entity_schema' \
    "$REMOTE_SCHEMA" | shasum -a 256 | awk '{print $1}'
)"
[[ "$REMOTE_GAME_ROOM_SIGNAL_HASH" == "$EXPECTED_GAME_ROOM_SIGNAL_HASH" ]] || \
  fail "BLOCKED_GAME_ROOM_SIGNAL_SCHEMA_DRIFT" 77

mkdir -p "$REMOTE_FUNCTIONS/base44"
cp "$CONFIG_FILE" "$APP_FILE" "$REMOTE_FUNCTIONS/base44/"
(
  cd "$REMOTE_FUNCTIONS"
  base44_cli functions list > "$FUNCTION_LIST"
  base44_cli functions pull
)
[[ -d "$REMOTE_FUNCTIONS/base44/functions" ]] || \
  fail "BLOCKED_NO_REMOTE_FUNCTION_BASELINE" 77
find "$REMOTE_FUNCTIONS/base44/functions" -mindepth 1 -maxdepth 1 -type d \
  -exec basename {} \; | LC_ALL=C sort > "$FUNCTION_NAMES_ACTUAL"
printf '%s\n' "${EXPECTED_FUNCTIONS[@]}" | LC_ALL=C sort > "$FUNCTION_NAMES_EXPECTED"
cmp -s "$FUNCTION_NAMES_EXPECTED" "$FUNCTION_NAMES_ACTUAL" || {
  diff -u "$FUNCTION_NAMES_EXPECTED" "$FUNCTION_NAMES_ACTUAL" >&2 || true
  fail "BLOCKED_REMOTE_FUNCTION_INVENTORY_DRIFT" 77
}
REMOTE_GAME_ROOM_ACTION="$REMOTE_FUNCTIONS/base44/functions/gameRoomAction"
REMOTE_GAME_ROOM_ACTION_HASH="$(tree_hash "$REMOTE_GAME_ROOM_ACTION")"
[[ "$REMOTE_GAME_ROOM_ACTION_HASH" == "$EXPECTED_GAME_ROOM_ACTION_HASH" ]] || \
  fail "BLOCKED_GAME_ROOM_ACTION_BASELINE_DRIFT" 77
REMOTE_GAME_ROOM_RUNTIME="$REMOTE_GAME_ROOM_ACTION/base44/functions/gameRoomAction"
[[ "$(jq -er '.name' "$REMOTE_GAME_ROOM_ACTION/function.jsonc")" == \
  "gameRoomAction" ]] || fail "Unexpected remote gameRoomAction config." 77
[[ "$(jq -er '.entry' "$REMOTE_GAME_ROOM_ACTION/function.jsonc")" == \
  "base44/functions/gameRoomAction/entry.ts" && \
  -f "$REMOTE_GAME_ROOM_RUNTIME/entry.ts" ]] || \
  fail "Unsupported pulled gameRoomAction package layout." 77
assert_no_find_match "Nested runtime directory in pulled gameRoomAction." \
  "$REMOTE_GAME_ROOM_RUNTIME" -mindepth 1 -type d

GENERATED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
GENERATED_EPOCH="$(date -u +'%s')"
RUN_ID="$(date -u +'%Y%m%dT%H%M%SZ')-${GIT_COMMIT:0:12}"
STAGE="$CUTOVER_ROOT/$RUN_ID"
[[ ! -e "$STAGE" && ! -L "$STAGE" ]] || fail "Cutover stage already exists."
mkdir -p \
  "$STAGE/candidate/base44/entities" \
  "$STAGE/candidate/base44/functions" \
  "$STAGE/rollback/base44/functions" \
  "$STAGE/snapshots/base44/functions" \
  "$STAGE/evidence"
chmod 700 "$CUTOVER_ROOT" "$STAGE" "$STAGE/candidate" "$STAGE/rollback" \
  "$STAGE/snapshots" "$STAGE/evidence"

cp "$CONFIG_FILE" "$STAGE/candidate/base44/config.jsonc"
cp "$CONFIG_FILE" "$STAGE/rollback/base44/config.jsonc"
cp "$REMOTE_SCHEMA" "$STAGE/snapshots/remote-entities.json"
cp "$FUNCTION_LIST" "$STAGE/snapshots/functions-list.txt"
cp -R "$REMOTE_FUNCTIONS/base44/functions/." \
  "$STAGE/snapshots/base44/functions/"

while IFS= read -r entity_name; do
  jq -S --arg name "$entity_name" \
    '.schemas[] | select(.entity_name == $name) | .entity_schema' \
    "$REMOTE_SCHEMA" > "$STAGE/candidate/base44/entities/$entity_name.jsonc"
done < "$ENTITY_NAMES_ACTUAL"

BASELINE_SIGNAL_SCHEMA="$STAGE/snapshots/GameRoomSignal.json"
cp "$STAGE/candidate/base44/entities/GameRoomSignal.jsonc" "$BASELINE_SIGNAL_SCHEMA"
jq -e --slurpfile fields "$PROJECTION_FIELDS" '
  . as $schema |
  all($fields[0] | keys[]; $schema.properties[.] == null)
' "$BASELINE_SIGNAL_SCHEMA" >/dev/null || fail "Projection fields already exist remotely." 77
jq -S --slurpfile fields "$PROJECTION_FIELDS" \
  '.properties += $fields[0]' "$BASELINE_SIGNAL_SCHEMA" \
  > "$WORK/GameRoomSignal.candidate.jsonc"
mv "$WORK/GameRoomSignal.candidate.jsonc" \
  "$STAGE/candidate/base44/entities/GameRoomSignal.jsonc"

ROLLBACK_FUNCTION="$STAGE/rollback/base44/functions/gameRoomAction"
CANDIDATE_FUNCTION="$STAGE/candidate/base44/functions/gameRoomAction"
"$FLATTEN_FUNCTION" \
  "$REMOTE_GAME_ROOM_ACTION" "$ROLLBACK_FUNCTION" \
  gameRoomAction "$EXPECTED_GAME_ROOM_ACTION_RUNTIME_COUNT"
ROLLBACK_SIGNAL="$ROLLBACK_FUNCTION/game-room-signal.ts"
cp "$PROJECTION_SAFE_SIGNAL" "$ROLLBACK_SIGNAL"
cp -R "$ROLLBACK_FUNCTION" "$CANDIDATE_FUNCTION"
(
  cd "$STAGE/candidate"
  git apply --check "$ENABLE_DIRECT_PATCH"
  git apply "$ENABLE_DIRECT_PATCH"
)
[[ "$(jq -er '.entry' "$CANDIDATE_FUNCTION/function.jsonc")" == "entry.ts" && \
  -f "$CANDIDATE_FUNCTION/entry.ts" ]] || \
  fail "Candidate function is not directly deployable." 77
[[ "$(jq -er '.entry' "$ROLLBACK_FUNCTION/function.jsonc")" == "entry.ts" && \
  -f "$ROLLBACK_FUNCTION/entry.ts" ]] || \
  fail "Rollback function is not directly deployable." 77

find "$STAGE" -type d -exec chmod 700 {} +
find "$STAGE" -type f -exec chmod 600 {} +
assert_no_find_match "Symlink in cutover package." "$STAGE" -type l
assert_no_find_match \
  "Generated package must remain unlinked from every Base44 app." \
  "$STAGE" -name '.app.json*'

: > "$ENTITY_INVENTORY_JSONL"
while IFS= read -r entity_name; do
  candidate_file="$STAGE/candidate/base44/entities/$entity_name.jsonc"
  remote_hash="$(
    jq -S -c --arg name "$entity_name" \
      '.schemas[] | select(.entity_name == $name) | .entity_schema' \
      "$REMOTE_SCHEMA" | shasum -a 256 | awk '{print $1}'
  )"
  candidate_raw_hash="$(hash_file "$candidate_file")"
  candidate_canonical_hash="$(canonical_json_hash "$candidate_file")"
  jq -n --arg name "$entity_name" --arg remote "$remote_hash" \
    --arg raw "$candidate_raw_hash" --arg candidate "$candidate_canonical_hash" \
    '{name:$name,remote_canonical_sha256:$remote,candidate_raw_sha256:$raw,
      candidate_canonical_sha256:$candidate,
      changed:($remote != $candidate)}' >> "$ENTITY_INVENTORY_JSONL"
done < "$ENTITY_NAMES_ACTUAL"
jq -s 'sort_by(.name)' "$ENTITY_INVENTORY_JSONL" \
  > "$STAGE/snapshots/entity-inventory.json"

: > "$FUNCTION_INVENTORY_JSONL"
while IFS= read -r function_name; do
  function_hash="$(
    tree_hash "$REMOTE_FUNCTIONS/base44/functions/$function_name"
  )"
  jq -n --arg name "$function_name" --arg hash "$function_hash" \
    '{name:$name,tree_sha256:$hash}' >> "$FUNCTION_INVENTORY_JSONL"
done < "$FUNCTION_NAMES_ACTUAL"
jq -s 'sort_by(.name)' "$FUNCTION_INVENTORY_JSONL" \
  > "$STAGE/snapshots/function-inventory.json"

REMOTE_ENTITY_SET_HASH="$(
  jq -S -c '[.schemas[].entity_schema] | sort_by(.name)' "$REMOTE_SCHEMA" |
    shasum -a 256 | awk '{print $1}'
)"
BASELINE_FUNCTION_HASH="$(tree_hash "$STAGE/snapshots/base44/functions/gameRoomAction")"
CANDIDATE_ENTITIES_HASH="$(tree_hash "$STAGE/candidate/base44/entities")"
CANDIDATE_FUNCTION_HASH="$(tree_hash "$CANDIDATE_FUNCTION")"
ROLLBACK_FUNCTION_HASH="$(tree_hash "$ROLLBACK_FUNCTION")"
EXPECTED_REMOTE_CANDIDATE="$WORK/expected-remote-candidate"
EXPECTED_REMOTE_ROLLBACK="$WORK/expected-remote-rollback"
mkdir -p \
  "$EXPECTED_REMOTE_CANDIDATE/base44/functions/gameRoomAction" \
  "$EXPECTED_REMOTE_ROLLBACK/base44/functions/gameRoomAction"
cp "$REMOTE_GAME_ROOM_ACTION/function.jsonc" \
  "$EXPECTED_REMOTE_CANDIDATE/function.jsonc"
cp "$REMOTE_GAME_ROOM_ACTION/function.jsonc" \
  "$EXPECTED_REMOTE_ROLLBACK/function.jsonc"
find "$CANDIDATE_FUNCTION" -maxdepth 1 -type f ! -name function.jsonc \
  -exec cp {} "$EXPECTED_REMOTE_CANDIDATE/base44/functions/gameRoomAction/" \;
find "$ROLLBACK_FUNCTION" -maxdepth 1 -type f ! -name function.jsonc \
  -exec cp {} "$EXPECTED_REMOTE_ROLLBACK/base44/functions/gameRoomAction/" \;
EXPECTED_REMOTE_CANDIDATE_HASH="$(tree_hash "$EXPECTED_REMOTE_CANDIDATE")"
EXPECTED_REMOTE_ROLLBACK_HASH="$(tree_hash "$EXPECTED_REMOTE_ROLLBACK")"
CANDIDATE_PACKAGE_HASH="$(tree_hash "$STAGE/candidate")"
ROLLBACK_PACKAGE_HASH="$(tree_hash "$STAGE/rollback")"
PROJECTION_FIELDS_HASH="$(canonical_json_hash "$PROJECTION_FIELDS")"
PROJECTION_SAFE_SIGNAL_HASH="$(hash_file "$PROJECTION_SAFE_SIGNAL")"
ENABLE_DIRECT_PATCH_HASH="$(hash_file "$ENABLE_DIRECT_PATCH")"

jq -n \
  --arg action "SPYCLASH_LOBBY_MODE_REALTIME_PILOT" \
  --arg target_app_id "$EXPECTED_APP_ID" \
  --arg generated_at "$GENERATED_AT" \
  --argjson generated_epoch "$GENERATED_EPOCH" \
  --arg operator "$OPERATOR" \
  --arg cli_version "$CLI_VERSION" \
  --arg git_commit "$GIT_COMMIT" \
  --arg git_branch "$GIT_BRANCH" \
  --arg remote_entity_set_hash "$REMOTE_ENTITY_SET_HASH" \
  --arg baseline_function_hash "$BASELINE_FUNCTION_HASH" \
  --arg candidate_entities_hash "$CANDIDATE_ENTITIES_HASH" \
  --arg candidate_function_hash "$CANDIDATE_FUNCTION_HASH" \
  --arg rollback_function_hash "$ROLLBACK_FUNCTION_HASH" \
  --arg expected_remote_candidate_hash "$EXPECTED_REMOTE_CANDIDATE_HASH" \
  --arg expected_remote_rollback_hash "$EXPECTED_REMOTE_ROLLBACK_HASH" \
  --arg candidate_package_hash "$CANDIDATE_PACKAGE_HASH" \
  --arg rollback_package_hash "$ROLLBACK_PACKAGE_HASH" \
  --arg projection_fields_hash "$PROJECTION_FIELDS_HASH" \
  --arg projection_safe_signal_hash "$PROJECTION_SAFE_SIGNAL_HASH" \
  --arg enable_direct_patch_hash "$ENABLE_DIRECT_PATCH_HASH" \
  --slurpfile entities "$STAGE/snapshots/entity-inventory.json" \
  --slurpfile functions "$STAGE/snapshots/function-inventory.json" '
  {
    manifest_version: 2,
    action: $action,
    target_app_id: $target_app_id,
    generated_at: $generated_at,
    generated_epoch: $generated_epoch,
    max_age_seconds: 120,
    source: {
      mode: "fresh-production-read-only",
      operator: $operator,
      cli_version: $cli_version,
      remote_entity_set_sha256: $remote_entity_set_hash,
      remote_game_room_action_sha256: $baseline_function_hash
    },
    git: {commit: $git_commit, branch: $git_branch, clean: true},
    inventory: {
      entity_count: ($entities[0] | length),
      entities: $entities[0],
      function_count: ($functions[0] | length),
      functions: $functions[0]
    },
    expected_change: {
      entity: "GameRoomSignal",
      added_optional_properties: [
        "projected_game_mode",
        "projection_committed_at",
        "projection_emitted_at",
        "projection_id",
        "projection_kind"
      ],
      function: "gameRoomAction",
      candidate_runtime_files: [
        "entry.ts",
        "game-room-signal.ts"
      ],
      rollback_runtime_files: [
        "game-room-signal.ts"
      ]
    },
    artifacts: {
      candidate_entities_tree_sha256: $candidate_entities_hash,
      candidate_function_tree_sha256: $candidate_function_hash,
      rollback_function_tree_sha256: $rollback_function_hash,
      expected_remote_candidate_function_tree_sha256: $expected_remote_candidate_hash,
      expected_remote_rollback_function_tree_sha256: $expected_remote_rollback_hash,
      baseline_function_tree_sha256: $baseline_function_hash,
      candidate_package_tree_sha256: $candidate_package_hash,
      rollback_package_tree_sha256: $rollback_package_hash,
      projection_fields_sha256: $projection_fields_hash,
      projection_safe_signal_sha256: $projection_safe_signal_hash,
      enable_direct_patch_sha256: $enable_direct_patch_hash
    },
    allowed_production_commands: [
      {
        step: "schema",
        cwd: "candidate",
        argv: ["env", "-u", "BASE44_APP_ID", "npx", "--yes", "base44@0.0.56", "--app-id", $target_app_id, "entities", "push"]
      },
      {
        step: "function",
        cwd: "candidate",
        argv: ["env", "-u", "BASE44_APP_ID", "npx", "--yes", "base44@0.0.56", "--app-id", $target_app_id, "functions", "deploy", "gameRoomAction"]
      },
      {
        step: "rollback",
        cwd: "rollback",
        argv: ["env", "-u", "BASE44_APP_ID", "npx", "--yes", "base44@0.0.56", "--app-id", $target_app_id, "functions", "deploy", "gameRoomAction"]
      }
    ],
    production_mutated: false
  }
' > "$STAGE/manifest.json"
chmod 600 "$STAGE/manifest.json"
hash_file "$STAGE/manifest.json" > "$STAGE/manifest.sha256"

"$ROOT/scripts/verify-base44-lobby-mode-pilot.sh" "$STAGE"
echo "Prepared read-only cutover package: $STAGE"
echo "Production mutated: no"
