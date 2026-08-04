import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

const schemaScriptURL = new URL(
  "../../scripts/cutover-base44-notification-schema.sh",
  import.meta.url,
);
const functionScriptURL = new URL(
  "../../scripts/cutover-base44-notification-functions.sh",
  import.meta.url,
);
const historicalSchemaURL = new URL(
  "../../scripts/push-base44-additive-schema.sh",
  import.meta.url,
);
const historicalFunctionsURL = new URL(
  "../../scripts/deploy-base44-coordinated-functions.sh",
  import.meta.url,
);
const entitiesURL = new URL("../entities/", import.meta.url);
const functionsURL = new URL("../functions/", import.meta.url);
const expectedStepZeroSchemaDigest =
  "f09988b0e0b5c5e93a55c4738e47ba20b160bd536ee0cacd65337fa05fd674af";
const postNotificationLobbyFields = [
  "lobby_schema_version",
  "lobby_revision",
  "lobby_word_source",
  "lobby_source_pack_id",
  "lobby_source_name",
  "lobby_theme",
  "lobby_category",
  "lobby_word_count",
  "lobby_word_count_mode",
  "lobby_word_pool",
  "lobby_last_mutation_id",
  "lobby_last_mutation_fingerprint",
];

const expectedEntities = [
  "AiGenerationQuota",
  "AiGenerationUsage",
  "AiWordPackCacheVariant",
  "AiWordPackRequestResult",
  "AppleSignInCredential",
  "AppStoreAccount",
  "BillingIdentityLifecycle",
  "CommunityReport",
  "Entitlement",
  "Friendship",
  "GameHistory",
  "GameRoom",
  "GameRoomSignal",
  "LiveActivityRegistration",
  "MembershipGrant",
  "NotificationAnnouncement",
  "NotificationReadReceipt",
  "ProfileComment",
  "PushDeviceRegistration",
  "PushNotificationEvent",
  "RoomInvite",
  "User",
  "WordPack",
].sort();

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
  "notificationAction",
  "pushNotificationAction",
  "stripe-entitlement-webhook",
  "wordPackAction",
].sort();

function assertBefore(source: string, earlier: string, later: string) {
  const earlierIndex = source.indexOf(earlier);
  const laterIndex = source.indexOf(later);
  assert(earlierIndex >= 0, `missing earlier boundary: ${earlier}`);
  assert(laterIndex >= 0, `missing later boundary: ${later}`);
  assert(earlierIndex < laterIndex, `${earlier} must precede ${later}`);
}

function occurrenceCount(source: string, needle: string): number {
  return source.split(needle).length - 1;
}

async function readJSON(path: URL): Promise<Record<string, unknown>> {
  return JSON.parse(await Deno.readTextFile(path));
}

async function copyTree(source: URL, destination: string): Promise<void> {
  await Deno.mkdir(destination, { recursive: true });
  for await (const entry of Deno.readDir(source)) {
    const from = new URL(entry.name + (entry.isDirectory ? "/" : ""), source);
    const to = `${destination}/${entry.name}`;
    if (entry.isDirectory) {
      await copyTree(from, to);
    } else if (entry.isFile) {
      await Deno.copyFile(from, to);
    }
  }
}

async function writePrivateJSON(path: string, value: unknown): Promise<void> {
  await Deno.writeTextFile(path, `${JSON.stringify(value, null, 2)}\n`, {
    mode: 0o600,
  });
  await Deno.chmod(path, 0o600);
}

async function schemaDigest(path: string): Promise<string> {
  const result = await new Deno.Command("sh", {
    args: [
      "-c",
      "jq -S '[.schemas[].entity_schema] | sort_by(.name)' \"$1\" | shasum -a 256 | awk '{print $1}'",
      "sh",
      path,
    ],
    stdout: "piped",
    stderr: "piped",
  }).output();
  assertEquals(result.code, 0, new TextDecoder().decode(result.stderr));
  return new TextDecoder().decode(result.stdout).trim();
}

