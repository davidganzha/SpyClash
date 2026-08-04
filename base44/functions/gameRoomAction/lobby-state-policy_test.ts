import { assertEquals, assertNotEquals, assertThrows } from "jsr:@std/assert@1";
import {
  assertAuthoritativeLobbyReady,
  authoritativeStartPayload,
  canonicalizeLobbyState,
  hasAuthoritativeLobbyState,
  lobbyMutationPatch,
  roomHasLobbyMutation,
  selectedAuthoritativeLobbyWordPool,
  validateLobbyMutation,
} from "./lobby-state-policy.ts";
import { hasValidEnabledStartWordPool } from "./start-word-pool-policy.ts";

function state(overrides: Record<string, unknown> = {}) {
  return {
    game_mode: "questions",
    game_duration_seconds: 900,
    lobby_word_source: "manual",
    lobby_source_pack_id: "pack-1",
    lobby_source_name: "City pack",
    lobby_theme: "Cities",
    lobby_category: "Places",
    lobby_word_count: 2,
    lobby_word_count_mode: "recommended",
    lobby_word_pool: [
      { id: "embassy", word: "Embassy", enabled: true },
      { id: "harbor", word: "Harbor", enabled: true },
      { id: "museum", word: "Museum", enabled: false },
    ],
    ...overrides,
  };
}

function errorCode(error: unknown): string | undefined {
  return (error as Error & { code?: string }).code;
}

function errorStatus(error: unknown): number | undefined {
  return (error as Error & { status?: number }).status;
}

Deno.test("lobby state accepts every source and count mode", () => {
  for (const source of ["none", "saved", "ai", "manual"]) {
    for (const mode of ["recommended", "custom"]) {
      const canonical = canonicalizeLobbyState(state({
        lobby_word_source: source,
        lobby_word_count_mode: mode,
      }));
      assertEquals(canonical.lobby_word_source, source);
      assertEquals(canonical.lobby_word_count_mode, mode);
    }
  }
});

Deno.test("optional lobby metadata safely canonicalizes to empty strings", () => {
  const canonical = canonicalizeLobbyState(state({
    lobby_source_pack_id: "",
    lobby_source_name: "",
    lobby_theme: "",
    lobby_category: "",
  }));
  assertEquals(canonical.lobby_source_pack_id, "");
  assertEquals(canonical.lobby_source_name, "");
  assertEquals(canonical.lobby_theme, "");
  assertEquals(canonical.lobby_category, "");
});

Deno.test("word pool canonicalizes Unicode and whitespace, deduplicates, and assigns stable ids", () => {
  const canonical = canonicalizeLobbyState(state({
    lobby_word_pool: [
      { word: "  Ｅｍｂａｓｓｙ  ", enabled: true },
      { id: "duplicate", word: "embassy", enabled: false },
      { id: "harbor", word: "Harbor", enabled: false },
    ],
  }));
  assertEquals(canonical.lobby_word_pool.length, 2);
  assertEquals(canonical.lobby_word_pool[0].word, "Embassy");
  assertEquals(canonical.lobby_word_pool[0].enabled, true);
  assertEquals(canonical.lobby_word_pool[0].id.startsWith("lw_"), true);
  assertEquals(canonical.lobby_word_pool[1], {
    id: "harbor",
    word: "Harbor",
    enabled: false,
  });

  const repeated = canonicalizeLobbyState(state({
    lobby_word_pool: [{ word: "Ｅｍｂａｓｓｙ", enabled: true }],
  }));
  assertEquals(
    repeated.lobby_word_pool[0].id,
    canonical.lobby_word_pool[0].id,
  );
});

Deno.test("lobby state rejects invalid ranges, unsafe content, and oversized pools", () => {
  for (const invalidCount of [-1, 201, 2.5]) {
    const error = assertThrows(
      () => canonicalizeLobbyState(state({ lobby_word_count: invalidCount })),
      Error,
    );
    assertEquals(errorStatus(error), 400);
  }

  const unsafe = assertThrows(
    () =>
      canonicalizeLobbyState(state({
        lobby_word_pool: [{ word: "go kill yourself", enabled: true }],
      })),
    Error,
  );
  assertEquals(errorStatus(unsafe), 422);

  const tooMany = assertThrows(
    () =>
      canonicalizeLobbyState(state({
        lobby_word_pool: Array.from(
          { length: 201 },
          (_, index) => ({ word: `Word ${index}`, enabled: true }),
        ),
      })),
    Error,
  );
  assertEquals(errorCode(tooMany), "lobby_word_pool_invalid");
});

Deno.test("mutation patch is atomic, increments once, and replays idempotently", () => {
  const mutation = validateLobbyMutation({
    mutation_id: "mutation-1",
    expected_revision: 0,
    state: state(),
  });
  const patch = lobbyMutationPatch(
    { lobby_revision: 0, game_mode: "associations" },
    mutation,
  );
  assertEquals(patch.lobby_revision, 1);
  assertEquals(patch.game_mode, "questions");
  assertEquals(patch.game_duration_seconds, 900);
  assertEquals(patch.lobby_word_count_mode, "recommended");
  assertEquals(Array.isArray(patch.lobby_word_pool), true);

  const persisted = { id: "room-1", ...patch };
  assertEquals(roomHasLobbyMutation(persisted, mutation), true);
  assertEquals(lobbyMutationPatch(persisted, mutation), {});
});

