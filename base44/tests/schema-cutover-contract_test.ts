import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

const additiveURL = new URL(
  "../../scripts/push-base44-additive-schema.sh",
  import.meta.url,
);
const finalURL = new URL(
  "../../scripts/push-base44-final-schema.sh",
  import.meta.url,
);
const coordinatedFunctionsURL = new URL(
  "../../scripts/deploy-base44-coordinated-functions.sh",
  import.meta.url,
);
const releaseSecretsURL = new URL(
  "../../scripts/check-base44-release-secrets.sh",
  import.meta.url,
);
const pseudonymSecretURL = new URL(
  "../../scripts/ensure-base44-pseudonym-secret.sh",
  import.meta.url,
);
const guardDeployURL = new URL(
  "../../scripts/deploy-base44-delete-maintenance-guard.sh",
  import.meta.url,
);
const ownerBackfillURL = new URL(
  "../../scripts/run-base44-sensitive-owner-backfill.sh",
  import.meta.url,
);
const finalDeleteURL = new URL(
  "../../scripts/deploy-base44-final-delete-account.sh",
  import.meta.url,
);

function assertBefore(source: string, earlier: string, later: string) {
  const earlierIndex = source.indexOf(earlier);
  const laterIndex = source.indexOf(later);
  assert(earlierIndex >= 0, `missing cutover step: ${earlier}`);
  assert(laterIndex >= 0, `missing cutover boundary: ${later}`);
  assert(
    earlierIndex < laterIndex,
    `${earlier} must be prepared before ${later}`,
  );
}

function occurrenceCount(source: string, value: string): number {
  return source.split(value).length - 1;
}

