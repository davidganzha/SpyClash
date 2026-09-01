import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  registerDevice,
  registerLiveActivity,
  unregisterInstallation,
  unregisterLiveActivity,
} from "./device-registration.ts";
import {
  claimLiveDelivery,
  completeLiveDelivery,
  forcedLiveEndFailurePatch,
  MAX_LIVE_DELIVERY_ATTEMPTS,
  queueLiveRetry,
} from "./live-delivery.ts";
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
  async updateMany(
    filter: Record<string, any>,
    update: Record<string, any>,
  ) {
    let updated = 0;
    this.records = this.records.map((record) => {
      if (
        !Object.entries(filter).every(([key, value]) => record[key] === value)
      ) return record;
      updated += 1;
      return { ...record, ...(update.$set || {}) };
    });
    return { updated };
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
    assertEquals(saved.delivery_state, "retry");
    assertEquals(saved.retry_requested, true);
    assertEquals(saved.pending_force_end, false);
    assertEquals(saved.pending_room_id, "room-1");
    assertEquals(saved.pending_match_id, "random-match");
    assertEquals(Boolean(saved.terminal_probe_started_at), true);
    assertEquals(Boolean(saved.terminal_probe_until), true);
    const staleReplica = await registerLiveActivity({
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
    });
    assertEquals(staleReplica.delivery_state, "retry");
    assertEquals(staleReplica.pending_force_end, false);
    assertEquals(Boolean(staleReplica.terminal_probe_started_at), true);
  });
});

Deno.test("late same-activity registration preserves a queued force end", async () => {
  await withEncryptionSecret(async () => {
    const fixture = await unregisterFixture();
    const liveStore = new Store([fixture.registration]);
    assertEquals(
      await queueLiveRetry({
        store: liveStore,
        registrationID: fixture.registration.id,
        roomID: "room-1",
        matchID: "match-1",
        roomRevision: 100,
        forceEnd: true,
        now: new Date("2026-09-01T12:00:00.000Z"),
      }),
      true,
    );

    const saved = await registerLiveActivity({
      liveActivityStore: liveStore,
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "playing",
        updated_date: "2026-09-01T12:00:00.000Z",
        participant_user_ids: ["player-1"],
      }]),
      userID: "player-1",
      body: {
        installation_id: fixture.installationID,
        live_activity_token: "ba".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: fixture.activityID,
        room_id: "room-1",
        match_id: "match-1",
      },
      persist: async (writer) => await writer(),
      now: new Date("2026-09-01T12:00:01.000Z"),
    });

    assertEquals(saved.id, fixture.registration.id);
    assertEquals(saved.status, "active");
    assertEquals(saved.delivery_state, "retry");
    assertEquals(saved.retry_requested, true);
    assertEquals(saved.pending_force_end, true);
    assertEquals(saved.pending_room_id, "room-1");
    assertEquals(saved.pending_match_id, "match-1");
    assertEquals(
      liveStore.records.some((row) => row.delivery_state === "idle"),
      false,
    );
  });
});

Deno.test("late registration against a finished room starts as a durable force end", async () => {
  await withEncryptionSecret(async () => {
    const liveStore = new Store();
    const saved = await registerLiveActivity({
      liveActivityStore: liveStore,
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "finished",
        game_finished_event_id: "game-finished:match-1",
        updated_date: "2026-09-01T12:00:00.000Z",
        participant_user_ids: ["player-1"],
      }]),
      userID: "player-1",
      body: {
        installation_id: "installation-late-finished",
        live_activity_token: "bc".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: "activity-late-finished",
        room_id: "room-1",
        match_id: "match-1",
      },
      persist: async (writer) => await writer(),
      now: new Date("2026-09-01T12:00:01.000Z"),
    });

    assertEquals(saved.status, "active");
    assertEquals(saved.delivery_state, "retry");
    assertEquals(saved.pending_force_end, true);
    assertEquals(saved.pending_room_id, "room-1");
    assertEquals(saved.pending_match_id, "match-1");
    assertEquals(saved.pending_room_revision, 1_788_264_000_000);
    assertEquals(
      saved.pending_force_end_commit_id,
      "game-finished:match-1",
    );
  });
});

