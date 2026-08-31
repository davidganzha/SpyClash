import { assertEquals } from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { pushErrorResponse } from "./error-response.ts";

Deno.test("push lifecycle contention preserves its retryable code", async () => {
  const response = pushErrorResponse(
    new BillingIdentityLifecycleError(
      "active_lease",
      "Account identity is being updated.",
    ),
  );

  assertEquals(response.status, 409);
  assertEquals(response.headers.get("Retry-After"), "1");
  assertEquals(await response.json(), {
    error: "Push registration is temporarily unavailable.",
    code: "active_lease",
    retryable: true,
  });
});

Deno.test("push rate limits are not disguised as 500", async () => {
  const response = pushErrorResponse({ statusCode: 429 });

  assertEquals(response.status, 429);
  assertEquals(await response.json(), {
    error: "Too many push requests. Retry shortly.",
    code: "rate_limited",
    retryable: true,
  });
});
