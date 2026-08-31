import { assertEquals } from "jsr:@std/assert@1";
import { NotificationContractError } from "./contracts.ts";
import { notificationErrorResponse } from "./error-response.ts";

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