Deno.test("a finished replica from another match cannot terminalize a new token", async () => {
  await withEncryptionSecret(async () => {
    const saved = await registerLiveActivity({
      liveActivityStore: new Store(),
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-old",
        status: "finished",
        game_finished_event_id: "game-finished:match-old",
        participant_user_ids: ["player-1"],
      }]),
      userID: "player-1",
      body: {
        installation_id: "installation-new-match",
        live_activity_token: "cc".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: "activity-new-match",
        room_id: "room-1",
        match_id: "match-new",
      },
      persist: async (writer) => await writer(),
    });
    assertEquals(saved.pending_force_end, false);
    assertEquals(saved.pending_force_end_commit_id, null);
    assertEquals(Boolean(saved.terminal_probe_started_at), true);
  });
});

Deno.test("committed finish outbox dominates a stale room even after delivery cancellation", async () => {
  await withEncryptionSecret(async () => {
    const liveStore = new Store();
    const saved = await registerLiveActivity({
      liveActivityStore: liveStore,
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "playing",
        updated_date: "2026-09-01T12:00:00.000Z",
        participant_user_ids: ["player-1"],
      }]),
      eventStore: new Store([{
        dedupe_key: "game_finished:game-finished:match-1:player-1",
        source_event_id: "game-finished:match-1",
        event_type: "game_finished",
        source_type: "game_room",
        recipient_user_id: "player-1",
        room_id: "room-1",
        match_id: "match-1",
        inbox_visible: false,
        inbox_committed_at: "2026-09-01T12:00:00.500Z",
        state: "cancelled",
      }]),
      userID: "player-1",
      body: {
        installation_id: "installation-stale-finish",
        live_activity_token: "be".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: "activity-stale-finish",
        room_id: "room-1",
        match_id: "match-1",
      },
      persist: async (writer) => await writer(),
      now: new Date("2026-09-01T12:00:01.000Z"),
    });
    assertEquals(saved.delivery_state, "retry");
    assertEquals(saved.pending_force_end, true);
    assertEquals(
      saved.pending_force_end_commit_id,
      "game-finished:match-1",
    );
  });
});

Deno.test("committed close signal dominates a stale playing room for a first late token", async () => {
  await withEncryptionSecret(async () => {
    const saved = await registerLiveActivity({
      liveActivityStore: new Store(),
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "playing",
        updated_date: "2026-09-01T12:00:00.000Z",
        participant_user_ids: ["player-1"],
      }]),
      signalStore: new Store([{
        id: "signal-1",
        user_id: "player-1",
        room_id: "room-1",
        state: "closed",
        close_intent_id: "close-1",
        close_match_id: "match-1",
      }]),
      userID: "player-1",
      body: {
        installation_id: "installation-stale-close",
        live_activity_token: "ce".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: "activity-stale-close",
        room_id: "room-1",
        match_id: "match-1",
      },
      persist: async (writer) => await writer(),
      now: new Date("2026-09-01T12:00:01.000Z"),
    });

    assertEquals(saved.delivery_state, "retry");
    assertEquals(saved.retry_requested, true);
    assertEquals(saved.pending_force_end, true);
    assertEquals(
      saved.pending_force_end_commit_id,
      "room-close:match-1:close-1",
    );
  });
});

Deno.test("an uncommitted finish outbox cannot terminalize a late token", async () => {
  await withEncryptionSecret(async () => {
    const saved = await registerLiveActivity({
      liveActivityStore: new Store(),
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "playing",
        participant_user_ids: ["player-1"],
      }]),
      eventStore: new Store([{
        dedupe_key: "game_finished:game-finished:match-1:player-1",
        source_event_id: "game-finished:match-1",
        event_type: "game_finished",
        source_type: "game_room",
        recipient_user_id: "player-1",
        room_id: "room-1",
        match_id: "match-1",
        inbox_committed_at: null,
        state: "pending",
      }]),
      userID: "player-1",
      body: {
        installation_id: "installation-uncommitted-finish",
        live_activity_token: "bf".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: "activity-uncommitted-finish",
        room_id: "room-1",
        match_id: "match-1",
      },
      persist: async (writer) => await writer(),
    });
    assertEquals(saved.delivery_state, "retry");
    assertEquals(saved.retry_requested, true);
    assertEquals(saved.pending_force_end, false);
    assertEquals(saved.pending_force_end_commit_id, null);
    assertEquals(Boolean(saved.terminal_probe_started_at), true);
    assertEquals(Boolean(saved.terminal_probe_until), true);
  });
});