function shellFunction(source: string, name: string): string {
  const start = source.indexOf(`${name}() {`);
  assert(start >= 0, `missing shell helper: ${name}`);
  const tail = source.slice(start + name.length + 4);
  const next = tail.search(/^\w+\(\) \{/m);
  return next < 0
    ? source.slice(start)
    : source.slice(start, start + name.length + 4 + next);
}

function assertSplitSignalTraps(source: string, label: string) {
  assertStringIncludes(source, "trap cleanup EXIT", `${label}: EXIT cleanup`);
  assertStringIncludes(source, "trap 'exit 129' HUP", `${label}: HUP exit`);
  assertStringIncludes(source, "trap 'exit 130' INT", `${label}: INT exit`);
  assertStringIncludes(source, "trap 'exit 143' TERM", `${label}: TERM exit`);
  assertEquals(
    source.includes("trap cleanup EXIT HUP INT TERM"),
    false,
    `${label}: signals must exit instead of resuming toward a mutation`,
  );
}

function assertDurableAttemptBeforeMutation(
  source: string,
  label: string,
  helperName: string,
  attemptMarker: string,
  mutationBoundary: string,
) {
  assertBefore(source, attemptMarker, mutationBoundary);
  const helper = shellFunction(source, helperName);
  assertStringIncludes(helper, "mktemp", `${label}: atomic temp file`);
  assertStringIncludes(helper, "mv ", `${label}: atomic rename`);
  assertStringIncludes(helper, "sync", `${label}: durable filesystem marker`);
  assertBefore(helper, "mktemp", "mv ");
  assertBefore(helper, "mv ", "sync");
}

function assertMutationLockOrder(
  source: string,
  label: string,
  guardedAcquire: string,
  perStepLock: string,
) {
  assertStringIncludes(
    source,
    'PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"',
  );
  assertEquals(
    occurrenceCount(source, "acquire_production_lock\n"),
    1,
    `${label}: shared lock may only be acquired from the mutation-mode branch`,
  );
  assertBefore(source, guardedAcquire, perStepLock);
}

Deno.test("additive schema stages every field required by coordinated functions", async () => {
  const source = await Deno.readTextFile(additiveURL);
  const pushBoundary = '--app-id "$APP_ID" entities push)';

  for (
    const field of [
      "add_optional_field GameHistory match_type",
      "add_optional_field GameHistory ranked",
      "add_optional_field User spy_card_theme",
      "add_optional_field User spy_card_accent",
      "add_optional_field User spy_card_badge",
      "extend_user_enum language",
    ]
  ) {
    assertBefore(source, field, pushBoundary);
  }

  for (
    const field of [
      "rating",
      "games_played",
      "games_won",
      "ai_generations_today",
      "last_ai_generation_date",
      "spy_id",
    ]
  ) {
    assertStringIncludes(source, `${field}`);
  }
  assertBefore(source, 'add_user_authoritative_field "$field"', pushBoundary);
  assertStringIncludes(source, "Production write rule for User.$field differs");
  assertBefore(
    source,
    "BASE44_CONFIRM_ADDITIVE_PLAN_DIGEST:-}",
    pushBoundary,
  );
  assertBefore(source, "BASE44_CONFIRM_ACTION:-}", pushBoundary);
  assertStringIncludes(source, "SECURITY_CUTOVER_STEP_1_ADDITIVE_SCHEMA");
  assertStringIncludes(source, '"$APP_ID" "$remote_digest"');
  assertStringIncludes(source, "remote_digest:$remote_digest");
  assertStringIncludes(source, "EXPECTED_APP_ID=69a0e57fa939f578082f8091");
  assertStringIncludes(source, "EXPECTED_ENTITY_COUNT=20");
  assertStringIncludes(source, "EXPECTED_CUSTOM_ENTITY_COUNT=19");
  assertStringIncludes(
    source,
    'cmp -s "$CANONICAL_NAMES" "$STAGE_NAMES"',
  );
  assertStringIncludes(source, '"$stage_count" -ne "$EXPECTED_ENTITY_COUNT"');
  assertStringIncludes(source, "($checks | length) == $expected");
  assertStringIncludes(source, '--slurpfile schema_deltas "$SCHEMA_DELTAS"');
  assertStringIncludes(source, "schema_deltas:$schema_deltas[0]");
  assertStringIncludes(source, "schema_deltas_digest:$schema_deltas_digest");
  assertBefore(source, "BASE44_APP_ID targets $BASE44_APP_ID", pushBoundary);
  assertBefore(source, 'mkdir "$LOCK_DIR"', 'fetch_remote_schema "$REMOTE"');
  assertBefore(
    source,
    'cp "$FIXED_STAGE/manifest.json" "$REVIEWED_MANIFEST"',
    pushBoundary,
  );
  assertBefore(
    source,
    'diff -qr "$STAGE/base44" "$FIXED_STAGE/base44"',
    pushBoundary,
  );
  assertBefore(
    source,
    "fixed_stage_bytes_now=$(tree_bytes_digest",
    pushBoundary,
  );
  assertBefore(source, 'fetch_remote_schema "$JIT_REMOTE"', pushBoundary);
  assertBefore(source, "jit_remote_digest=", pushBoundary);
  assertBefore(source, "local_inputs_now=$(local_inputs_digest)", pushBoundary);
  assertBefore(source, "set +e", pushBoundary);
  assertBefore(source, pushBoundary, 'fetch_remote_schema "$POST_REMOTE"');
  assertStringIncludes(source, "reviewed_manifest_digest");
  assertStringIncludes(source, "matches_reviewed_stage");
  assertStringIncludes(
    source,
    'EVIDENCE_DIR="$CUTOVER_DIR/evidence/additive-schema"',
  );
  assertStringIncludes(source, '[ -L "$FIXED_STAGE/manifest.json" ]');
  assertStringIncludes(
    source,
    'secure_private_json_file "$FIXED_STAGE/manifest.json"',
  );
  assertBefore(source, '"$attempt_dir/attempt.json"', pushBoundary);
  assertBefore(source, pushBoundary, '"$attempt_dir/postflight.json"');
  assertEquals(
    source.includes(
      'cp "$WORK/additive-manifest-verified.json" "$STAGE/manifest.json"',
    ),
    false,
  );
});

Deno.test("final schema refuses to run before the additive User and history boundary", async () => {
  const source = await Deno.readTextFile(finalURL);
  const diffBoundary = ': > "$CHANGED_NAMES"';

  for (
    const prerequisite of [
      "require_live_property GameHistory match_type",
      "require_live_property GameHistory ranked",
      "require_live_property User rating",
      "require_live_property User spy_id",
      "require_live_property User spy_card_theme",
      "require_live_property User spy_card_accent",
      "require_live_property User spy_card_badge",
      'require_live_user_admin_write "$field"',
    ]
  ) {
    assertBefore(source, prerequisite, diffBoundary);
  }

  assertStringIncludes(source, '["ru", "en", "es"]');
  assertStringIncludes(source, "($checks | length) == 19");
  assertStringIncludes(source, "live_admin_write_boundary:true");
  assertStringIncludes(source, "EXPECTED_APP_ID=69a0e57fa939f578082f8091");
  assertStringIncludes(source, "SECURITY_CUTOVER_STEP_6_FINAL_SCHEMA");
  assertStringIncludes(source, "Final schema Production postflight verified.");
  assertStringIncludes(source, 'properties.role.type == "string"');
  assertStringIncludes(source, '"id", "email", "full_name", "role"');
  assertStringIncludes(source, "platform_user_fields_preserved");
  assertStringIncludes(source, "property_additions");
  assertStringIncludes(source, "property_removals");
  assertStringIncludes(source, "entity_add_count");
  assertStringIncludes(source, "entity_delete_count");
  assertBefore(source, 'mkdir "$LOCK_DIR"', 'fetch_remote_schema "$REMOTE"');
  assertBefore(
    source,
    'cp "$FIXED_STAGE/manifest.json" "$REVIEWED_MANIFEST"',
    '--app-id "$APP_ID" entities push)',
  );
  assertBefore(
    source,
    "fixed_stage_bytes_now=$(reviewed_payload_digest",
    '--app-id "$APP_ID" entities push)',
  );
  assertBefore(
    source,
    'fetch_remote_schema "$JIT_REMOTE"',
    '--app-id "$APP_ID" entities push)',
  );
  assertBefore(
    source,
    "jit_remote_digest=",
    '--app-id "$APP_ID" entities push)',
  );
  assertBefore(
    source,
    "local_inputs_now=$(local_inputs_digest)",
    '--app-id "$APP_ID" entities push)',
  );
  assertBefore(source, "set +e", '--app-id "$APP_ID" entities push)');
  assertBefore(
    source,
    '--app-id "$APP_ID" entities push)',
    'fetch_remote_schema "$POST_REMOTE"',
  );
  assertStringIncludes(source, "reviewed_manifest_digest");
  assertStringIncludes(source, "matches_reviewed_stage");
  assertStringIncludes(
    source,
    'EVIDENCE_DIR="$CUTOVER_DIR/evidence/final-schema"',
  );
  assertStringIncludes(source, '[ -L "$FIXED_STAGE/manifest.json" ]');
  assertStringIncludes(
    source,
    'secure_private_json_file "$FIXED_STAGE/manifest.json"',
  );
  assertStringIncludes(source, "--check) MODE=check");
  assertStringIncludes(source, 'CHECK_STAGE="$CUTOVER_DIR/final-schema-check"');
  assertBefore(
    source,
    '"$attempt_dir/attempt.json"',
    '--app-id "$APP_ID" entities push)',
  );
  assertBefore(
    source,
    '--app-id "$APP_ID" entities push)',
    '"$attempt_dir/postflight.json"',
  );
  assertEquals(
    source.includes("Base44 owns the built-in User row rules"),
    false,
  );
  assertEquals(
    source.includes(
      'cp "$WORK/final-manifest-verified.json" "$STAGE/manifest.json"',
    ),
    false,
  );
});

Deno.test("coordinated function deploy is explicit, schema-bound, and guarded", async () => {
  const source = await Deno.readTextFile(coordinatedFunctionsURL);
  const arrayMatch = source.match(/FUNCTIONS=\(\n([\s\S]*?)\n\)/);
  assert(arrayMatch, "missing fixed coordinated function array");
  const names = arrayMatch[1]
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);

  assertEquals(names, [
    "advanceRound",
    "app-store-entitlement",
    "appleAuthBroker",
    "appleAuthCallback",
    "autoRegisterUser",
    "checkSubscription",
    "communityAction",
    "createCheckout",
    "gameRoomAction",
    "generateWordPack",
    "googleAuthCallback",
    "mobileAuthCallback",
    "pushNotificationAction",
    "stripe-entitlement-webhook",
    "wordPackAction",
  ]);

  const deployBoundary = 'base44_cli functions deploy "${FUNCTIONS[@]}"';
  assertBefore(
    source,
    '"$ROOT/scripts/push-base44-final-schema.sh"',
    deployBoundary,
  );
  assertBefore(source, 'delete_guard_digest="$(guard_digest', deployBoundary);
  assertBefore(source, "schema_remote_digest", deployBoundary);
  assertBefore(source, "remote_cli_input_digest", deployBoundary);
  assertBefore(source, "remote_function_digest", deployBoundary);
  assertBefore(source, "local_cli_input_digest", deployBoundary);
  assertBefore(source, "local_function_digest", deployBoundary);
  assertBefore(
    source,
    "BASE44_CONFIRM_COORDINATED_FUNCTION_PLAN_DIGEST:-}",
    deployBoundary,
  );
  assertBefore(source, "BASE44_CONFIRM_APP_ID:-}", deployBoundary);
  assertBefore(source, "BASE44_CONFIRM_ACTION:-}", deployBoundary);
  assertBefore(source, 'pull_remote_functions "$REMOTE_JIT"', deployBoundary);
  assertBefore(source, "jit_schema_remote_digest=", deployBoundary);
  assertBefore(source, "LOCAL_SOURCE_JIT=", deployBoundary);
  assertBefore(source, "jit_fixed_stage_bytes_digest=", deployBoundary);
  assertBefore(source, 'cmp -s "$LOCAL_SOURCE_JIT"', deployBoundary);
  assertBefore(source, "set +e", deployBoundary);
  assertStringIncludes(source, "verified_digest");
  assertBefore(
    source,
    deployBoundary,
    'pull_remote_functions "$VERIFY_REMOTE"',
  );
  assertStringIncludes(source, '--app-id "$APP_ID"');
  assertStringIncludes(
    source,
    'validate_inventory "$REMOTE_BEFORE/base44/functions"',
  );
  assertStringIncludes(
    source,
    'sync-base44-apple-sign-in-credential.sh" --check',
  );
  assertStringIncludes(source, 'check-apple-migration.sh"');
  assertStringIncludes(source, "live_admin_write_boundary == true");
  assertStringIncludes(source, "SECURITY_CUTOVER_STEP_4_DEPLOY_15");
  assertStringIncludes(source, "postflight.json");
  assertStringIncludes(source, "effective_digest");
  assertStringIncludes(source, "cli_input_digest");
  assertStringIncludes(source, "deploy_stage_bytes_digest");
  assertStringIncludes(source, "local_source_cli_input_digest");
  assertStringIncludes(source, "reviewed_manifest_digest");
  assertStringIncludes(source, '"$FIXED_STAGE/postflight.json"');
  assertStringIncludes(
    source,
    'EVIDENCE_DIR="$CUTOVER_DIR/evidence/coordinated-functions"',
  );
  assertStringIncludes(source, '-L "$FIXED_STAGE/manifest.json"');
  assertStringIncludes(
    source,
    'secure_private_json_file "$FIXED_STAGE/manifest.json"',
  );
  assertStringIncludes(source, 'push-base44-final-schema.sh" --check');
  assertBefore(source, '"$attempt_dir/attempt.json"', deployBoundary);
  assertBefore(source, deployBoundary, '"$attempt_dir/postflight.json"');
  assert(
    occurrenceCount(source, '"$ROOT/scripts/push-base44-final-schema.sh"') >= 2,
    "coordinated deploy must recheck Production schema immediately before mutation",
  );
  const afterDeploy = source.slice(source.indexOf(deployBoundary));
  assertStringIncludes(afterDeploy, "function_postflight_status=0");
  assertStringIncludes(afterDeploy, "function_postflight_status=$?");
  assertStringIncludes(afterDeploy, "schema_postflight_status=0");
  assertStringIncludes(afterDeploy, "schema_postflight_status=$?");
  assertStringIncludes(
    afterDeploy,
    '"$ROOT/scripts/push-base44-final-schema.sh" --check',
  );
  assertStringIncludes(afterDeploy, "schema_postflight_matches");
  assertStringIncludes(afterDeploy, '"$function_postflight_status" -ne 0');
  assertStringIncludes(afterDeploy, '"$schema_postflight_status" -ne 0');
  assertEquals(source.includes("functions deploy --force"), false);
  assertEquals(source.includes("base44 deploy"), false);
  assertEquals(source.includes('cp "$WORK/manifest.verified.json"'), false);
});