async function makeFixture(): Promise<{
  root: string;
  bin: string;
  home: string;
  log: string;
}> {
  const root = await Deno.makeTempDir({ prefix: "notification-cutover-" });
  const bin = `${root}/mock-bin`;
  const home = `${root}/home`;
  const log = `${root}/commands.log`;
  await Deno.mkdir(`${root}/scripts`, { recursive: true });
  await Deno.mkdir(`${root}/base44`, { recursive: true });
  await Deno.mkdir(`${home}/.base44/auth`, { recursive: true });
  await Deno.mkdir(`${root}/tmp`, { recursive: true });
  await Deno.mkdir(bin, { recursive: true });
  await Deno.copyFile(
    new URL("../config.jsonc", import.meta.url),
    `${root}/base44/config.jsonc`,
  );
  await Deno.copyFile(
    new URL("../.app.jsonc", import.meta.url),
    `${root}/base44/.app.jsonc`,
  );
  await copyTree(entitiesURL, `${root}/base44/entities`);
  await writePrivateJSON(`${home}/.base44/auth/auth.json`, {
    accessToken: "fixture-token",
  });
  await Deno.writeTextFile(log, "");
  return { root, bin, home, log };
}

async function pinHistoricalNotificationEntityFixture(root: string) {
  await Deno.remove(`${root}/base44/entities/game-room-signal.jsonc`);
  const roomPath = `${root}/base44/entities/GameRoom.jsonc`;
  const room = JSON.parse(await Deno.readTextFile(roomPath));
  for (const field of postNotificationLobbyFields) {
    delete room.properties[field];
  }
  await writePrivateJSON(roomPath, room);
}

async function writeFakeNetworkCommands(
  bin: string,
  withFunctionPull: boolean,
): Promise<void> {
  const npx = withFunctionPull
    ? `#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$MOCK_COMMAND_LOG"
case " $* " in
  *" functions pull "*)
    mkdir -p "$PWD/base44"
    cp -R "$MOCK_REMOTE_FUNCTIONS" "$PWD/base44/functions"
    ;;
  *" functions deploy "*)
    while [ "$#" -gt 0 ] && [ "$1" != "deploy" ]; do shift; done
    [ "\${1:-}" = "deploy" ]
    shift
    for function_name in "$@"; do
      mkdir -p "$MOCK_REMOTE_FUNCTIONS/$function_name"
      cp -R "$PWD/base44/functions/$function_name/." "$MOCK_REMOTE_FUNCTIONS/$function_name/"
    done
    ;;
  *" whoami "*) ;;
  *) exit 99 ;;
esac
`
    : `#!/bin/sh
set -eu
printf '%s\\n' "$*" >> "$MOCK_COMMAND_LOG"
case " $* " in
  *" whoami "*) ;;
  *) exit 99 ;;
esac
`;
  const curl = `#!/bin/sh
set -eu
cat "$MOCK_SCHEMA_PATH"
`;
  await Deno.writeTextFile(`${bin}/npx`, npx, { mode: 0o700 });
  await Deno.writeTextFile(`${bin}/curl`, curl, { mode: 0o700 });
  await Deno.chmod(`${bin}/npx`, 0o700);
  await Deno.chmod(`${bin}/curl`, 0o700);
}

async function snapshotFunctionTrees(
  root: string,
  names: string[],
): Promise<Array<{ path: string; contents: string }>> {
  const snapshot: Array<{ path: string; contents: string }> = [];

  async function walk(directory: string, relativeDirectory: string) {
    const entries = [];
    for await (const entry of Deno.readDir(directory)) entries.push(entry);
    entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const path = `${directory}/${entry.name}`;
      const relativePath = relativeDirectory
        ? `${relativeDirectory}/${entry.name}`
        : entry.name;
      if (entry.isDirectory) {
        await walk(path, relativePath);
      } else if (entry.isFile) {
        snapshot.push({
          path: relativePath,
          contents: await Deno.readTextFile(path),
        });
      }
    }
  }

  for (const name of [...names].sort()) {
    await walk(`${root}/${name}`, name);
  }
  return snapshot;
}