Deno.test("late registration against a logical close starts as a forced end", async () => {
  await withEncryptionSecret(async () => {
    const liveStore = new Store();
    const saved = await registerLiveActivity({
      liveActivityStore: liveStore,
      roomStore: new Store([{
        id: "room-1",
        match_id: "match-1",
        status: "playing",
        updated_date: "2026-09-01T12:00:00.000Z",
        participant_user_ids: ["player-1"],
        close_intent: {
          id: "close-1",
          room_id: "room-1",
          match_id: "match-1",
        },
      }]),
      userID: "player-1",
      body: {
        installation_id: "installation-logical-close",
        live_activity_token: "bd".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: "activity-logical-close",
        room_id: "room-1",
        match_id: "match-1",
      },
      persist: async (writer) => await writer(),
      now: new Date("2026-09-01T12:00:01.000Z"),
    });

    assertEquals(saved.status, "active");
    assertEquals(saved.delivery_state, "retry");
    assertEquals(saved.retry_requested, true);
    assertEquals(saved.pending_force_end, true);
    assertEquals(saved.pending_room_id, "room-1");
    assertEquals(saved.pending_match_id, "match-1");
  });
});

Deno.test("late registration for a missing room cannot replace a queued end with idle", async () => {
  await withEncryptionSecret(async () => {
    const fixture = await unregisterFixture();
    const liveStore = new Store([fixture.registration]);
    await queueLiveRetry({
      store: liveStore,
      registrationID: fixture.registration.id,
      roomID: "room-1",
      matchID: "match-1",
      roomRevision: 100,
      forceEnd: true,
      now: new Date("2026-09-01T12:00:00.000Z"),
    });

    const saved = await registerLiveActivity({
      liveActivityStore: liveStore,
      roomStore: new Store(),
      userID: "player-1",
      body: {
        installation_id: fixture.installationID,
        live_activity_token: "bd".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: fixture.activityID,
        room_id: "room-1",
        match_id: "match-1",
      },
      persist: async (writer) => await writer(),
    });
    assertEquals(saved.delivery_state, "retry");
    assertEquals(saved.pending_force_end, true);

    assertEquals(liveStore.records.length, 1);
    assertEquals(liveStore.records[0].delivery_state, "retry");
    assertEquals(liveStore.records[0].pending_force_end, true);
    assertEquals(
      liveStore.records.some((row) => row.delivery_state === "idle"),
      false,
    );
  });
});

Deno.test("a first token survives simultaneous missing room and marker reads as probation", async () => {
  await withEncryptionSecret(async () => {
    const liveStore = new Store();
    const saved = await registerLiveActivity({
      liveActivityStore: liveStore,
      roomStore: new Store(),
      eventStore: new Store(),
      signalStore: new Store(),
      userID: "player-1",
      body: {
        installation_id: "installation-probation",
        live_activity_token: "bf".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: "activity-probation",
        room_id: "room-1",
        match_id: "match-1",
      },
      persist: async (writer) => await writer(),
      now: new Date("2026-09-01T12:00:01.000Z"),
    });
    assertEquals(liveStore.records.length, 1);
    assertEquals(saved.delivery_state, "retry");
    assertEquals(saved.retry_requested, true);
    assertEquals(saved.pending_force_end, false);
    assertEquals(Boolean(saved.terminal_probe_started_at), true);
    assertEquals(Boolean(saved.terminal_probe_until), true);
  });
});

Deno.test("personal close receipt authorizes a first token after physical room deletion", async () => {
  await withEncryptionSecret(async () => {
    const saved = await registerLiveActivity({
      liveActivityStore: new Store(),
      roomStore: new Store(),
      signalStore: new Store([{
        id: "signal-1",
        user_id: "player-1",
        room_id: "room-1",
        state: "closed",
        close_intent_id: "close-1",
        close_match_id: "match-1",
      }]),
      userID: "player-1",
      body: {
        installation_id: "installation-after-delete",
        live_activity_token: "cf".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: "activity-after-delete",
        room_id: "room-1",
        match_id: "match-1",
      },
      persist: async (writer) => await writer(),
      now: new Date("2026-09-01T12:00:01.000Z"),
    });

    assertEquals(saved.delivery_state, "retry");
    assertEquals(saved.pending_force_end, true);
    assertEquals(
      saved.pending_force_end_commit_id,
      "room-close:match-1:close-1",
    );
    assertEquals(saved.terminal_probe_until, null);
  });
});

