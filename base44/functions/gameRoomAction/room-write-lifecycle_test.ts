import { assertEquals, assertRejects, assertThrows } from "jsr:@std/assert@1";
import {
  type BillingIdentityLease,
  BillingIdentityLifecycleError,
} from "./billing-identity-lifecycle.ts";
import {
  assertExactRoomLeaseCoverage,
  assertRoomWriterLeaseForUser,
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
  assertEquals(acquireCalls, 6);
  assertEquals(actionCalls, 0);
  assertEquals(delays, [25, 50, 100, 200, 400]);
});

for (const action of ["leave_room", "mark_role_card_read"] as const) {
  Deno.test(`${action} recovers after an active identity lease`, async () => {
    let recoveryCalls = 0;

    const result = await recoverSafeRoomActionAfterActiveIdentityLease({
      action,
      error: new BillingIdentityLifecycleError(
        "active_lease",
        "Account identity is being updated.",
      ),
      recover: () => {
        recoveryCalls += 1;
        return Promise.resolve(`${action}-recovered`);
      },
    });

    assertEquals(result, `${action}-recovered`);
    assertEquals(recoveryCalls, 1);
  });
}

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
  const originalConsoleError = console.error;
  console.error = () => {
    loggedFailures += 1;
  };

  try {
    const result = await withRoomWriteLeases({
      lifecycleStore: {},
      userIDs: ["user-a"],
      acquire: (_store, userID) => Promise.resolve(lease(userID)),
      release: () => {
        releaseCalls += 1;
        return Promise.reject(new Error("release unavailable"));
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
