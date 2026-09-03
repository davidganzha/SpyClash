import { assertEquals } from "jsr:@std/assert@1";
import { NotificationContractError } from "./contracts.ts";
import { notificationErrorResponse } from "./error-response.ts";
import { safeNotificationErrorDetails } from "./safe-error.ts";

async function body(response: Response) {
  return await response.json() as Record<string, unknown>;
}

Deno.test("notification rate limits remain 429 and tell clients to back off", async () => {
  const response = notificationErrorResponse({
    status: 429,
    response: { headers: { "retry-after": "7" } },
  });

  assertEquals(response.status, 429);
  assertEquals(response.headers.get("Retry-After"), "7");
  assertEquals(await body(response), {
    error: "Too many notification requests. Retry shortly.",
    code: "rate_limited",
    retryable: true,
  });
});

Deno.test("notification upstream outages are normalized to retryable 503", async () => {
  const response = notificationErrorResponse({ statusCode: 504 });

  assertEquals(response.status, 503);
  assertEquals(response.headers.get("Retry-After"), "2");
  assertEquals(await body(response), {
    error: "Notifications are temporarily unavailable.",
    code: "notifications_unavailable",
    retryable: true,
  });
});

Deno.test("notification contract errors keep their public contract", async () => {
  const response = notificationErrorResponse(
    new NotificationContractError("Forbidden", 403, "forbidden"),
  );

  assertEquals(response.status, 403);
  assertEquals(response.headers.get("Retry-After"), null);
  assertEquals(await body(response), { error: "Forbidden", code: "forbidden" });
});

Deno.test("notification lease contention is retryable but deletion remains terminal", async () => {
  for (const code of ["active_lease", "cas_contention"]) {
    const response = notificationErrorResponse(
      new NotificationContractError("Inbox is busy.", 409, code),
    );
    assertEquals(response.status, 409);
    assertEquals(response.headers.get("Retry-After"), "1");
    assertEquals(await body(response), {
      error: "Inbox is busy.",
      code,
      retryable: true,
    });
  }

  const deletion = notificationErrorResponse(
    new NotificationContractError(
      "Account deletion is in progress.",
      409,
      "deletion_in_progress",
    ),
  );
  assertEquals(deletion.status, 409);
  assertEquals(deletion.headers.get("Retry-After"), null);
  assertEquals(await body(deletion), {
    error: "Account deletion is in progress.",
    code: "deletion_in_progress",
  });
});

Deno.test("unexpected notification errors do not leak internal messages", async () => {
  const response = notificationErrorResponse(
    new Error("secret database topology"),
  );

  assertEquals(response.status, 500);
  assertEquals(await body(response), {
    error: "Notifications are temporarily unavailable.",
    code: "notifications_unavailable",
  });
});

Deno.test("cyclic notification SDK errors are reduced before structured logging", async () => {
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
    JSON.stringify(values);
    logged = values;
  };
  try {
    const response = notificationErrorResponse(sdkError);
    assertEquals(response.status, 503);
    assertEquals(await body(response), {
      error: "Notifications are temporarily unavailable.",
      code: "notifications_unavailable",
      retryable: true,
    });
  } finally {
    console.error = originalConsoleError;
  }
  assertEquals(logged, [
    "notificationAction failed",
    "upstream request failed",
    504,
  ]);
});

Deno.test("cyclic notification messages use a bounded scalar fallback", () => {
  const sdkError: Record<string, unknown> = { statusCode: "429" };
  sdkError.message = sdkError;
  sdkError.request = sdkError;

  assertEquals(safeNotificationErrorDetails(sdkError), {
    message: "Unknown notification backend error",
    status: 429,
  });
});
