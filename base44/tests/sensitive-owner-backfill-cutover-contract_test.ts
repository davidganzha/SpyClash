import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

const wrapperURL = new URL(
  "../../scripts/run-base44-sensitive-owner-backfill.sh",
  import.meta.url,
);
const implementationURL = new URL(
  "../../scripts/backfill-sensitive-entity-owners.ts",
  import.meta.url,
);

function assertBefore(source: string, earlier: string, later: string) {
  const earlierIndex = source.indexOf(earlier);
  const laterIndex = source.indexOf(later);
  assert(earlierIndex >= 0, `missing backfill guard: ${earlier}`);
  assert(laterIndex >= 0, `missing backfill boundary: ${later}`);
  assert(earlierIndex < laterIndex, `${earlier} must occur before ${later}`);
}

Deno.test("owner backfill wrapper is fixed-target, digest-bound, and always postflighted", async () => {
  const source = await Deno.readTextFile(wrapperURL);
  const applyBoundary = 'run_backfill apply "$PLAN_DIGEST"';

  assertStringIncludes(source, "EXPECTED_APP_ID=69a0e57fa939f578082f8091");
  assertStringIncludes(
    source,
    "EXPECTED_ACTION=SECURITY_CUTOVER_STEP_7_STABLE_OWNER_BACKFILL",
  );
  assertStringIncludes(
    source,
    'STAGE="$CUTOVER_DIR/sensitive-owner-backfill"',
  );
  assertStringIncludes(source, 'MANIFEST="$STAGE/manifest.json"');
  assertStringIncludes(source, 'COMPLETION="$STAGE/completion.json"');
  assertStringIncludes(source, 'LAST_ATTEMPT="$STAGE/last-attempt.json"');
  assertStringIncludes(
    source,
    'OPERATION_LOCK="$CUTOVER_DIR/sensitive-owner-backfill.operation.lock"',
  );
  assertStringIncludes(source, 'REVIEWED_ROOT="$STAGE/reviewed-inputs"');
  assertStringIncludes(
    source,
    'REVIEWED_POINTER="$STAGE/reviewed-inputs-current.json"',
  );
  assertStringIncludes(source, "spyclash-sensitive-owner-backfill-inputs-v1");
  assertStringIncludes(source, "INPUT_SET_SHA256");
  assertStringIncludes(source, "validate_reviewed_stage");
  assertStringIncludes(source, "verify_reviewed_execution_inputs");
  assertStringIncludes(source, 'EXECUTION_STAGE="$WORK/execution-inputs"');
  assertStringIncludes(source, '< "$EXECUTION_SCRIPT"');
  assertStringIncludes(
    source,
    '"$EXECUTION_STAGE/gameRoomAction/billing-identity-lifecycle.ts"',
  );
  assertStringIncludes(
    source,
    'FINAL_SCHEMA_MANIFEST="$CUTOVER_DIR/final-schema-check/manifest.json"',
  );
  assertStringIncludes(source, '"$FINAL_SCHEMA_SCRIPT" --check');
  assertStringIncludes(source, 'base44 --app-id \\"$APP_ID\\" exec');
  assertStringIncludes(source, "git check-ignore -q");
  assertStringIncludes(source, "run_stable_dry_pair preflight");
  assertStringIncludes(source, "run_stable_dry_pair postflight");
  assertStringIncludes(source, "cmp -s");
  assertStringIncludes(source, "preflight_snapshot_sha256");
  assertStringIncludes(source, "postflight_snapshot_sha256");
  assertStringIncludes(source, "LIFECYCLE_SOURCE_SHA256");
  assertStringIncludes(source, "SPYCLASH_BACKFILL_ROOM_WRITE_LIFECYCLE_URL");
  assertStringIncludes(source, "completion_verified");
  assertStringIncludes(source, ".requested_plan_digest == .plan_digest");
  assertStringIncludes(source, "completion_verified_at");
  assertStringIncludes(
    source,
    'state:"mutation-started-postflight-required"',
  );
  assertStringIncludes(source, "postflight_required:true");
  assertStringIncludes(
    source,
    'atomic_stage_file "$WORK/attempt-started.json" "$LAST_ATTEMPT" last-attempt',
  );
  assertStringIncludes(source, '"completed-postflight-verified"');
  assertBefore(
    source,
    ".success == true",
    'atomic_stage_file "$WORK/completion.json" "$COMPLETION" completion',
  );
  assertBefore(
    source,
    "run_stable_dry_pair postflight",
    'atomic_stage_file "$MANIFEST" "$LAST_ATTEMPT" last-attempt',
  );
  assertBefore(
    source,
    'atomic_stage_file "$MANIFEST" "$LAST_ATTEMPT" last-attempt',
    'atomic_stage_file "$WORK/completion.json" "$COMPLETION" completion',
  );
  assertStringIncludes(source, ".live_count == 20");
  assertStringIncludes(source, "(.changed_entities | length) == 0");
  assertBefore(source, '"$FINAL_SCHEMA_SCRIPT"', applyBoundary);
  assertBefore(source, "BASE44_CONFIRM_ACTION:-}", applyBoundary);
  assertBefore(source, "BASE44_CONFIRM_APP_ID:-}", applyBoundary);
  assertBefore(
    source,
    "BASE44_CONFIRM_SENSITIVE_OWNER_PLAN_DIGEST",
    applyBoundary,
  );
  assertBefore(source, "refresh_verified_final_schema", applyBoundary);
  assertBefore(source, 'cmp -s "$FINAL_SCHEMA_SUMMARY"', applyBoundary);
  assertBefore(source, "verify_reviewed_execution_inputs", applyBoundary);
  assertBefore(
    source,
    'atomic_stage_file "$WORK/attempt-started.json" "$LAST_ATTEMPT" last-attempt',
    applyBoundary,
  );
  assertBefore(
    source,
    'atomic_stage_file "$WORK/attempt-started.json" "$LAST_ATTEMPT" last-attempt',
    "sync\n\n# The apply status",
  );
  assertBefore(source, "sync\n\n# The apply status", applyBoundary);
  assertBefore(source, "run_stable_dry_pair preflight", applyBoundary);
  assertBefore(source, "APPLY_STATUS=$?", "run_stable_dry_pair postflight");
  assertBefore(source, applyBoundary, "run_stable_dry_pair postflight");
  assertEquals(source.includes("base44 deploy"), false);
  assertEquals(source.includes("entities push"), false);
  assertEquals(source.includes("functions deploy"), false);
  assertEquals(source.includes("site deploy"), false);
  assertEquals(source.includes("--force"), false);
  assertEquals(
    source.includes(
      'ROOM_WRITE_LIFECYCLE_URL="file://$ROOM_WRITE_LIFECYCLE_SCRIPT"',
    ),
    false,
  );
  assertEquals(source.includes('< "$SCRIPT"'), false);
});