async function canonicalSchemaResponse(
  root: string,
): Promise<{ total: number; schemas: Array<Record<string, unknown>> }> {
  const schemas: Array<Record<string, unknown>> = [];
  for await (const entry of Deno.readDir(`${root}/base44/entities`)) {
    if (!entry.isFile || !entry.name.endsWith(".jsonc")) continue;
    const entitySchema = JSON.parse(
      await Deno.readTextFile(`${root}/base44/entities/${entry.name}`),
    );
    schemas.push({
      entity_name: entitySchema.name,
      entity_schema: entitySchema,
    });
  }
  schemas.sort((left, right) =>
    String(left.entity_name).localeCompare(String(right.entity_name))
  );
  return { total: schemas.length, schemas };
}

Deno.test("notification cutover scripts are valid Bash", async () => {
  for (const script of [schemaScriptURL, functionScriptURL]) {
    const result = await new Deno.Command("bash", {
      args: ["-n", script.pathname],
      stdout: "piped",
      stderr: "piped",
    }).output();
    assertEquals(
      result.code,
      0,
      new TextDecoder().decode(result.stderr),
    );
  }
});

Deno.test("Step A read-only prepare builds the exact 20 to 22 candidate without a mutation", async () => {
  const fixture = await makeFixture();
  try {
    await pinHistoricalNotificationEntityFixture(fixture.root);
    await Deno.copyFile(
      schemaScriptURL,
      `${fixture.root}/scripts/cutover-base44-notification-schema.sh`,
    );
    const response = await canonicalSchemaResponse(fixture.root);
    response.schemas = response.schemas.filter((row) =>
      !["NotificationAnnouncement", "NotificationReadReceipt"].includes(
        String(row.entity_name),
      )
    );
    response.total = response.schemas.length;
    const user = response.schemas.find((row) => row.entity_name === "User")!
      .entity_schema as Record<string, unknown>;
    const userProperties = user.properties as Record<string, unknown>;
    delete userProperties.radar_invite_policy;
    userProperties.role = {
      default: "user",
      enum: ["admin", "user"],
      type: "string",
    };
    user.required = ["role"];
    const registration = response.schemas.find((row) =>
      row.entity_name === "PushDeviceRegistration"
    )!.entity_schema as Record<string, unknown>;
    delete (registration.properties as Record<string, unknown>)
      .announcements_enabled;
    const event = response.schemas.find((row) =>
      row.entity_name === "PushNotificationEvent"
    )!.entity_schema as Record<string, unknown>;
    const properties = event.properties as Record<
      string,
      Record<string, unknown>
    >;
    properties.event_type.enum = (properties.event_type.enum as string[])
      .filter((value) => value !== "global_announcement");
    properties.source_type.enum = (properties.source_type.enum as string[])
      .filter((value) => value !== "notification_announcement");
    for (
      const field of [
        "announcement_id",
        "inbox_kind",
        "inbox_importance",
        "inbox_title_en",
        "inbox_body_en",
        "inbox_title_ru",
        "inbox_body_ru",
        "inbox_title_es",
        "inbox_body_es",
        "inbox_action_deep_link",
        "inbox_published_at",
        "inbox_projection_version",
        "inbox_visible",
        "inbox_committed_at",
      ]
    ) {
      delete properties[field];
    }
    const remotePath = `${fixture.root}/remote-schema.json`;
    await writePrivateJSON(remotePath, response);
    await writeFakeNetworkCommands(fixture.bin, false);

    const missingStepZero = await new Deno.Command("bash", {
      args: [`${fixture.root}/scripts/cutover-base44-notification-schema.sh`],
      cwd: fixture.root,
      env: {
        HOME: fixture.home,
        TMPDIR: `${fixture.root}/tmp`,
        PATH: `${fixture.bin}:/usr/bin:/bin:/usr/sbin:/sbin`,
        MOCK_COMMAND_LOG: fixture.log,
        MOCK_SCHEMA_PATH: remotePath,
      },
      stdout: "piped",
      stderr: "piped",
    }).output();
    assertEquals(missingStepZero.code, 77);

    const stepZeroDigest = await schemaDigest(remotePath);
    assertEquals(stepZeroDigest, expectedStepZeroSchemaDigest);
    const stepZeroPlanDigest = "a".repeat(64);
    const stepZeroStage =
      `${fixture.root}/.base44-cutover/notification-step-0-schema-repair`;
    const stepZeroEvidence =
      `${fixture.root}/.base44-cutover/evidence/notification-step-0-schema-repair`;
    await Deno.mkdir(stepZeroStage, { recursive: true, mode: 0o700 });
    await Deno.mkdir(stepZeroEvidence, { recursive: true, mode: 0o700 });
    await writePrivateJSON(`${stepZeroStage}/manifest.json`, {
      app_id: "69a0e57fa939f578082f8091",
      action: "SPYCLASH_NOTIFICATION_STEP_0_SCHEMA_REPAIR",
      step: "0",
      live_count: 20,
      target_count: 20,
      target_custom_entity_count: 19,
      target_schema_digest: expectedStepZeroSchemaDigest,
      plan_digest: stepZeroPlanDigest,
      delta: {
        entity_additions: [],
        entity_deletions: [],
        property_removals: [],
        rls_changes: [
          "AiGenerationQuota",
          "GameHistory",
          "GameRoom",
          "WordPack",
        ],
      },
    });
    await writePrivateJSON(`${stepZeroEvidence}/latest-postflight.json`, {
      app_id: "69a0e57fa939f578082f8091",
      reviewed_plan_digest: stepZeroPlanDigest,
      expected_schema_digest: expectedStepZeroSchemaDigest,
      actual_schema_digest: expectedStepZeroSchemaDigest,
      expected_count: 20,
      actual_count: 20,
      push_status: 0,
      postflight_fetch_status: 0,
      postflight_schema_status: 0,
      admin_write_boundary: true,
      matches_reviewed_stage: true,
    });

    const result = await new Deno.Command("bash", {
      args: [`${fixture.root}/scripts/cutover-base44-notification-schema.sh`],
      cwd: fixture.root,
      env: {
        HOME: fixture.home,
        TMPDIR: `${fixture.root}/tmp`,
        PATH: `${fixture.bin}:/usr/bin:/bin:/usr/sbin:/sbin`,
        MOCK_COMMAND_LOG: fixture.log,
        MOCK_SCHEMA_PATH: remotePath,
      },
      stdout: "piped",
      stderr: "piped",
    }).output();
    assertEquals(result.code, 0, new TextDecoder().decode(result.stderr));
    const manifest = JSON.parse(
      await Deno.readTextFile(
        `${fixture.root}/.base44-cutover/notification-step-a-schema/manifest.json`,
      ),
    );
    assertEquals(manifest.live_count, 20);
    assertEquals(manifest.target_count, 22);
    assertEquals(manifest.delta.additions, [
      "NotificationAnnouncement",
      "NotificationReadReceipt",
    ]);
    assertEquals(manifest.delta.changes, [
      "PushDeviceRegistration",
      "PushNotificationEvent",
      "User",
    ]);
    assertEquals(manifest.delta.deletions, []);
    assertEquals(manifest.delta.unchanged.length, 17);
    assert(/^[0-9a-f]{64}$/.test(manifest.plan_digest));
    const commands = await Deno.readTextFile(fixture.log);
    assertStringIncludes(commands, "whoami");
    assertEquals(commands.includes("entities push"), false);
  } finally {
    await Deno.remove(fixture.root, { recursive: true });
  }
});

