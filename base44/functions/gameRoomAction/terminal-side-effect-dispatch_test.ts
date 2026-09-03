import { assertEquals } from "jsr:@std/assert@1";
import {
  claimTerminalSideEffectDispatch,
  runTerminalSideEffectsSingleFlight,
} from "./terminal-side-effect-dispatch.ts";

type Entity = Record<string, any>;

class Store {
  records: Entity[];

  constructor(records: Entity[]) {
    this.records = structuredClone(records);
  }

  async filter(filter: Entity) {
    await Promise.resolve();
    return this.records.filter((record) =>
      Object.entries(filter).every(([key, value]) => record[key] === value)
    ).map((record) => structuredClone(record));
  }

  async updateMany(filter: Entity, update: Entity) {
    let updated = 0;
    for (const record of this.records) {
      if (
        Object.entries(filter).every(([key, value]) => record[key] === value)
      ) {
        Object.assign(record, structuredClone(update.$set || {}));
        updated += 1;
      }
    }
    await Promise.resolve();
    return { updated };
  }
}

function room(overrides: Entity = {}) {
  return {
    id: "room-1",
    status: "finished",
    match_id: "match-1",
    game_finished_event_id: "game-finished:match-1",
    terminal_intent: {
      match_id: "match-1",
      winner: "spy",
      decided_at: "2026-08-31T11:59:00.000Z",
    },
    room_revision: 7,
    room_last_write_token: "finish-write",
    ...overrides,
  };
}

Deno.test("N competing terminal retries perform the side-effect pipeline once", async () => {
  const store = new Store([room()]);
  let dispatches = 0;
  const results = await Promise.all(
    Array.from(
      { length: 12 },
      (_, index) =>
        runTerminalSideEffectsSingleFlight({
          store,
          room: room(),
          now: new Date("2026-08-31T12:00:00.000Z"),
          randomUUID: () => `claim-${index}`,
          dispatch: async () => {
            dispatches += 1;
            await Promise.resolve();
            return true;
          },
        }),
    ),
  );

  assertEquals(dispatches, 1);
  assertEquals(
    results.filter((result) => result.outcome === "performed").length,
    1,
  );
  assertEquals(
    results.find((result) => result.outcome === "performed")?.room
      ?.room_revision,
    9,
  );
  assertEquals(
    results.filter((result) => result.outcome === "deferred").length,
    11,
  );
  assertEquals(
    store.records[0].terminal_intent.side_effect_dispatch.state,
    "completed",
  );
  assertEquals(store.records[0].room_revision, 9);
  assertEquals(
    store.records[0].terminal_intent.winner,
    "spy",
  );
});

Deno.test("an abandoned claim is recoverable only after its bounded lease", async () => {
  const store = new Store([room()]);
  const first = await claimTerminalSideEffectDispatch({
    store,
    room: room(),
    now: new Date("2026-08-31T12:00:00.000Z"),
    randomUUID: () => "first",
    leaseMilliseconds: 2_000,
  });
  assertEquals(first.status, "claimed");

  const blocked = await claimTerminalSideEffectDispatch({
    store,
    room: store.records[0],
    now: new Date("2026-08-31T12:00:01.000Z"),
    randomUUID: () => "blocked",
    leaseMilliseconds: 2_000,
  });
  assertEquals(blocked.status, "deferred");

  const recovered = await claimTerminalSideEffectDispatch({
    store,
    room: store.records[0],
    now: new Date("2026-08-31T12:00:03.000Z"),
    randomUUID: () => "recovered",
    leaseMilliseconds: 2_000,
  });
  assertEquals(recovered.status, "claimed");
  if (recovered.status === "claimed") {
    assertEquals(recovered.claim.token, "terminal-dispatch:recovered");
  }
});

Deno.test("legacy blank dispatch state initializes in the same room revision CAS", async () => {
  const store = new Store([room()]);
  let dispatches = 0;
  await Promise.all(
    Array.from({ length: 4 }, (_, index) =>
      runTerminalSideEffectsSingleFlight({
        store,
        room: room(),
        now: new Date("2026-08-31T12:00:00.000Z"),
        randomUUID: () => `legacy-${index}`,
        dispatch: async () => {
          dispatches += 1;
          return true;
        },
      })),
  );
  assertEquals(dispatches, 1);
  assertEquals(store.records[0].room_revision, 9);
});

