import { assertEquals, assertStrictEquals } from "jsr:@std/assert@1";
import {
  internalFunctionBody,
  profileRepairDrainSummary,
} from "./internal-function-response.ts";

Deno.test("raw backend invoke response is unwrapped without serializing its request cycle", () => {
  const redirectableRequest: Record<string, unknown> = {};
  const currentRequest: Record<string, unknown> = {
    _redirectable: redirectableRequest,
  };
  redirectableRequest._currentRequest = currentRequest;
  const response: Record<string, unknown> = {
    data: {
      ok: true,
      outcome: "completed",
      selected: 4,
      performed: 2,
      completed: 1,
      deferred: 1,
    },
    request: redirectableRequest,
  };

  assertStrictEquals(
    (redirectableRequest._currentRequest as Record<string, unknown>)
      ._redirectable,
    redirectableRequest,
  );
  assertEquals(internalFunctionBody(response), response.data);
  assertEquals(internalFunctionBody(response).outcome, "completed");
  const summary = profileRepairDrainSummary(response);
  assertEquals(summary, {
    ok: true,
    selected: 4,
    performed: 2,
    completed: 1,
    deferred: 1,
  });
  assertEquals(
    JSON.stringify(summary),
    '{"ok":true,"selected":4,"performed":2,"completed":1,"deferred":1}',
  );
  assertEquals(
    Response.json({ community_profile_repairs: summary }).status,
    200,
  );
});

Deno.test("unwrapped and malformed internal results produce a bounded plain summary", () => {
  assertEquals(
    profileRepairDrainSummary({
      ok: true,
      selected: "3",
      performed: -2,
      completed: Number.POSITIVE_INFINITY,
      deferred: 2_000_000,
    }),
    {
      ok: true,
      selected: 3,
      performed: 0,
      completed: 0,
      deferred: 1_000_000,
    },
  );

  const cyclic: Record<string, unknown> = {};
  cyclic.data = cyclic;
  assertEquals(profileRepairDrainSummary(cyclic), {
    ok: false,
    selected: 0,
    performed: 0,
    completed: 0,
    deferred: 0,
  });
});
