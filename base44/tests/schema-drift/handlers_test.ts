import { entity, fixture, resetFixture } from "./sdk-stub.ts";

function assert(value: unknown, message = "assertion failed"): asserts value {
  if (!value) throw new Error(message);
}
function equal(actual: unknown, expected: unknown) {
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${JSON.stringify(actual)} != ${JSON.stringify(expected)}`,
  );
}
type Handler = (request: Request) => Promise<Response>;
const handlers: Handler[] = [];
const originalServe = Deno.serve;
Deno.serve = ((handler: Handler) => {
  handlers.push(handler);
  return {};
}) as any;
try {
  await import("../../functions/wordPackAction/main.ts");
  await import("../../functions/communityAction/main.ts");
  await import("../../functions/gameRoomAction/main.ts");
} finally {
  Deno.serve = originalServe;
}
async function invoke(
  index: number,
  action: string,
  extra: Record<string, unknown> = {},
) {
  const response = await handlers[index](
    new Request("https://example.invalid/function", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "Base44-App-Id": "69a0e57fa939f578082f8091",
        "Base44-Service-Authorization": "Bearer fixture-service",
      },
      body: JSON.stringify({ action, access_token: "fixture-token", ...extra }),
    }),
  );
  return { status: response.status, value: await response.json() };
}
function seedDecks() {
  entity("WordPack").rows = [
    {
      id: "legacy",
      name: "Legacy places",
      words: ["Harbor", "Museum"],
      owner_email: fixture.user.email,
    },
    {
      id: "stable",
      name: "Stable places",
      words: ["Airport", "Vault"],
      owner_user_id: fixture.user.id,
      owner_email: "old-email@example.test",
    },
    {
      id: "both",
      name: "Both ownership fields",
      words: ["Castle", "Park"],
      owner_user_id: fixture.user.id,
      owner_email: fixture.user.email,
    },
    {
      id: "foreign",
      name: "Another user's deck",
      words: ["Private", "Words"],
      owner_user_id: "someone-else",
      owner_email: "someone-else@example.test",
    },
    {
      id: "reused-email",
      name: "Stable ownership wins",
      words: ["Private", "Words"],
      owner_user_id: "someone-else",
      owner_email: fixture.user.email,
    },
  ];
}

Deno.test("observed schema reproduces the deck 400, additive repair loads only owned decks", async () => {
  resetFixture();
  seedDecks();
  const before = await invoke(0, "list");
  equal(before.status, 400);
  assert(
    fixture.calls.some((call) =>
      call.entity === "WordPack" && call.query?.owner_user_id
    ),
  );

  resetFixture(true);
  seedDecks();
  const after = await invoke(0, "list");
  equal(after.status, 200);
  equal(after.value.map((pack: any) => pack.id), ["both", "legacy", "stable"]);
  assert(
    after.value.every((pack: any) => !Object.hasOwn(pack, "owner_user_id")),
    "private ownership key must stay out of client projection",
  );
});

Deno.test("restored schema preserves pagination and deduplicates overlapping ownership queries", async () => {
  resetFixture(true);
  entity("WordPack").rows = Array.from({ length: 201 }, (_, i) => ({
    id: `pack-${String(i).padStart(3, "0")}`,
    name: `Pack ${String(i).padStart(3, "0")}`,
    words: ["Harbor", "Museum"],
    owner_user_id: fixture.user.id,
    owner_email: fixture.user.email,
    created_date: new Date(Date.UTC(2026, 0, 1, 0, 0, i)).toISOString(),
  }));
  const result = await invoke(0, "list");
  equal(result.status, 200);
  equal(result.value.length, 201);
  equal(new Set(result.value.map((pack: any) => pack.id)).size, 201);
  equal(result.value.at(-1).id, "pack-200");
  equal(
    fixture.calls.filter((call) =>
      call.entity === "WordPack" && call.query?.owner_user_id
    ).map((call) => call.skip),
    [0, 100, 200],
  );
  equal(
    fixture.calls.filter((call) =>
      call.entity === "WordPack" && call.query?.owner_email
    ).map((call) => call.skip),
    [0, 100, 200],
  );
});

Deno.test("restoring spy_id fixes community state without hiding its failed request", async () => {
  resetFixture();
  const before = await invoke(1, "state");
  equal(before.status, 400);
  assert(
    fixture.calls.some((call) =>
      call.entity === "User" && call.query?.spy_id === fixture.user.spy_id
    ),
  );

  resetFixture(true);
  const after = await invoke(1, "state");
  equal(after.status, 200);
  equal(after.value.me.spy_id, "123-456");
  equal(after.value.friends, []);
});

Deno.test("restored schemas save room revisions then load lobby decks and community successfully", async () => {
  resetFixture();
  seedDecks();
  const before = await invoke(2, "create_room", {
    player: { email: fixture.user.email, name: "Fixture", avatar: "🕵️" },
    client_capabilities: ["multi_spy_v1", "fan_mode_v1", "fan_mode_v2"],
  });
  equal(before.status, 200);
  const unversioned = await entity("GameRoom").get(before.value.id);
  assert(unversioned);
  assert(!Object.hasOwn(unversioned, "room_revision"));
  assert(!Object.hasOwn(unversioned, "participant_user_ids"));
  equal((await invoke(0, "list")).status, 400);
  equal((await invoke(1, "state")).status, 400);

  resetFixture(true);
  seedDecks();
  const created = await invoke(2, "create_room", {
    player: { email: fixture.user.email, name: "Fixture", avatar: "🕵️" },
    client_capabilities: ["multi_spy_v1", "fan_mode_v1", "fan_mode_v2"],
  });
  equal(created.status, 200);
  assert(created.value.id && created.value.code);
  const persisted = await entity("GameRoom").get(created.value.id);
  assert(persisted);
  equal(persisted.participant_user_ids, [fixture.user.id]);
  equal(persisted.room_revision, 0);
  equal(persisted.lobby_revision, 0);
  assert(persisted.room_last_write_token.startsWith("created:"));
  equal((await invoke(0, "list")).status, 200);
  equal((await invoke(1, "state")).status, 200);
  equal((await invoke(2, "get_room", { room_id: persisted.id })).status, 200);
});

Deno.test("schema repair remains compatible with an empty library and rejects missing auth", async () => {
  resetFixture(true);
  const empty = await invoke(0, "list");
  equal(empty, { status: 200, value: [] });
  equal((await invoke(0, "list", { access_token: "" })).status, 401);
});
