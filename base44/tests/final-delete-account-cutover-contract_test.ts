import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

const finalDeleteURL = new URL(
  "../../scripts/deploy-base44-final-delete-account.sh",
  import.meta.url,
);

function assertBefore(source: string, earlier: string, later: string) {
  const earlierIndex = source.indexOf(earlier);
  const laterIndex = source.indexOf(later);
  assert(earlierIndex >= 0, `missing prerequisite: ${earlier}`);
  assert(laterIndex >= 0, `missing mutation boundary: ${later}`);
  assert(earlierIndex < laterIndex, `${earlier} must occur before ${later}`);
}

const expectedRemoteFunctions = [
  "advanceRound",
  "app-store-entitlement",
  "appleAuthBroker",
  "appleAuthCallback",
  "autoRegisterUser",
  "checkSubscription",
  "communityAction",
  "createCheckout",
  "deleteAccount",
  "gameRoomAction",
  "generateWordPack",
  "googleAuthCallback",
  "mobileAuthCallback",
  "pushNotificationAction",
  "stripe-entitlement-webhook",
  "wordPackAction",
];

async function sha256(content: string): Promise<string> {
  const bytes = new TextEncoder().encode(content);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function writeFixtureFile(path: string, content: string, mode = 0o600) {
  await Deno.mkdir(path.slice(0, path.lastIndexOf("/")), { recursive: true });
  await Deno.writeTextFile(path, content);
  await Deno.chmod(path, mode);
}

type Step8Fixture = {
  root: string;
  script: string;
  reviewedSource: string;
  lastAttempt: string;
  calls: string;
  env: Record<string, string>;
};

async function createStep8EvidenceFixture(): Promise<Step8Fixture> {
  const root = await Deno.makeTempDir({ prefix: "spyclash-step8-evidence-" });
  const appID = "69a0e57fa939f578082f8091";
  const scripts = `${root}/scripts`;
  const fakeBin = `${root}/fake-bin`;
  const stage = `${root}/.base44-cutover/sensitive-owner-backfill`;
  const reviewedRoot = `${stage}/reviewed-inputs`;
  const calls = `${root}/npx-calls.log`;
  const sourceContent = "// immutable reviewed owner-backfill fixture\n";
  const roomContent =
    'import "./billing-identity-lifecycle.ts";\nexport const room = true;\n';
  const billingContent = "export const billing = true;\n";
  const sourceDigest = await sha256(sourceContent);
  const roomDigest = await sha256(roomContent);
  const billingDigest = await sha256(billingContent);
  const lifecycleDigest = await sha256(`${roomDigest}\n${billingDigest}\n`);
  const inputSet = await sha256(
    `backfill-sensitive-entity-owners.ts=${sourceDigest}\n` +
      `gameRoomAction/room-write-lifecycle.ts=${roomDigest}\n` +
      `gameRoomAction/billing-identity-lifecycle.ts=${billingDigest}\n`,
  );
  const reviewedStage = `${reviewedRoot}/${inputSet}`;
  const reviewedSource = `${reviewedStage}/backfill-sensitive-entity-owners.ts`;
  const lastAttempt = `${stage}/last-attempt.json`;
  const digest = (character: string) => character.repeat(64);
  const attemptID = digest("a");
  const planDigest = digest("b");
  const postflightPlanDigest = digest("2");
  const snapshotDigest = digest("c");
  const postflightSnapshotDigest = digest("3");
  const remoteDigest = digest("d");
  const operator = { identity_sha256: digest("e"), role: "admin" };
  const reviewedInputs = {
    protocol: "spyclash-sensitive-owner-backfill-inputs-v1",
    input_set_sha256: inputSet,
    source_sha256: sourceDigest,
    lifecycle_source_sha256: lifecycleDigest,
    room_write_lifecycle_sha256: roomDigest,
    billing_identity_lifecycle_sha256: billingDigest,
  };
  const inputs = {
    protocol: "spyclash-sensitive-owner-backfill-inputs-v1",
    app_id: appID,
    input_set_sha256: inputSet,
    source_sha256: sourceDigest,
    lifecycle_source_sha256: lifecycleDigest,
    files: {
      "backfill-sensitive-entity-owners.ts": sourceDigest,
      "gameRoomAction/room-write-lifecycle.ts": roomDigest,
      "gameRoomAction/billing-identity-lifecycle.ts": billingDigest,
    },
  };
  const finalSchema = {
    verified: true,
    app_id: appID,
    live_count: 20,
    canonical_count: 20,
    adds: 0,
    deletes: 0,
    changed_entities_count: 0,
    live_admin_write_boundary: true,
    remote_digest: remoteDigest,
  };
  const postflightReport = {
    plan_digest: postflightPlanDigest,
    operator,
    source_sha256: sourceDigest,
    lifecycle_source_sha256: lifecycleDigest,
    final_schema_remote_digest: remoteDigest,
    unresolved_total: 0,
    mismatch_total: 0,
    room_updates: 0,
    word_pack_updates: 0,
  };
  const completion = {
    protocol: "spyclash-sensitive-owner-backfill-wrapper-v2",
    app_id: appID,
    mode: "apply",
    stable_snapshots: true,
    success: true,
    completion_verified: true,
    completion_verified_at: "2026-07-26T00:00:00Z",
    input_set_sha256: inputSet,
    source_sha256: sourceDigest,
    lifecycle_source_sha256: lifecycleDigest,
    reviewed_inputs: reviewedInputs,
    attempt: {
      protocol: "spyclash-sensitive-owner-backfill-attempt-v1",
      attempt_id: attemptID,
      started_at: "2026-07-26T00:00:00Z",
      state: "completed-postflight-verified",
      postflight_required: false,
    },
    final_schema: finalSchema,
    preflight_snapshot_sha256: snapshotDigest,
    requested_plan_digest: planDigest,
    plan_digest: planDigest,
    preflight: {
      operator,
      plan_digest: planDigest,
      room_updates: 13,
      word_pack_updates: 0,
    },
    apply: {
      status: 0,
      report_status: 0,
      report: {
        phase: "completed",
        plan_digest: planDigest,
        applied_room_updates: 13,
        applied_word_pack_updates: 0,
      },
    },
    postflight: {
      status: 0,
      snapshot_sha256: postflightSnapshotDigest,
      report: postflightReport,
    },
  };
  const verifiedAttempt = structuredClone(completion) as Record<
    string,
    unknown
  >;
  delete verifiedAttempt.completion_verified_at;
  const fresh = {
    protocol: "spyclash-sensitive-owner-backfill-wrapper-v2",
    app_id: appID,
    mode: "dry-run",
    stable_snapshots: true,
    success: false,
    completion_verified: true,
    input_set_sha256: inputSet,
    source_sha256: sourceDigest,
    lifecycle_source_sha256: lifecycleDigest,
    reviewed_inputs: reviewedInputs,
    final_schema: finalSchema,
    plan_digest: postflightPlanDigest,
    preflight: { operator },
    postflight: {
      status: 0,
      snapshot_sha256: postflightSnapshotDigest,
      report: postflightReport,
    },
  };

  const script = `${scripts}/deploy-base44-final-delete-account.sh`;
  await Deno.mkdir(scripts, { recursive: true });
  await Deno.mkdir(fakeBin, { recursive: true });
  await Deno.copyFile(decodeURIComponent(finalDeleteURL.pathname), script);
  await Deno.chmod(script, 0o700);
  await writeFixtureFile(
    `${root}/base44/.app.jsonc`,
    `{\n  "id": "${appID}"\n}\n`,
  );
  await writeFixtureFile(`${root}/base44/config.jsonc`, "{}\n");
  for (const name of expectedRemoteFunctions) {
    await writeFixtureFile(
      `${root}/base44/functions/${name}/function.jsonc`,
      JSON.stringify({ name, entry: "main.ts" }) + "\n",
    );
    await writeFixtureFile(
      `${root}/base44/functions/${name}/main.ts`,
      `export default "${name}";\n`,
    );
  }
  // Step 8 validates the reviewed maintenance guard before it attempts any
  // remote read. Mirror that immutable local prerequisite in this isolated
  // fixture so the test reaches its intended mocked `functions list` failure.
  await writeFixtureFile(
    `${scripts}/base44-maintenance/deleteAccount/function.jsonc`,
    JSON.stringify({ name: "deleteAccount", entry: "main.ts" }) + "\n",
  );
  await writeFixtureFile(
    `${scripts}/base44-maintenance/deleteAccount/main.ts`,
    'export default "deleteAccount-maintenance-guard";\n',
  );
  await writeFixtureFile(
    `${scripts}/backfill-sensitive-entity-owners.ts`,
    sourceContent,
  );
  await writeFixtureFile(
    `${root}/base44/functions/gameRoomAction/room-write-lifecycle.ts`,
    roomContent,
  );
  await writeFixtureFile(
    `${root}/base44/functions/gameRoomAction/billing-identity-lifecycle.ts`,
    billingContent,
  );
  await writeFixtureFile(
    `${scripts}/push-base44-final-schema.sh`,
    `#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/.base44-cutover/final-schema-check"
printf '%s\n' '{"app_id":"${appID}","live_count":20,"canonical_count":20,"adds":0,"deletes":0,"changed_entities":[],"live_admin_write_boundary":true,"remote_digest":"${remoteDigest}","canonical_digest":"${
      digest("f")
    }","plan_digest":"${
      digest("1")
    }"}' > "$ROOT/.base44-cutover/final-schema-check/manifest.json"
`,
    0o700,
  );
  await writeFixtureFile(
    `${scripts}/run-base44-sensitive-owner-backfill.sh`,
    "#!/bin/sh\nset -eu\nexit 0\n",
    0o700,
  );
  await writeFixtureFile(
    `${fakeBin}/npx`,
    `#!/bin/sh
set -eu
printf '%s\n' "$*" >> "$MOCK_NPX_CALLS"
case " $* " in
  *" whoami "*) printf '%s\n' 'mock@example.com' ;;
  *) exit 90 ;;
esac
`,
    0o700,
  );
  const inputsJSON = JSON.stringify(inputs, null, 2) + "\n";
  await writeFixtureFile(`${stage}/reviewed-inputs-current.json`, inputsJSON);
  await writeFixtureFile(`${reviewedStage}/inputs.json`, inputsJSON, 0o400);
  await writeFixtureFile(reviewedSource, sourceContent, 0o400);
  await writeFixtureFile(
    `${reviewedStage}/gameRoomAction/room-write-lifecycle.ts`,
    roomContent,
    0o400,
  );
  await writeFixtureFile(
    `${reviewedStage}/gameRoomAction/billing-identity-lifecycle.ts`,
    billingContent,
    0o400,
  );
  await Deno.chmod(`${reviewedStage}/gameRoomAction`, 0o500);
  await Deno.chmod(reviewedStage, 0o500);
  await writeFixtureFile(
    `${stage}/completion.json`,
    JSON.stringify(completion, null, 2) + "\n",
  );
  await writeFixtureFile(
    lastAttempt,
    JSON.stringify(verifiedAttempt, null, 2) + "\n",
  );
  await writeFixtureFile(
    `${stage}/manifest.json`,
    JSON.stringify(fresh, null, 2) + "\n",
  );

  return {
    root,
    script,
    reviewedSource,
    lastAttempt,
    calls,
    env: {
      PATH: `${fakeBin}:/usr/bin:/bin:/usr/sbin:/sbin`,
      TMPDIR: root,
      MOCK_NPX_CALLS: calls,
    },
  };
}

async function removeStep8Fixture(root: string) {
  await new Deno.Command("chmod", {
    args: ["-R", "u+w", root],
    stdout: "null",
    stderr: "null",
  }).output();
  await Deno.remove(root, { recursive: true });
}

async function runInvalidStep8Fixture(fixture: Step8Fixture) {
  const output = await new Deno.Command(fixture.script, {
    clearEnv: true,
    env: fixture.env,
    stdout: "piped",
    stderr: "piped",
  }).output();
  assertEquals(output.code, 65, new TextDecoder().decode(output.stderr));
  const calls = await Deno.readTextFile(fixture.calls);
  assertEquals(calls.includes("functions deploy deleteAccount"), false);
  return new TextDecoder().decode(output.stderr);
}

async function fixturePermissionsGranted() {
  const permissions = await Promise.all([
    Deno.permissions.query({ name: "read" }),
    Deno.permissions.query({ name: "write" }),
    Deno.permissions.query({ name: "run" }),
  ]);
  return permissions.every(({ state }) => state === "granted");
}

Deno.test("final deleteAccount accepts a verified mutating Step 7 with a distinct zero-update postflight plan", async () => {
  if (!(await fixturePermissionsGranted())) return;
  const fixture = await createStep8EvidenceFixture();
  try {
    const output = await new Deno.Command(fixture.script, {
      clearEnv: true,
      env: fixture.env,
      stdout: "piped",
      stderr: "piped",
    }).output();
    const stderr = new TextDecoder().decode(output.stderr);
    assertEquals(output.code, 70, stderr);
    assertEquals(
      stderr.includes(
        "completion/attempt evidence is not fully postflight-verified",
      ),
      false,
    );
    const calls = await Deno.readTextFile(fixture.calls);
    assertStringIncludes(calls, "functions list");
    assertEquals(calls.includes("functions deploy deleteAccount"), false);
  } finally {
    await removeStep8Fixture(fixture.root);
  }
});

Deno.test("final deleteAccount deploy is Step-8-only, exact-16 and evidence-bound", async () => {
  const source = await Deno.readTextFile(finalDeleteURL);
  const coordinatedMatch = source.match(
    /COORDINATED_FUNCTIONS=\(\n([\s\S]*?)\n\)/,
  );
  assert(coordinatedMatch, "missing fixed coordinated release array");
  const coordinated = coordinatedMatch[1]
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);

  assertEquals(
    coordinated,
    expectedRemoteFunctions.filter((name) => name !== "deleteAccount"),
  );
  assertStringIncludes(
    source,
    'EXPECTED_REMOTE_FUNCTIONS=("${COORDINATED_FUNCTIONS[@]}" deleteAccount)',
  );

  const deployBoundary = "base44_cli functions deploy deleteAccount";
  assertEquals(
    source.match(/base44_cli functions deploy/g)?.length,
    1,
    "only the explicit deleteAccount mutation is allowed",
  );
  assertStringIncludes(source, 'EXPECTED_APP_ID="69a0e57fa939f578082f8091"');
  assertStringIncludes(source, 'STAGE="$CUTOVER_DIR/final-delete-account"');
  assertStringIncludes(
    source,
    'SCHEMA_MANIFEST="$CUTOVER_DIR/final-schema-check/manifest.json"',
  );
  assertStringIncludes(
    source,
    '"$ROOT/scripts/push-base44-final-schema.sh" --check',
  );
  assertStringIncludes(source, '--app-id "$APP_ID"');
  assertStringIncludes(source, "reviewed Step 3 maintenance guard");
  assertStringIncludes(source, "local-coordinated-functions.json");
  assertStringIncludes(source, "remote-coordinated-functions-before.json");
  assertStringIncludes(source, "semantic_manifest_digest");

  for (
    const evidence of [
      '"$ROOT/scripts/push-base44-final-schema.sh"',
      '"$ROOT/scripts/run-base44-sensitive-owner-backfill.sh"',
      'BACKFILL_STAGE="$CUTOVER_DIR/sensitive-owner-backfill"',
      'BACKFILL_COMPLETION="$BACKFILL_STAGE/completion.json"',
      'BACKFILL_LAST_ATTEMPT="$BACKFILL_STAGE/last-attempt.json"',
      'BACKFILL_REVIEWED_POINTER="$BACKFILL_STAGE/reviewed-inputs-current.json"',
      'BACKFILL_REVIEWED_ROOT="$BACKFILL_STAGE/reviewed-inputs"',
      'BACKFILL_MANIFEST="$BACKFILL_STAGE/manifest.json"',
      '.mode == "apply"',
      '.mode == "dry-run"',
      '.changed_entities | type == "array" and length == 0',
      ".live_admin_write_boundary == true",
      "completion_plan_digest",
      "completion_postflight_snapshot_sha256",
      "fresh_plan_digest",
      "fresh_postflight_snapshot_sha256",
      "source_sha256",
      "lifecycle_source_sha256",
      "input_set_sha256",
      "room_write_lifecycle_sha256",
      "billing_identity_lifecycle_sha256",
      "reviewed_inputs_manifest_sha256",
      "reviewed_inputs_pointer_sha256",
      'state:"completed-postflight-verified"',
      "postflight_required:false",
      'BACKFILL_ROOM_LIFECYCLE="$ROOT/base44/functions/gameRoomAction/room-write-lifecycle.ts"',
      'BACKFILL_BILLING_LIFECYCLE="$ROOT/base44/functions/gameRoomAction/billing-identity-lifecycle.ts"',
      "remote_inventory_digest",
      "local_final_delete_account_digest",
      "schema_boundary_digest",
      "backfill_boundary_digest",
    ]
  ) {
    assertBefore(source, evidence, deployBoundary);
  }

  assertBefore(
    source,
    'if [[ "${BASE44_CONFIRM_ACTION:-}" != "SECURITY_CUTOVER_STEP_8_FINAL_DELETE_ACCOUNT" ]]',
    deployBoundary,
  );
  assertBefore(
    source,
    'if [[ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]]',
    deployBoundary,
  );
  assertBefore(
    source,
    'if [[ "${BASE44_CONFIRM_FINAL_DELETE_ACCOUNT_PLAN_DIGEST:-}" != "$plan_digest" ]]',
    deployBoundary,
  );
  assertBefore(source, "REMOTE_JIT=", deployBoundary);
  assertBefore(source, "jit_schema=", deployBoundary);
  assertBefore(source, "jit_backfill=", deployBoundary);
  assertBefore(source, deployBoundary, "REMOTE_AFTER=");
  assertBefore(source, deployBoundary, 'pull_remote_snapshot "$REMOTE_AFTER"');
  assertBefore(source, deployBoundary, 'post_schema="$WORK/post-schema.json"');
  assertBefore(
    source,
    deployBoundary,
    'post_backfill="$WORK/post-backfill.json"',
  );
  assertBefore(source, deployBoundary, '> "$POSTFLIGHT"');
  assertStringIncludes(source, "unchanged_coordinated_count");
  assertStringIncludes(source, "expected_remote_function_count");
  assertEquals(source.includes("functions deploy --force"), false);
  assertEquals(source.includes("base44 deploy"), false);
  assertEquals(source.includes("functions deploy\n"), false);
  assertEquals(source.includes("--push"), false);
  assertEquals(source.includes("--apply"), false);
  const refreshBoundary = source.slice(
    source.indexOf("refresh_backfill_boundary()"),
    source.indexOf("base44_cli whoami"),
  );
  assertBefore(
    refreshBoundary,
    '"$ROOT/scripts/run-base44-sensitive-owner-backfill.sh"',
    "acquire_backfill_snapshot_lock",
  );
  assertBefore(
    refreshBoundary,
    "acquire_backfill_snapshot_lock",
    "snapshot_backfill_evidence",
  );
  assertStringIncludes(source, 'mkdir "$BACKFILL_OPERATION_LOCK"');
});

