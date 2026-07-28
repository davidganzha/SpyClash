#!/bin/bash

set -euo pipefail
umask 077

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)"
SCRIPT="$ROOT/scripts/recover-base44-notification-push-function.sh"
SCHEMA_FIXTURE="$ROOT/scripts/tests/fixtures/notification-step-a-schema-response.json"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/spyclash-push-recovery-test.XXXXXX")"
TEST_ROOT="$(CDPATH= cd -- "$TEST_ROOT" && pwd -P)"
TEST_ROOT_PARENT="$(CDPATH= cd -- "$(dirname -- "$TEST_ROOT")" && pwd -P)"
WORKSPACE="$TEST_ROOT/workspace"
FAKE_BIN="$TEST_ROOT/bin"
FAKE_HOME="$TEST_ROOT/home"
FAKE_REMOTE="$TEST_ROOT/remote-functions"
FAKE_SCHEMA="$TEST_ROOT/schema.json"
DEPLOY_MARKER="$TEST_ROOT/deploy-marker.txt"

cleanup() {
    case "$TEST_ROOT" in
        "$TEST_ROOT_PARENT"/spyclash-push-recovery-test.*) rm -rf -- "$TEST_ROOT" ;;
    esac
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

FUNCTIONS=(
    advanceRound app-store-entitlement appleAuthBroker appleAuthCallback
    autoRegisterUser checkSubscription communityAction createCheckout
    deleteAccount gameRoomAction generateWordPack googleAuthCallback
    mobileAuthCallback notificationAction pushNotificationAction
    stripe-entitlement-webhook wordPackAction
)

mkdir -p "$WORKSPACE/scripts" "$WORKSPACE/base44/functions" "$FAKE_BIN" \
    "$FAKE_HOME/.base44/auth" "$FAKE_REMOTE"
cp "$SCRIPT" "$WORKSPACE/scripts/recover-base44-notification-push-function.sh"
chmod 755 "$WORKSPACE/scripts/recover-base44-notification-push-function.sh"
printf '%s\n' '{"name":"SpyClash"}' > "$WORKSPACE/base44/config.jsonc"
printf '%s\n' '{' '  "id": "69a0e57fa939f578082f8091"' '}' > "$WORKSPACE/base44/.app.jsonc"
printf '%s\n' '{"accessToken":"test-only-token"}' > "$FAKE_HOME/.base44/auth/auth.json"
chmod 600 "$FAKE_HOME/.base44/auth/auth.json"

for name in "${FUNCTIONS[@]}"; do
    mkdir -p "$FAKE_REMOTE/$name"
    printf '{"name":"%s","entry":"main.ts"}\n' "$name" > "$FAKE_REMOTE/$name/function.jsonc"
    printf 'export const functionName = %q;\n' "$name" > "$FAKE_REMOTE/$name/main.ts"
done

mkdir -p "$WORKSPACE/base44/functions/pushNotificationAction"
cp "$FAKE_REMOTE/pushNotificationAction/main.ts" "$WORKSPACE/base44/functions/pushNotificationAction/main.ts"
printf '%s\n' \
    '{' \
    '  "name": "pushNotificationAction",' \
    '  "entry": "main.ts",' \
    '  "automations": [{' \
    '    "type": "scheduled",' \
    '    "name": "drain_push_delivery_retries",' \
    '    "description": "Cost-bounded retry worker. The automation creator must retain the admin role.",' \
    '    "is_active": true,' \
    '    "schedule_mode": "recurring",' \
    '    "schedule_type": "simple",' \
    '    "repeat_unit": "minutes",' \
    '    "repeat_interval": 5,' \
    '    "ends_type": "never",' \
    '    "function_args": {"action":"drain","limit":64}' \
    '  }]' \
    '}' > "$WORKSPACE/base44/functions/pushNotificationAction/function.jsonc"

[[ -f "$SCHEMA_FIXTURE" ]] || fail "tracked schema response fixture is missing"
cp "$SCHEMA_FIXTURE" "$FAKE_SCHEMA"
jq -e '
  .total == 22 and .total == (.schemas | length) and
  ([.schemas[].entity_name] | unique | length) == 22 and
  all(.schemas[]; .entity_schema.name == .entity_name)
' "$FAKE_SCHEMA" >/dev/null || fail "tracked schema fixture is malformed"
schema_digest="$(jq -S '[.schemas[].entity_schema] | sort_by(.name)' "$FAKE_SCHEMA" | shasum -a 256 | awk '{print $1}')"
[[ "$schema_digest" == "1be1657ecc65e54e918dd2361f913bd881471f53d0f3cb2f67afb8d2560b811e" ]] || \
    fail "schema fixture does not match the reviewed digest"

printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'case " $* " in' \
    '  *" whoami "*) echo "Logged in as: test@example.com" ;;' \
    '  *" functions pull "*)' \
    '    mkdir -p "$PWD/base44/functions"' \
    '    cp -R "$FAKE_REMOTE_FUNCTIONS_DIR"/. "$PWD/base44/functions"/' \
    '    ;;' \
    '  *" functions deploy pushNotificationAction "*)' \
    '    printf "%s\t%s\n" pushNotificationAction "$PWD" >> "$FAKE_DEPLOY_MARKER"' \
    '    cp -R "$PWD/base44/functions/pushNotificationAction"/. "$FAKE_REMOTE_FUNCTIONS_DIR/pushNotificationAction"/' \
    '    ;;' \
    '  *) echo "unexpected fake npx invocation: $*" >&2; exit 64 ;;' \
    'esac' > "$FAKE_BIN/npx"
