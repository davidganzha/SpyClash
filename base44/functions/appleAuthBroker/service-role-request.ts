export const SPYCLASH_BASE44_APP_ID = "69a0e57fa939f578082f8091";
export const SPYCLASH_BASE44_API_URL = "https://base44.app";

export function requestForBase44ServiceRole(req: Request): Request {
  const headers = new Headers(req.headers);
  const authorization = headers.get("Authorization") || "";

  // The OIDC token endpoint authenticates Base44 with HTTP Basic. The Base44
  // SDK interprets Authorization as an app-user bearer token and rejects any
  // other scheme before it can use the separately injected service token.
  // Client authentication has already been verified by handleToken, so remove
  // only Basic auth from the SDK-facing request while preserving every
  // Base44-* runtime header.
  if (authorization.startsWith("Basic ")) {
    headers.delete("Authorization");
  }
  headers.set("Base44-App-Id", SPYCLASH_BASE44_APP_ID);
  headers.set("Base44-Api-Url", SPYCLASH_BASE44_API_URL);
  headers.delete("content-length");

  return new Request(req.url, { method: req.method, headers });
}