Deno.test("final deleteAccount wrapper rejects unsupported mode and stage override before CLI work", async () => {
  const scriptPath = decodeURIComponent(finalDeleteURL.pathname);
  const permission = await Deno.permissions.query({
    name: "run",
    command: scriptPath,
  });
  if (permission.state !== "granted") return;

  const baseEnvironment = {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
    TMPDIR: "/tmp",
  };
  const unsupported = await new Deno.Command(scriptPath, {
    args: ["--unsupported"],
    clearEnv: true,
    env: baseEnvironment,
    stdout: "piped",
    stderr: "piped",
  }).output();
  assertEquals(unsupported.code, 64);
  assertStringIncludes(new TextDecoder().decode(unsupported.stderr), "Usage:");

  const override = await new Deno.Command(scriptPath, {
    clearEnv: true,
    env: {
      ...baseEnvironment,
      BASE44_FINAL_DELETE_ACCOUNT_STAGE_DIR: "/tmp/not-reviewed",
    },
    stdout: "piped",
    stderr: "piped",
  }).output();
  assertEquals(override.code, 64);
  assertStringIncludes(
    new TextDecoder().decode(override.stderr),
    "stage path is fixed",
  );
});

Deno.test("final deleteAccount preserves verified and ambiguous stages before refresh", async () => {
  const source = await Deno.readTextFile(finalDeleteURL);
  const deployBoundary = "base44_cli functions deploy deleteAccount";
  const main = source.slice(source.indexOf("base44_cli whoami"));

  assertStringIncludes(
    source,
    'EVIDENCE_DIR="$CUTOVER_DIR/evidence/final-delete-account"',
  );
  assertStringIncludes(
    source,
    'STAGE_SNAPSHOTS="$EVIDENCE_DIR/stage-snapshots"',
  );
  assertStringIncludes(source, "preserve_previous_stage_evidence()");
  assertStringIncludes(source, 'for evidence_file in "$ATTEMPT" "$POSTFLIGHT"');
  assertStringIncludes(source, ".deployed_at // .verified_at");
  assertStringIncludes(source, 'mv "$STAGE" "$snapshot_dir"');
  assertStringIncludes(source, "mutation-started-postflight-required");
  assertStringIncludes(
    source,
    'atomic_private_json_file "$attempt_tmp" "$ATTEMPT" attempt',
  );
  assertEquals(source.match(/rm -rf -- "\$STAGE"/g)?.length, 1);
  assertEquals(source.includes('rm -rf -- "$EVIDENCE_DIR"'), false);
  assertEquals(source.includes('rm -rf -- "$STAGE_SNAPSHOTS"'), false);

  const preserveIndex = main.indexOf("preserve_previous_stage_evidence\n");
  const stageCreateIndex = main.indexOf(
    'mkdir -p "$DEPLOY_STAGE/base44/functions"',
  );
  assert(preserveIndex >= 0, "main prepare path must preserve prior evidence");
  assert(stageCreateIndex >= 0, "main prepare path must create a fresh stage");
  assert(
    preserveIndex < stageCreateIndex,
    "prior attempt evidence must move before the fixed stage is refreshed",
  );
  assertBefore(
    source,
    'atomic_private_json_file "$attempt_tmp" "$ATTEMPT" attempt',
    deployBoundary,
  );
  assertBefore(source, deployBoundary, '> "$POSTFLIGHT"');
});

