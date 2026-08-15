import { AppleSignInCredentialError } from "./apple-sign-in-credential.ts";

export type PublicAppleCredentialBrokerError = {
  code: "invalid_grant" | "temporarily_unavailable";
  status: 400 | 503;
};

/**
 * Maps internal Apple credential failures to the intentionally small public
 * OIDC error surface. Internal lifecycle, storage, and encryption details must
 * never be returned to the client.
 */
export function publicAppleCredentialBrokerError(
  error: unknown,
): PublicAppleCredentialBrokerError | undefined {
  if (!(error instanceof AppleSignInCredentialError)) return undefined;

  return error.status >= 500
    ? { code: "temporarily_unavailable", status: 503 }
    : { code: "invalid_grant", status: 400 };
}