Deno.test("new match registration preserves an older pending activity end on the installation", async () => {
  await withEncryptionSecret(async () => {
    const installationID = "installation-replay";
    const oldActivityID = "activity-old";
    const liveStore = new Store([{
      id: "old-pending-end",
      user_id: "player-1",
      installation_id_hash: await digest(installationID, "installation"),
      activity_id_hash: await digest(oldActivityID, "live-activity"),
      token_kind: "activity",
      token_hash: "old-token",
      status: "active",
      room_id: "room-old",
      match_id: "match-old",
      provider_match_id: "match-old",
      delivery_state: "retry",
      delivery_revision: "old-delivery",
      retry_requested: true,
      pending_force_end: true,
      pending_room_id: "room-old",
      pending_match_id: "match-old",
      pending_room_revision: 100,
    }]);

    const saved = await registerLiveActivity({
      liveActivityStore: liveStore,
      roomStore: new Store([{
        id: "room-new",
        match_id: "match-new",
        status: "playing",
        participant_user_ids: ["player-1"],
      }]),
      userID: "player-1",
      body: {
        installation_id: installationID,
        live_activity_token: "be".repeat(32),
        token_kind: "activity",
        environment: "sandbox",
        bundle_id: "com.spyclash.ios",
        activity_id: "activity-new",
        room_id: "room-new",
        match_id: "match-new",
      },
      persist: async (writer) => await writer(),
    });

    assertEquals(saved.room_id, "room-new");
    assertEquals(saved.delivery_state, "retry");
    assertEquals(saved.retry_requested, true);
    assertEquals(saved.pending_force_end, false);
    assertEquals(typeof saved.terminal_probe_started_at, "string");
    assertEquals(typeof saved.terminal_probe_until, "string");
    assertEquals(liveStore.records.length, 2);
    const old = liveStore.records.find((row) => row.id === "old-pending-end")!;
    assertEquals(old.status, "active");
    assertEquals(old.delivery_state, "retry");
    assertEquals(old.pending_force_end, true);
  });
});

Deno.test("probation preserves a confirmed same-install activity while pruning garbage", async () => {
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
        row.id === "same-installation-old-activity"
      ),
      true,
    );
    assertEquals(
      liveStore.records.some((row) =>
        ["system-expired-activity", "ended-activity"].includes(row.id)
      ),
      false,
    );
    assertEquals(
      liveStore.records.filter((row) => row.status === "active").length,
      16,
    );
  });
});

Deno.test("queued force end survives exact client unregister until delivery", async () => {
  const installationID = "installation-0001";
  const activityID = "activity-1";
  const liveStore = new Store([{
    id: "live-queued-end",
    user_id: "player-1",
    installation_id_hash: await digest(installationID, "installation"),
    activity_id_hash: await digest(activityID, "live-activity"),
    token_kind: "activity",
    token_hash: "activity-token",
    status: "active",
    room_id: "room-1",
    match_id: "match-1",
    provider_match_id: "match-1",
    delivery_state: "idle",
    delivery_revision: "delivery-1",
    delivery_lease_until: "2026-09-01T12:00:00.000Z",
    delivery_attempt_count: 0,
    pending_room_revision: 0,
  }]);

  assertEquals(
    await queueLiveRetry({
      store: liveStore,
      registrationID: "live-queued-end",
      roomID: "room-1",
      matchID: "match-1",
      roomRevision: 10,
      forceEnd: true,
      now: new Date("2026-09-01T12:00:01.000Z"),
    }),
    true,
  );

  await unregisterLiveActivity({
    liveActivityStore: liveStore,
    roomStore: new Store(),
    userID: "player-1",
    body: {
      installation_id: installationID,
      token_kind: "activity",
      activity_id: activityID,
    },
    persist: async (writer) => await writer(),
  });

  assertEquals(liveStore.records.length, 1);
  assertEquals(liveStore.records[0].id, "live-queued-end");
  assertEquals(liveStore.records[0].status, "active");
  assertEquals(liveStore.records[0].pending_force_end, true);
  assertEquals(liveStore.records[0].pending_room_id, "room-1");
  assertEquals(liveStore.records[0].pending_match_id, "match-1");
  assertEquals(liveStore.records[0].delivery_state, "retry");
});