Deno.test("final deleteAccount keeps cutover and evidence private", async () => {
  const source = await Deno.readTextFile(finalDeleteURL);
  assertBefore(source, "umask 077", 'WORK="$(mktemp');
  assertStringIncludes(source, "secure_private_directory()");
  assertStringIncludes(source, "secure_private_tree()");
  assertStringIncludes(
    source,
    'secure_private_directory "$CUTOVER_DIR" "Base44 cutover"',
  );
  assertStringIncludes(
    source,
    'secure_private_tree "$snapshot_dir" "final deleteAccount evidence snapshot"',
  );
  assertStringIncludes(source, '&& -O "$directory"');
  assertStringIncludes(source, 'chmod 700 "$directory"');
  assertStringIncludes(source, 'chmod "$expected_mode" "$entry"');
  const postflightIndex = source.indexOf('> "$POSTFLIGHT"');
  assert(postflightIndex >= 0);
  assertStringIncludes(
    source.slice(postflightIndex),
    'secure_private_tree "$STAGE" "final deleteAccount stage"',
  );
});

Deno.test("final deleteAccount blocks a pending Step 7 last-attempt", async () => {
  if (!(await fixturePermissionsGranted())) return;
  const fixture = await createStep8EvidenceFixture();
  try {
    const attempt = JSON.parse(await Deno.readTextFile(fixture.lastAttempt));
    attempt.attempt.state = "mutation-started-postflight-required";
    attempt.attempt.postflight_required = true;
    attempt.success = false;
    attempt.completion_verified = false;
    await Deno.writeTextFile(
      fixture.lastAttempt,
      JSON.stringify(attempt, null, 2) + "\n",
    );
    const stderr = await runInvalidStep8Fixture(fixture);
    assertStringIncludes(stderr, "completion/attempt evidence");
  } finally {
    await removeStep8Fixture(fixture.root);
  }
});

