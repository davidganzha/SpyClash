const APPLE_REVOCATION_ENDPOINT = "https://appleid.apple.com/auth/revoke";
const APPLE_PROVIDER_TIMEOUT_MILLISECONDS = 15_000;

export type AppleTokenCompensationDisposition = "release" | "retain";

export async function compensateUntrackedAppleRefreshToken(input: {
  refreshToken: string;
  clientID: string;
  createClientSecret: (clientID: string) => Promise<string>;
  fetcher?: typeof fetch;
}): Promise<AppleTokenCompensationDisposition> {
  try {
    const response = await (input.fetcher || fetch)(
      APPLE_REVOCATION_ENDPOINT,
      {
        method: "POST",
        headers: {
          Accept: "application/json",
          "Content-Type": "application/x-www-form-urlencoded",
        },
        body: new URLSearchParams({
          client_id: input.clientID,
          client_secret: await input.createClientSecret(input.clientID),
          token: input.refreshToken,
          token_type_hint: "refresh_token",
        }),
        redirect: "error",
        signal: AbortSignal.timeout(APPLE_PROVIDER_TIMEOUT_MILLISECONDS),
      },
    );
    // Apple's revocation endpoint documents HTTP 200 as the sole confirmed
    // success, including a token that was already invalidated. Every other
    // outcome retains the precommitted issuance boundary.
    return response.status === 200 ? "release" : "retain";
  } catch {
    return "retain";
  }
}
