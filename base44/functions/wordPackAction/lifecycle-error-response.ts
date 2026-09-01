import { BillingIdentityLifecycleError } from "./billing-identity-lifecycle.ts";

function lifecycleStatus(error: BillingIdentityLifecycleError): number {
  return ["deletion_in_progress", "active_lease", "cas_contention"].includes(
      error.code,
    )
    ? 409
    : 503;
}

/**
 * Only pre-action writer contention is safe for a client retry. Account
 * deletion and ambiguous lifecycle state remain terminal/fail-closed.
 */
export function wordPackLifecycleErrorResponse(
  error: BillingIdentityLifecycleError,
): Response {
  const status = lifecycleStatus(error);
  const retryable = status === 409 &&
    ["active_lease", "cas_contention"].includes(error.code);
  return Response.json(
    {
      error: error.message,
      code: error.code,
      ...(retryable ? { retryable: true } : {}),
    },
    {
      status,
      ...(retryable ? { headers: { "Retry-After": "1" } } : {}),
    },
  );
}
