import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

const scriptURL = new URL(
  "../../scripts/repair-base44-final-schema-before-notifications.sh",
  import.meta.url,
);
const runbookURL = new URL("../NOTIFICATION_CUTOVER.md", import.meta.url);
const entitiesURL = new URL("../entities/", import.meta.url);

const expectedAppID = "69a0e57fa939f578082f8091";
const expectedDriftedDigest =
  "038cd5a3f0989826ac92580272da099979549b15cdfa70353feafed3c20525fb";
const expectedFinalDigest =
  "f09988b0e0b5c5e93a55c4738e47ba20b160bd536ee0cacd65337fa05fd674af";
const expectedHistoricalPlan =
  "a55997ac76faa1c166fc3d68b4df644a961d4f41c04ad9cfd16ef345e4b4127a";
const postHistoricalGameRoomFields = [
  "close_intent",
  "spy_emails",
  "lobby_spy_count",
  "spies_know_each_other",
  "incompatible_player_emails",
  "departed_player_emails",
  "room_revision",
  "room_last_write_token",
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
  "detective_vote_round_id",
  "detective_vote_cancellation_event_id",
  "detective_vote_cancellation_round_id",
  "detective_vote_cancellation_present_at",
  "detective_vote_cancellation_reason",
  "replay_source_match_id",
];
const postHistoricalUserFields = [
  "onboarding_completed",
  "onboarding_version",
  "onboarding_completed_at",
  "acquisition_source",
  "spy_games_played",
  "spy_games_won",
  "detective_games_played",
  "detective_games_won",
];

function assertBefore(source: string, earlier: string, later: string) {
  const earlierIndex = source.indexOf(earlier);
  const laterIndex = source.indexOf(later);
  assert(earlierIndex >= 0, `missing earlier boundary: ${earlier}`);
  assert(laterIndex >= 0, `missing later boundary: ${later}`);
  assert(earlierIndex < laterIndex, `${earlier} must precede ${later}`);
}

async function readLocalSchemas(): Promise<Array<Record<string, unknown>>> {
  const schemas: Array<Record<string, unknown>> = [];
  for await (const entry of Deno.readDir(entitiesURL)) {
    if (!entry.isFile || !entry.name.endsWith(".jsonc")) continue;
    schemas.push(
      JSON.parse(await Deno.readTextFile(new URL(entry.name, entitiesURL))),
    );
  }
  return schemas;
}

async function jqSortedDigest(value: unknown): Promise<string> {
  const process = new Deno.Command("jq", {
    args: ["-S", "."],
    stdin: "piped",
    stdout: "piped",
    stderr: "piped",
  }).spawn();
  const writer = process.stdin.getWriter();
  await writer.write(new TextEncoder().encode(JSON.stringify(value)));
  await writer.close();
  const result = await process.output();
  assertEquals(result.code, 0, new TextDecoder().decode(result.stderr));
  const digest = await crypto.subtle.digest("SHA-256", result.stdout);
  return [...new Uint8Array(digest)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

Deno.test("notification Step 0 schema repair script is valid Bash", async () => {
  const result = await new Deno.Command("bash", {
    args: ["-n", scriptURL.pathname],
    stdout: "piped",
    stderr: "piped",
  }).output();
  assertEquals(result.code, 0, new TextDecoder().decode(result.stderr));
});

Deno.test("notification Step 0 pins the incident snapshot and approved Step 6 target", async () => {
  const source = await Deno.readTextFile(scriptURL);
  for (
    const value of [
      expectedAppID,
      expectedDriftedDigest,
      expectedFinalDigest,
      expectedHistoricalPlan,
      "SPYCLASH_NOTIFICATION_STEP_0_SCHEMA_REPAIR",
      "20260726T191333Z-27231",
    ]
  ) {
    assertStringIncludes(source, value);
  }
  assertStringIncludes(source, "validate_historical_evidence");
  assertStringIncludes(source, "validate_live_precondition");
  assertStringIncludes(source, 'cmp -s "$historical" "$candidate"');
});

Deno.test("checked-in schemas still derive the exact approved 20-entity target", async () => {
  const schemas = (await readLocalSchemas()).filter((schema) =>
    ![
      "GameRoomSignal",
      "CommunityProfileSignal",
      "NotificationAnnouncement",
      "NotificationReadReceipt",
    ].includes(
      String(schema.name),
    )
  );
  assertEquals(schemas.length, 20);

  const registration = schemas.find((schema) =>
    schema.name === "PushDeviceRegistration"
  )!;
  delete (registration.properties as Record<string, unknown>)
    .announcements_enabled;

  const event = schemas.find((schema) =>
    schema.name === "PushNotificationEvent"
  )!;
  const eventProperties = event.properties as Record<
    string,
    Record<string, unknown>
  >;
  eventProperties.event_type.enum =
    (eventProperties.event_type.enum as string[])
      .filter((value) => value !== "global_announcement");
  eventProperties.source_type.enum =
    (eventProperties.source_type.enum as string[])
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
      "inbox_title_uk",
      "inbox_body_uk",
      "inbox_action_deep_link",
      "inbox_published_at",
      "inbox_projection_version",
      "inbox_visible",
      "inbox_committed_at",
    ]
  ) {
    delete eventProperties[field];
  }

  const user = schemas.find((schema) => schema.name === "User")!;
  const userProperties = user.properties as Record<string, unknown>;
  delete userProperties.radar_invite_policy;
  const language = userProperties.language as Record<string, unknown>;
  language.enum = (language.enum as string[]).filter((value) => value !== "uk");
  for (const field of postHistoricalUserFields) {
    delete userProperties[field];
  }
  userProperties.role = {
    default: "user",
    enum: ["admin", "user"],
    type: "string",
  };
  user.required = ["role"];

  const room = schemas.find((schema) => schema.name === "GameRoom")!;
  const roomProperties = room.properties as Record<string, unknown>;
  for (const field of postHistoricalGameRoomFields) {
    delete roomProperties[field];
  }
  (roomProperties.players as Record<string, unknown>).description =
    "Server-normalized player objects {user_id, email, name, avatar}";
  const history = schemas.find((schema) => schema.name === "GameHistory")!;
  const historicalHistoryProperties = history.properties as Record<
    string,
    unknown
  >;
  delete historicalHistoryProperties.spy_count;
  delete historicalHistoryProperties.result_key;
  delete historicalHistoryProperties.profile_repair_state;
  delete historicalHistoryProperties.profile_repair_token;
  delete historicalHistoryProperties.profile_repair_lease_until;
  delete historicalHistoryProperties.profile_repair_attempt_count;
  delete historicalHistoryProperties.profile_repair_completed_at;
  const liveActivity = schemas.find((schema) =>
    schema.name === "LiveActivityRegistration"
  )!;
  delete (liveActivity.properties as Record<string, unknown>)
    .pending_force_end_commit_id;
  delete (liveActivity.properties as Record<string, unknown>)
    .terminal_probe_started_at;
  delete (liveActivity.properties as Record<string, unknown>)
    .terminal_probe_until;
  schemas.sort((left, right) => {
    const leftName = String(left.name);
    const rightName = String(right.name);
    return leftName < rightName ? -1 : leftName > rightName ? 1 : 0;
  });
  assertEquals(await jqSortedDigest(schemas), expectedFinalDigest);
});

