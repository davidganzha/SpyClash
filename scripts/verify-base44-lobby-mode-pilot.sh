#!/bin/bash

set -euo pipefail
umask 077

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
EXPECTED_APP_ID="69a0e57fa939f578082f8091"
EXPECTED_CLI_VERSION="0.0.56"
EXPECTED_FUNCTION_COUNT=17
EXPECTED_ENTITY_COUNT=24
EXPECTED_BASELINE_FUNCTION_HASH="61981ace27453bc04c013533519dbc49cd6a6d70bca85b68427ea75db2df1991"
EXPECTED_BASELINE_SIGNAL_HASH="bdfe7d186dbc3fcb08b5a4da849c2eec674401af9332d986de44f600dfe4c953"
APP_FILE="$ROOT/base44/.app.jsonc"
CONFIG_FILE="$ROOT/base44/config.jsonc"
AUTH_FILE="${BASE44_AUTH_FILE:-$HOME/.base44/auth/auth.json}"
CUTOVER_ROOT="$ROOT/.base44-cutover/lobby-mode-realtime-pilot"
OVERLAY_ROOT="$ROOT/cutovers/lobby-mode-realtime-pilot/overlays"
PROJECTION_FIELDS="$OVERLAY_ROOT/game-room-signal-projection-fields.json"
PROJECTION_SAFE_SIGNAL="$OVERLAY_ROOT/projection-safe-game-room-signal.ts"
ENABLE_DIRECT_PATCH="$OVERLAY_ROOT/enable-direct-mode.patch"
STAGE="${1:-}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/spyclash-lobby-mode-verify.XXXXXX")"
CURL_CONFIG="$WORK/curl.conf"
CURRENT_REMOTE_SCHEMA="$WORK/current-remote-entities.json"
CURRENT_REMOTE_FUNCTIONS="$WORK/current-remote-functions"
CURRENT_FUNCTION_LIST="$WORK/current-functions-list.txt"

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

PROJECTION_KEYS=(
  projected_game_mode projection_committed_at projection_emitted_at
  projection_id projection_kind
)

cleanup() {
  if [[ -f "$CURL_CONFIG" && ! -L "$CURL_CONFIG" ]]; then
    : > "$CURL_CONFIG"
  fi
  case "$WORK" in
    "${TMPDIR:-/tmp}"/spyclash-lobby-mode-verify.*) rm -rf -- "$WORK" ;;
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

assert_tree_hash() {
  local tree=$1 expected=$2 label=$3 actual
  actual="$(tree_hash "$tree")"
  [[ "$actual" == "$expected" ]] || \
    fail "$label hash drift: expected $expected, got $actual" 77
}

base44_cli() {
  env -u BASE44_APP_ID npx --yes "base44@$EXPECTED_CLI_VERSION" \
    --app-id "$EXPECTED_APP_ID" "$@"
}

for command in awk basename chmod cmp cp curl date diff env find git grep head \
  jq mkdir mktemp npx rm sed shasum sort stat tr wc; do
  command -v "$command" >/dev/null 2>&1 || fail "Missing command: $command" 69
done

