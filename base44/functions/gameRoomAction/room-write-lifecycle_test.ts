import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
} from "./billing-identity-lifecycle.ts";
import {
  assertExactRoomLeaseCoverage,
  assertRoomWriteLeases,
  assertRoomWriterLeaseForUser,
  reconcileCommittedGameStartAfterActiveIdentityLease,
  recoverSafeRoomActionAfterActiveIdentityLease,
  retryRoomMembershipChangeBeforeAction,
  uniqueStableUserIDs,
  withRoomWriteLeases,
} from "./room-write-lifecycle.ts";

function lease(userID: string, sequence = 1): BillingIdentityLease {
  return {
    recordID: `${userID}-record`,
    subjectKey: `${userID}-subject`,
    state: "active",
    leaseToken: `${userID}-lease-${sequence}`,
    leaseUntil: "2099-01-01T00:00:00.000Z",
    revision: `${userID}-revision-${sequence}`,
  };
}

Deno.test("room lifecycle identities are stable, unique and deadlock ordered", () => {
  assertEquals(
    uniqueStableUserIDs([" user-z ", "user-a", "user-z", null, ""]),
    ["user-a", "user-z"],
  );
});

Deno.test("stale room snapshot cannot cover a participant who joined while leases were acquired", () => {
  const staleLeaseContext = {
    lifecycleStore: {},
    userIDs: ["host-user", "player-a"],
    leases: [],
  };

  const error = assertThrows(
    () =>
      assertExactRoomLeaseCoverage(staleLeaseContext, [
        "host-user",
        "player-a",
        "concurrent-joiner",
      ]),
    Error,
    "Room membership changed",
  );
  assertEquals((error as Error & { status?: number }).status, 409);
  assertEquals(
    (error as Error & { code?: string }).code,
    "room_membership_changed",
  );
});

Deno.test("exact participant set is independent of ordering and duplicates", () => {
  assertExactRoomLeaseCoverage({
    lifecycleStore: {},
    userIDs: ["host-user", "player-a"],
    leases: [],
  }, ["player-a", "host-user", "player-a"]);
});

Deno.test("membership change before action refetches and retries instead of returning 409", async () => {
  let attemptCalls = 0;
  const delays: number[] = [];

  const result = await retryRoomMembershipChangeBeforeAction({
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
    attempt: (markActionStarted) => {
      attemptCalls += 1;
      if (attemptCalls === 1) {
        const staleContext = {
          lifecycleStore: {},
          userIDs: ["host-user", "joining-user"],
          leases: [],
        };
        assertExactRoomLeaseCoverage(staleContext, [
          "host-user",
          "first-joiner",
          "joining-user",
        ]);
      }
      markActionStarted();
      return Promise.resolve("joined");
    },
  });

  assertEquals(result, "joined");
  assertEquals(attemptCalls, 2);
  assertEquals(delays, [25]);
});

Deno.test("membership error after action start is never replayed", async () => {
  let attemptCalls = 0;
  const delays: number[] = [];

  const error = await assertRejects(
    () =>
      retryRoomMembershipChangeBeforeAction({
        delay: (milliseconds) => {
          delays.push(milliseconds);
          return Promise.resolve();
        },
        attempt: (markActionStarted) => {
          attemptCalls += 1;
          markActionStarted();
          const staleContext = {
            lifecycleStore: {},
            userIDs: ["host-user"],
            leases: [],
          };
          assertExactRoomLeaseCoverage(staleContext, [
            "host-user",
            "late-user",
          ]);
          return Promise.resolve("unreachable");
        },
      }),
    Error,
    "Room membership changed",
  );

  assertEquals(
    (error as Error & { code?: string }).code,
    "room_membership_changed",
  );
  assertEquals(attemptCalls, 1);
  assertEquals(delays, []);
});

Deno.test("history persistence cannot borrow another participant's lease", async () => {
  const error = await assertRejects(
    () =>
      assertRoomWriterLeaseForUser({
        lifecycleStore: {},
        userIDs: ["host-user"],
        leases: [{} as any],
      }, "concurrent-joiner"),
    Error,
    "Room membership changed",
  );
  assertEquals(
    (error as Error & { code?: string }).code,
    "room_membership_changed",
  );
});