Deno.test("owner backfill plan binds lifecycle-serialized authority projections before writes", async () => {
  const source = await Deno.readTextFile(implementationURL);
  const firstWrite = "base44.entities.GameRoom.update(plan.id";

  assertStringIncludes(
    source,
    'const EXPECTED_APP_ID = "69a0e57fa939f578082f8091"',
  );
  assertStringIncludes(
    source,
    'const EXPECTED_ACTION = "SECURITY_CUTOVER_STEP_7_STABLE_OWNER_BACKFILL"',
  );
  assertStringIncludes(source, "MAX_PAGES_PER_ENTITY = 1_000");
  assertStringIncludes(source, "pagination returned duplicate record id");
  assertStringIncludes(
    source,
    "exceeded the ${MAX_PAGES_PER_ENTITY}-page safety ceiling",
  );
  assertStringIncludes(source, "crypto.subtle.digest");
  assertStringIncludes(source, "source_sha256: sourceSHA256");
  assertStringIncludes(
    source,
    "lifecycle_source_sha256: lifecycleSourceSHA256",
  );
  assertStringIncludes(
    source,
    "final_schema_remote_digest: finalSchemaRemoteDigest",
  );
  assertStringIncludes(source, "identity_sha256: operatorIdentitySHA256");
  assertStringIncludes(source, 'lifecycle_entity: "BillingIdentityLifecycle"');
  assertStringIncludes(
    source,
    'game_room_fields: ["participant_user_ids", "players.user_id"]',
  );
  assertStringIncludes(source, "updated_date: updatedDate");
  assertStringIncludes(source, "participant_user_ids: participantUserIDs");
  assertStringIncludes(source, "player_user_ids_by_index");
  assertStringIncludes(source, "players_replacement_sha256");
  assertStringIncludes(source, "set: { owner_user_id: ownerUserID }");
  assertStringIncludes(source, "plan_digest: planDigest");
  assertBefore(
    source,
    'Deno.env.get("SPYCLASH_BACKFILL_EXPECTED_PLAN_DIGEST")',
    firstWrite,
  );
  assertBefore(source, "expectedPlanDigest !== planDigest", firstWrite);
  assertBefore(source, "unresolvedTotal > 0 || mismatchTotal > 0", firstWrite);
  assertBefore(
    source,
    "clean(latest.updated_date) !== plan.updated_date",
    firstWrite,
  );
  assertBefore(source, "await assertRoomWriteLeases(leaseContext)", firstWrite);
  assertStringIncludes(source, "await withRoomWriteLeases({");
  assertStringIncludes(source, "base44.entities.BillingIdentityLifecycle");
  assertStringIncludes(source, "base44.entities.WordPack.update(plan.id");
  assertEquals(source.includes("entities.GameRoom.updateMany("), false);
  assertEquals(source.includes("entities.WordPack.updateMany("), false);
  assertEquals(source.includes("console.log(email"), false);
  assertEquals(source.includes("owner_email:"), false);
  assertEquals(source.includes("host_email:"), false);
});

