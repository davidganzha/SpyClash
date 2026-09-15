import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { PushContractError } from "./contracts.ts";
import { safePushErrorDetails } from "./safe-error.ts";

function retryable(
  message: string,
  status: 409 | 429 | 503,
  code: string,
  seconds: number,
): Response {
  return Response.json(
    { error: message, code, retryable: true },
    { status, headers: { "Retry-After": String(seconds) } },
  );
}

export function pushErrorResponse(error: unknown): Response {
  if (error instanceof PushContractError) {
    if (error.status === 409 &&
      ["device_owner_changed", "activity_owner_changed"].includes(error.code)) {
      return retryable(error.message, 409, error.code, 1);
    }
    if (error.status === 429 || error.status === 503) {
      return retryable(error.message, error.status, error.code, 2);
    }
    return Response.json({ error: error.message, code: error.code }, {
      status: error.status,
    });
  }
  if (error instanceof BillingIdentityLifecycleError) {
    const conflict = ["deletion_in_progress", "active_lease", "cas_contention"]
      .includes(error.code);
    return Response.json({
      error: "Push registration is temporarily unavailable.",
      code: error.code,
      retryable: error.retryable,
    }, {
      status: conflict ? 409 : 503,
      ...(error.retryable ? { headers: { "Retry-After": "1" } } : {}),
    });
  }

  const details = safePushErrorDetails(error);
  console.error(
    "pushNotificationAction failed",
    details.message,
    details.status || 500,
  );
  const status = details.status;
  if (status === 429) {
    return retryable(
      "Too many push requests. Retry shortly.",
      429,
      "rate_limited",
      2,
    );
  }
  if (status === 502 || status === 503 || status === 504) {
    return retryable(
      "Push service is temporarily unavailable.",
      503,
      "push_unavailable",
      2,
    );
  }
  return Response.json({
    error: "Push service is temporarily unavailable.",
    code: "push_unavailable",
  }, { status: 500 });
}
