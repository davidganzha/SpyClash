import { assertEquals, assertGreater } from "jsr:@std/assert@1";
import {
  normalizePushDrainLimit,
  PUSH_DRAIN_DEFAULT_BATCH,
  pushDrainQueryLimit,
} from "./drain-policy.ts";

Deno.test("scheduled drain runs every minute with a batch substantially above eight", async () => {
  const configuration = JSON.parse(
    await Deno.readTextFile(new URL("./function.jsonc", import.meta.url)),
  );
  const scheduled = configuration.automations[0];
  assertEquals(scheduled.repeat_unit, "minutes");
  assertEquals(scheduled.repeat_interval, 1);
  assertEquals(scheduled.function_args.limit, 64);
  assertEquals(normalizePushDrainLimit(undefined), PUSH_DRAIN_DEFAULT_BATCH);
  assertGreater(normalizePushDrainLimit(undefined), 8);
  assertGreater(pushDrainQueryLimit(64), normalizePushDrainLimit(64));
});

Deno.test("drain batch normalization is bounded", () => {
  assertEquals(normalizePushDrainLimit(0), 1);
  assertEquals(normalizePushDrainLimit(10_000), 96);
  assertEquals(normalizePushDrainLimit(64.9), 64);
});
