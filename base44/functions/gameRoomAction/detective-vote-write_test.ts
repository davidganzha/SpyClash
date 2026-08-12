import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { scheduledDetectiveVoteCancellationEvent } from "./detective-vote-policy.ts";
import { commitDetectiveVoteCastWithRetry } from "./detective-vote-write.ts";

function conflict(): Error {
  return Object.assign(new Error("race"), { code: "cas_contention" });
}

Deno.test("concurrent cancellation reconciles after CAS loss without rebuilding inactive vote", async () => {
  const initial = { id: "room-1", revision: 1, voting: true, votes: ["a"] };
  const cancelled = { id: "room-1", revision: 2, voting: false, votes: [] };
  let builds = 0;
  let writes = 0;
  const result = await commitDetectiveVoteCastWithRetry({
    initialRoom: initial,
    buildPatch: (latest) => {
      builds += 1;
      if (!latest.voting) throw new Error("inactive vote was rebuilt");
      return { votes: [...latest.votes, "b"] };
    },
    write: async () => {
      writes += 1;
      throw conflict();
    },
    read: async () => cancelled,
    isConflict: (error) =>
      (error as { code?: string })?.code === "cas_contention",
    isSettledAfterConflict: (latest) => !latest.voting && !latest.votes.length,
    delay: async () => {},
  });
  assertEquals(result, cancelled);
  assertEquals(builds, 1);
  assertEquals(writes, 1);
});

Deno.test("concurrent durable ejection intent reconciles after CAS loss", async () => {
  const initial = { id: "room-1", revision: 1, voting: true, terminal: "" };
  const decided = {
    id: "room-1",
    revision: 2,
    voting: false,
    terminal: "detectives",
  };
  const result = await commitDetectiveVoteCastWithRetry({
    initialRoom: initial,
    buildPatch: () => ({ terminal: "detectives" }),
    write: async () => {
      throw conflict();
    },
    read: async () => decided,
    isConflict: (error) =>
      (error as { code?: string })?.code === "cas_contention",
    isSettledAfterConflict: (latest) => Boolean(latest.terminal),
    delay: async () => {},
  });
  assertEquals(result, decided);
});

Deno.test("CAS retry keeps the cancellation identity and refreshes present_at", async () => {
  type TimedRoom = {
    id: string;
    revision: number;
    voting: boolean;
    detective_vote_cancellation_present_at?: string;
  };
  const identity = { eventID: "cancel-event-1", roundID: "round-1" };
  const attemptTimes = [
    Date.parse("2026-08-12T12:00:00.000Z"),
    Date.parse("2026-08-12T12:00:00.800Z"),
  ];
  const initial: TimedRoom = { id: "room-1", revision: 1, voting: true };
  const refreshed: TimedRoom = { id: "room-1", revision: 2, voting: true };
  const attemptedPatches: Record<string, unknown>[] = [];
  let builds = 0;
  let writes = 0;

  const result = await commitDetectiveVoteCastWithRetry({
    initialRoom: initial,
    buildPatch: () => {
      const event = scheduledDetectiveVoteCancellationEvent(
        identity,
        attemptTimes[builds++],
      );
      return {
        detective_vote_cancellation_event_id: event.eventID,
        detective_vote_cancellation_round_id: event.roundID,
        detective_vote_cancellation_present_at: event.presentAt,
      };
    },
    write: async (latest, patch) => {
      writes += 1;
      attemptedPatches.push(patch);
      if (writes === 1) throw conflict();
      return { ...latest, ...patch, revision: 3 };
    },
    read: async () => refreshed,
    isConflict: (error) =>
      (error as { code?: string })?.code === "cas_contention",
    isSettledAfterConflict: () => false,
    delay: async () => {},
  });

  assertEquals(builds, 2);
  assertEquals(writes, 2);
  assertEquals(
    attemptedPatches.map((patch) => patch.detective_vote_cancellation_event_id),
    ["cancel-event-1", "cancel-event-1"],
  );
  assertEquals(
    attemptedPatches.map((patch) =>
      patch.detective_vote_cancellation_present_at
    ),
    ["2026-08-12T12:00:03.000Z", "2026-08-12T12:00:03.800Z"],
  );
  assertEquals(
    result.detective_vote_cancellation_present_at,
    "2026-08-12T12:00:03.800Z",
  );
});