Deno.test("final deleteAccount blocks a different Step 7 attempt id", async () => {
  if (!(await fixturePermissionsGranted())) return;
  const fixture = await createStep8EvidenceFixture();
  try {
    const attempt = JSON.parse(await Deno.readTextFile(fixture.lastAttempt));
    attempt.attempt.attempt_id = "9".repeat(64);
    await Deno.writeTextFile(
      fixture.lastAttempt,
      JSON.stringify(attempt, null, 2) + "\n",
    );
    const stderr = await runInvalidStep8Fixture(fixture);
    assertStringIncludes(stderr, "pending, ambiguous, or differs");
  } finally {
    await removeStep8Fixture(fixture.root);
  }
});

Deno.test("final deleteAccount blocks tampered Step 7 staged source bytes", async () => {
  if (!(await fixturePermissionsGranted())) return;
  const fixture = await createStep8EvidenceFixture();
  try {
    await Deno.chmod(fixture.reviewedSource, 0o600);
    await Deno.writeTextFile(
      fixture.reviewedSource,
      "// tampered after review\n",
      { append: true },
    );
    await Deno.chmod(fixture.reviewedSource, 0o400);
    const stderr = await runInvalidStep8Fixture(fixture);
    assertStringIncludes(stderr, "do not match the reviewed input_set");
  } finally {
    await removeStep8Fixture(fixture.root);
  }
});
