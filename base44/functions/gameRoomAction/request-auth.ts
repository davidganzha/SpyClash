type UserIdentity = {
  id?: unknown;
  email?: unknown;
};

type IdentityClient = {
  auth: {
    me: () => Promise<UserIdentity | null>;
  };
};

export const SPYCLASH_BASE44_APP_ID = "69a0e57fa939f578082f8091";
export const SPYCLASH_BASE44_API_URL = "https://base44.app";

export function hasTrustedRoomActionContext(request: Request): boolean {
  const serviceAuthorization =
    request.headers.get("Base44-Service-Authorization")?.trim() || "";
  return request.headers.get("Base44-App-Id")?.trim() ===
      SPYCLASH_BASE44_APP_ID && serviceAuthorization.startsWith("Bearer ");
}

export function canonicalRoomActionRequest(request: Request): Request {
  const headers = new Headers(request.headers);
  headers.set("Base44-App-Id", SPYCLASH_BASE44_APP_ID);
  headers.set("Base44-Api-Url", SPYCLASH_BASE44_API_URL);
  headers.delete("content-length");
  return new Request(request.url, { method: request.method, headers });
}

export async function resolveRoomActionUser({
  accessToken,
  requestClient,
  createIdentityClient,
}: {
  accessToken: string;
  requestClient: IdentityClient;
  createIdentityClient: (config: {
    appId: string;
    serverUrl: string;
    token: string;
  }) => IdentityClient;
}) {
  if (accessToken) {
    return await createIdentityClient({
      appId: SPYCLASH_BASE44_APP_ID,
      serverUrl: SPYCLASH_BASE44_API_URL,
      token: accessToken,
    }).auth.me();
  }

  // Base44 SSO may keep a valid web identity in the authenticated request
  // without exposing the token to localStorage. In that case the SDK request
  // context is the authoritative user identity.
  return await requestClient.auth.me();
}