Deno.test("room lease acquisition retries contention before invoking the action once", async () => {
  let acquireCalls = 0;
  let actionCalls = 0;
  const delays: number[] = [];
  const released: string[] = [];

  const result = await withRoomWriteLeases({
    lifecycleStore: {},
    userIDs: ["user-a"],
    acquire: async (store, userID) => {
      assertEquals(store, {});
      acquireCalls += 1;
      if (acquireCalls === 1) {
        throw new BillingIdentityLifecycleError(
          "cas_contention",
          "concurrent lease update",
        );
      }
      return lease(userID, acquireCalls);
    },
    release: (_store, acquiredLease) => {
      released.push(acquiredLease.leaseToken);
      return Promise.resolve();
    },
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
    action: (context) => {
      actionCalls += 1;
      assertEquals(context.leases.length, 1);
      return Promise.resolve("written");
    },
  });

  assertEquals(result, "written");
  assertEquals(acquireCalls, 2);
  assertEquals(actionCalls, 1);
  assertEquals(delays, [25]);
  assertEquals(released, ["user-a-lease-2"]);
});

Deno.test("partial room leases are released before acquisition retry", async () => {
  const events: string[] = [];
  let attempt = 1;
  let actionCalls = 0;

  await withRoomWriteLeases({
    lifecycleStore: {},
    userIDs: ["user-b", "user-a"],
    acquire: (_store, userID) => {
      events.push(`acquire-${attempt}-${userID}`);
      if (attempt === 1 && userID === "user-b") {
        throw new BillingIdentityLifecycleError(
          "active_lease",
          "lease is active",
        );
      }
      return Promise.resolve(lease(userID, attempt));
    },
    release: (_store, acquiredLease) => {
      events.push(`release-${acquiredLease.leaseToken}`);
      return Promise.resolve();
    },
    delay: (milliseconds) => {
      events.push(`delay-${milliseconds}`);
      attempt += 1;
      return Promise.resolve();
    },
    action: () => {
      actionCalls += 1;
      events.push("action");
      return Promise.resolve();
    },
  });

  assertEquals(actionCalls, 1);
  assertEquals(events, [
    "acquire-1-user-a",
    "acquire-1-user-b",
    "release-user-a-lease-1",
    "delay-25",
    "acquire-2-user-a",
    "acquire-2-user-b",
    "action",
    "release-user-b-lease-2",
    "release-user-a-lease-2",
  ]);
});

