import { BILLING_IDENTITY_LEASE_MILLISECONDS } from "./billing-identity-lifecycle.ts";

export const ACCOUNT_DELETION_RETRY_AFTER_SECONDS = Math.ceil(
  BILLING_IDENTITY_LEASE_MILLISECONDS / 1_000,
);

export function retryableAccountDeletionResponse(
  error: string,
  code: string,
): Response {
  return Response.json({
    error,
    code,
    retryable: true,
    retry_after_seconds: ACCOUNT_DELETION_RETRY_AFTER_SECONDS,
  }, {
    status: 503,
    headers: {
      "cache-control": "no-store",
      "retry-after": String(ACCOUNT_DELETION_RETRY_AFTER_SECONDS),
    },
  });
}