Deno.test("legacy terminal intent without mirrored room match id can claim", async () => {
  const legacyMatchID = "legacy:room-1:2026-08-31T11:00:00.000Z";
  const legacyRoom = room({
    match_id: "",
    game_finished_event_id: `game-finished:${legacyMatchID}`,
    terminal_intent: {
      match_id: legacyMatchID,
      winner: "spy",
      decided_at: "2026-08-31T11:59:00.000Z",
    },
  });
  const store = new Store([legacyRoom]);
  let dispatches = 0;
  const result = await runTerminalSideEffectsSingleFlight({
    store,
    room: legacyRoom,
    randomUUID: () => "legacy-room",
    dispatch: async () => {
      dispatches += 1;
      return true;
    },
  });
  assertEquals(result.outcome, "performed");
  assertEquals(dispatches, 1);
});

Deno.test("recipient outbox topology changes cannot create another source winner", async () => {
  const store = new Store([room(), { id: "event-z", recipient_user_id: "z" }]);
  let dispatches = 0;
  const first = runTerminalSideEffectsSingleFlight({
    store,
    room: room(),
    now: new Date("2026-08-31T12:00:00.000Z"),
    randomUUID: () => "winner",
    dispatch: async () => {
      dispatches += 1;
      store.records.push({ id: "event-a", recipient_user_id: "a" });
      await Promise.resolve();
      return true;
    },
  });
  const second = runTerminalSideEffectsSingleFlight({
    store,
    room: room(),
    now: new Date("2026-08-31T12:00:00.000Z"),
    randomUUID: () => "loser",
    dispatch: async () => {
      dispatches += 1;
      return true;
    },
  });
  await Promise.all([first, second]);
  assertEquals(dispatches, 1);
});

Deno.test("recipient deletion preserves completion and room deletion blocks stale dispatch", async () => {
  const store = new Store([room(), { id: "event-a", recipient_user_id: "a" }]);
  let dispatches = 0;
  await runTerminalSideEffectsSingleFlight({
    store,
    room: room(),
    randomUUID: () => "first",
    dispatch: async () => {
      dispatches += 1;
      return true;
    },
  });
  store.records = store.records.filter((record) => record.id !== "event-a");
  await runTerminalSideEffectsSingleFlight({
    store,
    room: store.records[0],
    randomUUID: () => "retry",
    dispatch: async () => {
      dispatches += 1;
      return true;
    },
  });
  assertEquals(dispatches, 1);

  const deletedRoom = structuredClone(store.records[0]);
  store.records = [];
  const deleted = await runTerminalSideEffectsSingleFlight({
    store,
    room: deletedRoom,
    now: new Date("2026-08-31T12:03:00.000Z"),
    randomUUID: () => "deleted",
    dispatch: async () => {
      dispatches += 1;
      return true;
    },
  });
  assertEquals(deleted.room, null);
  assertEquals(dispatches, 1);
});

Deno.test("replay invalidates an old completion token", async () => {
  const store = new Store([room()]);
  let dispatches = 0;
  const result = await runTerminalSideEffectsSingleFlight({
    store,
    room: room(),
    randomUUID: () => "old-match",
    dispatch: async () => {
      dispatches += 1;
      const live = store.records[0];
      Object.assign(live, {
        status: "roulette",
        match_id: "match-2",
        game_finished_event_id: "",
        terminal_intent: null,
        room_revision: live.room_revision + 1,
      });
      return true;
    },
  });
  assertEquals(result.outcome, "failed");
  assertEquals(result.room?.match_id, "match-2");
  assertEquals(dispatches, 1);
});