type WrapperFixture = {
  root: string;
  wrapper: string;
  source: string;
  capture: string;
  env: Record<string, string>;
};

async function createWrapperFixture(): Promise<WrapperFixture> {
  const root = await Deno.makeTempDir({ prefix: "spyclash-owner-stage-test-" });
  const scripts = `${root}/scripts`;
  const lifecycle = `${root}/base44/functions/gameRoomAction`;
  const fakeBin = `${root}/fake-bin`;
  await Deno.mkdir(scripts, { recursive: true });
  await Deno.mkdir(lifecycle, { recursive: true });
  await Deno.mkdir(fakeBin, { recursive: true });

  const wrapper = `${scripts}/run-base44-sensitive-owner-backfill.sh`;
  const source = `${scripts}/backfill-sensitive-entity-owners.ts`;
  const finalSchema = `${scripts}/push-base44-final-schema.sh`;
  const capture = `${root}/execution-urls.log`;
  await Deno.writeTextFile(wrapper, await Deno.readTextFile(wrapperURL));
  await Deno.chmod(wrapper, 0o700);
  await Deno.writeTextFile(
    source,
    "// fixture backfill source; fake npx validates these exact stdin bytes\n",
  );
  await Deno.writeTextFile(
    `${lifecycle}/room-write-lifecycle.ts`,
    'import "./billing-identity-lifecycle.ts";\nexport const marker = "room";\n',
  );
  await Deno.writeTextFile(
    `${lifecycle}/billing-identity-lifecycle.ts`,
    'export const marker = "billing";\n',
  );
  await Deno.writeTextFile(
    finalSchema,
    `#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$ROOT/.base44-cutover/final-schema-check"
printf '%s\n' '{"app_id":"69a0e57fa939f578082f8091","live_count":20,"canonical_count":20,"adds":0,"deletes":0,"changed_entities":[],"live_admin_write_boundary":true,"remote_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","canonical_digest":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","plan_digest":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}' > "$ROOT/.base44-cutover/final-schema-check/manifest.json"
`,
  );
  await Deno.chmod(finalSchema, 0o700);

  await Deno.writeTextFile(`${fakeBin}/git`, "#!/bin/sh\nexit 0\n");
  await Deno.chmod(`${fakeBin}/git`, 0o700);
  await Deno.writeTextFile(
    `${fakeBin}/npx`,
    `#!/bin/sh
set -eu
cat > "$FAKE_STDIN_CAPTURE"
actual_source=$(shasum -a 256 "$FAKE_STDIN_CAPTURE" | sed 's/[[:space:]].*$//')
[ "$actual_source" = "$SPYCLASH_BACKFILL_SOURCE_SHA256" ] || exit 91
case "$SPYCLASH_BACKFILL_ROOM_WRITE_LIFECYCLE_URL" in
  file:///tmp/spyclash-owner-backfill.*/execution-inputs/gameRoomAction/room-write-lifecycle.ts) ;;
  *) exit 92 ;;
esac
room_path=\${SPYCLASH_BACKFILL_ROOM_WRITE_LIFECYCLE_URL#file://}
[ -f "$room_path" ] && [ ! -L "$room_path" ] || exit 93
billing_path=\${room_path%/room-write-lifecycle.ts}/billing-identity-lifecycle.ts
[ -f "$billing_path" ] && [ ! -L "$billing_path" ] || exit 94
printf '%s\n' "$SPYCLASH_BACKFILL_ROOM_WRITE_LIFECYCLE_URL" >> "$FAKE_CAPTURE_PATH"
printf '%s\n' 'SPYCLASH_SENSITIVE_OWNER_BACKFILL_REPORT={"app_id":"69a0e57fa939f578082f8091","source_sha256":"'"$SPYCLASH_BACKFILL_SOURCE_SHA256"'","lifecycle_source_sha256":"'"$SPYCLASH_BACKFILL_LIFECYCLE_SOURCE_SHA256"'","final_schema_verified":true,"final_schema_remote_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","plan_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","operator":{"identity_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","role":"admin"},"room_updates":0,"word_pack_updates":0,"unresolved_total":0,"mismatch_total":0,"cas_plan":{"game_rooms":[],"word_packs":[]}}'
`,
  );
  await Deno.chmod(`${fakeBin}/npx`, 0o700);

  return {
    root,
    wrapper,
    source,
    capture,
    env: {
      PATH: `${fakeBin}:${Deno.env.get("PATH") ?? "/usr/bin:/bin"}`,
      FAKE_CAPTURE_PATH: capture,
      FAKE_STDIN_CAPTURE: `${root}/execution-stdin.ts`,
    },
  };
}

