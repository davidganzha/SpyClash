import assert from "node:assert/strict";
import test from "node:test";

import {
  createLobbySyncController,
  lobbyControlsFromRoom,
  lobbyStateFromRoom,
  lobbyStatesEquivalent,
  lobbyThemeInputAfterHydration,
  materializePlayableLobbyState,
  normalizeLobbyState,
  normalizeLobbyThemeInput,
  roomScopeMatches,
} from "./lobbySync.js";

function lobbyState(overrides = {}) {
  return normalizeLobbyState({
    game_mode: "questions",
    game_duration_seconds: 600,
    lobby_word_source: "manual",
    lobby_source_pack_id: "",
    lobby_source_name: "Cities",
    lobby_theme: "World cities",
    lobby_category: "Cities",
    lobby_word_count: 2,
    lobby_word_count_mode: "custom",
    lobby_word_pool: [
      { id: "kyiv", word: "Kyiv", enabled: true },
      { id: "london", word: "London", enabled: true },
    ],
    ...overrides,
  });
}

function roomAt(revision, state, overrides = {}) {
  return {
    id: "room-1",
    status: "waiting",
    lobby_revision: revision,
    room_revision: revision,
    ...state,
    ...overrides,
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

async function waitUntil(predicate, attempts = 50) {
  for (let attempt = 0; attempt < attempts; attempt += 1) {
    if (predicate()) return;
    await new Promise((resolve) => setTimeout(resolve, 0));
  }
  assert.fail("Condition was not reached");
}

test("authoritative room hydration preserves the complete lobby snapshot", () => {
  const state = lobbyState({
    game_mode: "associations",
    game_duration_seconds: 720,
    lobby_word_source: "saved",
    lobby_source_pack_id: "pack-7",
    lobby_source_name: "Capitals",
    lobby_theme: "",
    lobby_category: "Geography",
    lobby_word_count: 2,
    lobby_word_count_mode: "recommended",
    lobby_word_pool: [
      { id: "word-1", word: " Kyiv ", enabled: true },
      { id: "word-2", word: "London", enabled: false },
    ],
  });

  const controls = lobbyControlsFromRoom(roomAt(8, state));

  assert.equal(controls.gameMode, "associations");
  assert.equal(controls.gameDuration, 12);
  assert.equal(controls.wordSource, "saved");
  assert.equal(controls.selectedPackId, "pack-7");
  assert.equal(controls.customTheme, "");
  assert.equal(controls.generatedCategory, "Geography");
  assert.equal(controls.wordCount, 2);
  assert.equal(controls.wordCountMode, "recommended");
  assert.deepEqual(controls.wordPool, [
    { id: "word-1", word: "Kyiv", enabled: true },
    { id: "word-2", word: "London", enabled: false },
  ]);
  assert(lobbyStatesEquivalent(controls.state, lobbyStateFromRoom(roomAt(8, state))));
});

test("an ungenerated authoritative theme remains editable while its pool is empty", () => {
  const controls = lobbyControlsFromRoom(roomAt(4, lobbyState({
    lobby_word_source: "none",
    lobby_source_name: "",
    lobby_theme: "Space opera",
    lobby_category: "Space opera",
    lobby_word_count: 25,
    lobby_word_count_mode: "custom",
    lobby_word_pool: [],
  })));

  assert.equal(controls.customTheme, "Space opera");
  assert.equal(controls.themeAnalyzed, false);
  assert.equal(controls.customWordCount, 25);
});

test("raw theme input keeps an editing suffix while canonical themes stay normalized", () => {
  assert.equal(normalizeLobbyThemeInput("  Space opera  "), "Space opera");
  assert.equal(
    lobbyThemeInputAfterHydration("Space ", "Space", true),
    "Space ",
  );
  assert.equal(
    lobbyThemeInputAfterHydration("stale draft", "  Space opera  ", false),
    "Space opera",
  );
});

test("room scope rejects an old generation or a different query room", () => {
  const scope = { generation: 7, roomID: "room-1" };
  assert.equal(roomScopeMatches(scope, {
    generation: 7,
    requestedRoomID: "room-1",
    roomID: "room-1",
  }), true);
  assert.equal(roomScopeMatches(scope, {
    generation: 8,
    requestedRoomID: "room-1",
    roomID: "room-1",
  }), false);
  assert.equal(roomScopeMatches(scope, {
    generation: 7,
    requestedRoomID: "room-2",
    roomID: "room-2",
  }), false);
});

test("a revision-zero default becomes a complete playable fallback snapshot", () => {
  const state = lobbyStateFromRoom({
    id: "room-1",
    lobby_revision: 0,
    game_mode: "associations",
    game_duration_seconds: 480,
  });
  const materialized = materializePlayableLobbyState(state, {
    category: "Cities",
    pool: [
      { word: "Kyiv", enabled: true },
      { word: "London", enabled: true },
      { word: "Bratislava", enabled: false },
    ],
  });

  assert.equal(materialized.game_mode, "associations");
  assert.equal(materialized.game_duration_seconds, 480);
  assert.equal(materialized.lobby_word_source, "manual");
  assert.equal(materialized.lobby_category, "Cities");
  assert.equal(materialized.lobby_word_count, 2);
  assert.equal(materialized.lobby_word_pool.filter((entry) => entry.enabled).length >= 2, true);
  assert.deepEqual(Object.keys(materialized).sort(), [
    "game_duration_seconds",
    "game_mode",
    "lobby_category",
    "lobby_source_name",
    "lobby_source_pack_id",
    "lobby_theme",
    "lobby_word_count",
    "lobby_word_count_mode",
    "lobby_word_pool",
    "lobby_word_source",
  ]);
});

test("semantic lobby equality ignores server word ids but not order or enabled state", () => {
  const base = lobbyState();
  const reassignedIDs = lobbyState({
    lobby_word_pool: [
      { id: "server-a", word: "  KYIV ", enabled: true },
      { id: "server-b", word: "London", enabled: true },
    ],
  });
  assert.equal(lobbyStatesEquivalent(base, reassignedIDs), true);
  assert.equal(lobbyStatesEquivalent(base, lobbyState({
    lobby_word_pool: [...base.lobby_word_pool].reverse(),
  })), false);
  assert.equal(lobbyStatesEquivalent(base, lobbyState({
    lobby_word_pool: [base.lobby_word_pool[0], { ...base.lobby_word_pool[1], enabled: false }],
  })), false);
});

test("every write is expanded to the complete canonical lobby snapshot", async () => {
  const calls = [];
  const controller = createLobbySyncController({
    updateLobbyState: async (request) => {
      calls.push(request);
      return roomAt(2, request.state);
    },
    refreshRoom: async () => null,
    makeMutationID: () => "full-snapshot-id",
    debounceMilliseconds: 0,
  });
  controller.reset(roomAt(1, lobbyState()));
  controller.enqueue({ game_mode: "associations" }, { debounceMilliseconds: 0 });
  controller.flush();
  await controller.waitForIdle();

  assert.deepEqual(Object.keys(calls[0].state).sort(), [
    "game_duration_seconds",
    "game_mode",
    "lobby_category",
    "lobby_source_name",
    "lobby_source_pack_id",
    "lobby_theme",
    "lobby_word_count",
    "lobby_word_count_mode",
    "lobby_word_pool",
    "lobby_word_source",
  ]);
  assert.equal(calls[0].mutationID, "full-snapshot-id");
  assert.equal(calls[0].expectedRevision, 1);
});

test("latest wins writer serializes A then newest C and rejects A as a UI snapshot", async () => {
  const first = deferred();
  const second = deferred();
  const calls = [];
  const confirmed = [];
  const ids = ["mutation-a", "mutation-b", "mutation-c"];
  const initial = lobbyState();
  const stateA = lobbyState({ lobby_theme: "A", lobby_category: "A" });
  const stateB = lobbyState({ lobby_theme: "B", lobby_category: "B" });
  const stateC = lobbyState({ lobby_theme: "C", lobby_category: "C" });

  const controller = createLobbySyncController({
    updateLobbyState: (request) => {
      calls.push(request);
      return calls.length === 1 ? first.promise : second.promise;
    },
    refreshRoom: async () => null,
    onConfirmedRoom: (room) => confirmed.push(room),
    makeMutationID: () => ids.shift(),
    debounceMilliseconds: 0,
  });
  controller.reset(roomAt(1, initial));
  controller.enqueue(stateA, { debounceMilliseconds: 0 });
  controller.flush();
  await waitUntil(() => calls.length === 1);

  controller.enqueue(stateB, { debounceMilliseconds: 0 });
  controller.enqueue(stateC, { debounceMilliseconds: 0 });
  first.resolve(roomAt(2, stateA));
  await waitUntil(() => calls.length === 2);

  assert.equal(calls[0].expectedRevision, 1);
  assert.equal(calls[0].mutationID, "mutation-a");
  assert.equal(calls[1].expectedRevision, 2);
  assert.equal(calls[1].mutationID, "mutation-c");
  assert(lobbyStatesEquivalent(calls[1].state, stateC));
  assert.equal(confirmed.length, 0, "superseded response must not hydrate host controls");

  second.resolve(roomAt(3, stateC));
  await controller.waitForIdle();
  assert.equal(confirmed.length, 1);
  assert.equal(confirmed[0].lobby_revision, 3);
});

test("revision conflict reloads and retries the same mutation id at the fresh revision", async () => {
  const calls = [];
  const sleeps = [];
  const desired = lobbyState({ game_mode: "associations" });
  const external = lobbyState({ game_duration_seconds: 780 });
  let refreshCalls = 0;

  const controller = createLobbySyncController({
    updateLobbyState: async (request) => {
      calls.push(request);
      if (calls.length === 1) {
        throw Object.assign(new Error("Lobby changed"), {
          status: 409,
          code: "lobby_revision_conflict",
        });
      }
      return roomAt(4, desired);
    },
    refreshRoom: async () => {
      refreshCalls += 1;
      return roomAt(3, external);
    },
    makeMutationID: () => "stable-mutation",
    sleep: async (milliseconds) => sleeps.push(milliseconds),
    debounceMilliseconds: 0,
  });
  controller.reset(roomAt(2, lobbyState()));
  controller.enqueue(desired, { debounceMilliseconds: 0 });
  controller.flush();
  await controller.waitForIdle();

  assert.equal(refreshCalls, 1);
  assert.deepEqual(calls.map((call) => call.expectedRevision), [2, 3]);
  assert.deepEqual(calls.map((call) => call.mutationID), ["stable-mutation", "stable-mutation"]);
  assert.deepEqual(sleeps, [180]);
});

test("a response older than an observed room revision is never applied and is retried", async () => {
  const first = deferred();
  const calls = [];
  const confirmed = [];
  const desired = lobbyState({ lobby_theme: "Web", lobby_category: "Web" });
  const iosState = lobbyState({ lobby_theme: "iOS", lobby_category: "iOS" });

  const controller = createLobbySyncController({
    updateLobbyState: async (request) => {
      calls.push(request);
      if (calls.length === 1) return await first.promise;
      return roomAt(4, desired);
    },
    refreshRoom: async () => roomAt(3, iosState),
    onConfirmedRoom: (room) => confirmed.push(room),
    makeMutationID: () => "stable-stale-response-id",
    sleep: async () => {},
    debounceMilliseconds: 0,
  });
  controller.reset(roomAt(1, lobbyState()));
  controller.enqueue(desired, { debounceMilliseconds: 0 });
  controller.flush();
  await waitUntil(() => calls.length === 1);

  assert.equal(controller.reconcile(roomAt(3, iosState)), false);
  first.resolve(roomAt(2, desired));
  await controller.waitForIdle();

  assert.deepEqual(calls.map((call) => call.expectedRevision), [1, 3]);
  assert.deepEqual(calls.map((call) => call.mutationID), [
    "stable-stale-response-id",
    "stable-stale-response-id",
  ]);
  assert.equal(confirmed.length, 1);
  assert.equal(confirmed[0].lobby_revision, 4);
});

test("lost success response is reconciled by equivalent refreshed state without another write", async () => {
  const calls = [];
  const confirmed = [];
  const desired = lobbyState({ lobby_word_count: 1 });

  const controller = createLobbySyncController({
    updateLobbyState: async (request) => {
      calls.push(request);
      throw Object.assign(new Error("Response lost"), { status: 503 });
    },
    refreshRoom: async () => roomAt(2, desired),
    onConfirmedRoom: (room) => confirmed.push(room),
    makeMutationID: () => "lost-response-id",
    debounceMilliseconds: 0,
  });
  controller.reset(roomAt(1, lobbyState()));
  controller.enqueue(desired, { debounceMilliseconds: 0 });
  controller.flush();
  await controller.waitForIdle();

  assert.equal(calls.length, 1);
  assert.equal(confirmed.length, 1);
  assert.equal(confirmed[0].lobby_revision, 2);
});

test("terminal failure reloads and rolls every control back to the authoritative room", async () => {
  const rollback = [];
  const authoritative = lobbyState({
    game_mode: "associations",
    lobby_theme: "Server",
    lobby_category: "Server",
  });

  const controller = createLobbySyncController({
    updateLobbyState: async () => {
      throw Object.assign(new Error("Invalid lobby"), {
        status: 422,
        code: "lobby_state_invalid",
      });
    },
    refreshRoom: async () => roomAt(7, authoritative),
    onRollback: (room, error) => rollback.push({ room, error }),
    makeMutationID: () => "fatal-id",
    debounceMilliseconds: 0,
  });
  controller.reset(roomAt(6, lobbyState()));
  controller.enqueue(lobbyState({ lobby_theme: "Broken" }), { debounceMilliseconds: 0 });
  controller.flush();
  const final = await controller.waitForIdle();

  assert.equal(final.optimistic, false);
  assert.equal(final.error?.code, "lobby_state_invalid");
  assert.equal(rollback.length, 1);
  assert(lobbyStatesEquivalent(lobbyStateFromRoom(rollback[0].room), authoritative));
});

test("an accepted idle authoritative snapshot clears a terminal sync error", async () => {
  const controller = createLobbySyncController({
    updateLobbyState: async () => {
      throw Object.assign(new Error("Invalid lobby"), {
        status: 422,
        code: "lobby_state_invalid",
      });
    },
    refreshRoom: async () => roomAt(7, lobbyState()),
    makeMutationID: () => "fatal-recovery-id",
    debounceMilliseconds: 0,
  });
  controller.reset(roomAt(6, lobbyState()));
  controller.enqueue(lobbyState({ lobby_theme: "Broken" }), { debounceMilliseconds: 0 });
  controller.flush();
  await controller.waitForIdle();

  assert.equal(controller.snapshot().error?.code, "lobby_state_invalid");
  assert.equal(controller.reconcile(roomAt(8, lobbyState())), true);
  assert.equal(controller.snapshot().error, null);
});

test("reset invalidates an in-flight response from a room that left writable scope", async () => {
  const inFlight = deferred();
  const confirmed = [];
  const controller = createLobbySyncController({
    updateLobbyState: () => inFlight.promise,
    refreshRoom: async () => null,
    onConfirmedRoom: (room) => confirmed.push(room),
    makeMutationID: () => "old-scope-id",
    debounceMilliseconds: 0,
  });
  const desired = lobbyState({ lobby_theme: "Old room", lobby_category: "Old room" });
  controller.reset(roomAt(1, lobbyState()));
  controller.enqueue(desired, { debounceMilliseconds: 0 });
  controller.flush();
  await waitUntil(() => controller.snapshot().inFlight);

  controller.reset(null);
  inFlight.resolve(roomAt(2, desired));
  await new Promise((resolve) => setTimeout(resolve, 0));

  assert.equal(controller.snapshot().roomID, null);
  assert.equal(controller.snapshot().optimistic, false);
  assert.equal(controller.snapshot().error, null);
  assert.equal(confirmed.length, 0);
});

test("dispose cancels pending work and reset safely activates a new room scope", async () => {
  const calls = [];
  const controller = createLobbySyncController({
    updateLobbyState: async (request) => {
      calls.push(request);
      return roomAt(6, request.state, { id: request.roomID });
    },
    refreshRoom: async () => null,
    makeMutationID: () => "scope-id",
    debounceMilliseconds: 10_000,
  });
  controller.reset(roomAt(1, lobbyState()));
  controller.enqueue(lobbyState({ lobby_theme: "Cancelled" }));
  const firstIdle = controller.waitForIdle();
  controller.dispose();
  assert.equal((await firstIdle).optimistic, false);
  assert.equal(calls.length, 0);

  controller.reset(roomAt(5, lobbyState(), { id: "room-2" }));
  controller.enqueue(lobbyState({ lobby_theme: "New room" }), { debounceMilliseconds: 0 });
  controller.flush();
  await controller.waitForIdle();

  assert.equal(calls.length, 1);
  assert.equal(calls[0].roomID, "room-2");
  assert.equal(calls[0].expectedRevision, 5);
});
