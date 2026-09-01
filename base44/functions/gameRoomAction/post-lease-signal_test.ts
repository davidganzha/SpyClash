import { assertEquals } from "jsr:@std/assert@1";
import { runPostLeaseSignalWithinDeadline } from "./post-lease-signal.ts";

Deno.test("caller deadline does not release the independent signal lease before late writes finish", async () => {
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

  const completed = await runPostLeaseSignalWithinDeadline({
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
  });

  assertEquals(completed, false);
  assertEquals(leaseHeld, true);
  assertEquals(order, ["lease-acquired"]);

  releaseWrite();
  await leaseReleased;
  assertEquals(leaseHeld, false);
  assertEquals(order, [
    "lease-acquired",
    "late-signal-write",
    "lease-released",
  ]);
});