async function removeWrapperFixture(root: string) {
  await new Deno.Command("chmod", {
    args: ["-R", "u+w", root],
    stdout: "null",
    stderr: "null",
  }).output();
  await Deno.remove(root, { recursive: true });
}

Deno.test("owner backfill dry-run executes immutable staged bytes and preserves attempt evidence", async () => {
  const fixture = await createWrapperFixture();
  try {
    const stage = `${fixture.root}/.base44-cutover/sensitive-owner-backfill`;
    await Deno.mkdir(stage, { recursive: true });
    const sentinel = '{"state":"mutation-started-postflight-required"}\n';
    await Deno.writeTextFile(`${stage}/last-attempt.json`, sentinel);

    const output = await new Deno.Command("/bin/sh", {
      args: [fixture.wrapper],
      cwd: fixture.root,
      env: fixture.env,
      stdout: "piped",
      stderr: "piped",
    }).output();
    assertEquals(output.code, 0, new TextDecoder().decode(output.stderr));

    const pointer = JSON.parse(
      await Deno.readTextFile(`${stage}/reviewed-inputs-current.json`),
    );
    assert(/^[0-9a-f]{64}$/.test(pointer.input_set_sha256));
    const reviewed = `${stage}/reviewed-inputs/${pointer.input_set_sha256}`;
    assertEquals(
      await Deno.readTextFile(
        `${reviewed}/backfill-sensitive-entity-owners.ts`,
      ),
      await Deno.readTextFile(fixture.source),
    );
    assertEquals(
      await Deno.readTextFile(`${reviewed}/inputs.json`),
      await Deno.readTextFile(`${stage}/reviewed-inputs-current.json`),
    );
    const manifest = JSON.parse(
      await Deno.readTextFile(`${stage}/manifest.json`),
    );
    assertEquals(manifest.input_set_sha256, pointer.input_set_sha256);
    assertEquals(manifest.reviewed_inputs.source_sha256, pointer.source_sha256);
    assertEquals(
      await Deno.readTextFile(`${stage}/last-attempt.json`),
      sentinel,
    );
    assertEquals(
      await Deno.readTextFile(fixture.env.FAKE_STDIN_CAPTURE),
      await Deno.readTextFile(fixture.source),
    );
    const executionURLs = (await Deno.readTextFile(fixture.capture)).trim()
      .split("\n");
    assertEquals(executionURLs.length, 2);
    for (const executionURL of executionURLs) {
      assertStringIncludes(executionURL, "/execution-inputs/gameRoomAction/");
      assertEquals(executionURL.includes(fixture.root), false);
    }
    let lockExists = true;
    try {
      await Deno.lstat(
        `${fixture.root}/.base44-cutover/sensitive-owner-backfill.operation.lock`,
      );
    } catch (error) {
      if (error instanceof Deno.errors.NotFound) lockExists = false;
      else throw error;
    }
    assertEquals(lockExists, false);
  } finally {
    await removeWrapperFixture(fixture.root);
  }
});

