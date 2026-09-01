import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  OperationDeadlineError,
  runWithWallClockDeadline,
} from "./operation-deadline.ts";

Deno.test("wall-clock deadline releases a caller even when started work never settles", async () => {
  const startedAt = performance.now();
  const error = await assertRejects(
    () =>
      runWithWallClockDeadline({
        timeoutMS: 20,
        operation: () => new Promise<string>(() => {}),
      }),
    OperationDeadlineError,
  );

  assertEquals(error.code, "operation_deadline_exceeded");
  assertEquals(error.status, 503);
  if (performance.now() - startedAt > 500) {
    throw new Error("wall-clock deadline did not release the caller promptly");
  }
});

Deno.test("wall-clock deadline returns completed work and clears its timer", async () => {
  const result = await runWithWallClockDeadline({
    timeoutMS: 1_000,
    operation: async () => "completed",
  });

  assertEquals(result, "completed");
});