Deno.test("mutation id reuse and stale expected revisions fail with typed conflicts", () => {
  const first = validateLobbyMutation({
    mutation_id: "mutation-1",
    expected_revision: 0,
    state: state(),
  });
  const persisted = { ...lobbyMutationPatch({ lobby_revision: 0 }, first) };

  const reused = validateLobbyMutation({
    mutation_id: "mutation-1",
    expected_revision: 1,
    state: state({ lobby_theme: "Museums" }),
  });
  const reusedError = assertThrows(
    () => lobbyMutationPatch(persisted, reused),
    Error,
  );
  assertEquals(errorStatus(reusedError), 409);
  assertEquals(errorCode(reusedError), "lobby_mutation_id_reused");

  const stale = validateLobbyMutation({
    mutation_id: "mutation-2",
    expected_revision: 0,
    state: state({ lobby_theme: "Museums" }),
  });
  const staleError = assertThrows(
    () => lobbyMutationPatch(persisted, stale),
    Error,
  ) as Error & { current_revision?: number };
  assertEquals(errorCode(staleError), "lobby_revision_conflict");
  assertEquals(staleError.current_revision, 1);
});

Deno.test("later accepted revision wins over an out-of-order older intent", () => {
  const first = validateLobbyMutation({
    mutation_id: "mutation-a",
    expected_revision: 0,
    state: state({ lobby_theme: "First" }),
  });
  const roomAfterFirst = {
    ...lobbyMutationPatch({ lobby_revision: 0 }, first),
  };
  const second = validateLobbyMutation({
    mutation_id: "mutation-b",
    expected_revision: 1,
    state: state({ lobby_theme: "Latest" }),
  });
  const roomAfterSecond = {
    ...roomAfterFirst,
    ...lobbyMutationPatch(roomAfterFirst, second),
  };
  assertEquals(roomAfterSecond.lobby_revision, 2);
  assertEquals(roomAfterSecond.lobby_theme, "Latest");

  const staleRetry = validateLobbyMutation({
    mutation_id: "mutation-c",
    expected_revision: 1,
    state: state({ lobby_theme: "First" }),
  });
  const error = assertThrows(
    () => lobbyMutationPatch(roomAfterSecond, staleRetry),
    Error,
  );
  assertEquals(errorCode(error), "lobby_revision_conflict");
  assertNotEquals(roomAfterSecond.lobby_theme, "First");
});

Deno.test("authoritative start ignores stale client settings and filters the dedicated pool", () => {
  const mutation = validateLobbyMutation({
    mutation_id: "mutation-start",
    expected_revision: 0,
    state: state({
      game_mode: "associations",
      game_duration_seconds: 300,
      lobby_word_count: 2,
      lobby_word_pool: [
        { word: "Embassy", enabled: true },
        { word: "Museum", enabled: false },
        { word: "Harbor", enabled: true },
        { word: "Station", enabled: true },
      ],
    }),
  });
  const room = {
    id: "room-1",
    ...lobbyMutationPatch({ lobby_revision: 0 }, mutation),
  };
  assertEquals(hasAuthoritativeLobbyState(room), true);
  assertEquals(
    selectedAuthoritativeLobbyWordPool(room).map((entry) => entry.word),
    ["Embassy", "Harbor"],
  );

  const payload = authoritativeStartPayload(
    room,
    {
      spy_email: "spy@example.com",
      word: "Embassy",
      game_mode: "questions",
      game_duration_seconds: 60,
      category: "Client override",
      word_pool: [{ word: "Wrong", enabled: true }],
    },
    1,
  );
  assertEquals(payload.game_mode, "associations");
  assertEquals(payload.game_duration_seconds, 300);
  assertEquals(payload.category, "Places");
  assertEquals(payload.word_pool, [
    { word: "Embassy", enabled: true },
    { word: "Harbor", enabled: true },
  ]);
  assertEquals(payload.spy_email, "spy@example.com");
  assertEquals(
    hasValidEnabledStartWordPool(
      payload.word_pool as Array<{ word: unknown; enabled: unknown }>,
      "Embassy",
    ),
    true,
  );
  assertEquals(
    hasValidEnabledStartWordPool(
      payload.word_pool as Array<{ word: unknown; enabled: unknown }>,
      "Museum",
    ),
    false,
  );
});

Deno.test("authoritative start requires a current revision and two selected words", () => {
  const room = {
    lobby_revision: 3,
    ...state({
      lobby_word_count: 1,
      lobby_word_pool: [{ word: "Embassy", enabled: true }],
    }),
  };
  const missingRevision = assertThrows(
    () => authoritativeStartPayload(room, {}, undefined),
    Error,
  );
  assertEquals(errorCode(missingRevision), "lobby_revision_required");

  const staleRevision = assertThrows(
    () => authoritativeStartPayload(room, {}, 2),
    Error,
  );
  assertEquals(errorCode(staleRevision), "lobby_revision_conflict");

  const incomplete = assertThrows(
    () => assertAuthoritativeLobbyReady(room),
    Error,
  );
  assertEquals(errorCode(incomplete), "lobby_word_pool_incomplete");
});

Deno.test("legacy revision zero keeps the existing client start contract", () => {
  const payload = { game_mode: "questions", word_pool: [{ word: "Legacy" }] };
  assertEquals(hasAuthoritativeLobbyState({ lobby_revision: 0 }), false);
  assertEquals(
    authoritativeStartPayload({ lobby_revision: 0 }, payload, undefined),
    payload,
  );
});