[[ -n "$STAGE" ]] || fail "Usage: $0 <prepared-stage>" 64
STAGE="$(CDPATH= cd -- "$STAGE" && pwd -P)" || fail "Missing cutover stage." 66
case "$STAGE" in
  "$CUTOVER_ROOT"/*) ;;
  *) fail "Cutover stage is outside the fixed private root." 77 ;;
esac
[[ -d "$STAGE" && ! -L "$STAGE" && -O "$STAGE" ]] || \
  fail "Unsafe cutover stage ownership." 77
! find "$STAGE" -type l -print | grep -q . || fail "Symlink in cutover stage." 77
! find "$STAGE" -name '.app.json*' -print | grep -q . || \
  fail "Cutover stage must remain unlinked from every Base44 app." 77

MANIFEST="$STAGE/manifest.json"
MANIFEST_HASH_FILE="$STAGE/manifest.sha256"
[[ -f "$MANIFEST" && -f "$MANIFEST_HASH_FILE" ]] || fail "Missing manifest."
EXPECTED_MANIFEST_HASH="$(tr -d '[:space:]' < "$MANIFEST_HASH_FILE")"
[[ "$EXPECTED_MANIFEST_HASH" =~ ^[0-9a-f]{64}$ ]] || fail "Invalid manifest hash."
[[ "$(hash_file "$MANIFEST")" == "$EXPECTED_MANIFEST_HASH" ]] || \
  fail "Manifest hash mismatch." 77

jq -e --arg app "$EXPECTED_APP_ID" --arg cli "$EXPECTED_CLI_VERSION" \
  --argjson entities "$EXPECTED_ENTITY_COUNT" \
  --argjson functions "$EXPECTED_FUNCTION_COUNT" '
  .manifest_version == 1 and
  .action == "SPYCLASH_LOBBY_MODE_REALTIME_PILOT" and
  .target_app_id == $app and
  .source.mode == "fresh-production-read-only" and
  (.source.operator | type == "string" and length > 0) and
  .source.cli_version == $cli and
  .inventory.entity_count == $entities and
  .inventory.function_count == $functions and
  .production_mutated == false and
  .git.clean == true
' "$MANIFEST" >/dev/null || fail "Manifest contract mismatch." 77

GENERATED_EPOCH="$(jq -er '.generated_epoch' "$MANIFEST")"
MAX_AGE="$(jq -er '.max_age_seconds' "$MANIFEST")"
NOW_EPOCH="$(date -u +'%s')"
AGE=$((NOW_EPOCH - GENERATED_EPOCH))
[[ "$AGE" -ge -60 && "$AGE" -le "$MAX_AGE" ]] || \
  fail "BLOCKED_STALE_CUTOVER_PACKAGE age=${AGE}s max=${MAX_AGE}s" 77

GIT_COMMIT="$(jq -er '.git.commit' "$MANIFEST")"
GIT_BRANCH="$(jq -er '.git.branch' "$MANIFEST")"
[[ "$(git -C "$ROOT" rev-parse HEAD)" == "$GIT_COMMIT" ]] || \
  fail "Git commit drifted after preparation." 77
[[ "$(git -C "$ROOT" symbolic-ref --short HEAD)" == "$GIT_BRANCH" ]] || \
  fail "Git branch drifted after preparation." 77
[[ -z "$(git -C "$ROOT" status --porcelain=v1)" ]] || \
  fail "Worktree is no longer clean." 77

if [[ -n "${BASE44_APP_ID+x}" && "$BASE44_APP_ID" != "$EXPECTED_APP_ID" ]]; then
  fail "BASE44_APP_ID targets another app." 77
fi
[[ -f "$APP_FILE" && ! -L "$APP_FILE" ]] || fail "Missing Base44 app link." 77
[[ -f "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || fail "Missing Base44 config." 77
[[ -f "$AUTH_FILE" && ! -L "$AUTH_FILE" && -O "$AUTH_FILE" ]] || \
  fail "Base44 authentication must be a user-owned regular file." 77
[[ "$(private_mode "$AUTH_FILE")" == 600 ]] || \
  fail "Base44 authentication must have mode 600." 77
APP_ID="$(sed -n 's/^[[:space:]]*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$APP_FILE" | head -n 1)"
[[ "$APP_ID" == "$EXPECTED_APP_ID" ]] || \
  fail "Refusing non-canonical Base44 app: $APP_ID" 77

CLI_VERSION="$(base44_cli --version | head -n 1 | tr -d '[:space:]')"
[[ "$CLI_VERSION" == "$EXPECTED_CLI_VERSION" ]] || fail "Base44 CLI drift." 77
WHOAMI_OUTPUT="$(base44_cli whoami)"
OPERATOR="$(printf '%s\n' "$WHOAMI_OUTPUT" | sed -n 's/^Logged in as:[[:space:]]*//p' | head -n 1)"
MANIFEST_OPERATOR="$(jq -er '.source.operator' "$MANIFEST")"
[[ "$OPERATOR" == "$MANIFEST_OPERATOR" ]] || fail "Base44 operator drift." 77