Deno.test("Step B read-only prepare binds exact Step A evidence and the 16 to 17 source delta", async () => {
  const fixture = await makeFixture();
  try {
    await pinHistoricalNotificationEntityFixture(fixture.root);
    await Deno.copyFile(
      functionScriptURL,
      `${fixture.root}/scripts/cutover-base44-notification-functions.sh`,
    );
    await copyTree(functionsURL, `${fixture.root}/base44/functions`);
    const response = await canonicalSchemaResponse(fixture.root);
    const remoteSchemaPath = `${fixture.root}/remote-schema.json`;
    await writePrivateJSON(remoteSchemaPath, response);
    const digest = await schemaDigest(remoteSchemaPath);

    const schemaStage =
      `${fixture.root}/.base44-cutover/notification-step-a-schema`;
    const schemaEvidence =
      `${fixture.root}/.base44-cutover/evidence/notification-step-a-schema`;
    await Deno.mkdir(schemaStage, { recursive: true, mode: 0o700 });
    await Deno.mkdir(schemaEvidence, { recursive: true, mode: 0o700 });
    await writePrivateJSON(`${schemaStage}/manifest.json`, {
      app_id: "69a0e57fa939f578082f8091",
      step: "A",
      live_count: 20,
      target_count: 22,
      delta: {
        additions: ["NotificationAnnouncement", "NotificationReadReceipt"],
        deletions: [],
        changes: ["PushDeviceRegistration", "PushNotificationEvent", "User"],
      },
      target_schema_digest: digest,
    });
    await writePrivateJSON(`${schemaEvidence}/latest-postflight.json`, {
      app_id: "69a0e57fa939f578082f8091",
      expected_count: 22,
      actual_count: 22,
      expected_schema_digest: digest,
      actual_schema_digest: digest,
      names_match: true,
      matches_reviewed_stage: true,
    });

    const remoteFunctions = `${fixture.root}/remote-functions`;
    await copyTree(functionsURL, remoteFunctions);
    await Deno.remove(`${remoteFunctions}/notificationAction`, {
      recursive: true,
    });
    for (
      const name of [
        "communityAction",
        "deleteAccount",
        "gameRoomAction",
        "pushNotificationAction",
      ]
    ) {
      const main = `${remoteFunctions}/${name}/main.ts`;
      await Deno.writeTextFile(
        main,
        `${await Deno.readTextFile(main)}\n// fixture legacy source\n`,
      );
    }
    const deferredLocalDrift = [
      "advanceRound",
      "autoRegisterUser",
      "checkSubscription",
      "createCheckout",
    ];
    for (const name of deferredLocalDrift) {
      const main = `${remoteFunctions}/${name}/main.ts`;
      await Deno.writeTextFile(
        main,
        `${await Deno.readTextFile(main)}\n// fixture remote-only source\n`,
      );
    }
    await writeFakeNetworkCommands(fixture.bin, true);

    const result = await new Deno.Command("bash", {
      args: [
        `${fixture.root}/scripts/cutover-base44-notification-functions.sh`,
      ],
      cwd: fixture.root,
      env: {
        HOME: fixture.home,
        TMPDIR: `${fixture.root}/tmp`,
        PATH: `${fixture.bin}:/usr/bin:/bin:/usr/sbin:/sbin`,
        MOCK_COMMAND_LOG: fixture.log,
        MOCK_SCHEMA_PATH: remoteSchemaPath,
        MOCK_REMOTE_FUNCTIONS: remoteFunctions,
      },
      stdout: "piped",
      stderr: "piped",
    }).output();
    assertEquals(result.code, 0, new TextDecoder().decode(result.stderr));
    const manifest = JSON.parse(
      await Deno.readTextFile(
        `${fixture.root}/.base44-cutover/notification-step-b-functions/manifest.json`,
      ),
    );
    assertEquals(manifest.schema_count, 22);
    assertEquals(manifest.live_function_count, 16);
    assertEquals(manifest.target_function_count, 17);
    assertEquals(manifest.delta.additions, ["notificationAction"]);
    assertEquals(manifest.delta.changes, [
      "communityAction",
      "deleteAccount",
      "gameRoomAction",
      "pushNotificationAction",
    ]);
    assertEquals(manifest.delta.deletions, []);
    assertEquals(manifest.delta.unchanged.length, 12);
    assertEquals(manifest.informational_deferred_local_delta.additions, []);
    assertEquals(manifest.informational_deferred_local_delta.deletions, []);
    assertEquals(
      manifest.informational_deferred_local_delta.changes,
      deferredLocalDrift,
    );
    assertEquals(
      manifest.informational_deferred_local_delta.unchanged.length,
      8,
    );
    assertEquals(manifest.deploy_function_order, [
      "notificationAction",
      "communityAction",
      "gameRoomAction",
      "deleteAccount",
      "pushNotificationAction",
    ]);
    assert(/^[0-9a-f]{64}$/.test(manifest.plan_digest));
    const commands = await Deno.readTextFile(fixture.log);
    assertStringIncludes(commands, "functions pull");
    assertEquals(commands.includes("functions deploy"), false);

    const unchangedNames = manifest.delta.unchanged as string[];
    const unchangedBefore = await snapshotFunctionTrees(
      remoteFunctions,
      unchangedNames,
    );
    const deployResult = await new Deno.Command("bash", {
      args: [
        `${fixture.root}/scripts/cutover-base44-notification-functions.sh`,
        "--deploy",
        "--plan-digest",
        manifest.plan_digest,
      ],
      cwd: fixture.root,
      env: {
        HOME: fixture.home,
        TMPDIR: `${fixture.root}/tmp`,
        PATH: `${fixture.bin}:/usr/bin:/bin:/usr/sbin:/sbin`,
        MOCK_COMMAND_LOG: fixture.log,
        MOCK_SCHEMA_PATH: remoteSchemaPath,
        MOCK_REMOTE_FUNCTIONS: remoteFunctions,
        BASE44_CONFIRM_APP_ID: "69a0e57fa939f578082f8091",
        BASE44_CONFIRM_ACTION: "SPYCLASH_NOTIFICATION_STEP_B_FUNCTIONS",
        BASE44_CONFIRM_NOTIFICATION_FUNCTION_PLAN_DIGEST: manifest.plan_digest,
      },
      stdout: "piped",
      stderr: "piped",
    }).output();
    assertEquals(
      deployResult.code,
      0,
      new TextDecoder().decode(deployResult.stderr),
    );
    assertEquals(
      await snapshotFunctionTrees(remoteFunctions, unchangedNames),
      unchangedBefore,
    );
    const postflight = JSON.parse(
      await Deno.readTextFile(
        `${fixture.root}/.base44-cutover/evidence/notification-step-b-functions/latest-postflight.json`,
      ),
    );
    assertEquals(postflight.deploy_status, 0);
    assertEquals(postflight.function_postflight_status, 0);
    assertEquals(postflight.schema_postflight_status, 0);
    assertEquals(postflight.matches_reviewed_stage, true);
    assertEquals(
      postflight.actual_unchanged_bytes_digest,
      postflight.expected_unchanged_bytes_digest,
    );
    const commandsAfterDeploy = await Deno.readTextFile(fixture.log);
    assertStringIncludes(
      commandsAfterDeploy,
      "functions deploy notificationAction communityAction gameRoomAction deleteAccount pushNotificationAction",
    );
    assertEquals(commandsAfterDeploy.includes("--force"), false);
  } finally {
    await Deno.remove(fixture.root, { recursive: true });
  }
});

