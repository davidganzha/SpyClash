import { assertEquals } from "jsr:@std/assert@1";
import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { pushErrorResponse } from "./error-response.ts";
import { safePushErrorDetails } from "./safe-error.ts";

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

Deno.test("cyclic SDK errors are reduced before logging or JSON response", async () => {
  const sdkResponse: Record<string, unknown> = { status: 504 };
  const sdkError: Record<string, unknown> = {
    message: "upstream request failed",
    response: sdkResponse,
  };
  sdkError.self = sdkError;
  sdkResponse.error = sdkError;

  const originalConsoleError = console.error;
  let logged: unknown[] = [];
  console.error = (...values: unknown[]) => {
    // Mirrors a structured logger that serializes all arguments. Passing the
    // SDK error itself would throw because request and response form a cycle.
    JSON.stringify(values);
    logged = values;
  };
  try {
    const response = pushErrorResponse(sdkError);
    assertEquals(response.status, 503);
    assertEquals(response.headers.get("Retry-After"), "2");
    assertEquals(await response.json(), {
      error: "Push service is temporarily unavailable.",
      code: "push_unavailable",
      retryable: true,
    });
  } finally {
    console.error = originalConsoleError;
  }
  assertEquals(logged, [
    "pushNotificationAction failed",
    "upstream request failed",
    504,
  ]);
});

Deno.test("cyclic non-scalar SDK messages use a bounded scalar fallback", () => {
  const sdkError: Record<string, unknown> = { statusCode: "429" };
  sdkError.message = sdkError;
  sdkError.request = sdkError;

  const details = safePushErrorDetails(sdkError);
  assertEquals(details, {
    message: "Unknown push backend error",
    status: 429,
  });
  assertEquals(
    JSON.stringify(details),
    '{"message":"Unknown push backend error","status":429}',
  );
});
