import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import {
  committedGameStartIdentity,
  repairCommittedGameStartWithFreshLeases,
} from "./committed-game-start-repair.ts";
import {
  reconcileCommittedGameStartAfterActiveIdentityLease,
  recoverSafeRoomActionAfterActiveIdentityLease,
} from "./room-write-lifecycle.ts";

type Room = Record<string, unknown>;
type LeaseContext = { userIDs: string[] };

function startedRoom(overrides: Room = {}): Room {
  return {
    id: "room-1",
    status: "playing",
    match_id: "match-1",
    game_started_event_id: "start-1",
    players: [
      { user_id: "user-1", email: "one@example.com" },
      { user_id: "user-2", email: "two@example.com" },
    ],
    participant_user_ids: ["user-1", "user-2"],
    ...overrides,
  };
}

function activeLeaseError(): BillingIdentityLifecycleError {
  return new BillingIdentityLifecycleError(
    "active_lease",
    "Account identity is being updated.",
  );
}

Deno.test("post-CAS repair enqueues under fresh leases and signals after release", async () => {
  const room = startedRoom();
  const events: string[] = [];
  let leaseHeld = false;

  const result = await reconcileCommittedGameStartAfterActiveIdentityLease({
    action: "complete_game_start",
    error: activeLeaseError(),
    refetch: () => Promise.resolve(room),
    assertParticipant: () => {
      events.push("detected-participant");
    },
    repair: async (detected) => {
      const expected = committedGameStartIdentity(detected);
      assert(expected);
      return await repairCommittedGameStartWithFreshLeases<
        Room,
        LeaseContext
      >({
        expected,
        refetch: () => Promise.resolve(room),
        assertParticipant: () => {
          events.push("current-participant");
        },
        lifecycleUserIDs: () => Promise.resolve(["user-1", "user-2"]),
        withFreshLeases: async <T>(
          userIDs: readonly unknown[],
          action: (
            context: LeaseContext,
          ) => Promise<T>,
        ) => {
          assertEquals(userIDs, ["user-1", "user-2"]);
          events.push("lease-acquired");
          leaseHeld = true;
          try {
            return await action({ userIDs: [...userIDs] as string[] });
          } finally {
            leaseHeld = false;
            events.push("lease-released");
          }
        },
        currentUserIDs: () => Promise.resolve(["user-1", "user-2"]),
        assertExactLeaseCoverage: (context, userIDs) => {
          assert(leaseHeld);
          assertEquals(context.userIDs, userIDs);
          events.push("coverage-checked");
        },
        assertLeasesActive: () => {
          assert(leaseHeld);
          events.push("leases-asserted");
          return Promise.resolve();
        },
        migrate: (candidate) => {
          assert(leaseHeld);
          events.push("migration-checked");
          return Promise.resolve(candidate);
        },
        reconcile: (candidate) => {
          assert(leaseHeld);
          events.push("enqueue-reconciled");
          return Promise.resolve(candidate);
        },
        fanout: () => {
          assertEquals(leaseHeld, false);
          events.push("signal-fanout");
          return Promise.resolve();
        },
      });
    },
  });

  assertEquals(result, room);
  assertEquals(events, [
    "detected-participant",
    "current-participant",
    "lease-acquired",
    "current-participant",
    "coverage-checked",
    "migration-checked",
    "current-participant",
    "enqueue-reconciled",
    "current-participant",
    "coverage-checked",
    "leases-asserted",
    "lease-released",
    "signal-fanout",
  ]);
});

Deno.test("committed-start fanout uses the exact snapshot after participant leases release", async () => {
  const room = startedRoom();
  const expectedRecipients = ["user-1", "user-2"];
  let leaseHeld = false;
  let membershipMutationCalls = 0;
  let outboxRecipients: string[] = [];
  let signalRecipients: string[] = [];

  const expected = committedGameStartIdentity(room);
  assert(expected);
  const result = await repairCommittedGameStartWithFreshLeases<
    Room,
    LeaseContext
  >({
    expected,
    refetch: () => Promise.resolve(room),
    assertParticipant: () => undefined,
    lifecycleUserIDs: () => Promise.resolve(expectedRecipients),
    withFreshLeases: async <T>(
      userIDs: readonly unknown[],
      action: (context: LeaseContext) => Promise<T>,
    ) => {
      assertEquals(userIDs, expectedRecipients);
      leaseHeld = true;
      try {
        return await action({ userIDs: [...expectedRecipients] });
      } finally {
        leaseHeld = false;
      }
    },
    currentUserIDs: () => Promise.resolve(expectedRecipients),
    assertExactLeaseCoverage: (context, userIDs) => {
      assert(leaseHeld);
      assertEquals(context.userIDs, userIDs);
    },
    assertLeasesActive: () => {
      assert(leaseHeld);
      return Promise.resolve();
    },
    migrate: (candidate) => Promise.resolve(candidate),
    reconcile: async (candidate) => {
      assert(leaseHeld);
      const leaseError = activeLeaseError();
      const error = await assertRejects(
        () =>
          recoverSafeRoomActionAfterActiveIdentityLease({
            action: "leave_room",
            error: leaseError,
            recover: () => {
              membershipMutationCalls += 1;
              return Promise.resolve(candidate);
            },
          }),
        BillingIdentityLifecycleError,
      );
      assertEquals(error, leaseError);
      outboxRecipients = [
        ...(candidate.participant_user_ids as string[]),
      ];
      return candidate;
    },
    fanout: (candidate) => {
      assertEquals(leaseHeld, false);
      signalRecipients = [
        ...(candidate.participant_user_ids as string[]),
      ];
      return Promise.resolve();
    },
  });

  assertEquals(result, room);
  assertEquals(membershipMutationCalls, 0);
  assertEquals(outboxRecipients, expectedRecipients);
  assertEquals(signalRecipients, expectedRecipients);
});