Deno.test("Step A is exact, additive, digest-bound, and fail closed", async () => {
  const source = await Deno.readTextFile(schemaScriptURL);
  const mutation = '(cd "$FIXED_STAGE" && base44_cli entities push)';

  for (
    const value of [
      'EXPECTED_APP_ID="69a0e57fa939f578082f8091"',
      "EXPECTED_LIVE_COUNT=20",
      "EXPECTED_TARGET_COUNT=22",
      "EXPECTED_CUSTOM_ENTITY_COUNT=21",
      "ADDED_ENTITIES=(NotificationAnnouncement NotificationReadReceipt)",
      "CHANGED_ENTITIES=(PushDeviceRegistration PushNotificationEvent User)",
      "add_property_from_local User radar_invite_policy",
      `EXPECTED_STEP_ZERO_SCHEMA_DIGEST="${expectedStepZeroSchemaDigest}"`,
      'verify_step_zero_boundary "$REMOTE"',
      'verify_step_zero_boundary "$JIT_REMOTE"',
      'ACTION="SPYCLASH_NOTIFICATION_STEP_A_SCHEMA"',
      "--deploy --plan-digest <sha256>",
      "BASE44_CONFIRM_NOTIFICATION_SCHEMA_PLAN_DIGEST",
      'PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"',
      "trap cleanup EXIT",
      "trap 'exit 129' HUP",
      "trap 'exit 130' INT",
      "trap 'exit 143' TERM",
      "schema_delta_digest",
      "stage_bytes_digest",
      "local_inputs_digest",
      "target_custom_entity_count",
      'status:"mutation-started-postflight-required"',
      "matches_reviewed_stage",
    ]
  ) {
    assertStringIncludes(source, value);
  }
  assertBefore(
    source,
    'if [[ "$MODE" == "deploy" ]]; then\n    acquire_production_lock',
    'if ! mkdir "$LOCK_DIR"',
  );
  assertBefore(source, 'fetch_remote_schema "$JIT_REMOTE"', mutation);
  assertBefore(source, 'install_durable_json "$WORK/attempt.json"', mutation);
  assertBefore(source, mutation, 'fetch_remote_schema "$POST_REMOTE"');
  assertStringIncludes(source, ".deletions == []");
  assertStringIncludes(source, "(.property_removals | length) == 0");
  assertStringIncludes(source, ".rls_changed == false");
  assertStringIncludes(
    source,
    "extend_enum_from_local PushNotificationEvent event_type global_announcement",
  );
  assertStringIncludes(
    source,
    "extend_enum_from_local PushNotificationEvent source_type notification_announcement",
  );
  assertEquals(occurrenceCount(source, "base44_cli entities push"), 1);
  assertEquals(source.includes("functions deploy"), false);
  assertEquals(source.includes("base44 deploy"), false);
  assertEquals(source.includes("secrets set"), false);
  assertEquals(source.includes("sites deploy"), false);
});