Deno.test("notification Step 0 is additive and forbids every entity or field removal", async () => {
  const source = await Deno.readTextFile(scriptURL);
  assertStringIncludes(
    source,
    ".entity_additions == [] and .entity_deletions == []",
  );
  assertStringIncludes(source, ".property_removals == []");
  assertStringIncludes(source, "all(.details[]; .required_changed == false)");
  assertStringIncludes(
    source,
    '.rls_changes == ["AiGenerationQuota","GameHistory","GameRoom","WordPack"]',
  );
  assertStringIncludes(source, "($checks | length) == $expected");
  assertEquals(source.includes("functions deploy"), false);
  assertEquals(source.includes("site deploy"), false);
  assertEquals(source.includes("secrets set"), false);
});

Deno.test("notification Step 0 gates mutation behind review, confirmation, JIT, and durable evidence", async () => {
  const source = await Deno.readTextFile(scriptURL);
  assertBefore(
    source,
    'if [[ "$MODE" == "prepare" ]]',
    '(cd "$FIXED_STAGE" && base44_cli entities push)',
  );
  assertBefore(
    source,
    "BASE44_CONFIRM_NOTIFICATION_SCHEMA_REPAIR_PLAN_DIGEST",
    'fetch_remote_schema "$JIT_REMOTE"',
  );
  assertBefore(
    source,
    'fetch_remote_schema "$JIT_REMOTE"',
    '(cd "$FIXED_STAGE" && base44_cli entities push)',
  );
  assertBefore(
    source,
    'install_durable_json "$WORK/attempt.json"',
    '(cd "$FIXED_STAGE" && base44_cli entities push)',
  );
  assertBefore(
    source,
    '(cd "$FIXED_STAGE" && base44_cli entities push)',
    'install_durable_json "$WORK/postflight.json"',
  );
  assertStringIncludes(source, ".production-mutation.lock");
  assertStringIncludes(source, 'status:"mutation-started-postflight-required"');
  assertStringIncludes(source, "postflight_required:true");
});

Deno.test("notification runbook requires Step 0 before additive notification schema", async () => {
  const runbook = await Deno.readTextFile(runbookURL);
  assertBefore(
    runbook,
    "## Step 0: restore the approved final 20-entity boundary",
    "## Step A: additive notification schema",
  );
  for (
    const value of [
      expectedAppID,
      expectedDriftedDigest,
      expectedFinalDigest,
      expectedHistoricalPlan,
      "BASE44_CONFIRM_NOTIFICATION_SCHEMA_REPAIR_PLAN_DIGEST",
    ]
  ) {
    assertStringIncludes(runbook, value);
  }
  assertStringIncludes(runbook, "removes zero fields");
  assertStringIncludes(runbook, "adds or deletes zero");
  assertStringIncludes(runbook, "entities. Required lists do not change.");
});