Deno.test("action contention is not retried", async () => {
  let acquireCalls = 0;
  let actionCalls = 0;
  let releaseCalls = 0;
  const delays: number[] = [];

  const error = await assertRejects(
    () =>
      withRoomWriteLeases({
        lifecycleStore: {},
        userIDs: ["user-a"],
        acquire: (_store, userID) => {
          acquireCalls += 1;
          return Promise.resolve(lease(userID));
        },
        release: () => {
          releaseCalls += 1;
          return Promise.resolve();
        },
        delay: (milliseconds) => {
          delays.push(milliseconds);
          return Promise.resolve();
        },
        action: () => {
          actionCalls += 1;
          throw new BillingIdentityLifecycleError(
            "cas_contention",
            "assertion changed concurrently",
          );
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error.code, "cas_contention");
  assertEquals(acquireCalls, 1);
  assertEquals(actionCalls, 1);
  assertEquals(releaseCalls, 1);
  assertEquals(delays, []);
});

for (const code of ["deletion_in_progress", "ambiguous"] as const) {
  Deno.test(`room lease acquisition does not retry ${code}`, async () => {
    let acquireCalls = 0;
    let actionCalls = 0;
    const delays: number[] = [];

    const error = await assertRejects(
      () =>
        withRoomWriteLeases({
          lifecycleStore: {},
          userIDs: ["user-a"],
          acquire: () => {
            acquireCalls += 1;
            throw new BillingIdentityLifecycleError(code, code);
          },
          release: () => Promise.resolve(),
          delay: (milliseconds) => {
            delays.push(milliseconds);
            return Promise.resolve();
          },
          action: () => {
            actionCalls += 1;
            return Promise.resolve();
          },
        }),
      BillingIdentityLifecycleError,
    );

    assertEquals(error.code, code);
    assertEquals(acquireCalls, 1);
    assertEquals(actionCalls, 0);
    assertEquals(delays, []);
  });
}

Deno.test("exhausted room lease contention never invokes the action", async () => {
  let acquireCalls = 0;
  let actionCalls = 0;
  const delays: number[] = [];

  const error = await assertRejects(
    () =>
      withRoomWriteLeases({
        lifecycleStore: {},
        userIDs: ["user-a"],
        acquire: () => {
          acquireCalls += 1;
          throw new BillingIdentityLifecycleError(
            "active_lease",
            "lease is active",
          );
        },
        release: () => Promise.resolve(),
        delay: (milliseconds) => {
          delays.push(milliseconds);
          return Promise.resolve();
        },
        action: () => {
          actionCalls += 1;
          return Promise.resolve();
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error.code, "active_lease");
  assertEquals(acquireCalls, 8);
  assertEquals(actionCalls, 0);
  assertEquals(delays, [25, 50, 100, 200, 400, 800, 1_000]);
  assertEquals(delays.reduce((sum, value) => sum + value, 0), 2_575);
});

Deno.test("mark_role_card_read recovers after an active identity lease", async () => {
  let recoveryCalls = 0;

  const result = await recoverSafeRoomActionAfterActiveIdentityLease({
    action: "mark_role_card_read",
    error: new BillingIdentityLifecycleError(
      "active_lease",
      "Account identity is being updated.",
    ),
    recover: () => {
      recoveryCalls += 1;
      return Promise.resolve("mark_role_card_read-recovered");
    },
  });

  assertEquals(result, "mark_role_card_read-recovered");
  assertEquals(recoveryCalls, 1);
});

Deno.test("leave_room never bypasses an active identity lease", async () => {
  let recoveryCalls = 0;
  const leaseError = new BillingIdentityLifecycleError(
    "active_lease",
    "Account identity is being updated.",
  );

  const error = await assertRejects(
    () =>
      recoverSafeRoomActionAfterActiveIdentityLease({
        action: "leave_room",
        error: leaseError,
        recover: () => {
          recoveryCalls += 1;
          return Promise.resolve("unsafe");
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error, leaseError);
  assertEquals(recoveryCalls, 0);
});

Deno.test("other room actions remain blocked by an active identity lease", async () => {
  let recoveryCalls = 0;
  const leaseError = new BillingIdentityLifecycleError(
    "active_lease",
    "Account identity is being updated.",
  );

  const error = await assertRejects(
    () =>
      recoverSafeRoomActionAfterActiveIdentityLease({
        action: "pause_game",
        error: leaseError,
        recover: () => {
          recoveryCalls += 1;
          return Promise.resolve("unsafe");
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error, leaseError);
  assertEquals(recoveryCalls, 0);
});

Deno.test("complete game start reconciles only after committed start identity is visible", async () => {
  const leaseError = new BillingIdentityLifecycleError(
    "active_lease",
    "Account identity is being updated.",
  );
  const rooms = [
    { id: "room-1", status: "roulette" },
    { id: "room-1", status: "playing", match_id: "match-1" },
    {
      id: "room-1",
      status: "playing",
      match_id: "match-1",
      game_started_event_id: "start-1",
    },
  ];
  const delays: number[] = [];
  let refetchCalls = 0;
  let participantChecks = 0;
  let repairCalls = 0;

  const result = await reconcileCommittedGameStartAfterActiveIdentityLease({
    action: "complete_game_start",
    error: leaseError,
    delay: (milliseconds) => {
      delays.push(milliseconds);
      return Promise.resolve();
    },
    refetch: () => Promise.resolve(rooms[refetchCalls++]),
    assertParticipant: () => {
      participantChecks += 1;
    },
    repair: (room) => {
      repairCalls += 1;
      return Promise.resolve(room);
    },
  });

  assertEquals(result, rooms[2]);
  assertEquals(refetchCalls, 3);
  assertEquals(delays, [50, 100]);
  assertEquals(participantChecks, 1);
  assertEquals(repairCalls, 1);
});

Deno.test("incomplete game start reconciliation is bounded and rethrows the lease error", async () => {
  const leaseError = new BillingIdentityLifecycleError(
    "active_lease",
    "Account identity is being updated.",
  );
  const delays: number[] = [];
  let refetchCalls = 0;
  let participantChecks = 0;
  let repairCalls = 0;

  const error = await assertRejects(
    () =>
      reconcileCommittedGameStartAfterActiveIdentityLease({
        action: "complete_game_start",
        error: leaseError,
        delay: (milliseconds) => {
          delays.push(milliseconds);
          return Promise.resolve();
        },
        refetch: () => {
          refetchCalls += 1;
          return Promise.resolve({
            id: "room-1",
            status: "playing",
            match_id: "match-1",
            game_started_event_id: "",
          });
        },
        assertParticipant: () => {
          participantChecks += 1;
        },
        repair: (room) => {
          repairCalls += 1;
          return Promise.resolve(room);
        },
      }),
    BillingIdentityLifecycleError,
  );

  assertEquals(error, leaseError);
  assertEquals(refetchCalls, 6);
  assertEquals(delays, [50, 100, 200, 400, 800]);
  assertEquals(participantChecks, 0);
  assertEquals(repairCalls, 0);
});

Deno.test("game start reconciliation never bypasses non-lease lifecycle errors", async () => {
  const blockedErrors: Array<{ action: string; error: unknown }> = [
    {
      action: "pause_game",
      error: new BillingIdentityLifecycleError(
        "active_lease",
        "Account identity is being updated.",
      ),
    },
    {
      action: "complete_game_start",
      error: new BillingIdentityLifecycleError(
        "deletion_in_progress",
        "Account deletion is in progress or already completed.",
      ),
    },
    {
      action: "complete_game_start",
      error: Object.assign(new Error("untyped"), { code: "active_lease" }),
    },
  ];

  for (const blocked of blockedErrors) {
    let delayCalls = 0;
    let refetchCalls = 0;
    const error = await assertRejects(() =>
      reconcileCommittedGameStartAfterActiveIdentityLease({
        ...blocked,
        delay: () => {
          delayCalls += 1;
          return Promise.resolve();
        },
        refetch: () => {
          refetchCalls += 1;
          return Promise.resolve({
            status: "playing",
            match_id: "match-1",
            game_started_event_id: "start-1",
          });
        },
        assertParticipant: () => Promise.resolve(),
        repair: (room) => Promise.resolve(room),
      })
    );
    assertEquals(error, blocked.error);
    assertEquals(delayCalls, 0);
    assertEquals(refetchCalls, 0);
  }
});

for (const action of ["leave_room", "mark_role_card_read"] as const) {
  Deno.test(`${action} recovery does not bypass account deletion`, async () => {
    let recoveryCalls = 0;
    const deletionError = new BillingIdentityLifecycleError(
      "deletion_in_progress",
      "Account deletion is in progress or already completed.",
    );

    const error = await assertRejects(
      () =>
        recoverSafeRoomActionAfterActiveIdentityLease({
          action,
          error: deletionError,
          recover: () => {
            recoveryCalls += 1;
            return Promise.resolve("unsafe");
          },
        }),
      BillingIdentityLifecycleError,
    );

    assertEquals(error, deletionError);
    assertEquals(recoveryCalls, 0);
  });
}

Deno.test("partial lease release failure aborts acquisition retry", async () => {
  let acquireCalls = 0;
  let actionCalls = 0;
  let delayCalls = 0;
  const releaseError = new Error("partial release failed");

  const error = await assertRejects(
    () =>
      withRoomWriteLeases({
        lifecycleStore: {},
        userIDs: ["user-a", "user-b"],
        acquire: (_store, userID) => {
          acquireCalls += 1;
          if (userID === "user-b") {
            throw new BillingIdentityLifecycleError(
              "cas_contention",
              "concurrent lease update",
            );
          }
          return Promise.resolve(lease(userID));
        },
        release: () => Promise.reject(releaseError),
        delay: () => {
          delayCalls += 1;
          return Promise.resolve();
        },
        action: () => {
          actionCalls += 1;
          return Promise.resolve();
        },
      }),
    Error,
    "partial release failed",
  );

  assertEquals(error, releaseError);
  assertEquals(acquireCalls, 2);
  assertEquals(actionCalls, 0);
  assertEquals(delayCalls, 2);
});

Deno.test("committed action result survives bounded release failure", async () => {
  let releaseCalls = 0;
  const delays: number[] = [];
  let loggedFailures = 0;
  const cyclicReleaseError: Record<string, unknown> = {
    message: "release unavailable",
    status: 503,
    code: "lease_release_failed",
  };
  cyclicReleaseError.self = cyclicReleaseError;
  const originalConsoleError = console.error;
  console.error = (...values: unknown[]) => {
    JSON.stringify(values);
    loggedFailures += 1;
  };

  try {
    const result = await withRoomWriteLeases({
      lifecycleStore: {},
      userIDs: ["user-a"],
      acquire: (_store, userID) => Promise.resolve(lease(userID)),
      release: () => {
        releaseCalls += 1;
        return Promise.reject(cyclicReleaseError);
      },
      delay: (milliseconds) => {
        delays.push(milliseconds);
        return Promise.resolve();
      },
      action: () => Promise.resolve("committed"),
    });

    assertEquals(result, "committed");
  } finally {
    console.error = originalConsoleError;
  }

  assertEquals(releaseCalls, 3);
  assertEquals(delays, [25, 50]);
  assertEquals(loggedFailures, 1);
});

function gate<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((yes, no) => {
    resolve = yes;
    reject = no;
  });
  return { promise, resolve, reject };
}

Deno.test("participant validation overlaps four reads and awaits siblings before throwing", async () => {
  const leases = Array.from(
    { length: 6 },
    (_, index) => lease(`user-${index}`),
  );
  const reads = leases.map(() => gate<Record<string, unknown>[]>());
  const started: number[] = [];
  const failure = new Error("storage unavailable");
  const lifecycleStore = {
    filter: ({ subject_key }: { subject_key: string }) => {
      const index = leases.findIndex((value) =>
        value.subjectKey === subject_key
      );
      started.push(index);
      return reads[index].promise;
    },
  };
  let settled = false;
  const operation = assertRoomWriteLeases({
    lifecycleStore,
    leases,
    userIDs: [],
  })
    .then(() => {
      settled = true;
    }, (error) => {
      settled = true;
      return error;
    });
  assertEquals(started, [0, 1, 2, 3]);
  reads[0].reject(failure);
  await Promise.resolve();
  await Promise.resolve();
  assertEquals(settled, false);
  for (const index of [1, 2, 3]) {
    const current = leases[index];
    reads[index].resolve([{
      id: current.recordID,
      subject_key: current.subjectKey,
      state: current.state,
      lease_token: current.leaseToken,
      lease_until: current.leaseUntil,
      revision: current.revision,
    }]);
  }
  assertEquals(await operation, failure);
  assertEquals(started, [0, 1, 2, 3]);
});

Deno.test("participant releases overlap in bounded waves and response awaits the final release", async () => {
  const userIDs = Array.from({ length: 6 }, (_, index) => `user-${index}`);
  const releases = userIDs.map(() => gate<void>());
  const firstWave = gate<void>();
  const secondWave = gate<void>();
  const started: number[] = [];
  const acquired: string[] = [];
  let settled = false;
  const operation = withRoomWriteLeases({
    lifecycleStore: {},
    userIDs,
    acquire: (_store, userID) => {
      acquired.push(userID);
      return Promise.resolve(lease(userID));
    },
    release: (_store, current) => {
      const index = userIDs.findIndex((userID) =>
        current.recordID === `${userID}-record`
      );
      started.push(index);
      if (started.length === 4) firstWave.resolve();
      if (started.length === 6) secondWave.resolve();
      return releases[index].promise;
    },
    action: () => Promise.resolve("committed"),
  }).then((value) => {
    settled = true;
    return value;
  });
  await firstWave.promise;
  assertEquals(acquired, userIDs);
  assertEquals(started, [5, 4, 3, 2]);
  assertEquals(settled, false);
  for (const index of [5, 4, 3]) releases[index].resolve();
  await Promise.resolve();
  assertEquals(started.length, 4);
  releases[2].resolve();
  await secondWave.promise;
  assertEquals(started, [5, 4, 3, 2, 1, 0]);
  releases[1].resolve();
  await Promise.resolve();
  assertEquals(settled, false);
  releases[0].resolve();
  assertEquals(await operation, "committed");
});

Deno.test("one exhausted cleanup never skips another participant or releases the response early", async () => {
  const slow = gate<void>();
  const slowStarted = gate<void>();
  const failedFinished = gate<void>();
  let failedAttempts = 0;
  let settled = false;
  let logs = 0;
  const originalLog = console.error;
  console.error = () => {
    logs += 1;
  };
  try {
    const operation = withRoomWriteLeases({
      lifecycleStore: {},
      userIDs: ["user-a", "user-b"],
      acquire: (_store, userID) => Promise.resolve(lease(userID)),
      delay: () => Promise.resolve(),
      release: (_store, current) => {
        if (current.recordID === "user-a-record") {
          slowStarted.resolve();
          return slow.promise;
        }
        failedAttempts += 1;
        if (failedAttempts === 3) failedFinished.resolve();
        return Promise.reject(new Error("release unavailable"));
      },
      action: () => Promise.resolve("committed once"),
    }).then((value) => {
      settled = true;
      return value;
    });
    await slowStarted.promise;
    await failedFinished.promise;
    assertEquals(failedAttempts, 3);
    assertEquals(settled, false);
    slow.resolve();
    assertEquals(await operation, "committed once");
    assertEquals(logs, 1);
  } finally {
    console.error = originalLog;
  }
});