Deno.test("a removed actor receives the participant error and no repair result", async () => {
  const participantError = Object.assign(
    new Error("Not a player in this room"),
    { status: 403, code: "player_access_required" },
  );
  let repairCalls = 0;

  const error = await assertRejects(
    () =>
      reconcileCommittedGameStartAfterActiveIdentityLease({
        action: "complete_game_start",
        error: activeLeaseError(),
        refetch: () => Promise.resolve(startedRoom()),
        assertParticipant: () => {
          throw participantError;
        },
        repair: (room) => {
          repairCalls += 1;
          return Promise.resolve(room);
        },
      }),
    Error,
  );

  assertEquals(error, participantError);
  assertEquals(repairCalls, 0);
});

Deno.test("fresh lease deletion blocks committed-start enqueue and signal repair", async () => {
  const room = startedRoom();
  const deletionError = new BillingIdentityLifecycleError(
    "deletion_in_progress",
    "Account deletion is in progress or already completed.",
  );
  let leasedActionCalls = 0;
  let enqueueCalls = 0;
  let fanoutCalls = 0;

  const error = await assertRejects(
    () =>
      reconcileCommittedGameStartAfterActiveIdentityLease({
        action: "complete_game_start",
        error: activeLeaseError(),
        refetch: () => Promise.resolve(room),
        assertParticipant: () => undefined,
        repair: async (detected) => {
          const expected = committedGameStartIdentity(detected);
          assert(expected);
          return await repairCommittedGameStartWithFreshLeases<
            Room,
            LeaseContext
          >({
            expected,
            refetch: () => Promise.resolve(room),
            assertParticipant: () => undefined,
            lifecycleUserIDs: () => Promise.resolve(["user-1", "user-2"]),
            withFreshLeases: () => {
              throw deletionError;
            },
            currentUserIDs: () => Promise.resolve(["user-1", "user-2"]),
            assertExactLeaseCoverage: () => undefined,
            assertLeasesActive: () => Promise.resolve(),
            migrate: (candidate) => Promise.resolve(candidate),
            reconcile: (candidate) => {
              leasedActionCalls += 1;
              enqueueCalls += 1;
              return Promise.resolve(candidate);
            },
            fanout: () => {
              fanoutCalls += 1;
              return Promise.resolve();
            },
          });
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error, deletionError);
  assertEquals(leasedActionCalls, 0);
  assertEquals(enqueueCalls, 0);
  assertEquals(fanoutCalls, 0);
});

Deno.test("repair never replays complete start for a different committed identity", async () => {
  const detected = startedRoom();
  const changed = startedRoom({
    match_id: "match-2",
    game_started_event_id: "start-2",
  });
  const expected = committedGameStartIdentity(detected);
  assert(expected);
  let leaseCalls = 0;
  let enqueueCalls = 0;

  const error = await assertRejects(
    () =>
      repairCommittedGameStartWithFreshLeases<Room, LeaseContext>({
        expected,
        refetch: () => Promise.resolve(changed),
        assertParticipant: () => undefined,
        lifecycleUserIDs: () => Promise.resolve(["user-1", "user-2"]),
        withFreshLeases: async <T>(
          _userIDs: readonly unknown[],
          action: (
            context: LeaseContext,
          ) => Promise<T>,
        ) => {
          leaseCalls += 1;
          return await action({ userIDs: ["user-1", "user-2"] });
        },
        currentUserIDs: () => Promise.resolve(["user-1", "user-2"]),
        assertExactLeaseCoverage: () => undefined,
        assertLeasesActive: () => Promise.resolve(),
        migrate: (candidate) => Promise.resolve(candidate),
        reconcile: (candidate) => {
          enqueueCalls += 1;
          return Promise.resolve(candidate);
        },
        fanout: () => Promise.resolve(),
      }),
    Error,
  );

  assertEquals(
    (error as Error & { code?: string }).code,
    "game_start_reconciliation_changed",
  );
  assertEquals(leaseCalls, 0);
  assertEquals(enqueueCalls, 0);
});
