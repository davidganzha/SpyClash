import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  dueCommunityProfileRepairSources,
  ensureCommunityProfileRepairSource,
  pendingCommunityProfileRepairFields,
  repairCommunityProfileRecipients,
  runCommunityProfileRepair,
} from "./community-profile-repair-queue.ts";
import {
  replayResetMembershipPatch,
  replayVoteState,
} from "./replay-policy.ts";

type Entity = Record<string, any>;

class Store {
  records: Entity[];
  loseNextUpdateResponse = false;

  constructor(records: Entity[]) {
    this.records = structuredClone(records);
  }

  async filter(query: Entity, sort = "created_date", limit = 100, skip = 0) {
    const rows = this.records.filter((row) =>
      Object.entries(query).every(([key, value]) => row[key] === value)
    ).sort((left, right) =>
      String(left[sort] || "").localeCompare(
        String(right[sort] || ""),
      )
    );
    return structuredClone(rows.slice(skip, skip + limit));
  }

  async updateMany(query: Entity, update: Entity) {
    const matches = this.records.filter((row) =>
      Object.entries(query).every(([key, value]) => row[key] === value)
    );
    for (const row of matches) Object.assign(row, update.$set || {});
    if (this.loseNextUpdateResponse) {
      this.loseNextUpdateResponse = false;
      throw new Error("response lost");
    }
    return { updated: matches.length };
  }
}

function source(overrides: Entity = {}): Entity {
  return {
    id: "history-1",
    result_key: "game-result:v1:match-1:user-1",
    match_id: "match-1",
    player_user_id: "user-1",
    created_date: "2026-09-01T12:00:00.000Z",
    ...pendingCommunityProfileRepairFields(),
    ...overrides,
  };
}

Deno.test("history repair source is idempotent and recovers a lost update response", async () => {
  const store = new Store([source({
    profile_repair_state: undefined,
    profile_repair_attempt_count: undefined,
  })]);
  store.loseNextUpdateResponse = true;
  const ensured = await ensureCommunityProfileRepairSource({
    store,
    record: store.records[0],
  });
  assertEquals(ensured.profile_repair_state, "pending");
  assertEquals(ensured.profile_repair_attempt_count, 0);
  assertEquals(
    (await ensureCommunityProfileRepairSource({ store, record: ensured })).id,
    "history-1",
  );
});

Deno.test("failed repair keeps a durable leased source and succeeds after expiry", async () => {
  const store = new Store([source()]);
  const first = await runCommunityProfileRepair({
    store,
    source: store.records[0],
    now: new Date("2026-09-01T12:00:00.000Z"),
    leaseMilliseconds: 2_000,
    randomUUID: () => "first",
    repair: async () => false,
  });
  assertEquals(first.outcome, "failed");
  assertEquals(store.records[0].profile_repair_state, "processing");

  const deferred = await runCommunityProfileRepair({
    store,
    source: store.records[0],
    now: new Date("2026-09-01T12:00:01.000Z"),
    leaseMilliseconds: 2_000,
    randomUUID: () => "early",
    repair: async () => true,
  });
  assertEquals(deferred.outcome, "deferred");

  const retry = await runCommunityProfileRepair({
    store,
    source: store.records[0],
    now: new Date("2026-09-01T12:00:03.000Z"),
    leaseMilliseconds: 2_000,
    randomUUID: () => "retry",
    repair: async () => true,
  });
  assertEquals(retry.outcome, "performed");
  assertEquals(store.records[0].profile_repair_state, "completed");
  assertEquals(store.records[0].profile_repair_attempt_count, 2);
});

Deno.test("due scan cannot age an old leased source out behind newer rooms", async () => {
  const records = Array.from({ length: 30 }, (_, index) =>
    source({
      id: `history-${index}`,
      result_key: `result-${index}`,
      created_date: `2026-09-01T12:${String(index).padStart(2, "0")}:00.000Z`,
      profile_repair_state: index === 0 ? "processing" : "completed",
      profile_repair_lease_until: index === 0
        ? "2026-09-01T12:01:00.000Z"
        : "2026-09-01T12:00:00.000Z",
    }));
  records.push(source({
    id: "new-pending",
    result_key: "new-pending",
    created_date: "2026-09-01T13:00:00.000Z",
  }));
  const due = await dueCommunityProfileRepairSources({
    store: new Store(records),
    limit: 8,
    now: new Date("2026-09-01T12:03:00.000Z"),
  });
  assertEquals(due.map((row) => row.id), ["history-0", "new-pending"]);
});

Deno.test("repair source creation fails closed without a stable result", async () => {
  await assertRejects(() =>
    ensureCommunityProfileRepairSource({
      store: new Store([]),
      record: { result_key: "missing" },
    })
  );
});

Deno.test("failed profile repair survives a unanimous replay reset", async () => {
  const store = new Store([source()]);
  const failed = await runCommunityProfileRepair({
    store,
    source: store.records[0],
    now: new Date("2026-09-01T12:00:00.000Z"),
    leaseMilliseconds: 2_000,
    randomUUID: () => "before-replay",
    repair: async () => false,
  });
  assertEquals(failed.outcome, "failed");

  const finishedRoom = {
    status: "finished",
    host_email: "a@example.com",
    players: [
      { user_id: "user-a", email: "a@example.com" },
      { user_id: "user-b", email: "b@example.com" },
    ],
    participant_user_ids: ["user-a", "user-b"],
    departed_player_emails: [],
    ready_players: ["a@example.com", "b@example.com"],
  };
  assertEquals(replayVoteState(finishedRoom).unanimous, true);
  assertEquals(replayResetMembershipPatch(finishedRoom).players.length, 2);

  // GameRoom can now be reset or deleted; the canonical history row remains
  // independently discoverable after its failed claim expires.
  const due = await dueCommunityProfileRepairSources({
    store,
    limit: 8,
    now: new Date("2026-09-01T12:00:03.000Z"),
  });
  assertEquals(due.map((row) => row.id), ["history-1"]);
});

Deno.test("one unavailable recipient does not block survivor repair progress", async () => {
  const attempted: string[] = [];
  const result = await repairCommunityProfileRecipients({
    recipientUserIDs: ["user-a", "user-deleting", "user-b"],
    concurrency: 2,
    repairRecipient: async (userID) => {
      attempted.push(userID);
      if (userID === "user-deleting") throw new Error("deleting");
      return true;
    },
  });
  assertEquals(attempted, ["user-a", "user-deleting", "user-b"]);
  assertEquals(result, {
    attempted: 3,
    succeeded: 2,
    failedUserIDs: ["user-deleting"],
  });
});

Deno.test("repair completion recovers a lost update response without replay", async () => {
  const store = new Store([source()]);
  let repairs = 0;
  const result = await runCommunityProfileRepair({
    store,
    source: store.records[0],
    randomUUID: () => "completion-response-lost",
    repair: async () => {
      repairs += 1;
      store.loseNextUpdateResponse = true;
      return true;
    },
  });
  assertEquals(result.outcome, "performed");
  assertEquals(repairs, 1);
  assertEquals(store.records[0].profile_repair_state, "completed");
});