Deno.test("owner backfill operation lock rejects concurrent dry-run before Base44 exec", async () => {
  const fixture = await createWrapperFixture();
  try {
    const lock =
      `${fixture.root}/.base44-cutover/sensitive-owner-backfill.operation.lock`;
    await Deno.mkdir(lock, { recursive: true });
    await Deno.writeTextFile(`${lock}/owner`, "another-process\n");
    const output = await new Deno.Command("/bin/sh", {
      args: [fixture.wrapper],
      cwd: fixture.root,
      env: fixture.env,
      stdout: "piped",
      stderr: "piped",
    }).output();
    assertEquals(output.code, 75);
    assertStringIncludes(
      new TextDecoder().decode(output.stderr),
      "Another owner-backfill prepare/apply operation holds",
    );
    let captureExists = true;
    try {
      await Deno.lstat(fixture.capture);
    } catch (error) {
      if (error instanceof Deno.errors.NotFound) captureExists = false;
      else throw error;
    }
    assertEquals(captureExists, false);
  } finally {
    await removeWrapperFixture(fixture.root);
  }
});

Deno.test("owner backfill rejects directory and symlink evidence destinations", async () => {
  for (const destinationKind of ["directory", "symlink"] as const) {
    const fixture = await createWrapperFixture();
    try {
      const stage = `${fixture.root}/.base44-cutover/sensitive-owner-backfill`;
      const manifest = `${stage}/manifest.json`;
      await Deno.mkdir(stage, { recursive: true });

      let symlinkTarget = "";
      if (destinationKind === "directory") {
        await Deno.mkdir(manifest);
      } else {
        symlinkTarget = `${fixture.root}/must-not-be-overwritten.json`;
        await Deno.writeTextFile(symlinkTarget, '{"sentinel":true}\n');
        const linked = await new Deno.Command("ln", {
          args: ["-s", symlinkTarget, manifest],
          stdout: "null",
          stderr: "piped",
        }).output();
        assertEquals(
          linked.code,
          0,
          new TextDecoder().decode(linked.stderr),
        );
      }

      const output = await new Deno.Command("/bin/sh", {
        args: [fixture.wrapper],
        cwd: fixture.root,
        env: fixture.env,
        stdout: "piped",
        stderr: "piped",
      }).output();
      assertEquals(
        output.code,
        65,
        `${destinationKind}: ${new TextDecoder().decode(output.stderr)}`,
      );
      assertStringIncludes(
        new TextDecoder().decode(output.stderr),
        "Atomic evidence destination must be a regular non-symlink file",
      );

      const destination = await Deno.lstat(manifest);
      if (destinationKind === "directory") {
        assertEquals(destination.isDirectory, true);
      } else {
        assertEquals(destination.isSymlink, true);
        assertEquals(
          await Deno.readTextFile(symlinkTarget),
          '{"sentinel":true}\n',
        );
      }
    } finally {
      await removeWrapperFixture(fixture.root);
    }
  }
});
