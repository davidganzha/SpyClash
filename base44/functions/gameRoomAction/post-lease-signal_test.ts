import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  runLatestRoomSignalAfterLeaseContention,
  runPostLeaseSignalWithinDeadline,
} from "./post-lease-signal.ts";

Deno.test("signal response waits for a late write and its account lease cleanup", async () => {
  let releaseWrite!: () => void;
  let releaseLease!: () => void;
  const writeGate = new Promise<void>((resolve) => {
    releaseWrite = resolve;
  });
  const leaseReleased = new Promise<void>((resolve) => {
    releaseLease = resolve;
  });
  const order: string[] = [];
  let leaseHeld = false;

  let responded = false;
  const response = runPostLeaseSignalWithinDeadline({
    timeoutMS: 20,
    leasedOperation: async () => {
      leaseHeld = true;
      order.push("lease-acquired");
      try {
        await writeGate;
        order.push("late-signal-write");
        return true;
      } finally {
        leaseHeld = false;
        order.push("lease-released");
        releaseLease();
      }
    },
  }).then((value) => {
    responded = true;
    return value;
  });

  await new Promise((resolve) => setTimeout(resolve, 30));
  assertEquals(responded, false);
  assertEquals(leaseHeld, true);
  assertEquals(order, ["lease-acquired"]);

  releaseWrite();
  await leaseReleased;
  assertEquals(await response, true);
  assertEquals(leaseHeld, false);
  assertEquals(order, [
    "lease-acquired",
    "late-signal-write",
    "lease-released",
  ]);
});

Deno.test("signal budget skips later work and awaits cleanup before reporting deferral", async () => {
  let epoch = 0;
  const order: string[] = [];
  const completed = await runPostLeaseSignalWithinDeadline({
    timeoutMS: 600,
    nowEpochMS: () => epoch,
    leasedOperation: async (budget) => {
      order.push("lease-acquired");
      try {
        epoch = 601;
        budget.assertCanStart();
        order.push("signal-created");
        return true;
      } finally {
        await Promise.resolve();
        order.push("lease-released");
      }
    },
  });
  assertEquals(completed, false);
  assertEquals(order, ["lease-acquired", "lease-released"]);
});

Deno.test("latest signal repair never retries through account deletion", async () => {
  let attempts = 0;
  let latestReads = 0;
  const error = Object.assign(new Error("account deletion owns the identity"), {
    code: "deletion_in_progress",
  });

  await assertRejects(() =>
    runLatestRoomSignalAfterLeaseContention({
      initial: { room_revision: 1 },
      attempt: () => {
        attempts += 1;
        return Promise.reject(error);
      },
      loadLatest: () => {
        latestReads += 1;
        return Promise.resolve({ room_revision: 2 });
      },
      delay: () => Promise.resolve(),
    })
  );

  assertEquals(attempts, 1);
  assertEquals(latestReads, 0);
});

Deno.test("active-lease repair stops if account deletion wins before the retry", async () => {
  let attempts = 0;
  let latestReads = 0;

  await assertRejects(() =>
    runLatestRoomSignalAfterLeaseContention({
      initial: { room_revision: 1 },
      attempt: () => {
        attempts += 1;
        return Promise.reject(Object.assign(new Error("identity busy"), {
          code: attempts === 1 ? "active_lease" : "deletion_in_progress",
        }));
      },
      loadLatest: () => {
        latestReads += 1;
        return Promise.resolve({ room_revision: 2 });
      },
      delay: () => Promise.resolve(),
    })
  );

  assertEquals(attempts, 2);
  assertEquals(latestReads, 1);
});
