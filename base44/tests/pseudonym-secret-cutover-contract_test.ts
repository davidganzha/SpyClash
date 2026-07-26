import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

const pseudonymSecretURL = new URL(
  "../../scripts/ensure-base44-pseudonym-secret.sh",
  import.meta.url,
);

function assertBefore(source: string, earlier: string, later: string) {
  const earlierIndex = source.indexOf(earlier);
  const laterIndex = source.indexOf(later);
  assert(earlierIndex >= 0, `missing prerequisite: ${earlier}`);
  assert(laterIndex >= 0, `missing mutation boundary: ${later}`);
  assert(earlierIndex < laterIndex, `${earlier} must occur before ${later}`);
}

Deno.test("pseudonym secret creation is candidate, plan, JIT, and postflight guarded", async () => {
  const source = await Deno.readTextFile(pseudonymSecretURL);
  const setBoundary = 'base44_cli secrets set --env-file "$CANDIDATE_FILE"';

  assertStringIncludes(source, "EXPECTED_APP_ID=69a0e57fa939f578082f8091");
  assertStringIncludes(source, "SECRET_NAME=SPYCLASH_PSEUDONYM_KEY");
  assertStringIncludes(
    source,
    "EXPECTED_ACTION=SECURITY_CUTOVER_STEP_2_PSEUDONYM_SECRET",
  );
  assertStringIncludes(source, 'STAGE="$CUTOVER_DIR/pseudonym-secret"');
  assertStringIncludes(source, '--app-id "$APP_ID"');
  assertStringIncludes(
    source,
    'if ! openssl rand -hex 48 > "$raw_candidate"; then',
  );
  assertStringIncludes(source, "length(value) != 96");
  assertStringIncludes(source, "unique < 12");
  assertStringIncludes(source, "check_mode_600");
  assertStringIncludes(source, 'chmod 600 "$raw_candidate" "$env_candidate"');
  assertStringIncludes(source, "candidate_value_sha256");
  assertStringIncludes(source, "initial_secret_inventory_sha256");
  assertStringIncludes(source, "plan_digest");
  assertStringIncludes(source, 'POSTFLIGHT="$STAGE/postflight.json"');
  assertStringIncludes(source, 'ATTEMPT="$STAGE/attempt.json"');
  assertStringIncludes(source, 'status:"mutation-started-postflight-required"');
  assertStringIncludes(source, "postflight_required:true");

  assertBefore(
    source,
    'grep -qx "$SECRET_NAME" "$INITIAL_NAMES"',
    "\n  generate_candidate\n",
  );
  assertBefore(
    source,
    'if [ "${BASE44_CONFIRM_ACTION:-}" != "$EXPECTED_ACTION" ]',
    setBoundary,
  );
  assertBefore(
    source,
    'if [ "${BASE44_CONFIRM_APP_ID:-}" != "$APP_ID" ]',
    setBoundary,
  );
  assertBefore(
    source,
    'if [ "${BASE44_CONFIRM_PSEUDONYM_SECRET_PLAN_DIGEST:-}" != "$plan_digest" ]',
    setBoundary,
  );
  assertBefore(
    source,
    'list_secret_names "$JIT_RAW" "$JIT_NAMES"',
    setBoundary,
  );
  assertBefore(
    source,
    'grep -qx "$SECRET_NAME" "$JIT_NAMES"',
    setBoundary,
  );
  assertBefore(
    source,
    "appeared after plan preparation; refusing to overwrite or rotate it",
    setBoundary,
  );
  assertBefore(
    source,
    'validate_candidate_file "$CANDIDATE_FILE"',
    setBoundary,
  );
  assertBefore(source, "set_status=0", setBoundary);
  assertBefore(
    source,
    'atomic_stage_file "$attempt_tmp" "$ATTEMPT" attempt',
    setBoundary,
  );
  assertBefore(
    source,
    setBoundary,
    'list_secret_names "$POST_RAW" "$POST_NAMES"',
  );
  assertBefore(source, setBoundary, "set_status:$set_status");
  assertBefore(
    source,
    setBoundary,
    'atomic_stage_file "$postflight_tmp" "$POSTFLIGHT" postflight',
  );
  assertBefore(
    source,
    setBoundary,
    'protocol:"spyclash-pseudonym-secret-postflight-v1"',
  );

  assertEquals(source.match(/secrets set --env-file/g)?.length, 1);
  assertEquals(source.includes("functions deploy"), false);
  assertEquals(source.includes("base44 deploy"), false);
  assertEquals(source.includes("$(openssl"), false);
  assertEquals(source.includes("secrets set SPYCLASH_PSEUDONYM_KEY="), false);
  assertEquals(source.includes("secrets set $SECRET_NAME="), false);
});