Deno.test("two concurrent innocent ejections converge on one authoritative revision", async () => {
  const initial = {
    id: "room-1",
    revision: 7,
    voting: true,
    votes: ["a", "b"],
    spectators: [],
    eliminated: [],
  };
  let store = structuredClone(initial);
  let writeAttempts = 0;
  const runCast = () =>
    commitDetectiveVoteCastWithRetry({
      initialRoom: structuredClone(initial),
      buildPatch: (latest) => {
        if (!latest.voting) {
          throw Object.assign(new Error("inactive"), {
            code: "detective_vote_inactive",
          });
        }
        return {
          voting: false,
          votes: [],
          spectators: ["innocent"],
          eliminated: ["innocent"],
        };
      },
      write: async (latest, patch) => {
        writeAttempts += 1;
        if (latest.revision !== store.revision) throw conflict();
        store = {
          ...store,
          ...patch,
          revision: store.revision + 1,
        };
        return structuredClone(store);
      },
      read: async () => structuredClone(store),
      isConflict: (error) =>
        (error as { code?: string })?.code === "cas_contention",
      isSettledAfterConflict: (latest) =>
        !latest.voting && !latest.votes.length,
      delay: async () => {},
    });

  const winner = await runCast();
  const loser = await runCast();
  assertEquals(winner, loser);
  assertEquals(store.revision, 8);
  assertEquals(store.spectators, ["innocent"]);
  assertEquals(store.eliminated, ["innocent"]);
  assertEquals(writeAttempts, 2);
});

Deno.test("a truly stale later cast is rejected before any write", async () => {
  const stale = { id: "room-1", voting: false };
  let writes = 0;
  const error = await assertRejects(
    () =>
      commitDetectiveVoteCastWithRetry({
        initialRoom: stale,
        buildPatch: () => {
          throw Object.assign(
            new Error("Detective voting is no longer active"),
            {
              code: "detective_vote_inactive",
            },
          );
        },
        write: async (latest) => {
          writes += 1;
          return latest;
        },
        read: async () => stale,
        isConflict: () => false,
        isSettledAfterConflict: () => true,
      }),
    Error,
    "no longer active",
  );
  assertEquals(
    (error as Error & { code?: string }).code,
    "detective_vote_inactive",
  );
  assertEquals(writes, 0);
});

Deno.test("CAS retry that crosses the deadline commits the spy terminal instead", async () => {
  const initial = { id: "room-1", revision: 1, voting: true, expired: false };
  const crossed = { id: "room-1", revision: 2, voting: false, expired: true };
  const committed = {
    id: "room-1",
    revision: 3,
    voting: false,
    expired: true,
    terminal: "spy",
  };
  let writes = 0;
  const result = await commitDetectiveVoteCastWithRetry({
    initialRoom: initial,
    buildPatch: (latest) =>
      latest.expired ? { terminal: "spy" } : { votes: ["a"] },
    write: async (_latest, patch) => {
      writes += 1;
      if (writes === 1) throw conflict();
      assertEquals(patch, { terminal: "spy" });
      return committed;
    },
    read: async () => crossed,
    isConflict: (error) =>
      (error as { code?: string })?.code === "cas_contention",
    // A closed voting table is not settled while its timer requires a terminal.
    isSettledAfterConflict: (latest) => !latest.expired && !latest.voting,
    delay: async () => {},
  });
  assertEquals(result, committed);
  assertEquals(writes, 2);
});
