type UserIdentity = {
  id?: unknown;
  email?: unknown;
};

type IdentityClient = {
  auth: {
    me: () => Promise<UserIdentity | null>;
  };
};

export async function resolveRoomActionUser({
  accessToken,
  appId,
  serverUrl,
  requestClient,
  createIdentityClient,
}: {
  accessToken: string;
  appId: string;
  serverUrl: string;
  requestClient: IdentityClient;
  createIdentityClient: (config: {
    appId: string;
    serverUrl: string;
    token: string;
  }) => IdentityClient;
}) {
  if (accessToken) {
    return await createIdentityClient({
      appId,
      serverUrl,
      token: accessToken,
    }).auth.me();
  }

  // Base44 SSO may keep a valid web identity in the authenticated request
  // without exposing the token to localStorage. In that case the SDK request
  // context is the authoritative user identity.
  return await requestClient.auth.me();
}