CANDIDATE="$STAGE/candidate"
ROLLBACK="$STAGE/rollback"
SNAPSHOTS="$STAGE/snapshots"
CANDIDATE_ENTITIES="$CANDIDATE/base44/entities"
CANDIDATE_FUNCTION="$CANDIDATE/base44/functions/gameRoomAction"
ROLLBACK_FUNCTION="$ROLLBACK/base44/functions/gameRoomAction"
BASELINE_FUNCTIONS="$SNAPSHOTS/base44/functions"
BASELINE_FUNCTION="$BASELINE_FUNCTIONS/gameRoomAction"
REMOTE_SCHEMA="$SNAPSHOTS/remote-entities.json"

[[ -d "$CANDIDATE_ENTITIES" && -d "$CANDIDATE_FUNCTION" && \
  -d "$ROLLBACK_FUNCTION" && -d "$BASELINE_FUNCTIONS" && \
  -d "$BASELINE_FUNCTION" && \
  -f "$REMOTE_SCHEMA" ]] || fail "Prepared package is incomplete."

[[ "$(find "$CANDIDATE/base44/functions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 1 ]] || \
  fail "Candidate contains more than gameRoomAction." 77
[[ "$(find "$ROLLBACK/base44/functions" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" == 1 ]] || \
  fail "Rollback contains more than gameRoomAction." 77
[[ "$(basename "$CANDIDATE_FUNCTION")" == "gameRoomAction" && \
  "$(basename "$ROLLBACK_FUNCTION")" == "gameRoomAction" ]] || \
  fail "Unexpected function target." 77
[[ ! -d "$ROLLBACK/base44/entities" ]] || \
  fail "Rollback must never push entity schemas." 77

printf '%s\n' "${EXPECTED_ENTITIES[@]}" | LC_ALL=C sort > "$WORK/entities-expected.txt"
find "$CANDIDATE_ENTITIES" -maxdepth 1 -type f -name '*.jsonc' -exec basename {} .jsonc \; \
  | LC_ALL=C sort > "$WORK/entities-actual.txt"
cmp -s "$WORK/entities-expected.txt" "$WORK/entities-actual.txt" || {
  diff -u "$WORK/entities-expected.txt" "$WORK/entities-actual.txt" >&2 || true
  fail "Candidate entity inventory mismatch." 77
}

printf '%s\n' "${EXPECTED_FUNCTIONS[@]}" | LC_ALL=C sort > "$WORK/functions-expected.txt"
jq -r '.inventory.functions[].name' "$MANIFEST" | LC_ALL=C sort \
  > "$WORK/functions-manifest.txt"
find "$BASELINE_FUNCTIONS" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
  | LC_ALL=C sort > "$WORK/functions-snapshot.txt"
cmp -s "$WORK/functions-expected.txt" "$WORK/functions-manifest.txt" || \
  fail "Manifest function inventory mismatch." 77
cmp -s "$WORK/functions-expected.txt" "$WORK/functions-snapshot.txt" || \
  fail "Snapshot function inventory mismatch." 77

