import { assertEquals } from "jsr:@std/assert@1";
import {
  backfillLegacyInboxProjections,
  LEGACY_INBOX_BACKFILL_BATCH,
} from "./inbox-backfill.ts";
import { billingIdentitySubjectKey } from "./billing-identity-lifecycle.ts";

type Row = Record<string, any>;

function matches(row: Row, filter: Row): boolean {
  return Object.entries(filter).every(([key, value]) => {
    if (key === "$or") {
      return (value as Row[]).some((branch) => matches(row, branch));
    }
    if (value && typeof value === "object" && !Array.isArray(value)) {
      return Object.entries(value as Row).every(([operator, expected]) => {
        if (operator === "$in") {
          return (expected as unknown[]).includes(row[key]);
        }
        if (operator === "$exists") return (key in row) === expected;
        return false;
      });
    }
    return row[key] === value;
  });
}

class Store {
  filterCalls: Array<
    { filter: Row; sort: string; limit: number; skip: number }
  > = [];
  updateManyCalls: Array<{ filter: Row; update: Row }> = [];
  constructor(public records: Row[] = []) {
    this.records = structuredClone(records);
  }
  async filter(filter: Row, sort = "created_date", limit = 100, skip = 0) {
    this.filterCalls.push({
      filter: structuredClone(filter),
      sort,
      limit,
      skip,
    });
    const descending = sort.startsWith("-");
    const field = descending ? sort.slice(1) : sort;
    return this.records.filter((row) => matches(row, filter)).sort(
      (left, right) => {
        const order = String(left[field] ?? "").localeCompare(
          String(right[field] ?? ""),
        );
        return descending ? -order : order;
      },
    ).slice(skip, skip + limit).map((row) => structuredClone(row));
  }
  async create(row: Row) {
    const saved = {
      id: `row-${crypto.randomUUID()}`,
      created_date: "2026-07-27T00:00:00.000Z",
      ...structuredClone(row),
    };
    this.records.push(saved);
    return structuredClone(saved);
  }
  async updateMany(filter: Row, update: Row) {
    this.updateManyCalls.push({
      filter: structuredClone(filter),
      update: structuredClone(update),
    });
    let updated = 0;
    this.records = this.records.map((row) => {
      if (!matches(row, filter)) return row;
      updated += 1;
      return { ...row, ...structuredClone(update.$set || {}) };
    });
    return { updated };
  }
  async delete(id: string) {
    this.records = this.records.filter((row) => row.id !== id);
  }
}

Deno.test("legacy inbox backfill is bounded and self-advances to the tail", async () => {
  const eventStore = new Store(Array.from({ length: 70 }, (_, index) => ({
    id: `event-${String(index).padStart(3, "0")}`,
    state: "failed",
    event_type: "friend_request",
    source_event_id: `source-${index}`,
    actor_user_id: `actor-${index}`,
    recipient_user_id: `recipient-${index}`,
    lease_token: "",
    revision: `revision-${index}`,
    created_at: `2026-07-26T${
      String(Math.floor(index / 60)).padStart(2, "0")
    }:${String(index % 60).padStart(2, "0")}:00.000Z`,
  })));
  const friendshipStore = new Store(Array.from({ length: 70 }, (_, index) => ({
    request_event_id: `source-${index}`,
    requester_id: `actor-${index}`,
    addressee_id: `recipient-${index}`,
    status: "accepted",
  })));
  const userStore = new Store(Array.from({ length: 70 }, (_, index) => ({
    id: `actor-${index}`,
    display_name: `Operative ${index}`,
  })));
  const app = {
    asServiceRole: {
      entities: {
        PushNotificationEvent: eventStore,
        BillingIdentityLifecycle: new Store(),
        Friendship: friendshipStore,
        RoomInvite: new Store(),
        GameRoom: new Store(),
        User: userStore,
      },
    },
  };
  let migrated = 0;
  for (let pass = 0; pass < 4; pass += 1) {
    const result = await backfillLegacyInboxProjections({
      base44: app,
      deadlineEpochMs: Date.now() + 30_000,
      now: new Date("2026-07-27T12:00:00.000Z"),
    });
    migrated += result.visible;
    if (migrated === 70) break;
  }
  assertEquals(migrated, 70);
  assertEquals(
    eventStore.records.every((event) =>
      event.inbox_visible === true &&
      Boolean(event.inbox_committed_at) &&
      event.inbox_projection_version === 1
    ),
    true,
  );
  const migrationQueries = eventStore.filterCalls.filter((call) =>
    "$or" in call.filter
  );
  assertEquals(
    migrationQueries.every((call) =>
      call.sort === "updated_at" &&
      call.limit === LEGACY_INBOX_BACKFILL_BATCH && call.skip === 0
    ),
    true,
  );
});