Deno.test("pseudonym wrapper rejects unsupported mode and stage override before Base44 work", async () => {
  const scriptPath = decodeURIComponent(pseudonymSecretURL.pathname);
  const permission = await Deno.permissions.query({
    name: "run",
    command: scriptPath,
  });
  if (permission.state !== "granted") return;

  const baseEnvironment = {
    PATH: "/usr/bin:/bin:/usr/sbin:/sbin",
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
      BASE44_PSEUDONYM_SECRET_STAGE_DIR: "/tmp/not-reviewed",
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

Deno.test("pseudonym wrapper never sets after generation failure or JIT appearance", async () => {
  const [runPermission, writePermission, envPermission] = await Promise.all([
    Deno.permissions.query({ name: "run" }),
    Deno.permissions.query({ name: "write" }),
    Deno.permissions.query({ name: "env" }),
  ]);
  if (
    runPermission.state !== "granted" ||
    writePermission.state !== "granted" ||
    envPermission.state !== "granted"
  ) return;

  const sourcePath = decodeURIComponent(pseudonymSecretURL.pathname);

  async function createMockRoot() {
    const root = await Deno.makeTempDir({
      prefix: "spyclash-pseudonym-contract-",
    });
    const scripts = `${root}/scripts`;
    const base44 = `${root}/base44`;
    const bin = `${root}/mock-bin`;
    await Deno.mkdir(scripts, { recursive: true });
    await Deno.mkdir(base44, { recursive: true });
    await Deno.mkdir(bin, { recursive: true });
    const script = `${scripts}/ensure-base44-pseudonym-secret.sh`;
    await Deno.copyFile(sourcePath, script);
    await Deno.chmod(script, 0o755);
    await Deno.writeTextFile(
      `${base44}/.app.jsonc`,
      '{\n  "id": "69a0e57fa939f578082f8091"\n}\n',
    );

    const npx = `${bin}/npx`;
    await Deno.writeTextFile(
      npx,
      [
        "#!/bin/sh",
        'case " $* " in',
        '  *" whoami "*) exit 0 ;;',
        '  *" secrets list "*)',
        "    count=0",
        '    if [ -f "$MOCK_STATE" ]; then count=$(sed -n \'1p\' "$MOCK_STATE"); fi',
        "    count=$((count + 1))",
        '    printf \'%s\\n\' "$count" > "$MOCK_STATE"',
        '    if [ -f "$MOCK_REMOTE_PRESENT" ] ||',
        '       { [ "${MOCK_LIST_MODE:-}" = jit-appears ] && [ "$count" -ge 3 ]; } ||',
        '       { [ "${MOCK_LIST_MODE:-}" = set-success ] && [ "$count" -ge 4 ]; }; then',
        "      printf '%s\\n' SPYCLASH_PSEUDONYM_KEY",
        "    else",
        "      printf '%s\\n' 'No secrets configured.'",
        "    fi",
        "    exit 0",
        "    ;;",
        '  *" secrets set --env-file "*)',
        '    printf x >> "$MOCK_SET_MARKER"',
        '    if [ "${MOCK_SET_FAIL:-}" = 1 ]; then exit 42; fi',
        '    : > "$MOCK_REMOTE_PRESENT"',
        '    if [ "${MOCK_CRASH_AFTER_SET:-}" = 1 ]; then',
        '      kill -KILL "$PPID"',
        "      exit 137",
        "    fi",
        "    exit 0",
        "    ;;",
        "esac",
        "exit 99",
      ].join("\n") + "\n",
    );
    await Deno.chmod(npx, 0o755);

    const openssl = `${bin}/openssl`;
    await Deno.writeTextFile(
      openssl,
      [
        "#!/bin/sh",
        'if [ "${MOCK_OPENSSL_FAIL:-}" = 1 ]; then exit 42; fi',
        "printf '%s\\n' '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'",
      ].join("\n") + "\n",
    );
    await Deno.chmod(openssl, 0o755);

    const git = `${bin}/git`;
    await Deno.writeTextFile(git, "#!/bin/sh\nexit 0\n");
    await Deno.chmod(git, 0o755);
    return { root, script, bin };
  }

  async function runScript(
    script: string,
    bin: string,
    root: string,
    args: string[],
    extraEnvironment: Record<string, string>,
  ) {
    return await new Deno.Command(script, {
      args,
      clearEnv: true,
      env: {
        PATH: `${bin}:/usr/bin:/bin:/usr/sbin:/sbin`,
        HOME: root,
        MOCK_STATE: `${root}/list-count`,
        MOCK_SET_MARKER: `${root}/set-called`,
        MOCK_REMOTE_PRESENT: `${root}/remote-present`,
        ...extraEnvironment,
      },
      stdout: "piped",
      stderr: "piped",
    }).output();
  }

  const failedGeneration = await createMockRoot();
  try {
    const result = await runScript(
      failedGeneration.script,
      failedGeneration.bin,
      failedGeneration.root,
      [],
      { MOCK_OPENSSL_FAIL: "1" },
    );
    assertEquals(result.code, 70);
    assertStringIncludes(
      new TextDecoder().decode(result.stderr),
      "OpenSSL failed",
    );
    await assertRejectsPath(`${failedGeneration.root}/set-called`);
    await assertRejectsPath(
      `${failedGeneration.root}/.base44-cutover/pseudonym-secret/candidate.env`,
    );
  } finally {
    await Deno.remove(failedGeneration.root, { recursive: true });
  }

  const jitAppearance = await createMockRoot();
  try {
    const prepare = await runScript(
      jitAppearance.script,
      jitAppearance.bin,
      jitAppearance.root,
      [],
      { MOCK_LIST_MODE: "jit-appears" },
    );
    assertEquals(prepare.code, 77);
    const manifestPath =
      `${jitAppearance.root}/.base44-cutover/pseudonym-secret/manifest.json`;
    const manifest = JSON.parse(await Deno.readTextFile(manifestPath));
    assertEquals(typeof manifest.plan_digest, "string");

    const attemptedSet = await runScript(
      jitAppearance.script,
      jitAppearance.bin,
      jitAppearance.root,
      ["--set"],
      {
        MOCK_LIST_MODE: "jit-appears",
        BASE44_CONFIRM_ACTION: "SECURITY_CUTOVER_STEP_2_PSEUDONYM_SECRET",
        BASE44_CONFIRM_APP_ID: "69a0e57fa939f578082f8091",
        BASE44_CONFIRM_PSEUDONYM_SECRET_PLAN_DIGEST: manifest.plan_digest,
      },
    );
    assertEquals(attemptedSet.code, 77);
    assertStringIncludes(
      new TextDecoder().decode(attemptedSet.stderr),
      "appeared after plan preparation",
    );
    await assertRejectsPath(`${jitAppearance.root}/set-called`);
  } finally {
    await Deno.remove(jitAppearance.root, { recursive: true });
  }

  const verifiedSet = await createMockRoot();
  try {
    const prepare = await runScript(
      verifiedSet.script,
      verifiedSet.bin,
      verifiedSet.root,
      [],
      { MOCK_LIST_MODE: "set-success" },
    );
    assertEquals(prepare.code, 77);
    const stage = `${verifiedSet.root}/.base44-cutover/pseudonym-secret`;
    const manifest = JSON.parse(
      await Deno.readTextFile(`${stage}/manifest.json`),
    );
    const result = await runScript(
      verifiedSet.script,
      verifiedSet.bin,
      verifiedSet.root,
      ["--set"],
      {
        MOCK_LIST_MODE: "set-success",
        BASE44_CONFIRM_ACTION: "SECURITY_CUTOVER_STEP_2_PSEUDONYM_SECRET",
        BASE44_CONFIRM_APP_ID: "69a0e57fa939f578082f8091",
        BASE44_CONFIRM_PSEUDONYM_SECRET_PLAN_DIGEST: manifest.plan_digest,
      },
    );
    assertEquals(result.code, 0);
    await Deno.stat(`${verifiedSet.root}/set-called`);
    await assertRejectsPath(`${stage}/candidate.env`);
    const postflight = JSON.parse(
      await Deno.readTextFile(`${stage}/postflight.json`),
    );
    assertEquals(postflight.set_status, 0);
    assertEquals(postflight.post_list_status, 0);
    assertEquals(postflight.secret_present, true);
    assertEquals(postflight.matches, true);
  } finally {
    await Deno.remove(verifiedSet.root, { recursive: true });
  }

  const failedSet = await createMockRoot();
  try {
    const prepare = await runScript(
      failedSet.script,
      failedSet.bin,
      failedSet.root,
      [],
      { MOCK_LIST_MODE: "set-fails" },
    );
    assertEquals(prepare.code, 77);
    const stage = `${failedSet.root}/.base44-cutover/pseudonym-secret`;
    const manifest = JSON.parse(
      await Deno.readTextFile(`${stage}/manifest.json`),
    );
    const result = await runScript(
      failedSet.script,
      failedSet.bin,
      failedSet.root,
      ["--set"],
      {
        MOCK_LIST_MODE: "set-fails",
        MOCK_SET_FAIL: "1",
        BASE44_CONFIRM_ACTION: "SECURITY_CUTOVER_STEP_2_PSEUDONYM_SECRET",
        BASE44_CONFIRM_APP_ID: "69a0e57fa939f578082f8091",
        BASE44_CONFIRM_PSEUDONYM_SECRET_PLAN_DIGEST: manifest.plan_digest,
      },
    );
    assertEquals(result.code, 70);
    const postflight = JSON.parse(
      await Deno.readTextFile(`${stage}/postflight.json`),
    );
    assertEquals(postflight.set_status, 42);
    assertEquals(postflight.post_list_status, 0);
    assertEquals(postflight.secret_present, false);
    assertEquals(postflight.matches, false);
    await Deno.stat(`${stage}/candidate.env`);
  } finally {
    await Deno.remove(failedSet.root, { recursive: true });
  }

  const existingWithoutAttempt = await createMockRoot();
  try {
    await Deno.writeTextFile(
      `${existingWithoutAttempt.root}/remote-present`,
      "present\n",
    );
    const result = await runScript(
      existingWithoutAttempt.script,
      existingWithoutAttempt.bin,
      existingWithoutAttempt.root,
      [],
      {},
    );
    assertEquals(result.code, 0);
    assertStringIncludes(
      new TextDecoder().decode(result.stdout),
      "already configured; keeping it stable",
    );
    await assertRejectsPath(`${existingWithoutAttempt.root}/set-called`);
  } finally {
    await Deno.remove(existingWithoutAttempt.root, { recursive: true });
  }

  const crashedAfterSet = await createMockRoot();
  try {
    const prepare = await runScript(
      crashedAfterSet.script,
      crashedAfterSet.bin,
      crashedAfterSet.root,
      [],
      {},
    );
    assertEquals(prepare.code, 77);
    const stage = `${crashedAfterSet.root}/.base44-cutover/pseudonym-secret`;
    const manifest = JSON.parse(
      await Deno.readTextFile(`${stage}/manifest.json`),
    );
    const crashed = await runScript(
      crashedAfterSet.script,
      crashedAfterSet.bin,
      crashedAfterSet.root,
      ["--set"],
      {
        MOCK_CRASH_AFTER_SET: "1",
        BASE44_CONFIRM_ACTION: "SECURITY_CUTOVER_STEP_2_PSEUDONYM_SECRET",
        BASE44_CONFIRM_APP_ID: "69a0e57fa939f578082f8091",
        BASE44_CONFIRM_PSEUDONYM_SECRET_PLAN_DIGEST: manifest.plan_digest,
      },
    );
    assert(crashed.code !== 0);
    const attemptPath = `${stage}/attempt.json`;
    const attempt = JSON.parse(await Deno.readTextFile(attemptPath));
    assertEquals(attempt.status, "mutation-started-postflight-required");
    assertEquals(attempt.postflight_required, true);
    assertEquals(typeof attempt.attempt_id, "string");
    assertEquals((await Deno.stat(attemptPath)).mode! & 0o777, 0o600);
    await Deno.stat(`${stage}/candidate.env`);
    await assertRejectsPath(`${stage}/postflight.json`);
    assertEquals(
      await Deno.readTextFile(`${crashedAfterSet.root}/set-called`),
      "x",
    );

    const earlyPresent = await runScript(
      crashedAfterSet.script,
      crashedAfterSet.bin,
      crashedAfterSet.root,
      [],
      {},
    );
    assertEquals(earlyPresent.code, 70);
    assertStringIncludes(
      new TextDecoder().decode(earlyPresent.stderr),
      "pending or ambiguous durable attempt",
    );
    await Deno.stat(`${stage}/candidate.env`);
    assertEquals(
      await Deno.readTextFile(`${crashedAfterSet.root}/set-called`),
      "x",
    );

    const auditedAt = "2026-07-26T00:00:00Z";
    await Deno.writeTextFile(
      `${stage}/postflight.json`,
      JSON.stringify({
        protocol: "spyclash-pseudonym-secret-postflight-v1",
        attempt_id: attempt.attempt_id,
        audited_at: auditedAt,
        app_id: attempt.app_id,
        action: attempt.action,
        secret_name: attempt.secret_name,
        plan_digest: attempt.plan_digest,
        candidate_value_sha256: attempt.candidate_value_sha256,
        initial_secret_inventory_sha256:
          attempt.initial_secret_inventory_sha256,
        jit_secret_inventory_sha256: attempt.jit_secret_inventory_sha256,
        post_secret_inventory_sha256: attempt.jit_secret_inventory_sha256,
        set_status: 0,
        post_list_status: 0,
        secret_present: true,
        matches: true,
        status: "completed-postflight-verified",
        postflight_required: false,
      }) + "\n",
    );
    await Deno.chmod(`${stage}/postflight.json`, 0o600);

    const reconciled = await runScript(
      crashedAfterSet.script,
      crashedAfterSet.bin,
      crashedAfterSet.root,
      [],
      {},
    );
    assertEquals(reconciled.code, 0);
    await assertRejectsPath(`${stage}/candidate.env`);
    const completedAttempt = JSON.parse(
      await Deno.readTextFile(attemptPath),
    );
    assertEquals(completedAttempt.status, "completed-postflight-verified");
    assertEquals(completedAttempt.postflight_required, false);
    assertEquals(completedAttempt.postflight_verified_at, auditedAt);
    assertEquals(
      await Deno.readTextFile(`${crashedAfterSet.root}/set-called`),
      "x",
    );
  } finally {
    await Deno.remove(crashedAfterSet.root, { recursive: true });
  }
});

async function assertRejectsPath(path: string) {
  try {
    await Deno.stat(path);
    assert(false, `unexpected path exists: ${path}`);
  } catch (error) {
    assert(error instanceof Deno.errors.NotFound);
  }
}
