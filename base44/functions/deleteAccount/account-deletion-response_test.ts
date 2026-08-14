import {
  ACCOUNT_DELETION_RETRY_AFTER_SECONDS,
  retryableAccountDeletionResponse,
} from "./account-deletion-response.ts";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

Deno.test("retryable deletion response exposes the retained lease delay", async () => {
  const response = retryableAccountDeletionResponse(
    "Account deletion is incomplete.",
    "apple_revocation_unavailable",
  );
  const body = await response.json();

  assert(response.status === 503, "retry response status changed");
  assert(
    ACCOUNT_DELETION_RETRY_AFTER_SECONDS === 600,
    "retry delay drifted from the deletion lease",
  );
  assert(
    response.headers.get("retry-after") === "600",
    "Retry-After header is missing",
  );
  assert(
    response.headers.get("cache-control") === "no-store",
    "retry response became cacheable",
  );
  assert(body.retryable === true, "retryable flag is missing");
  assert(
    body.retry_after_seconds === 600,
    "JSON retry delay is missing",
  );
  assert(
    body.code === "apple_revocation_unavailable",
    "retry code is missing",
  );
});