Deno.test("all Production cutover sinks are signal-safe, durably marked, and globally serialized", async () => {
  const sources = {
    step1: await Deno.readTextFile(additiveURL),
    secret: await Deno.readTextFile(pseudonymSecretURL),
    step3: await Deno.readTextFile(guardDeployURL),
    step4: await Deno.readTextFile(coordinatedFunctionsURL),
    step6: await Deno.readTextFile(finalURL),
    step7: await Deno.readTextFile(ownerBackfillURL),
    step8: await Deno.readTextFile(finalDeleteURL),
  };

  for (const [label, source] of Object.entries(sources)) {
    assertSplitSignalTraps(source, label);
  }

  assertMutationLockOrder(
    sources.step1,
    "Step 1",
    'if [ "$MODE" = push ]; then\n  acquire_production_lock\nfi',
    'if ! mkdir "$LOCK_DIR"',
  );
  assertMutationLockOrder(
    sources.secret,
    "secret",
    'if [ "$MODE" = set ]; then\n  acquire_production_lock\nfi',
    'if ! mkdir "$LOCK_DIR"',
  );
  assertMutationLockOrder(
    sources.step3,
    "Step 3",
    'if [[ "$MODE" == "deploy" ]]; then\n    acquire_production_lock\nfi',
    'if ! mkdir "$LOCK_DIR"',
  );
  assertMutationLockOrder(
    sources.step4,
    "Step 4",
    'if [[ "$MODE" == "deploy" ]]; then\n    acquire_production_lock\nfi',
    'if ! mkdir "$LOCK_DIR"',
  );
  assertMutationLockOrder(
    sources.step6,
    "Step 6",
    'if [ "$MODE" = push ]; then\n  acquire_production_lock\nfi',
    'if ! mkdir "$LOCK_DIR"',
  );
  assertMutationLockOrder(
    sources.step7,
    "Step 7",
    'if [ "$MODE" = apply ]; then\n  acquire_production_lock\nfi',
    'if ! mkdir "$OPERATION_LOCK"',
  );
  assertMutationLockOrder(
    sources.step8,
    "Step 8",
    'if [[ "$MODE" == "deploy" ]]; then\n    acquire_production_lock\nfi',
    'if ! mkdir "$LOCK_DIR"',
  );

  assertDurableAttemptBeforeMutation(
    sources.step1,
    "Step 1",
    "install_durable_json",
    'install_durable_json "$attempt_tmp" "$attempt_dir/attempt.json" "$attempt_dir" attempt',
    '--app-id "$APP_ID" entities push)',
  );
  assertDurableAttemptBeforeMutation(
    sources.secret,
    "secret",
    "atomic_stage_file",
    'atomic_stage_file "$attempt_tmp" "$ATTEMPT" attempt',
    'base44_cli secrets set --env-file "$CANDIDATE_FILE"',
  );
  assertDurableAttemptBeforeMutation(
    sources.step3,
    "Step 3",
    "atomic_private_json_file",
    'atomic_private_json_file "$attempt_tmp" "$ATTEMPT" attempt',
    '(cd "$DEPLOY_STAGE" && base44_cli functions deploy deleteAccount)',
  );
  assertDurableAttemptBeforeMutation(
    sources.step4,
    "Step 4",
    "install_durable_json",
    'install_durable_json "$attempt_tmp" "$attempt_dir/attempt.json" "$attempt_dir" attempt',
    '(cd "$FIXED_STAGE/deploy" && base44_cli functions deploy "${FUNCTIONS[@]}")',
  );
  assertDurableAttemptBeforeMutation(
    sources.step6,
    "Step 6",
    "install_durable_json",
    'install_durable_json "$attempt_tmp" "$attempt_dir/attempt.json" "$attempt_dir" attempt',
    '--app-id "$APP_ID" entities push)',
  );
  assertDurableAttemptBeforeMutation(
    sources.step7,
    "Step 7",
    "atomic_stage_file",
    'atomic_stage_file "$WORK/attempt-started.json" "$LAST_ATTEMPT" last-attempt',
    'run_backfill apply "$PLAN_DIGEST"',
  );
  assertDurableAttemptBeforeMutation(
    sources.step8,
    "Step 8",
    "atomic_private_json_file",
    'atomic_private_json_file "$attempt_tmp" "$ATTEMPT" attempt',
    '(cd "$DEPLOY_STAGE" && base44_cli functions deploy deleteAccount)',
  );
});

Deno.test("release secret checks are pinned to the reviewed Base44 app", async () => {
  const releaseSecrets = await Deno.readTextFile(releaseSecretsURL);
  const pseudonymSecret = await Deno.readTextFile(pseudonymSecretURL);

  for (const source of [releaseSecrets, pseudonymSecret]) {
    assertStringIncludes(source, "EXPECTED_APP_ID=69a0e57fa939f578082f8091");
    assertStringIncludes(source, '--app-id "$APP_ID"');
    assertStringIncludes(source, "BASE44_APP_ID targets $BASE44_APP_ID");
  }
  assertStringIncludes(
    pseudonymSecret,
    "SECURITY_CUTOVER_STEP_2_PSEUDONYM_SECRET",
  );
  assertEquals(pseudonymSecret.includes("base44 deploy"), false);
});
