import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  assertSameMatch,
  commitRoomActionTransition,
} from "./room-action-transition.ts";
import { writeRoomWithCAS } from "./room-write-cas.ts";

const initial = {
  id: "room-1",
  room_revision: 1,
  match_id: "match-1",
  status: "playing",
  current_asker_email: "a@test",
  current_answerer_email: "b@test",
  questions_in_round: 1,
  cards_read: ["a@test"],
  vote_requests: [],
  players: [{ user_id: "a", email: "a@test" }],
};
const patch = {
  current_asker_email: "b@test",
  current_answerer_email: "a@test",
  questions_in_round: 2,
};

function harness(concurrent: Record<string, unknown>) {
  let room: Record<string, any> = {
    ...structuredClone(initial),
    room_revision: 2,
    ...concurrent,
  };
  let writes = 0;
  let commits = 0;
  return {
    read: () => Promise.resolve(room),
    delay: () => Promise.resolve(),
    validate: () => {},
    write: (snapshot: Record<string, any>, data: Record<string, any>) => {
      writes += 1;
      return writeRoomWithCAS({
        room: snapshot,
        patch: data,
        store: {
          updateMany: (filter, update) => {
            if (filter.room_revision !== room.room_revision) {
              return Promise.resolve({ updated: 0 });
            }
            room = { ...room, ...(update.$set as Record<string, any>) };
            commits += 1;
            return Promise.resolve({ updated: 1 });
          },
        },
      });
    },
    counts: () => ({ writes, commits }),
  };
}

Deno.test("question advance survives a concurrent acknowledgement without erasing it", async () => {
  const io = harness({ cards_read: ["a@test", "b@test"] });
  const result = await commitRoomActionTransition({
    ...io,
    initialRoom: initial,
    patch,
  });
  assertEquals(result.questions_in_round, 2);
  assertEquals(result.cards_read, ["a@test", "b@test"]);
  assertEquals(io.counts(), { writes: 2, commits: 1 });
});

Deno.test("question advance preserves a concurrent detective-vote request", async () => {
  const io = harness({ vote_requests: ["b@test"] });
  const result = await commitRoomActionTransition({
    ...io,
    initialRoom: initial,
    patch,
  });
  assertEquals(result.vote_requests, ["b@test"]);
  assertEquals(result.questions_in_round, 2);
});

Deno.test("concurrent identical transition returns winner without advancing twice", async () => {
  const io = harness(patch);
  const result = await commitRoomActionTransition({
    ...io,
    initialRoom: initial,
    patch,
  });
  assertEquals(result.questions_in_round, 2);
  assertEquals(io.counts(), { writes: 1, commits: 0 });
});

for (
  const [name, change] of Object.entries({
    "next question": { questions_in_round: 3 },
    "new match": { match_id: "match-2" },
    "host transfer": { host_email: "b@test" },
    "participant replacement": {
      players: [{ user_id: "replacement", email: "a@test" }],
    },
    "vote settlement": { spectators: ["a@test"] },
    "terminal intent": { terminal_intent: { winner: "spy" } },
    "game pause": { game_paused_at: "2026-09-15T00:00:00Z" },
  })
) {
  Deno.test(`gameplay CAS retry cannot cross ${name}`, async () => {
    const io = harness(change);
    const error = await assertRejects(() =>
      commitRoomActionTransition({ ...io, initialRoom: initial, patch })
    );
    assertEquals((error as any).status, 409);
    assertEquals(io.counts(), { writes: 1, commits: 0 });
  });
}

Deno.test("gameplay CAS retry cannot overwrite an independent field it changes", async () => {
  const io = harness({ cards_read: ["a@test", "b@test"] });
  await assertRejects(() =>
    commitRoomActionTransition({
      ...io,
      initialRoom: initial,
      patch: { ...patch, cards_read: [] },
    })
  );
  assertEquals(io.counts(), { writes: 1, commits: 0 });
});

Deno.test("gameplay CAS retry revalidates the deadline before its second write", async () => {
  const io = harness({ cards_read: ["a@test", "b@test"] });
  let validations = 0;
  const error = await assertRejects(() =>
    commitRoomActionTransition({
      ...io,
      initialRoom: initial,
      patch,
      validate: () => {
        validations += 1;
        if (validations > 1) {
          throw Object.assign(new Error("Timer elapsed"), {
            status: 409,
            code: "game_timer_elapsed",
          });
        }
      },
    })
  );
  assertEquals((error as any).code, "game_timer_elapsed");
  assertEquals(io.counts(), { writes: 1, commits: 0 });
});

Deno.test("ambiguous room write never repeats a potentially committed action", async () => {
  let writes = 0;
  const error = Object.assign(new Error("Response lost"), {
    status: 503,
    code: "room_write_ambiguous",
  });
  assertEquals(
    await assertRejects(() =>
      commitRoomActionTransition({
        initialRoom: initial,
        patch,
        validate: () => {},
        write: () => {
          writes += 1;
          throw error;
        },
        read: () => Promise.resolve(initial),
      })
    ),
    error,
  );
  assertEquals(writes, 1);
});

Deno.test("match-bound acknowledgement cannot leak into replay", () => {
  const error = assertThrows(() =>
    assertSameMatch(initial, { ...initial, match_id: "match-2" })
  );
  assertEquals((error as any).code, "room_action_stale");
});
