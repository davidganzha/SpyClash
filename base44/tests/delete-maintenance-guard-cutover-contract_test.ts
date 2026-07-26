import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

const guardDeployURL = new URL(
  "../../scripts/deploy-base44-delete-maintenance-guard.sh",
  import.meta.url,
);

function assertBefore(source: string, earlier: string, later: string) {
  const earlierIndex = source.indexOf(earlier);
  const laterIndex = source.indexOf(later);
  assert(earlierIndex >= 0, `missing guard boundary: ${earlier}`);
  assert(laterIndex >= 0, `missing guard boundary: ${later}`);
  assert(earlierIndex < laterIndex, `${earlier} must occur before ${later}`);
}

async function writeFixtureFile(path: string, content: string, mode?: number) {
  await Deno.mkdir(new URL(".", `file://${path}`).pathname, {
    recursive: true,
  });
  await Deno.writeTextFile(path, content);
  if (mode !== undefined) await Deno.chmod(path, mode);
}

async function assertPrivateTree(root: string) {
  const ownerUID = (await Deno.lstat(root)).uid;
  const visit = async (path: string) => {
    const info = await Deno.lstat(path);
    assertEquals(
      info.isSymlink,
      false,
      `evidence must not be a symlink: ${path}`,
    );
    assertEquals(
      info.uid,
      ownerUID,
      `evidence must be owned by the test user: ${path}`,
    );
    const expectedMode = info.isDirectory ? 0o700 : 0o600;
    assertEquals(
      (info.mode ?? 0) & 0o777,
      expectedMode,
      `unexpected evidence mode: ${path}`,
    );
    if (!info.isDirectory) return;
    for await (const entry of Deno.readDir(path)) {
      await visit(`${path}/${entry.name}`);
    }
  };
  await visit(root);
}

Deno.test("deleteAccount guard cutover is exact, digest-bound, and postflight-verified", async () => {
  const source = await Deno.readTextFile(guardDeployURL);
  const arrayMatch = source.match(
    /EXPECTED_REMOTE_FUNCTIONS=\(\n([\s\S]*?)\n\)/,
  );
  assert(arrayMatch, "missing fixed remote function inventory");
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
    "deleteAccount",
    "gameRoomAction",
    "generateWordPack",
    "googleAuthCallback",
    "mobileAuthCallback",
    "pushNotificationAction",
    "stripe-entitlement-webhook",
    "wordPackAction",
  ]);

  const deployBoundary = "base44_cli functions deploy deleteAccount";
  assertStringIncludes(source, 'EXPECTED_APP_ID="69a0e57fa939f578082f8091"');
  assertStringIncludes(
    source,
    'STAGE="$CUTOVER_DIR/delete-maintenance-guard"',
  );
  assertStringIncludes(source, '--app-id "$APP_ID"');
  assertStringIncludes(source, "Change needed: $change_needed");
  assertStringIncludes(source, "remote_delete_account_semantic_digest");
  assertStringIncludes(source, "desired_delete_account_semantic_digest");
  assertStringIncludes(source, "plan_digest");
  assertStringIncludes(
    source,
    "SECURITY_CUTOVER_STEP_3_DELETE_ACCOUNT_GUARD",
  );
  assertBefore(source, "BASE44_CONFIRM_ACTION:-}", deployBoundary);
  assertBefore(source, "BASE44_CONFIRM_APP_ID:-}", deployBoundary);
  assertBefore(
    source,
    "BASE44_CONFIRM_DELETE_GUARD_PLAN_DIGEST:-}",
    deployBoundary,
  );
  assertBefore(
    source,
    'pull_remote_snapshot "$REMOTE_JIT" remote-jit',
    deployBoundary,
  );
  assertBefore(source, deployBoundary, 'pull_remote_snapshot "$REMOTE_AFTER"');
  assertStringIncludes(
    source,
    '(set -e; pull_remote_snapshot "$REMOTE_AFTER" remote-after "$after_manifest")',
  );
  assertStringIncludes(source, "postflight.json");
  assertStringIncludes(source, "unchanged_non_guard_count");
  assertStringIncludes(source, "semantic_digest");
  assertEquals(source.includes("functions deploy --force"), false);
  assertEquals(source.includes("base44 deploy"), false);
  assertEquals(source.includes("functions deploy\n"), false);
});

