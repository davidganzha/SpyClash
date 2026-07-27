import { assertEquals } from "jsr:@std/assert@1";
import { clampDeadline, runBounded } from "./bounded-work.ts";

Deno.test("deadline clamp preserves an already-expired caller deadline", () => {
  const now = 10_000;
  assertEquals(clampDeadline(9_000, 5_000, now), 9_000);
  assertEquals(clampDeadline(99_000, 5_000, now), 15_000);
  assertEquals(clampDeadline(undefined, 5_000, now), 15_000);
});

Deno.test("bounded worker never exceeds configured concurrency", async () => {
  let active = 0;
  let peak = 0;
  const result = await runBounded({
    items: [1, 2, 3, 4, 5, 6],
    concurrency: 3,
    deadlineEpochMs: Date.now() + 5_000,
    worker: async () => {
      active += 1;
      peak = Math.max(peak, active);
      await new Promise((resolve) => setTimeout(resolve, 2));
      active -= 1;
    },
  });
  assertEquals(peak, 3);
  assertEquals(result.completed.length, 6);
  assertEquals(result.unstarted, []);
});

Deno.test("expired deadline leaves work unstarted for durable retry", async () => {
  const result = await runBounded({
    items: [1, 2, 3],
    concurrency: 2,
    deadlineEpochMs: Date.now() - 1,
    worker: async () => {},
  });
  assertEquals(result.completed, []);
  assertEquals(result.unstarted, [1, 2, 3]);
});

Deno.test("injected clock stops new work after a completed item exhausts the deadline", async () => {
  let epoch = 0;
  const started: number[] = [];
  const result = await runBounded({
    items: [1, 2, 3],
    concurrency: 1,
    deadlineEpochMs: 50,
    nowEpochMs: () => epoch,
    worker: async (item) => {
      started.push(item);
      epoch = 50;
    },
  });
  assertEquals(started, [1]);
  assertEquals(result.completed, [1]);
  assertEquals(result.unstarted, [2, 3]);
});