Deno.test("missing source never becomes a visible phantom", async () => {
  const eventStore = new Store([{
    id: "event-phantom",
    state: "failed",
    event_type: "friend_request",
    source_event_id: "missing-source",
    actor_user_id: "actor",
    recipient_user_id: "recipient",
    lease_token: "",
    revision: "revision",
    inbox_title_en: "Must stay hidden",
    inbox_body_en: "No source was committed.",
    inbox_projection_version: 1,
    inbox_visible: false,
    inbox_committed_at: null,
    created_at: "2026-07-26T00:00:00.000Z",
  }]);
  const app = {
    asServiceRole: {
      entities: {
        PushNotificationEvent: eventStore,
        BillingIdentityLifecycle: new Store(),
        Friendship: new Store(),
        RoomInvite: new Store(),
        GameRoom: new Store(),
        User: new Store(),
      },
    },
  };
  const result = await backfillLegacyInboxProjections({
    base44: app,
    deadlineEpochMs: Date.now() + 10_000,
    now: new Date("2026-07-27T12:00:00.000Z"),
  });
  assertEquals(result.hidden, 1);
  assertEquals(eventStore.records[0].inbox_visible, false);
  assertEquals(Boolean(eventStore.records[0].inbox_committed_at), true);
});

Deno.test("game finish stays hidden until room status and event marker commit", async () => {
  const eventStore = new Store([{
    id: "finish-before-commit",
    state: "failed",
    event_type: "game_finished",
    source_event_id: "finish-event",
    actor_user_id: "actor",
    recipient_user_id: "recipient",
    room_id: "room-1",
    match_id: "match-1",
    lease_token: "",
    revision: "revision",
    created_at: "2026-07-26T00:00:00.000Z",
  }]);
  const app = {
    asServiceRole: {
      entities: {
        PushNotificationEvent: eventStore,
        BillingIdentityLifecycle: new Store(),
        Friendship: new Store(),
        RoomInvite: new Store(),
        GameRoom: new Store([{
          id: "room-1",
          status: "playing",
          match_id: "match-1",
          participant_user_ids: ["recipient"],
          game_finished_event_id: "",
        }]),
        User: new Store(),
      },
    },
  };
  const result = await backfillLegacyInboxProjections({
    base44: app,
    deadlineEpochMs: Date.now() + 10_000,
    now: new Date("2026-07-27T12:00:00.000Z"),
  });
  assertEquals(result.visible, 0);
  assertEquals(result.hidden, 1);
  assertEquals(eventStore.records[0].inbox_visible, false);
  assertEquals(Boolean(eventStore.records[0].inbox_committed_at), true);
});

Deno.test("committed game finish becomes visible", async () => {
  const eventStore = new Store([{
    id: "finish-committed",
    state: "failed",
    event_type: "game_finished",
    source_event_id: "finish-event",
    actor_user_id: "actor",
    recipient_user_id: "recipient",
    room_id: "room-1",
    match_id: "match-1",
    lease_token: "",
    revision: "revision",
    created_at: "2026-07-26T00:00:00.000Z",
  }]);
  const app = {
    asServiceRole: {
      entities: {
        PushNotificationEvent: eventStore,
        BillingIdentityLifecycle: new Store(),
        Friendship: new Store(),
        RoomInvite: new Store(),
        GameRoom: new Store([{
          id: "room-1",
          status: "finished",
          match_id: "match-1",
          participant_user_ids: ["recipient"],
          game_finished_event_id: "finish-event",
        }]),
        User: new Store(),
      },
    },
  };
  const result = await backfillLegacyInboxProjections({
    base44: app,
    deadlineEpochMs: Date.now() + 10_000,
    now: new Date("2026-07-27T12:00:00.000Z"),
  });
  assertEquals(result.visible, 1);
  assertEquals(eventStore.records[0].inbox_visible, true);
});

