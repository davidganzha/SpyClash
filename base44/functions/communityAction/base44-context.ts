export const SPYCLASH_BASE44_APP_ID = "69a0e57fa939f578082f8091";
export const SPYCLASH_BASE44_API_URL = "https://base44.app";

export function hasTrustedBase44Context(request: Request): boolean {
  const serviceAuthorization =
    request.headers.get("Base44-Service-Authorization")?.trim() || "";
  return request.headers.get("Base44-App-Id")?.trim() ===
      SPYCLASH_BASE44_APP_ID && serviceAuthorization.startsWith("Bearer ");
}

export function canonicalBase44Request(request: Request): Request {
  const headers = new Headers(request.headers);
  headers.set("Base44-App-Id", SPYCLASH_BASE44_APP_ID);
  headers.set("Base44-Api-Url", SPYCLASH_BASE44_API_URL);
  headers.delete("content-length");
  return new Request(request.url, { method: request.method, headers });
}

export function canonicalIdentityClientConfig(token: string) {
  return {
    appId: SPYCLASH_BASE44_APP_ID,
    serverUrl: SPYCLASH_BASE44_API_URL,
    token,
  };
}