chmod 755 "$FAKE_BIN/npx"

printf '%s\n' \
    '#!/bin/bash' \
    'set -euo pipefail' \
    'command cat "$FAKE_SCHEMA_RESPONSE"' > "$FAKE_BIN/curl"
chmod 755 "$FAKE_BIN/curl"

run_recovery() {
    env PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" TMPDIR="$TEST_ROOT" \
        FAKE_REMOTE_FUNCTIONS_DIR="$FAKE_REMOTE" FAKE_SCHEMA_RESPONSE="$FAKE_SCHEMA" \
        FAKE_DEPLOY_MARKER="$DEPLOY_MARKER" \
        "$WORKSPACE/scripts/recover-base44-notification-push-function.sh" "$@"
}

prepare_output="$(run_recovery)"
plan_digest="$(printf '%s\n' "$prepare_output" | sed -n 's/^Plan digest: //p')"
[[ "$plan_digest" =~ ^[0-9a-f]{64}$ ]] || fail "prepare did not produce a plan digest"
[[ ! -e "$DEPLOY_MARKER" ]] || fail "read-only prepare invoked deployment"
manifest="$WORKSPACE/.base44-cutover/notification-step-b-push-recovery/plans/$plan_digest/manifest.json"
[[ -f "$manifest" ]] || fail "immutable reviewed plan was not written"
jq -e '
  .target_function == "pushNotificationAction" and
  .schema_digest == "1be1657ecc65e54e918dd2361f913bd881471f53d0f3cb2f67afb8d2560b811e" and
  .deploy_function_order == ["pushNotificationAction"] and
  .delta.additions == [] and .delta.deletions == [] and
  .delta.changes == ["pushNotificationAction"] and (.delta.unchanged | length) == 16
' "$manifest" >/dev/null || fail "prepared manifest violates the recovery boundary"

second_prepare_output="$(run_recovery)"
second_plan_digest="$(printf '%s\n' "$second_prepare_output" | sed -n 's/^Plan digest: //p')"
[[ "$second_plan_digest" == "$plan_digest" ]] || fail "identical prepare was not deterministic"

set +e
run_recovery --deploy --plan-digest "$plan_digest" > "$TEST_ROOT/missing-confirmation.out" 2>&1
missing_confirmation_status=$?
set -e
[[ "$missing_confirmation_status" -eq 77 ]] || fail "missing confirmation did not fail closed"
[[ ! -e "$DEPLOY_MARKER" ]] || fail "missing confirmation reached deployment"

env PATH="$FAKE_BIN:$PATH" HOME="$FAKE_HOME" TMPDIR="$TEST_ROOT" \
    FAKE_REMOTE_FUNCTIONS_DIR="$FAKE_REMOTE" FAKE_SCHEMA_RESPONSE="$FAKE_SCHEMA" \
    FAKE_DEPLOY_MARKER="$DEPLOY_MARKER" \
    BASE44_CONFIRM_APP_ID="69a0e57fa939f578082f8091" \
    BASE44_CONFIRM_ACTION="SPYCLASH_NOTIFICATION_STEP_B_PUSH_RECOVERY" \
    BASE44_CONFIRM_NOTIFICATION_PUSH_RECOVERY_PLAN_DIGEST="$plan_digest" \
    "$WORKSPACE/scripts/recover-base44-notification-push-function.sh" \
    --deploy --plan-digest "$plan_digest" > "$TEST_ROOT/deploy.out"

[[ "$(wc -l < "$DEPLOY_MARKER" | tr -d ' ')" -eq 1 ]] || fail "recovery did not deploy exactly once"
IFS=$'\t' read -r deployed_function deployed_from < "$DEPLOY_MARKER"
[[ "$deployed_function" == "pushNotificationAction" ]] || fail "recovery deployed another function"
case "$deployed_from" in
    "$TEST_ROOT"/spyclash-notification-push-recovery.*/verified-deploy) ;;
    *) fail "recovery did not deploy from the fresh private verified payload: $deployed_from" ;;
esac
case "$deployed_from" in
    "$WORKSPACE"/.base44-cutover/*) fail "recovery deployed directly from the durable reviewed plan" ;;
esac
postflight="$WORKSPACE/.base44-cutover/evidence/notification-step-b-push-recovery/latest-postflight.json"
jq -e '
  .target_function == "pushNotificationAction" and .deploy_status == 0 and
  .function_postflight_status == 0 and .schema_postflight_status == 0 and
  .expected_non_target_bytes_digest == .actual_non_target_bytes_digest and
  .expected_schema_digest == .actual_schema_digest and .matches_reviewed_stage == true
' "$postflight" >/dev/null || fail "successful recovery postflight is incomplete"

echo "PASS: pushNotificationAction recovery prepare, guards, scoped deploy, and postflight"