Deno.test("one poisoned source row does not abort independent backfill rows", async () => {
  const eventStore = new Store([{
    id: "poison",
    state: "failed",
    event_type: "friend_request",
    source_event_id: "source-poison",
    actor_user_id: "actor-poison",
    recipient_user_id: "recipient-poison",
    lease_token: "",
    revision: "revision-poison",
    created_at: "2026-07-26T00:00:00.000Z",
  }, {
    id: "healthy",
    state: "failed",
    event_type: "friend_request",
    source_event_id: "source-healthy",
    actor_user_id: "actor-healthy",
    recipient_user_id: "recipient-healthy",
    lease_token: "",
    revision: "revision-healthy",
    created_at: "2026-07-26T00:01:00.000Z",
  }]);
  const friendshipStore = new Store([{
    request_event_id: "source-healthy",
    requester_id: "actor-healthy",
    addressee_id: "recipient-healthy",
    status: "accepted",
  }]);
  const originalFilter = friendshipStore.filter.bind(friendshipStore);
  friendshipStore.filter = async (filter, sort, limit, skip) => {
    if (filter.request_event_id === "source-poison") {
      throw new Error("corrupt legacy source");
    }
    return await originalFilter(filter, sort, limit, skip);
  };
  const app = {
    asServiceRole: {
      entities: {
        PushNotificationEvent: eventStore,
        BillingIdentityLifecycle: new Store(),
        Friendship: friendshipStore,
        RoomInvite: new Store(),
        GameRoom: new Store(),
        User: new Store([{
          id: "actor-healthy",
          display_name: "Healthy operative",
        }]),
      },
    },
  };
  const result = await backfillLegacyInboxProjections({
    base44: app,
    deadlineEpochMs: Date.now() + 10_000,
    now: new Date("2026-07-27T12:00:00.000Z"),
  });
  assertEquals(result.errors, 1);
  assertEquals(result.visible, 1);
  assertEquals(
    eventStore.records.find((row) => row.id === "healthy")?.inbox_visible,
    true,
  );
});

Deno.test("non-retryable lifecycle poison is terminally hidden for progress", async () => {
  const eventStore = new Store([{
    id: "lifecycle-poison",
    state: "failed",
    event_type: "friend_request",
    source_event_id: "source",
    actor_user_id: "actor",
    recipient_user_id: "recipient",
    lease_token: "",
    revision: "revision",
    created_at: "2026-07-26T00:00:00.000Z",
  }]);
  const subjectKey = await billingIdentitySubjectKey("actor");
  const lifecycleStore = new Store([{
    id: "deleting-actor",
    subject_key: subjectKey,
    state: "deleting",
    lease_token: "deleting",
    lease_until: "2026-07-26T00:00:00.000Z",
    revision: "deleting-revision",
    created_date: "2026-07-26T00:00:00.000Z",
  }]);
  const app = {
    asServiceRole: {
      entities: {
        PushNotificationEvent: eventStore,
        BillingIdentityLifecycle: lifecycleStore,
        Friendship: new Store([{
          request_event_id: "source",
          requester_id: "actor",
          addressee_id: "recipient",
          status: "accepted",
        }]),
        RoomInvite: new Store(),
        GameRoom: new Store(),
        User: new Store([{ id: "actor", display_name: "Actor" }]),
      },
    },
  };
  const result = await backfillLegacyInboxProjections({
    base44: app,
    deadlineEpochMs: Date.now() + 10_000,
    now: new Date("2026-07-27T12:00:00.000Z"),
  });
  assertEquals(result.hidden, 1);
  assertEquals(result.deferred, 0);
  assertEquals(eventStore.records[0].inbox_visible, false);
  assertEquals(Boolean(eventStore.records[0].inbox_committed_at), true);
});