Deno.test("installation unregister preserves and repairs a pending activity end", async () => {
  const fixture = await unregisterFixture();
  const deviceStore = new Store([{
    id: "device-1",
    user_id: "player-1",
    installation_id_hash: fixture.registration.installation_id_hash,
  }]);
  const liveStore = new Store([{
    ...fixture.registration,
    delivery_state: "failed",
    retry_requested: false,
    pending_force_end: true,
    pending_room_id: "room-1",
    pending_match_id: "match-1",
    pending_room_revision: 100,
  }]);

  await unregisterInstallation({
    deviceStore,
    liveActivityStore: liveStore,
    userID: "player-1",
    installationID: fixture.installationID,
    persist: async (writer) => await writer(),
  });

  assertEquals(deviceStore.records, []);
  assertEquals(liveStore.records.length, 1);
  assertEquals(liveStore.records[0].delivery_state, "retry");
  assertEquals(liveStore.records[0].retry_requested, true);
  assertEquals(liveStore.records[0].pending_force_end, true);
});

Deno.test("unregister requeues legacy failed or idle pending force ends", async () => {
  for (const deliveryState of ["failed", "idle"]) {
    const fixture = await unregisterFixture();
    const liveStore = new Store([{
      ...fixture.registration,
      delivery_state: deliveryState,
      retry_requested: true,
      pending_force_end: true,
      pending_room_id: "room-1",
      pending_match_id: "match-1",
      pending_room_revision: 100,
    }]);

    await unregisterFixtureActivity({
      liveStore,
      roomStore: new Store(),
      installationID: fixture.installationID,
      activityID: fixture.activityID,
    });

    assertEquals(liveStore.records.length, 1);
    assertEquals(liveStore.records[0].status, "active");
    assertEquals(liveStore.records[0].delivery_state, "retry");
    assertEquals(liveStore.records[0].retry_requested, true);
    assertEquals(liveStore.records[0].pending_force_end, true);
  }
});

async function unregisterFixture() {
  const installationID = "installation-unregister";
  const activityID = "activity-unregister";
  return {
    installationID,
    activityID,
    registration: {
      id: "live-unregister",
      user_id: "player-1",
      installation_id_hash: await digest(installationID, "installation"),
      activity_id_hash: await digest(activityID, "live-activity"),
      token_kind: "activity",
      token_hash: "activity-token",
      status: "active",
      room_id: "room-1",
      match_id: "match-1",
      provider_match_id: "match-1",
      delivery_state: "idle",
      delivery_revision: "delivery-1",
      delivery_lease_until: "2026-09-01T12:00:00.000Z",
      delivery_attempt_count: 0,
      pending_room_revision: 0,
    },
  };
}

async function unregisterFixtureActivity(input: {
  liveStore: Store;
  roomStore: Store;
  installationID: string;
  activityID: string;
}) {
  await unregisterLiveActivity({
    liveActivityStore: input.liveStore,
    roomStore: input.roomStore,
    userID: "player-1",
    body: {
      installation_id: input.installationID,
      token_kind: "activity",
      activity_id: input.activityID,
    },
    persist: async (writer) => await writer(),
    now: new Date("2026-09-01T12:00:01.000Z"),
  });
}

Deno.test("finished authoritative room converts unregister into durable force end", async () => {
  const fixture = await unregisterFixture();
  const liveStore = new Store([fixture.registration]);
  await unregisterFixtureActivity({
    liveStore,
    roomStore: new Store([{
      id: "room-1",
      match_id: "match-1",
      status: "finished",
      updated_date: "2026-09-01T12:00:00.000Z",
    }]),
    installationID: fixture.installationID,
    activityID: fixture.activityID,
  });

  assertEquals(liveStore.records.length, 1);
  assertEquals(liveStore.records[0].pending_force_end, true);
  assertEquals(liveStore.records[0].delivery_state, "retry");
  assertEquals(liveStore.records[0].pending_room_id, "room-1");
  assertEquals(liveStore.records[0].pending_match_id, "match-1");
});

Deno.test("missing authoritative room converts unregister into durable force end", async () => {
  const fixture = await unregisterFixture();
  const liveStore = new Store([fixture.registration]);
  await unregisterFixtureActivity({
    liveStore,
    roomStore: new Store(),
    installationID: fixture.installationID,
    activityID: fixture.activityID,
  });

  assertEquals(liveStore.records.length, 1);
  assertEquals(liveStore.records[0].pending_force_end, true);
  assertEquals(liveStore.records[0].delivery_state, "retry");
});

