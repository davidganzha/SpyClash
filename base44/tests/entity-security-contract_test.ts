import { assert, assertEquals, assertStringIncludes } from "jsr:@std/assert@1";

type EntitySchema = {
  name: string;
  properties: Record<string, Record<string, unknown>>;
  required?: string[];
  rls?: Record<"create" | "read" | "update" | "delete", unknown>;
};

type Principal = {
  id: string;
  email: string;
  role: "admin" | "user";
  data?: Record<string, unknown>;
};

const entitiesURL = new URL("../entities/", import.meta.url);
const admin: Principal = {
  id: "admin-1",
  email: "admin@example.com",
  role: "admin",
};
const owner: Principal = {
  id: "user-1",
  email: "owner@example.com",
  role: "user",
};
const outsider: Principal = {
  id: "user-2",
  email: "outsider@example.com",
  role: "user",
};

const expectedEntityNames = [
  "AiGenerationQuota",
  "AiGenerationUsage",
  "AiWordPackCacheVariant",
  "AiWordPackRequestResult",
  "AppStoreAccount",
  "AppleSignInCredential",
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

const serverOnlyEntities = [
  "AiGenerationQuota",
  "AiGenerationUsage",
  "AiWordPackCacheVariant",
  "AiWordPackRequestResult",
  "AppStoreAccount",
  "AppleSignInCredential",
  "BillingIdentityLifecycle",
  "CommunityReport",
  "Entitlement",
  "Friendship",
  "GameRoom",
  "LiveActivityRegistration",
  "NotificationAnnouncement",
  "NotificationReadReceipt",
  "ProfileComment",
  "PushDeviceRegistration",
  "PushNotificationEvent",
  "RoomInvite",
  "WordPack",
] as const;

async function schemas(): Promise<Map<string, EntitySchema>> {
  const result = new Map<string, EntitySchema>();
  for await (const entry of Deno.readDir(entitiesURL)) {
    if (!entry.isFile || !entry.name.endsWith(".jsonc")) continue;
    const schema = JSON.parse(
      await Deno.readTextFile(new URL(entry.name, entitiesURL)),
    ) as EntitySchema;
    assert(schema.name, `${entry.name} must declare an entity name`);
    assert(!result.has(schema.name), `duplicate entity ${schema.name}`);
    result.set(schema.name, schema);
  }
  return result;
}

function userValue(user: Principal, key: string): unknown {
  if (key.startsWith("data.")) return user.data?.[key.slice(5)];
  return user[key as keyof Principal];
}

function resolveTemplate(value: unknown, user: Principal): unknown {
  if (typeof value !== "string") return value;
  const match = /^\{\{user\.(.+)\}\}$/.exec(value);
  return match ? userValue(user, match[1]) : value;
}

function valueMatches(actual: unknown, expected: unknown, user: Principal) {
  const resolved = resolveTemplate(expected, user);
  if (!resolved || typeof resolved !== "object" || Array.isArray(resolved)) {
    return actual === resolved;
  }
  const operators = resolved as Record<string, unknown>;
  if (Array.isArray(operators.$in)) return operators.$in.includes(actual);
  if (Array.isArray(operators.$nin)) return !operators.$nin.includes(actual);
  if ("$ne" in operators) return actual !== operators.$ne;
  if (Array.isArray(operators.$all)) {
    return Array.isArray(actual) &&
      operators.$all.every((item) => actual.includes(item));
  }
  return false;
}

function policyAllows(
  policy: unknown,
  row: Record<string, unknown>,
  user: Principal,
): boolean {
  if (policy === true) return true;
  if (!policy || policy === false || typeof policy !== "object") return false;
  const condition = policy as Record<string, unknown>;

  if (Array.isArray(condition.$or)) {
    return condition.$or.some((item) => policyAllows(item, row, user));
  }
  if (Array.isArray(condition.$and)) {
    return condition.$and.every((item) => policyAllows(item, row, user));
  }
  if (Array.isArray(condition.$nor)) {
    return !condition.$nor.some((item) => policyAllows(item, row, user));
  }
  if (condition.user_condition) {
    const expected = condition.user_condition as Record<string, unknown>;
    return Object.entries(expected).every(([key, value]) =>
      valueMatches(userValue(user, key), value, user)
    );
  }

  return Object.entries(condition).every(([key, expected]) => {
    const actual = key.startsWith("data.") ? row[key.slice(5)] : row[key];
    return valueMatches(actual, expected, user);
  });
}

function assertAdminOnlyPolicy(
  entity: EntitySchema,
  operation: "create" | "read" | "update" | "delete",
) {
  const policy = entity.rls?.[operation];
  assert(
    policyAllows(policy, {}, admin),
    `${entity.name}.${operation} must allow an authenticated admin`,
  );
  assert(
    !policyAllows(policy, {}, owner),
    `${entity.name}.${operation} must deny a regular authenticated user`,
  );
}

Deno.test("all 23 canonical entity schemas are explicit and parseable", async () => {
  const all = await schemas();
  assertEquals([...all.keys()].sort(), expectedEntityNames);

  for (const [name, schema] of all) {
    assertEquals(typeof schema.properties, "object", `${name}.properties`);
    if (name === "User") continue;
    for (const operation of ["create", "read", "update", "delete"] as const) {
      assert(
        schema.rls && operation in schema.rls,
        `${name} must declare ${operation} RLS`,
      );
    }
  }
});

Deno.test("server-owned entities deny direct user CRUD and allow service-role admins", async () => {
  const all = await schemas();
  for (const name of serverOnlyEntities) {
    const schema = all.get(name);
    assert(schema, `missing ${name}`);
    for (const operation of ["create", "read", "update", "delete"] as const) {
      assertAdminOnlyPolicy(schema, operation);
    }
  }
});

Deno.test("GameHistory authorizes only owner reads while all writes stay server-owned", async () => {
  const history = (await schemas()).get("GameHistory");
  assert(history?.rls);
  const stableOwnerRow = {
    player_user_id: owner.id,
    player_email: "old-address@example.com",
  };
  const legacyOwnerRow = { player_email: owner.email };

  assert(policyAllows(history.rls.read, stableOwnerRow, owner));
  assert(policyAllows(history.rls.read, legacyOwnerRow, owner));
  assert(!policyAllows(history.rls.read, stableOwnerRow, outsider));
  assert(!policyAllows(history.rls.read, legacyOwnerRow, outsider));
  assert(policyAllows(history.rls.read, stableOwnerRow, admin));

  for (const operation of ["create", "update", "delete"] as const) {
    assertAdminOnlyPolicy(history, operation);
  }

  for (const field of ["player_user_id", "match_id"]) {
    const fieldPolicy = history.properties[field]?.rls as
      | Record<string, unknown>
      | undefined;
    assert(fieldPolicy, `${field} must protect server writes`);
    assertEquals(
      fieldPolicy.read,
      undefined,
      `${field} must stay visible after the owner-scoped row read succeeds`,
    );
    assert(policyAllows(fieldPolicy.write, {}, admin));
    assert(!policyAllows(fieldPolicy.write, {}, owner));
  }
});

Deno.test("GameRoomSignal exposes only the caller's wake-up row and keeps writes server-owned", async () => {
  const signal = (await schemas()).get("GameRoomSignal");
  assert(signal?.rls);
  const ownerRow = {
    user_id: owner.id,
    room_id: "room-1",
    lobby_revision: 7,
    state: "active",
  };
  assert(policyAllows(signal.rls.read, ownerRow, owner));
  assert(!policyAllows(signal.rls.read, ownerRow, outsider));
  assert(policyAllows(signal.rls.read, ownerRow, admin));
  for (const operation of ["create", "update", "delete"] as const) {
    assertAdminOnlyPolicy(signal, operation);
  }
  assertEquals(signal.properties.state.enum, ["active", "closed"]);
  assertEquals(
    Object.keys(signal.properties).sort(),
    ["lobby_revision", "room_id", "state", "user_id"],
  );
});

Deno.test("MembershipGrant exposes only the caller's grant and hides support labels", async () => {
  const grant = (await schemas()).get("MembershipGrant");
  assert(grant?.rls);
  assert(policyAllows(grant.rls.read, { user_id: owner.id }, owner));
  assert(!policyAllows(grant.rls.read, { user_id: owner.id }, outsider));
  assert(policyAllows(grant.rls.read, { user_id: owner.id }, admin));
  for (const operation of ["create", "update", "delete"] as const) {
    assertAdminOnlyPolicy(grant, operation);
  }

  const labelPolicy = grant.properties.label?.rls as
    | Record<string, unknown>
    | undefined;
  assert(labelPolicy);
  assert(policyAllows(labelPolicy.read, {}, admin));
  assert(policyAllows(labelPolicy.write, {}, admin));
  assert(!policyAllows(labelPolicy.read, {}, owner));
  assert(!policyAllows(labelPolicy.write, {}, owner));
});

Deno.test("built-in User security is preserved and authority mirrors are admin-write", async () => {
  const user = (await schemas()).get("User");
  assert(user);
  assertEquals(user.rls, undefined, "Base44 owns the built-in User row rules");

  for (
    const builtIn of [
      "id",
      "email",
      "full_name",
      "role",
      "created_date",
      "updated_date",
    ]
  ) {
    assert(
      !(builtIn in user.properties),
      `User schema must not redefine built-in field ${builtIn}`,
    );
    assert(
      !user.required?.includes(builtIn),
      `User schema must not require built-in field ${builtIn}`,
    );
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
    const write = (user.properties[field]?.rls as Record<string, unknown>)
      ?.write;
    assert(policyAllows(write, {}, admin), `admin must write User.${field}`);
    assert(
      !policyAllows(write, {}, owner),
      `regular users must not write User.${field}`,
    );
  }

  for (
    const selfEditable of [
      "display_name",
      "avatar",
      "language",
      "spy_card_theme",
      "spy_card_accent",
      "spy_card_badge",
    ]
  ) {
    const write = (user.properties[selfEditable]?.rls as
      | Record<string, unknown>
      | undefined)?.write;
    assertEquals(
      write,
      undefined,
      `User.${selfEditable} must remain self-editable through auth.updateMe`,
    );
  }
});

Deno.test("release schemas contain every additive identity and Live Activity field", async () => {
  const all = await schemas();
  const requiredFields: Record<string, string[]> = {
    Friendship: ["blocked_by_id", "request_event_id"],
    GameHistory: ["player_user_id", "match_id", "match_type", "ranked"],
    GameRoom: [
      "participant_user_ids",
      "match_id",
      "terminal_intent",
      "game_started_event_id",
      "game_finished_event_id",
      "intro_started_at",
      "game_paused_at",
      "game_paused_total_seconds",
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
    ],
    GameRoomSignal: ["user_id", "room_id", "lobby_revision", "state"],
    RoomInvite: ["notification_event_id"],
    WordPack: ["owner_user_id"],
    AppStoreAccount: ["reservation_state"],
    Entitlement: ["write_revision"],
    LiveActivityRegistration: ["locale", "pending_force_end"],
    NotificationAnnouncement: [
      "importance",
      "status",
      "fanout_state",
      "fanout_revision",
      "fanout_phase",
      "fanout_cursor_registration_id",
      "fanout_cutoff_at",
      "fanout_enqueued_count",
      "action_deep_link",
    ],
    NotificationReadReceipt: ["user_id", "notification_key", "read_at"],
    PushDeviceRegistration: ["announcements_enabled"],
    PushNotificationEvent: [
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
    ],
    User: [
      "rating",
      "spy_id",
      "spy_card_theme",
      "spy_card_accent",
      "spy_card_badge",
    ],
  };

  for (const [name, fields] of Object.entries(requiredFields)) {
    const schema = all.get(name);
    assert(schema, `missing ${name}`);
    for (const field of fields) {
      assert(field in schema.properties, `${name}.${field} must be canonical`);
    }
  }

  for (
    const missingProductionEntity of [
      "AppleSignInCredential",
      "AiWordPackCacheVariant",
      "AiWordPackRequestResult",
    ]
  ) {
    assert(
      all.has(missingProductionEntity),
      `${missingProductionEntity} must be staged before guarded functions`,
    );
  }
});

Deno.test("mediated functions authenticate callers before service-role entity access", async () => {
  const guardedFunctions = [
    "communityAction",
    "gameRoomAction",
    "notificationAction",
    "pushNotificationAction",
    "wordPackAction",
  ];
  for (const name of guardedFunctions) {
    const source = await Deno.readTextFile(
      new URL(`../functions/${name}/main.ts`, import.meta.url),
    );
    assertStringIncludes(source, "createClientFromRequest(req)");
    if (name === "gameRoomAction") {
      assertStringIncludes(source, "resolveRoomActionUser({");
      const requestAuth = await Deno.readTextFile(
        new URL(
          "../functions/gameRoomAction/request-auth.ts",
          import.meta.url,
        ),
      );
      assertStringIncludes(requestAuth, ".auth.me()");
    } else {
      assertStringIncludes(source, ".auth.me()");
    }
    assertStringIncludes(source, "asServiceRole.entities");
  }

  const deletion = await Deno.readTextFile(
    new URL("../functions/deleteAccount/main.ts", import.meta.url),
  );
  assertStringIncludes(deletion, "const user = await base44.auth.me()");
  assertStringIncludes(deletion, "base44.asServiceRole.entities.User");

  const generation = await Deno.readTextFile(
    new URL("../functions/generateWordPack/main.ts", import.meta.url),
  );
  assertStringIncludes(
    generation,
    "base44.asServiceRole.entities.User.update(user.id",
  );
  assert(
    !generation.includes("base44.auth.updateMe("),
    "AI usage mirrors must not bypass User field authority",
  );
});
