export const SPYCLASH_BASE44_APP_ID = "69a0e57fa939f578082f8091";
export const SPYCLASH_BASE44_API_URL = "https://base44.app";

export function hasTrustedBase44Context(request: Request): boolean {
  const serviceAuthorization =
    request.headers.get("Base44-Service-Authorization")?.trim() || "";
  return request.headers.get("Base44-App-Id")?.trim() ===
      SPYCLASH_BASE44_APP_ID && serviceAuthorization.startsWith("Bearer ");
}

export function canonicalIdentityClientConfig(token: string) {
  return {
    appId: SPYCLASH_BASE44_APP_ID,
    serverUrl: SPYCLASH_BASE44_API_URL,
    token,
  };
}