Deno.test("more than one poison batch rotates durably so later and recovered rows progress", async () => {
  const poisonCount = LEGACY_INBOX_BACKFILL_BATCH + 1;
  const baseTime = Date.parse("2026-07-26T00:00:00.000Z");
  const poisonEvents = Array.from({ length: poisonCount }, (_, index) => ({
    id: `poison-${String(index).padStart(3, "0")}`,
    state: "failed",
    event_type: "friend_request",
    source_event_id: `source-poison-${String(index).padStart(3, "0")}`,
    actor_user_id: `actor-poison-${index}`,
    recipient_user_id: `recipient-poison-${index}`,
    lease_token: "",
    revision: `revision-poison-${index}`,
    created_at: new Date(baseTime + index * 1_000).toISOString(),
    updated_at: new Date(baseTime + index * 1_000).toISOString(),
  }));
  const healthyEvent = {
    id: "healthy-later",
    state: "failed",
    event_type: "friend_request",
    source_event_id: "source-healthy-later",
    actor_user_id: "actor-healthy-later",
    recipient_user_id: "recipient-healthy-later",
    lease_token: "",
    revision: "revision-healthy-later",
    created_at: new Date(baseTime + poisonCount * 1_000).toISOString(),
    updated_at: new Date(baseTime + poisonCount * 1_000).toISOString(),
  };
  const eventStore = new Store([...poisonEvents, healthyEvent]);
  const friendshipStore = new Store([{
    request_event_id: "source-poison-000",
    requester_id: "actor-poison-0",
    addressee_id: "recipient-poison-0",
    status: "accepted",
  }, {
    request_event_id: "source-healthy-later",
    requester_id: "actor-healthy-later",
    addressee_id: "recipient-healthy-later",
    status: "accepted",
  }]);
  let recoveredFirstPoison = false;
  const originalFilter = friendshipStore.filter.bind(friendshipStore);
  friendshipStore.filter = async (filter, sort, limit, skip) => {
    const sourceID = String(filter.request_event_id || "");
    if (
      sourceID.startsWith("source-poison-") &&
      !(recoveredFirstPoison && sourceID === "source-poison-000")
    ) {
      throw new Error("corrupt legacy source");
    }
    return await originalFilter(filter, sort, limit, skip);
  };
  const app = {
    asServiceRole: {
      entities: {
        PushNotificationEvent: eventStore,
        BillingIdentityLifecycle: new Store(),
        Friendship: friendshipStore,
        RoomInvite: new Store(),
        GameRoom: new Store(),
        User: new Store([{
          id: "actor-poison-0",
          display_name: "Recovered operative",
        }, {
          id: "actor-healthy-later",
          display_name: "Healthy operative",
        }]),
      },
    },
  };
  const originalConsoleError = console.error;
  console.error = () => {};
  try {
    const first = await backfillLegacyInboxProjections({
      base44: app,
      deadlineEpochMs: Date.now() + 30_000,
      now: new Date("2026-07-27T12:00:00.000Z"),
    });
    assertEquals(first.selected, LEGACY_INBOX_BACKFILL_BATCH);
    assertEquals(first.errors, LEGACY_INBOX_BACKFILL_BATCH);
    assertEquals(first.visible, 0);
    assertEquals(
      eventStore.records.find((row) => row.id === "healthy-later")
        ?.inbox_committed_at,
      undefined,
    );

    recoveredFirstPoison = true;
    const second = await backfillLegacyInboxProjections({
      base44: app,
      deadlineEpochMs: Date.now() + 30_000,
      now: new Date("2026-07-27T12:01:00.000Z"),
    });
    assertEquals(second.visible, 2);
  } finally {
    console.error = originalConsoleError;
  }

  assertEquals(
    eventStore.records.find((row) => row.id === "healthy-later")
      ?.inbox_visible,
    true,
  );
  assertEquals(
    eventStore.records.find((row) => row.id === "poison-000")?.inbox_visible,
    true,
  );
  assertEquals(
    eventStore.records.some((row) =>
      row.id.startsWith("poison-") && row.inbox_visible === false &&
      Boolean(row.inbox_committed_at)
    ),
    false,
  );

  const selection = eventStore.filterCalls.find((call) =>
    "$or" in call.filter && "event_type" in call.filter
  );
  assertEquals(selection, {
    filter: {
      event_type: {
        $in: [
          "friend_request",
          "room_invite",
          "game_started",
          "game_finished",
        ],
      },
      $or: [
        { inbox_committed_at: { $exists: false } },
        { inbox_committed_at: null },
      ],
    },
    sort: "updated_at",
    limit: LEGACY_INBOX_BACKFILL_BATCH,
    skip: 0,
  });
  const firstRotation = eventStore.updateManyCalls.find((call) =>
    call.filter.id === "poison-000" &&
    Object.keys(call.update.$set || {}).length === 2
  );
  assertEquals(firstRotation?.filter, {
    id: "poison-000",
    state: "failed",
    lease_token: "",
    revision: "revision-poison-0",
    $or: [
      { inbox_committed_at: { $exists: false } },
      { inbox_committed_at: null },
    ],
  });
  assertEquals(
    firstRotation?.update.$set.updated_at,
    "2026-07-27T12:00:00.000Z",
  );
  assertEquals(typeof firstRotation?.update.$set.revision, "string");
});