while IFS= read -r function_name; do
  expected_hash="$(
    jq -er --arg name "$function_name" \
      '.inventory.functions[] | select(.name == $name) | .tree_sha256' \
      "$MANIFEST"
  )"
  [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || \
    fail "Invalid snapshot hash for function: $function_name" 77
  assert_tree_hash "$BASELINE_FUNCTIONS/$function_name" "$expected_hash" \
    "snapshot function $function_name"
done < "$WORK/functions-expected.txt"

BASELINE_HASH="$(jq -er '.artifacts.baseline_function_tree_sha256' "$MANIFEST")"
CANDIDATE_ENTITIES_HASH="$(jq -er '.artifacts.candidate_entities_tree_sha256' "$MANIFEST")"
CANDIDATE_FUNCTION_HASH="$(jq -er '.artifacts.candidate_function_tree_sha256' "$MANIFEST")"
ROLLBACK_FUNCTION_HASH="$(jq -er '.artifacts.rollback_function_tree_sha256' "$MANIFEST")"
CANDIDATE_PACKAGE_HASH="$(jq -er '.artifacts.candidate_package_tree_sha256' "$MANIFEST")"
ROLLBACK_PACKAGE_HASH="$(jq -er '.artifacts.rollback_package_tree_sha256' "$MANIFEST")"
[[ "$BASELINE_HASH" == "$EXPECTED_BASELINE_FUNCTION_HASH" ]] || \
  fail "Unexpected gameRoomAction baseline." 77
assert_tree_hash "$BASELINE_FUNCTION" "$BASELINE_HASH" "baseline function"
assert_tree_hash "$CANDIDATE_ENTITIES" "$CANDIDATE_ENTITIES_HASH" "candidate entities"
assert_tree_hash "$CANDIDATE_FUNCTION" "$CANDIDATE_FUNCTION_HASH" "candidate function"
assert_tree_hash "$ROLLBACK_FUNCTION" "$ROLLBACK_FUNCTION_HASH" "rollback function"
assert_tree_hash "$CANDIDATE" "$CANDIDATE_PACKAGE_HASH" "candidate package"
assert_tree_hash "$ROLLBACK" "$ROLLBACK_PACKAGE_HASH" "rollback package"

[[ "$(canonical_json_hash "$PROJECTION_FIELDS")" == \
  "$(jq -er '.artifacts.projection_fields_sha256' "$MANIFEST")" ]] || \
  fail "Projection schema overlay drift." 77
[[ "$(hash_file "$PROJECTION_SAFE_SIGNAL")" == \
  "$(jq -er '.artifacts.projection_safe_signal_sha256' "$MANIFEST")" ]] || \
  fail "Projection-safe function overlay drift." 77
[[ "$(hash_file "$ENABLE_DIRECT_PATCH")" == \
  "$(jq -er '.artifacts.enable_direct_patch_sha256' "$MANIFEST")" ]] || \
  fail "Direct-mode patch drift." 77

jq -e --argjson count "$EXPECTED_ENTITY_COUNT" '
  .total == $count and .total == (.schemas | length) and
  ([.schemas[].entity_name] | unique | length) == $count and
  all(.schemas[];
    (.entity_name | type == "string" and test("^[A-Za-z0-9-]+$")) and
    (.entity_schema | type == "object") and
    .entity_schema.name == .entity_name)
' "$REMOTE_SCHEMA" >/dev/null || fail "Remote entity snapshot is malformed." 77
jq -r '.schemas[].entity_name' "$REMOTE_SCHEMA" | LC_ALL=C sort \
  > "$WORK/entities-snapshot.txt"
cmp -s "$WORK/entities-expected.txt" "$WORK/entities-snapshot.txt" || \
  fail "Snapshot entity inventory mismatch." 77
SNAPSHOT_ENTITY_SET_HASH="$(
  jq -S -c '[.schemas[].entity_schema] | sort_by(.name)' "$REMOTE_SCHEMA" |
    shasum -a 256 | awk '{print $1}'
)"
[[ "$SNAPSHOT_ENTITY_SET_HASH" == \
  "$(jq -er '.source.remote_entity_set_sha256' "$MANIFEST")" ]] || \
  fail "Snapshot entity set hash drift." 77