Deno.test("closed authoritative room converts unregister into durable force end", async () => {
  const fixture = await unregisterFixture();
  const liveStore = new Store([fixture.registration]);
  await unregisterFixtureActivity({
    liveStore,
    roomStore: new Store([{
      id: "room-1",
      match_id: "match-1",
      status: "closed",
      updated_date: "2026-09-01T12:00:00.000Z",
    }]),
    installationID: fixture.installationID,
    activityID: fixture.activityID,
  });

  assertEquals(liveStore.records.length, 1);
  assertEquals(liveStore.records[0].pending_force_end, true);
  assertEquals(liveStore.records[0].delivery_state, "retry");
});

Deno.test("logical-close room converts unregister into a durable force end", async () => {
  const fixture = await unregisterFixture();
  const liveStore = new Store([fixture.registration]);
  await unregisterFixtureActivity({
    liveStore,
    roomStore: new Store([{
      id: "room-1",
      match_id: "match-1",
      status: "playing",
      updated_date: "2026-09-01T12:00:00.000Z",
      close_intent: {
        id: "close-1",
        room_id: "room-1",
        match_id: "match-1",
      },
    }]),
    installationID: fixture.installationID,
    activityID: fixture.activityID,
  });

  assertEquals(liveStore.records.length, 1);
  assertEquals(liveStore.records[0].pending_force_end, true);
  assertEquals(liveStore.records[0].delivery_state, "retry");
});

Deno.test("active exact room match keeps ordinary unregister deletion", async () => {
  const fixture = await unregisterFixture();
  const liveStore = new Store([fixture.registration]);
  await unregisterFixtureActivity({
    liveStore,
    roomStore: new Store([{
      id: "room-1",
      match_id: "match-1",
      status: "playing",
    }]),
    installationID: fixture.installationID,
    activityID: fixture.activityID,
  });

  assertEquals(liveStore.records, []);
});

Deno.test("unregister during pending end leaves no active row after terminal failure", async () => {
  const fixture = await unregisterFixture();
  const liveStore = new Store([{
    ...fixture.registration,
    delivery_state: "retry",
    delivery_attempt_count: MAX_LIVE_DELIVERY_ATTEMPTS - 1,
    pending_force_end: true,
    pending_room_id: "room-1",
    pending_match_id: "match-1",
    pending_room_revision: 100,
  }]);
  assertEquals(
    await queueLiveRetry({
      store: liveStore,
      registrationID: fixture.registration.id,
      roomID: "room-1",
      matchID: "match-1",
      roomRevision: 100,
      forceEnd: true,
      now: new Date("2026-09-01T12:00:00.000Z"),
    }),
    true,
  );
  await unregisterFixtureActivity({
    liveStore,
    roomStore: new Store(),
    installationID: fixture.installationID,
    activityID: fixture.activityID,
  });
  assertEquals(liveStore.records.length, 1);
  assertEquals(liveStore.records[0].pending_force_end, true);

  const claimed = await claimLiveDelivery({
    store: liveStore,
    registration: structuredClone(liveStore.records[0]),
    roomID: "room-1",
    matchID: "match-1",
    roomRevision: 100,
    forceEnd: true,
    now: new Date("2026-09-01T12:00:02.000Z"),
    randomUUID: () => "last-attempt",
  });
  assertEquals(claimed?.delivery_attempt_count, MAX_LIVE_DELIVERY_ATTEMPTS);
  assertEquals(
    await completeLiveDelivery({
      store: liveStore,
      claimed: claimed!,
      state: "failed",
      errorCode: "nonretryable",
      patch: forcedLiveEndFailurePatch(
        false,
        new Date("2026-09-01T12:00:03.000Z"),
      ),
      now: new Date("2026-09-01T12:00:03.000Z"),
      randomUUID: () => "terminal",
    }),
    true,
  );

  assertEquals(
    liveStore.records.filter((row) => row.status === "active"),
    [],
  );
  assertEquals(liveStore.records[0].status, "ended");
  assertEquals(liveStore.records[0].ended_at, "2026-09-01T12:00:03.000Z");
  assertEquals(liveStore.records[0].pending_force_end, false);
});
