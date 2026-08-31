const SPYCLASH_BASE44_APP_ID = "69a0e57fa939f578082f8091";
const SPYCLASH_BASE44_API_URL = "https://base44.app";

export function canonicalBase44Request(request: Request): Request {
  const headers = new Headers(request.headers);
  headers.set("Base44-App-Id", SPYCLASH_BASE44_APP_ID);
  headers.set("Base44-Api-Url", SPYCLASH_BASE44_API_URL);
  headers.delete("content-length");
  return new Request(request.url, { method: request.method, headers });
}