CHANGED_ENTITIES=0
while IFS= read -r entity_name; do
  candidate_file="$CANDIDATE_ENTITIES/$entity_name.jsonc"
  jq -S --arg name "$entity_name" \
    '.schemas[] | select(.entity_name == $name) | .entity_schema' \
    "$REMOTE_SCHEMA" > "$WORK/$entity_name.remote.json"
  if ! cmp -s <(jq -S -c . "$candidate_file") \
    <(jq -S -c . "$WORK/$entity_name.remote.json"); then
    CHANGED_ENTITIES=$((CHANGED_ENTITIES + 1))
    [[ "$entity_name" == "GameRoomSignal" ]] || \
      fail "Non-target entity changed: $entity_name" 77
  fi
done < "$WORK/entities-expected.txt"
[[ "$CHANGED_ENTITIES" == 1 ]] || fail "Expected exactly one entity change." 77

BASELINE_SIGNAL="$WORK/GameRoomSignal.remote.json"
CANDIDATE_SIGNAL="$CANDIDATE_ENTITIES/GameRoomSignal.jsonc"
[[ "$(canonical_json_hash "$BASELINE_SIGNAL")" == "$EXPECTED_BASELINE_SIGNAL_HASH" ]] || \
  fail "GameRoomSignal baseline drift." 77
jq -S --argjson keys "$(printf '%s\n' "${PROJECTION_KEYS[@]}" | jq -R . | jq -s .)" \
  'reduce $keys[] as $key (. ; del(.properties[$key]))' "$CANDIDATE_SIGNAL" \
  > "$WORK/GameRoomSignal.without-projection.json"
cmp -s <(jq -S -c . "$BASELINE_SIGNAL") \
  <(jq -S -c . "$WORK/GameRoomSignal.without-projection.json") || \
  fail "GameRoomSignal changed outside the five optional projection fields." 77
jq -e --slurpfile expected "$PROJECTION_FIELDS" '
  ([.required[]] | any(. == "projection_kind" or . == "projection_id" or
    . == "projected_game_mode" or . == "projection_committed_at" or
    . == "projection_emitted_at") | not) and
  .properties.projection_kind == $expected[0].projection_kind and
  .properties.projection_id == $expected[0].projection_id and
  .properties.projected_game_mode == $expected[0].projected_game_mode and
  .properties.projection_committed_at == $expected[0].projection_committed_at and
  .properties.projection_emitted_at == $expected[0].projection_emitted_at
' "$CANDIDATE_SIGNAL" >/dev/null || fail "Projection schema contract mismatch." 77

find "$BASELINE_FUNCTION" -type f -print | sed "s#^$BASELINE_FUNCTION/##" | LC_ALL=C sort \
  > "$WORK/baseline-files.txt"
find "$ROLLBACK_FUNCTION" -type f -print | sed "s#^$ROLLBACK_FUNCTION/##" | LC_ALL=C sort \
  > "$WORK/rollback-files.txt"
find "$CANDIDATE_FUNCTION" -type f -print | sed "s#^$CANDIDATE_FUNCTION/##" | LC_ALL=C sort \
  > "$WORK/candidate-files.txt"
cmp -s "$WORK/baseline-files.txt" "$WORK/rollback-files.txt" || \
  fail "Rollback function file inventory drift." 77
cmp -s "$WORK/rollback-files.txt" "$WORK/candidate-files.txt" || \
  fail "Candidate function file inventory drift." 77

SIGNAL_RELATIVE="base44/functions/gameRoomAction/game-room-signal.ts"
ENTRY_RELATIVE="base44/functions/gameRoomAction/entry.ts"
while IFS= read -r relative; do
  if [[ "$relative" != "$SIGNAL_RELATIVE" ]]; then
    cmp -s "$BASELINE_FUNCTION/$relative" "$ROLLBACK_FUNCTION/$relative" || \
      fail "Rollback changed unexpected runtime file: $relative" 77
  fi
  if [[ "$relative" != "$ENTRY_RELATIVE" ]]; then
    cmp -s "$ROLLBACK_FUNCTION/$relative" "$CANDIDATE_FUNCTION/$relative" || \
      fail "Candidate changed unexpected runtime file: $relative" 77
  fi
