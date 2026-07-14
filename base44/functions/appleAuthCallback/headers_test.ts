import { copyResponseHeaders } from "./headers.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("Apple callback drops worker cookies and preserves both app clears", () => {
  const source = new Headers();
  source.append(
    "Set-Cookie",
    "__Host-SpyClashOAuthTransaction=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=None, " +
      "__Host-SpyClashNativeOIDC=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax, " +
      "__cf_bm=worker; HttpOnly; Domain=base44.workers.dev; " +
      "Expires=Sat, 11 Jul 2026 22:23:43 GMT",
  );

  const copied = copyResponseHeaders(source) as Headers & {
    getSetCookie?: () => string[];
  };
  const cookies = (copied.getSetCookie?.() ||
    (copied.get("set-cookie") ? [copied.get("set-cookie")!] : [])).join("\n");
  assert(
    cookies.includes("__Host-SpyClashOAuthTransaction="),
    "transaction clear was dropped",
  );
  assert(
    cookies.includes("__Host-SpyClashNativeOIDC="),
    "native clear was dropped",
  );
  assert(!cookies.includes("__cf_bm"), "worker cookie leaked through proxy");
});