Deno.test("retry rotation cannot overwrite a concurrent committed projection", async () => {
  const eventStore = new Store([{
    id: "concurrent-event",
    state: "failed",
    event_type: "friend_request",
    source_event_id: "source-concurrent",
    actor_user_id: "actor-concurrent",
    recipient_user_id: "recipient-concurrent",
    lease_token: "",
    revision: "revision-before",
    created_at: "2026-07-26T00:00:00.000Z",
    updated_at: "2026-07-26T00:00:00.000Z",
  }]);
  const concurrentCommittedAt = "2026-07-27T11:59:59.000Z";
  const originalUpdateMany = eventStore.updateMany.bind(eventStore);
  let injectedConcurrentCommit = false;
  eventStore.updateMany = async (filter, update) => {
    if (!injectedConcurrentCommit && update.$set?.updated_at) {
      injectedConcurrentCommit = true;
      eventStore.records = eventStore.records.map((row) =>
        row.id === "concurrent-event"
          ? {
            ...row,
            inbox_projection_version: 1,
            inbox_visible: true,
            inbox_committed_at: concurrentCommittedAt,
            updated_at: concurrentCommittedAt,
            revision: "revision-concurrent-commit",
          }
          : row
      );
    }
    return await originalUpdateMany(filter, update);
  };
  const friendshipStore = new Store();
  friendshipStore.filter = async () => {
    throw new Error("source read failed");
  };
  const app = {
    asServiceRole: {
      entities: {
        PushNotificationEvent: eventStore,
        BillingIdentityLifecycle: new Store(),
        Friendship: friendshipStore,
        RoomInvite: new Store(),
        GameRoom: new Store(),
        User: new Store(),
      },
    },
  };
  const originalConsoleError = console.error;
  console.error = () => {};
  let result: Row;
  try {
    result = await backfillLegacyInboxProjections({
      base44: app,
      deadlineEpochMs: Date.now() + 10_000,
      now: new Date("2026-07-27T12:00:00.000Z"),
    });
  } finally {
    console.error = originalConsoleError;
  }

  assertEquals(result!.errors, 1);
  assertEquals(injectedConcurrentCommit, true);
  assertEquals(eventStore.records[0].inbox_committed_at, concurrentCommittedAt);
  assertEquals(eventStore.records[0].inbox_visible, true);
  assertEquals(eventStore.records[0].updated_at, concurrentCommittedAt);
  assertEquals(eventStore.records[0].revision, "revision-concurrent-commit");
});
