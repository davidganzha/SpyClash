import {
  fallbackGoogleTransactionHandoff,
  primaryGoogleTransactionHandoff,
} from "./handoff.ts";
import {
  upstreamFallbackTransactionCookie,
  upstreamTransactionCookie,
} from "./transaction.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

function assertStrictHandoffHeaders(response: Response) {
  assert(response.status === 200, "handoff is not an HTML settle response");
  assert(response.headers.get("cache-control") === "no-store", "cache enabled");
  assert(response.headers.get("pragma") === "no-cache", "legacy cache enabled");
  assert(
    response.headers.get("referrer-policy") === "no-referrer",
    "referrer can leak state",
  );
  assert(
    response.headers.get("x-content-type-options") === "nosniff",
    "MIME sniffing is enabled",
  );
  const csp = response.headers.get("content-security-policy") || "";
  assert(csp.includes("default-src 'none'"), "CSP default is not closed");
  assert(csp.includes("script-src 'nonce-"), "CSP nonce missing");
  assert(csp.includes("frame-ancestors 'none'"), "handoff can be framed");
  assert(csp.includes("form-action 'none'"), "handoff can submit forms");
}

Deno.test("primary Google handoff settles before confirmation", async () => {
  const secret = "A".repeat(43);
  const confirmationURL =
    "https://spyclash.com/functions/appleAuthBroker?action=confirm-google-transaction&state=signed-hash-only";
  const cookie = upstreamTransactionCookie(secret, 300, "None");
  const response = primaryGoogleTransactionHandoff(confirmationURL, cookie);
  assertStrictHandoffHeaders(response);
  assert(
    response.headers.get("set-cookie") === cookie,
    "primary cookie missing",
  );

  const body = await response.text();
  assert(
    body.includes("window.location.replace"),
    "settle redirect is not replace",
  );
  assert(
    body.includes(confirmationURL.replaceAll("&", "\\u0026")),
    "confirmation URL missing",
  );
  assert(!body.includes(secret), "primary secret leaked into HTML");
  const nonce = response.headers.get("content-security-policy")?.match(
    /script-src 'nonce-([^']+)'/,
  )?.[1];
  assert(Boolean(nonce), "CSP nonce could not be parsed");
  assert(body.includes(`<script nonce="${nonce}">`), "script nonce mismatch");
});

Deno.test("fallback Google handoff sets only its scoped script cookie", async () => {
  const secret = "B".repeat(43);
  const confirmationURL =
    "https://spyclash.com/functions/appleAuthBroker?action=confirm-google-transaction&state=reissued-signed-hash-only";
  const cookie = upstreamFallbackTransactionCookie(secret, 300);
  const response = fallbackGoogleTransactionHandoff(confirmationURL, cookie);
  assertStrictHandoffHeaders(response);
  assert(
    response.headers.get("set-cookie") === null,
    "fallback used HTTP cookie",
  );

  const body = await response.text();
  assert(
    body.includes(`document.cookie=${JSON.stringify(cookie)}`),
    "fallback cookie setter missing",
  );
  assert(
    body.includes("window.location.replace"),
    "fallback redirect is not replace",
  );
  assert(
    body.includes(confirmationURL.replaceAll("&", "\\u0026")),
    "fallback confirmation URL missing",
  );
  assert(
    !confirmationURL.includes(secret),
    "fallback secret was placed in the confirmation URL",
  );
  assert(
    body.indexOf(secret) === body.lastIndexOf(secret),
    "fallback secret was duplicated outside its cookie setter",
  );
});

Deno.test("handoff script literals neutralize closing-tag injection", async () => {
  const response = primaryGoogleTransactionHandoff(
    "https://spyclash.com/functions/appleAuthBroker?state=</script><script>alert(1)</script>",
    upstreamTransactionCookie("C".repeat(43), 300),
  );
  const body = await response.text();
  assert(
    !body.includes("</script><script>alert(1)"),
    "script injection remained raw",
  );
  assert(body.includes("\\u003c/script\\u003e"), "closing tag was not escaped");
});
