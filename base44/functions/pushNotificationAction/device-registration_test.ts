import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { registerDevice, registerLiveActivity } from "./device-registration.ts";
import { digest } from "./token-crypto.ts";

class Store {
  constructor(public records: Record<string, any>[] = []) {}
  async filter(
    filter: Record<string, any>,
    _sort?: string,
    limit = 100,
    skip = 0,
  ) {
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    ).slice(skip, skip + limit).map((record) => structuredClone(record));
  }
  async create(record: Record<string, any>) {
    const saved = { id: `row-${this.records.length + 1}`, ...record };
    this.records.push(saved);
    return structuredClone(saved);
  }
  async update(id: string, patch: Record<string, any>) {
    const index = this.records.findIndex((record) => record.id === id);
    if (index < 0) throw new Error("missing row");
    this.records[index] = { ...this.records[index], ...patch };
    return structuredClone(this.records[index]);
  }
  async delete(id: string) {
    this.records = this.records.filter((record) => record.id !== id);
  }
}

async function withEncryptionSecret<T>(action: () => Promise<T>): Promise<T> {
  const previous = Deno.env.get("PUSH_TOKEN_ENCRYPTION_KEY");
  Deno.env.set("PUSH_TOKEN_ENCRYPTION_KEY", "22".repeat(32));
  try {
    return await action();
  } finally {
    if (previous === undefined) Deno.env.delete("PUSH_TOKEN_ENCRYPTION_KEY");
    else Deno.env.set("PUSH_TOKEN_ENCRYPTION_KEY", previous);
  }
}

Deno.test("APNs token can move accounts only while both deletion-safe leases are held", async () => {
  await withEncryptionSecret(async () => {
    const token = "ab".repeat(32);
    const store = new Store([{
      id: "old-row",
      user_id: "old-user",
      token_hash: await digest(token, "apns-token"),
      installation_id_hash: "old-install",
    }]);
    await assertRejects(() =>
      registerDevice({
        deviceStore: store,
        userID: "new-user",
        body: {
          installation_id: "installation-0001",
          apns_token: token,
          environment: "sandbox",
          bundle_id: "com.spyclash.ios",
          alert_authorized: true,
        },
        persist: async (writer) => await writer(),
        leasedUserIDs: ["new-user"],
      })
    );
    const saved = await registerDevice({
      deviceStore: store,
      userID: "new-user",
      body: {
        installation_id: "installation-0001",
        apns_token: token,
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        alert_authorized: true,
      },
      persist: async (writer) => await writer(),
      leasedUserIDs: ["new-user", "old-user"],
    });
    assertEquals(saved.user_id, "new-user");
    assertEquals(store.records.map((record) => record.user_id), ["new-user"]);
    assertEquals("apns_token" in store.records[0], false);
  });
});

Deno.test("per-activity token requires the room's current match generation", async () => {
  await withEncryptionSecret(async () => {
    const roomStore = new Store([{
      id: "room-1",
      match_id: "random-match",
      participant_user_ids: ["player-1"],
      players: [{ user_id: "player-1", email: "player@example.com" }],
    }]);
    const liveStore = new Store();
    const saved = await registerLiveActivity({
      liveActivityStore: liveStore,
      roomStore,
      userID: "player-1",
      body: {
        installation_id: "installation-0001",
        live_activity_token: "cd".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        locale: "ru",
        activity_id: "activity-1",
        room_id: "room-1",
        match_id: "random-match",
      },
      persist: async (writer) => await writer(),
    });
    assertEquals(saved.match_id, "random-match");
    assertEquals(saved.provider_match_id, "random-match");
    assertEquals(saved.locale, "ru");
    await assertRejects(() =>
      registerLiveActivity({
        liveActivityStore: liveStore,
        roomStore,
        userID: "player-1",
        body: {
          installation_id: "installation-0001",
          live_activity_token: "ef".repeat(32),
          token_kind: "activity",
          environment: "sandbox",
          bundle_id: "com.spyclash.ios",
          activity_id: "activity-2",
          room_id: "room-1",
          match_id: "unrelated-match",
        },
        persist: async (writer) => await writer(),
      })
    );
  });
});

Deno.test("new activity prunes superseded, terminal, and system-expired rows before the cap", async () => {
  await withEncryptionSecret(async () => {
    const now = new Date("2026-07-15T12:00:00.000Z");
    const installationHash = await digest(
      "installation-0001",
      "installation",
    );
    const liveStore = new Store([
      {
        id: "same-installation-old-activity",
        user_id: "player-1",
        installation_id_hash: installationHash,
        token_kind: "activity",
        token_hash: "old-token",
        status: "active",
        created_at: "2026-07-15T11:00:00.000Z",
      },
      {
        id: "system-expired-activity",
        user_id: "player-1",
        installation_id_hash: "other-installation",
        token_kind: "activity",
        token_hash: "expired-token",
        status: "active",
        created_at: "2026-07-14T23:59:59.000Z",
      },
      {
        id: "ended-activity",
        user_id: "player-1",
        installation_id_hash: "third-installation",
        token_kind: "activity",
        token_hash: "ended-token",
        status: "ended",
        created_at: "2026-07-15T10:00:00.000Z",
      },
      ...Array.from({ length: 14 }, (_, index) => ({
        id: `push-to-start-${index}`,
        user_id: "player-1",
        installation_id_hash: `installation-${index + 10}`,
        token_kind: "push_to_start",
        token_hash: `push-token-${index}`,
        status: "active",
        created_at: "2026-07-15T10:00:00.000Z",
      })),
    ]);
    const roomStore = new Store([{
      id: "room-1",
      match_id: "match-1",
      participant_user_ids: ["player-1"],
    }]);

    const saved = await registerLiveActivity({
      liveActivityStore: liveStore,
      roomStore,
      userID: "player-1",
      body: {
        installation_id: "installation-0001",
        live_activity_token: "aa".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: "new-activity",
        room_id: "room-1",
        match_id: "match-1",
      },
      persist: async (writer) => await writer(),
      now,
    });

    assertEquals(saved.status, "active");
    assertEquals(
      liveStore.records.some((row) =>
        [
          "same-installation-old-activity",
          "system-expired-activity",
          "ended-activity",
        ].includes(row.id)
      ),
      false,
    );
    assertEquals(
      liveStore.records.filter((row) => row.status === "active").length,
      15,
    );
  });
});