Deno.test("Step B binds 16 to 17 sources and preserves all non-targets", async () => {
  const source = await Deno.readTextFile(functionScriptURL);
  const mutation =
    '(cd "$FIXED_STAGE/deploy" && base44_cli functions deploy "${DEPLOY_FUNCTIONS[@]}")';

  for (
    const value of [
      'EXPECTED_APP_ID="69a0e57fa939f578082f8091"',
      "EXPECTED_LIVE_FUNCTION_COUNT=16",
      "EXPECTED_TARGET_FUNCTION_COUNT=17",
      "EXPECTED_SCHEMA_COUNT=22",
      "ADDED_FUNCTIONS=(notificationAction)",
      "CHANGED_FUNCTIONS=(communityAction deleteAccount gameRoomAction pushNotificationAction)",
      "DEPLOY_FUNCTIONS=(notificationAction communityAction gameRoomAction deleteAccount pushNotificationAction)",
      'ACTION="SPYCLASH_NOTIFICATION_STEP_B_FUNCTIONS"',
      "--deploy --plan-digest <sha256>",
      "BASE44_CONFIRM_NOTIFICATION_FUNCTION_PLAN_DIGEST",
      'PRODUCTION_LOCK_DIR="$CUTOVER_DIR/.production-mutation.lock"',
      "trap cleanup EXIT",
      "trap 'exit 129' HUP",
      "trap 'exit 130' INT",
      "trap 'exit 143' TERM",
      "remote_function_digest",
      "expected_target_function_digest",
      "local_deploy_function_digest",
      "unchanged_before_digest",
      "unchanged_before_bytes_digest",
      "informational_deferred_local_delta",
      "function_set_bytes_digest",
      "copy_scoped_target_functions",
      'status:"mutation-started-postflight-required"',
      "matches_reviewed_stage",
    ]
  ) {
    assertStringIncludes(source, value);
  }
  assertBefore(
    source,
    'if [[ "$MODE" == "deploy" ]]; then acquire_production_lock',
    'if ! mkdir "$LOCK_DIR"',
  );
  assertBefore(source, 'pull_remote_functions "$REMOTE_JIT"', mutation);
  assertBefore(source, 'install_durable_json "$WORK/attempt.json"', mutation);
  assertBefore(source, mutation, 'pull_remote_functions "$REMOTE_AFTER"');
  assertBefore(source, mutation, 'fetch_remote_schema "$SCHEMA_POST"');
  assertStringIncludes(source, '.additions == ["notificationAction"]');
  assertStringIncludes(
    source,
    '.delta.changes == ["PushDeviceRegistration","PushNotificationEvent","User"]',
  );
  assertStringIncludes(source, ".deletions == []");
  assertStringIncludes(source, "(.unchanged | length) == 12");
  assertEquals(occurrenceCount(source, "base44_cli functions deploy"), 1);
  assertEquals(source.includes("--force"), false);
  assertEquals(source.includes("base44 deploy"), false);
  assertEquals(source.includes("entities push"), false);
  assertEquals(source.includes("secrets set"), false);
  assertEquals(source.includes("sites deploy"), false);
});