done < "$WORK/baseline-files.txt"
cmp -s "$ROLLBACK_FUNCTION/$SIGNAL_RELATIVE" "$PROJECTION_SAFE_SIGNAL" || \
  fail "Rollback projection-safe module mismatch." 77
cmp -s "$CANDIDATE_FUNCTION/$SIGNAL_RELATIVE" "$PROJECTION_SAFE_SIGNAL" || \
  fail "Candidate projection-safe module mismatch." 77
cp "$BASELINE_FUNCTION/$ENTRY_RELATIVE" "$WORK/entry.ts"
mkdir -p "$WORK/expected-entry/base44/functions/gameRoomAction"
cp "$WORK/entry.ts" "$WORK/expected-entry/$ENTRY_RELATIVE"
(
  cd "$WORK/expected-entry"
  git apply --check "$ENABLE_DIRECT_PATCH"
  git apply "$ENABLE_DIRECT_PATCH"
)
cmp -s "$WORK/expected-entry/$ENTRY_RELATIVE" "$CANDIDATE_FUNCTION/$ENTRY_RELATIVE" || \
  fail "Candidate direct-mode entry patch mismatch." 77

jq -e --arg app "$EXPECTED_APP_ID" '
  .allowed_production_commands == [
    {
      step: "schema",
      cwd: "candidate",
      argv: ["env", "-u", "BASE44_APP_ID", "npx", "--yes", "base44@0.0.56", "--app-id", $app, "entities", "push"]
    },
    {
      step: "function",
      cwd: "candidate",
      argv: ["env", "-u", "BASE44_APP_ID", "npx", "--yes", "base44@0.0.56", "--app-id", $app, "functions", "deploy", "gameRoomAction"]
    },
    {
      step: "rollback",
      cwd: "rollback",
      argv: ["env", "-u", "BASE44_APP_ID", "npx", "--yes", "base44@0.0.56", "--app-id", $app, "functions", "deploy", "gameRoomAction"]
    }
  ]
' "$MANIFEST" >/dev/null || fail "Production command allowlist mismatch." 77

# Final just-in-time production readback. This is intentionally last so a
# successful READY_FOR_APPROVAL is tied to the freshest available baseline.
mkdir -p "$CURRENT_REMOTE_FUNCTIONS/base44"
cp "$CONFIG_FILE" "$APP_FILE" "$CURRENT_REMOTE_FUNCTIONS/base44/"
(
  cd "$CURRENT_REMOTE_FUNCTIONS"
  base44_cli functions list > "$CURRENT_FUNCTION_LIST"
  base44_cli functions pull
)
CURRENT_FUNCTIONS="$CURRENT_REMOTE_FUNCTIONS/base44/functions"
[[ -s "$CURRENT_FUNCTION_LIST" && -d "$CURRENT_FUNCTIONS" ]] || \
  fail "BLOCKED_NO_CURRENT_REMOTE_FUNCTION_BASELINE" 77
! find "$CURRENT_FUNCTIONS" -type l -print | grep -q . || \
  fail "Symlink in current remote function baseline." 77
find "$CURRENT_FUNCTIONS" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; \
  | LC_ALL=C sort > "$WORK/functions-current.txt"
cmp -s "$WORK/functions-expected.txt" "$WORK/functions-current.txt" || {
  diff -u "$WORK/functions-expected.txt" "$WORK/functions-current.txt" >&2 || true
  fail "BLOCKED_REMOTE_FUNCTION_INVENTORY_DRIFT" 77
}
while IFS= read -r function_name; do
  expected_hash="$(
    jq -er --arg name "$function_name" \
      '.inventory.functions[] | select(.name == $name) | .tree_sha256' \
      "$MANIFEST"
  )"
  current_hash="$(tree_hash "$CURRENT_FUNCTIONS/$function_name")"
  [[ "$current_hash" == "$expected_hash" ]] || \
    fail "BLOCKED_REMOTE_FUNCTION_HASH_DRIFT function=$function_name" 77
