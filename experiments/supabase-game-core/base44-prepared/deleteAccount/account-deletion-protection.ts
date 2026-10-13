export const ADMIN_ACCOUNT_DELETION_CODE =
  "account_deletion_admin_transfer_required";
export const UNVERIFIED_ACCOUNT_ROLE_DELETION_CODE =
  "account_deletion_role_unavailable";

type AuthenticatedUser = {
  role?: unknown;
};

function normalizedRole(user: unknown): string {
  if (!user || typeof user !== "object") return "";
  return String((user as AuthenticatedUser).role ?? "").trim().toLowerCase();
}

/**
 * Base44 does not expose an owner flag to this backend function. The affected
 * owner is represented as an administrator, but the live-app admin role alone
 * does not prove ownership. Conservatively block every administrator and every
 * unclassified role before any deletion lease or irreversible cleanup begins.
 */
export function protectedAccountDeletionResponse(
  user: unknown,
): Response | undefined {
  const role = normalizedRole(user);
  if (role === "user") return undefined;

  if (role !== "admin") {
    return Response.json({
      error:
        "Account role could not be verified. Retry account deletion later.",
      code: UNVERIFIED_ACCOUNT_ROLE_DELETION_CODE,
      retryable: true,
      retry_after_seconds: 60,
    }, {
      status: 503,
      headers: {
        "cache-control": "no-store",
        "retry-after": "60",
      },
    });
  }

  return Response.json({
    error:
      "Administrator accounts cannot be deleted in the app. Transfer ownership and remove administrator access first.",
    code: ADMIN_ACCOUNT_DELETION_CODE,
    retryable: false,
  }, {
    status: 409,
    headers: { "cache-control": "no-store" },
  });
}
