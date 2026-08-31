import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";
import { PushContractError } from "./contracts.ts";

type ErrorShape = {
  status?: unknown;
  statusCode?: unknown;
  response?: { status?: unknown };
};

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
    return retryable(
      "Push registration is temporarily unavailable.",
      conflict ? 409 : 503,
      error.code,
      conflict ? 1 : 2,
    );
  }

  console.error(
    "pushNotificationAction failed",
    error instanceof Error ? error.message : error,
  );
  const shape = error as ErrorShape | null;
  const status = Number(
    shape?.status ?? shape?.statusCode ?? shape?.response?.status ?? 0,
  );
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