done < "$WORK/functions-expected.txt"

ACCESS_TOKEN="$(jq -er '.accessToken' "$AUTH_FILE")" || \
  fail "Unable to read Base44 access token." 77
printf 'header = "Authorization: Bearer %s"\n' "$ACCESS_TOKEN" > "$CURL_CONFIG"
unset ACCESS_TOKEN
curl -fsS --connect-timeout 10 --max-time 60 --retry 2 \
  --config "$CURL_CONFIG" \
  "https://app.base44.com/api/apps/$EXPECTED_APP_ID/entity-schemas" \
  > "$CURRENT_REMOTE_SCHEMA"
: > "$CURL_CONFIG"
chmod 600 "$CURRENT_REMOTE_SCHEMA"
jq -e --argjson count "$EXPECTED_ENTITY_COUNT" '
  .total == $count and .total == (.schemas | length) and
  ([.schemas[].entity_name] | unique | length) == $count and
  all(.schemas[];
    (.entity_name | type == "string" and test("^[A-Za-z0-9-]+$")) and
    (.entity_schema | type == "object") and
    .entity_schema.name == .entity_name)
' "$CURRENT_REMOTE_SCHEMA" >/dev/null || \
  fail "BLOCKED_INVALID_CURRENT_REMOTE_ENTITY_BASELINE" 77
jq -r '.schemas[].entity_name' "$CURRENT_REMOTE_SCHEMA" | LC_ALL=C sort \
  > "$WORK/entities-current.txt"
cmp -s "$WORK/entities-expected.txt" "$WORK/entities-current.txt" || {
  diff -u "$WORK/entities-expected.txt" "$WORK/entities-current.txt" >&2 || true
  fail "BLOCKED_REMOTE_ENTITY_INVENTORY_DRIFT" 77
}
CURRENT_ENTITY_SET_HASH="$(
  jq -S -c '[.schemas[].entity_schema] | sort_by(.name)' \
    "$CURRENT_REMOTE_SCHEMA" | shasum -a 256 | awk '{print $1}'
)"
[[ "$CURRENT_ENTITY_SET_HASH" == "$SNAPSHOT_ENTITY_SET_HASH" ]] || \
  fail "BLOCKED_REMOTE_ENTITY_BASELINE_DRIFT" 77
cmp -s \
  <(jq -S -c '[.schemas[].entity_schema] | sort_by(.name)' "$REMOTE_SCHEMA") \
  <(jq -S -c '[.schemas[].entity_schema] | sort_by(.name)' "$CURRENT_REMOTE_SCHEMA") || \
  fail "BLOCKED_REMOTE_ENTITY_BASELINE_DRIFT" 77

REVALIDATED_AT="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
NOW_EPOCH="$(date -u +'%s')"
AGE=$((NOW_EPOCH - GENERATED_EPOCH))
[[ "$AGE" -ge -60 && "$AGE" -le "$MAX_AGE" ]] || \
  fail "BLOCKED_STALE_CUTOVER_PACKAGE age=${AGE}s max=${MAX_AGE}s" 77

echo "READY_FOR_APPROVAL"
echo "target_app_id=$EXPECTED_APP_ID"
echo "manifest_sha256=$EXPECTED_MANIFEST_HASH"
echo "age_seconds=$AGE"
echo "entity_count=$EXPECTED_ENTITY_COUNT changed_entity=GameRoomSignal"
echo "function_count=$EXPECTED_FUNCTION_COUNT changed_function=gameRoomAction"
echo "remote_revalidated_at=$REVALIDATED_AT"
echo "production_mutated=false"