Deno.test("deleteAccount guard preserves verified and ambiguous stages before refresh", async () => {
  const source = await Deno.readTextFile(guardDeployURL);
  const deployBoundary = "base44_cli functions deploy deleteAccount";
  const main = source.slice(source.indexOf("base44_cli whoami"));

  assertStringIncludes(
    source,
    'EVIDENCE_DIR="$CUTOVER_DIR/evidence/delete-maintenance-guard"',
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
  assertBefore(source, "umask 077", 'WORK="$(mktemp');
  assertStringIncludes(source, "secure_private_directory()");
  assertStringIncludes(source, "secure_private_tree()");
  assertStringIncludes(
    source,
    'secure_private_directory "$CUTOVER_DIR" "Base44 cutover"',
  );
  assertStringIncludes(
    source,
    'secure_private_tree "$snapshot_dir" "deleteAccount guard evidence snapshot"',
  );
  assertStringIncludes(source, '&& -O "$directory"');
  assertStringIncludes(source, 'chmod 700 "$directory"');
  assertStringIncludes(source, 'chmod "$expected_mode" "$entry"');

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
  const postflightIndex = source.indexOf('> "$POSTFLIGHT"');
  assertStringIncludes(
    source.slice(postflightIndex),
    'secure_private_tree "$STAGE" "deleteAccount guard stage"',
  );
});

Deno.test("deleteAccount guard fails closed when postflight reports a 17th function", async () => {
  const permissions = await Promise.all([
    Deno.permissions.query({ name: "read" }),
    Deno.permissions.query({ name: "write" }),
    Deno.permissions.query({ name: "run" }),
  ]);
  if (permissions.some(({ state }) => state !== "granted")) return;

  const expectedFunctions = [
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
  const appID = "69a0e57fa939f578082f8091";
  const fixture = await Deno.makeTempDir({
    prefix: "delete-guard-postflight-",
  });
  try {
    const script =
      `${fixture}/scripts/deploy-base44-delete-maintenance-guard.sh`;
    const mockBin = `${fixture}/mock-bin`;
    const mockState = `${fixture}/mock-state`;
    await Deno.mkdir(`${fixture}/base44`, { recursive: true });
    await Deno.mkdir(`${fixture}/scripts/base44-maintenance/deleteAccount`, {
      recursive: true,
    });
    await Deno.mkdir(mockBin, { recursive: true });
    await Deno.mkdir(mockState, { recursive: true });
    await Deno.copyFile(decodeURIComponent(guardDeployURL.pathname), script);
    await Deno.chmod(script, 0o700);
    await writeFixtureFile(
      `${fixture}/base44/.app.jsonc`,
      `{\n  "id": "${appID}"\n}\n`,
    );
    await writeFixtureFile(`${fixture}/base44/config.jsonc`, "{}\n");
    await writeFixtureFile(
      `${fixture}/scripts/base44-maintenance/deleteAccount/function.jsonc`,
      '{"name":"deleteAccount","entry":"main.ts"}\n',
    );
    await writeFixtureFile(
      `${fixture}/scripts/base44-maintenance/deleteAccount/main.ts`,
      'export default "desired-delete-account";\n',
    );
    await writeFixtureFile(
      `${mockBin}/npx`,
      `#!/bin/sh
set -eu
command_line=" $* "
case "$command_line" in
  *" whoami "*)
    printf '%s\n' 'mock@example.com'
    ;;
  *" functions list "*)
    if [ -f "$MOCK_BASE44_STATE/deployed" ]; then
      printf '%s\n' '17 functions on remote'
    else
      printf '%s\n' '16 functions on remote'
    fi
    for name in $MOCK_REMOTE_FUNCTIONS; do
      printf '  %s\n' "$name"
    done
    if [ -f "$MOCK_BASE44_STATE/deployed" ]; then
      printf '  %s\n' 'unexpectedSeventeenthFunction'
    fi
    ;;
  *" functions pull "*)
    for name in $MOCK_REMOTE_FUNCTIONS; do
      mkdir -p "base44/functions/$name"
      printf '{"name":"%s","entry":"main.ts"}\n' "$name" > "base44/functions/$name/function.jsonc"
      printf 'export default "%s-remote";\n' "$name" > "base44/functions/$name/main.ts"
    done
    ;;
  *" functions deploy deleteAccount "*)
    : > "$MOCK_BASE44_STATE/deployed"
    ;;
  *)
    printf 'unexpected mock npx call: %s\n' "$*" >&2
    exit 90
    ;;
esac
`,
      0o700,
    );

    const baseEnvironment = {
      PATH: `${mockBin}:/usr/bin:/bin:/usr/sbin:/sbin`,
      TMPDIR: fixture,
      MOCK_BASE44_STATE: mockState,
      MOCK_REMOTE_FUNCTIONS: expectedFunctions.join(" "),
    };
    const prepare = await new Deno.Command(script, {
      clearEnv: true,
      env: baseEnvironment,
      stdout: "piped",
      stderr: "piped",
    }).output();
    assertEquals(
      prepare.code,
      0,
      new TextDecoder().decode(prepare.stderr),
    );
    const manifestPath =
      `${fixture}/.base44-cutover/delete-maintenance-guard/manifest.json`;
    const manifest = JSON.parse(await Deno.readTextFile(manifestPath));

    const deploy = await new Deno.Command(script, {
      args: ["--deploy"],
      clearEnv: true,
      env: {
        ...baseEnvironment,
        BASE44_CONFIRM_ACTION: "SECURITY_CUTOVER_STEP_3_DELETE_ACCOUNT_GUARD",
        BASE44_CONFIRM_APP_ID: appID,
        BASE44_CONFIRM_DELETE_GUARD_PLAN_DIGEST: manifest.plan_digest,
      },
      stdout: "piped",
      stderr: "piped",
    }).output();
    assertEquals(deploy.code, 70, new TextDecoder().decode(deploy.stderr));
    const postflightPath =
      `${fixture}/.base44-cutover/delete-maintenance-guard/postflight.json`;
    const postflight = JSON.parse(await Deno.readTextFile(postflightPath));
    assertEquals(postflight.deploy_status, 0);
    assertEquals(postflight.after_pull_status, 65);
    assertEquals(postflight.matches, false);
    await assertPrivateTree(
      `${fixture}/.base44-cutover/delete-maintenance-guard`,
    );

    const preserve = await new Deno.Command(script, {
      clearEnv: true,
      env: baseEnvironment,
      stdout: "piped",
      stderr: "piped",
    }).output();
    assertEquals(preserve.code, 65);
    const evidenceRoot =
      `${fixture}/.base44-cutover/evidence/delete-maintenance-guard`;
    await assertPrivateTree(evidenceRoot);
    const snapshots = [];
    for await (const entry of Deno.readDir(`${evidenceRoot}/stage-snapshots`)) {
      if (entry.isDirectory) snapshots.push(entry.name);
    }
    assertEquals(snapshots.length, 1);
    await Deno.lstat(
      `${evidenceRoot}/stage-snapshots/${snapshots[0]}/postflight.json`,
    );
  } finally {
    await Deno.remove(fixture, { recursive: true });
  }
});
