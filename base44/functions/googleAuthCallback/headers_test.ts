import { copyResponseHeaders } from "./headers.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

function copiedSetCookies(source: Headers) {
  const copied = copyResponseHeaders(source) as Headers & {
    getSetCookie?: () => string[];
  };
  return copied.getSetCookie?.() ||
    (copied.get("set-cookie") ? [copied.get("set-cookie")!] : []);
}

Deno.test("Google callback keeps both SpyClash transaction cookies", () => {
  const source = new Headers({
    "Content-Encoding": "br",
    "Content-Type": "text/html",
  });
  source.append(
    "Set-Cookie",
    "__Host-SpyClashOAuthTransaction=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=None, " +
      "__Secure-SpyClashOAuthTransactionFallback=; Max-Age=0; Path=/functions/; Secure; SameSite=None, " +
      "__cf_bm=worker; HttpOnly; Domain=base44.workers.dev; " +
      "Expires=Sat, 11 Jul 2026 22:23:43 GMT",
  );

  const cookies = copiedSetCookies(source).join("\n");
  assert(
    cookies.includes("__Host-SpyClashOAuthTransaction="),
    "transaction clear was dropped",
  );
  assert(
    cookies.includes("__Secure-SpyClashOAuthTransactionFallback="),
    "fallback transaction clear was dropped",
  );
  assert(!cookies.includes("__cf_bm"), "worker cookie leaked through proxy");
  assert(
    copyResponseHeaders(source).get("content-encoding") === null,
    "transport encoding was copied",
  );
  assert(
    copyResponseHeaders(source).get("content-type") === "text/html",
    "safe response header was dropped",
  );
});