Deno.test("push failure cannot gate independent profile completion", async () => {
  const store = new Store([room()]);
  let pushDispatches = 0;
  let profileDispatches = 0;
  const now = new Date("2026-08-31T12:00:00.000Z");

  const push = await runTerminalSideEffectsSingleFlight({
    store,
    room: room(),
    now,
    randomUUID: () => "push-failure",
    dispatch: async () => {
      pushDispatches += 1;
      return false;
    },
  });
  const profile = await runTerminalSideEffectsSingleFlight({
    store,
    room: push.room || room(),
    stateKey: "profile_side_effect_dispatch",
    now,
    randomUUID: () => "profile-success",
    dispatch: async () => {
      profileDispatches += 1;
      return true;
    },
  });

  assertEquals(push.outcome, "failed");
  assertEquals(profile.outcome, "performed");
  assertEquals(pushDispatches, 1);
  assertEquals(profileDispatches, 1);
  assertEquals(
    store.records[0].terminal_intent.profile_side_effect_dispatch.state,
    "completed",
  );

  await runTerminalSideEffectsSingleFlight({
    store,
    room: store.records[0],
    stateKey: "profile_side_effect_dispatch",
    now: new Date("2026-08-31T12:03:00.000Z"),
    randomUUID: () => "profile-retry",
    dispatch: async () => {
      profileDispatches += 1;
      return true;
    },
  });
  assertEquals(profileDispatches, 1);
});

Deno.test("profile and push use independent concurrent single-flight claims", async () => {
  const store = new Store([room()]);
  const started = new Set<string>();
  let releaseDispatches!: () => void;
  const dispatchGate = new Promise<void>((resolve) => {
    releaseDispatches = resolve;
  });
  let bothStarted!: () => void;
  const bothStartedGate = new Promise<void>((resolve) => {
    bothStarted = resolve;
  });
  const dispatch = (name: string) => async () => {
    started.add(name);
    if (started.size === 2) bothStarted();
    await dispatchGate;
    return true;
  };

  const profile = runTerminalSideEffectsSingleFlight({
    store,
    room: room(),
    stateKey: "profile_side_effect_dispatch",
    now: new Date("2026-08-31T12:00:00.000Z"),
    randomUUID: () => "profile-concurrent",
    dispatch: dispatch("profile"),
  });
  const push = runTerminalSideEffectsSingleFlight({
    store,
    room: room(),
    now: new Date("2026-08-31T12:00:00.000Z"),
    randomUUID: () => "push-concurrent",
    dispatch: dispatch("push"),
  });

  let timedOut = false;
  const timeout = setTimeout(() => {
    timedOut = true;
    releaseDispatches();
  }, 1_000);
  await bothStartedGate;
  clearTimeout(timeout);
  assertEquals(timedOut, false);
  assertEquals([...started].sort(), ["profile", "push"]);
  releaseDispatches();

  const [profileResult, pushResult] = await Promise.all([profile, push]);
  assertEquals(profileResult.outcome, "performed");
  assertEquals(pushResult.outcome, "performed");
  assertEquals(
    store.records[0].terminal_intent.profile_side_effect_dispatch.state,
    "completed",
  );
  assertEquals(
    store.records[0].terminal_intent.side_effect_dispatch.state,
    "completed",
  );
});

Deno.test("profile partial failure retries without replaying completed push", async () => {
  const store = new Store([room()]);
  let pushDispatches = 0;
  let profileDispatches = 0;
  const firstNow = new Date("2026-08-31T12:00:00.000Z");

  await runTerminalSideEffectsSingleFlight({
    store,
    room: room(),
    now: firstNow,
    randomUUID: () => "push-success",
    dispatch: async () => {
      pushDispatches += 1;
      return true;
    },
  });
  await runTerminalSideEffectsSingleFlight({
    store,
    room: store.records[0],
    stateKey: "profile_side_effect_dispatch",
    now: firstNow,
    leaseMilliseconds: 2_000,
    randomUUID: () => "profile-partial",
    dispatch: async () => {
      profileDispatches += 1;
      return false;
    },
  });

  const retryNow = new Date("2026-08-31T12:00:03.000Z");
  await runTerminalSideEffectsSingleFlight({
    store,
    room: store.records[0],
    now: retryNow,
    randomUUID: () => "push-retry",
    dispatch: async () => {
      pushDispatches += 1;
      return true;
    },
  });
  const profileRetry = await runTerminalSideEffectsSingleFlight({
    store,
    room: store.records[0],
    stateKey: "profile_side_effect_dispatch",
    now: retryNow,
    leaseMilliseconds: 2_000,
    randomUUID: () => "profile-retry",
    dispatch: async () => {
      profileDispatches += 1;
      return true;
    },
  });

  assertEquals(pushDispatches, 1);
  assertEquals(profileDispatches, 2);
  assertEquals(profileRetry.outcome, "performed");
});
