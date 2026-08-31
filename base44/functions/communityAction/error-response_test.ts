import { assertEquals } from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { communityErrorResponse } from "./error-response.ts";

async function body(response: Response) {
  return await response.json() as Record<string, unknown>;
}

Deno.test("active community lease is a retryable 409 instead of 503", async () => {
  const response = communityErrorResponse(
    new BillingIdentityLifecycleError(
      "active_lease",
      "Account identity is being updated.",
    ),
  );

  assertEquals(response.status, 409);
  assertEquals(response.headers.get("Retry-After"), "1");
  assertEquals(await body(response), {
    error: "Account identity is being updated.",
    code: "active_lease",
    retryable: true,
  });
});

Deno.test("community rate limits preserve 429 and upstream delay", async () => {
  const response = communityErrorResponse({
    status: 429,
    response: { headers: { "Retry-After": "9" } },
  });

  assertEquals(response.status, 429);
  assertEquals(response.headers.get("Retry-After"), "9");
  assertEquals(await body(response), {
    error: "Too many community requests. Retry shortly.",
    code: "rate_limited",
    retryable: true,
  });
});

Deno.test("unexpected community failures do not leak internals", async () => {
  const response = communityErrorResponse(
    new Error("private database connection string"),
  );

  assertEquals(response.status, 500);
  assertEquals(await body(response), {
    error: "Community is temporarily unavailable.",
    code: "community_unavailable",
  });
});

Deno.test("intentional community validation errors stay public", async () => {
  const response = communityErrorResponse(
    Object.assign(new Error("Operative not found"), { status: 404 }),
  );

  assertEquals(response.status, 404);
  assertEquals(await body(response), { error: "Operative not found" });
});