Deno.test("canonical inventory is exactly 23 entities and 17 functions", async () => {
  const entityNames: string[] = [];
  for await (const entry of Deno.readDir(entitiesURL)) {
    if (!entry.isFile || !entry.name.endsWith(".jsonc")) continue;
    const schema = await readJSON(new URL(entry.name, entitiesURL));
    entityNames.push(String(schema.name));
  }
  assertEquals(entityNames.sort(), expectedEntities);

  const functionNames: string[] = [];
  for await (const entry of Deno.readDir(functionsURL)) {
    if (!entry.isDirectory) continue;
    const config = await readJSON(
      new URL(`${entry.name}/function.jsonc`, functionsURL),
    );
    assertEquals(config.name, entry.name);
    functionNames.push(entry.name);
  }
  assertEquals(functionNames.sort(), expectedFunctions);
});

Deno.test("notification schema and worker activation match the reviewed contract", async () => {
  const announcement = await readJSON(
    new URL("notification-announcement.jsonc", entitiesURL),
  );
  const receipt = await readJSON(
    new URL("notification-read-receipt.jsonc", entitiesURL),
  );
  for (const schema of [announcement, receipt]) {
    const rls = schema.rls as Record<
      string,
      Record<string, Record<string, string>>
    >;
    for (const operation of ["create", "update", "delete"]) {
      assertEquals(rls[operation].user_condition.role, "admin");
    }
  }

  const registration = await readJSON(
    new URL("push-device-registration.jsonc", entitiesURL),
  );
  const registrationProperties = registration.properties as Record<
    string,
    unknown
  >;
  assertEquals(registrationProperties.announcements_enabled, {
    type: "boolean",
    default: true,
  });
  assertEquals(
    (registration.required as string[]).includes("announcements_enabled"),
    false,
  );

  const event = await readJSON(
    new URL("push-notification-event.jsonc", entitiesURL),
  );
  const eventProperties = event.properties as Record<
    string,
    Record<string, unknown>
  >;
  assert(
    (eventProperties.event_type.enum as string[]).includes(
      "global_announcement",
    ),
  );
  assert(
    (eventProperties.source_type.enum as string[]).includes(
      "notification_announcement",
    ),
  );
  for (
    const field of [
      "announcement_id",
      "inbox_kind",
      "inbox_importance",
      "inbox_title_en",
      "inbox_body_en",
      "inbox_title_ru",
      "inbox_body_ru",
      "inbox_title_es",
      "inbox_body_es",
      "inbox_action_deep_link",
      "inbox_published_at",
      "inbox_projection_version",
      "inbox_visible",
      "inbox_committed_at",
    ]
  ) {
    assert(field in eventProperties, `missing ${field}`);
    assertEquals((event.required as string[]).includes(field), false);
  }

  const notificationConfig = await readJSON(
    new URL("notificationAction/function.jsonc", functionsURL),
  );
  assertEquals("automations" in notificationConfig, false);
  const pushConfig = await readJSON(
    new URL("pushNotificationAction/function.jsonc", functionsURL),
  );
  const automations = pushConfig.automations as Array<Record<string, unknown>>;
  assertEquals(automations.length, 1);
  assertEquals(automations[0].is_active, true);
  assertEquals(automations[0].repeat_unit, "minutes");
  assertEquals(automations[0].repeat_interval, 5);
  assertEquals(
    (automations[0].function_args as Record<string, unknown>).limit,
    64,
  );
});

Deno.test("historical cutover scripts retain their reviewed 20/16 contracts", async () => {
  const historicalSchema = await Deno.readTextFile(historicalSchemaURL);
  const historicalFunctions = await Deno.readTextFile(historicalFunctionsURL);
  assertStringIncludes(historicalSchema, "EXPECTED_ENTITY_COUNT=20");
  assertStringIncludes(historicalSchema, "EXPECTED_CUSTOM_ENTITY_COUNT=19");
  assertEquals(historicalSchema.includes("NotificationAnnouncement"), false);
  assertEquals(historicalFunctions.includes("notificationAction"), false);
  assertStringIncludes(
    historicalFunctions,
    'SCHEMA_MANIFEST="$CUTOVER_DIR/final-schema-check/manifest.json"',
  );
});
