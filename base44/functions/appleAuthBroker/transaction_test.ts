import {
  clearUpstreamFallbackTransactionCookie,
  clearUpstreamTransactionCookie,
  createUpstreamTransaction,
  UPSTREAM_FALLBACK_TRANSACTION_COOKIE,
  UPSTREAM_TRANSACTION_COOKIE,
  upstreamFallbackTransactionCookie,
  upstreamFallbackTransactionMatches,
  upstreamTransactionCookie,
  upstreamTransactionMatches,
} from "./transaction.ts";

function assert(condition: boolean, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("upstream transaction stores only a hash in state", async () => {
  const transaction = await createUpstreamTransaction();
  assert(transaction.secret.length === 43, "unexpected secret length");
  assert(transaction.secretHash.length === 43, "unexpected hash length");
  assert(
    transaction.secret !== transaction.secretHash,
    "secret leaked as hash",
  );
});

Deno.test("transaction cookie is cross-site safe and bounded by state TTL", async () => {
  const transaction = await createUpstreamTransaction();
  const cookie = upstreamTransactionCookie(transaction.secret, 120);
  assert(cookie.startsWith(`${UPSTREAM_TRANSACTION_COOKIE}=`), "wrong name");
  assert(cookie.includes("Max-Age=120"), "wrong max age");
  assert(cookie.includes("Path=/"), "missing host-only path");
  assert(cookie.includes("HttpOnly"), "missing HttpOnly");
  assert(cookie.includes("Secure"), "missing Secure");
  assert(cookie.includes("SameSite=None"), "missing SameSite=None");
  assert(
    await upstreamTransactionMatches(cookie, transaction.secretHash),
    "valid transaction did not match",
  );
});

Deno.test("Google primary transaction cookie supports cross-site auth", async () => {
  const transaction = await createUpstreamTransaction();
  const cookie = upstreamTransactionCookie(transaction.secret, 300, "None");
  assert(cookie.includes("SameSite=None"), "Google cookie is not cross-site");
  assert(cookie.includes("HttpOnly"), "primary cookie lost HttpOnly");
  assert(
    await upstreamTransactionMatches(cookie, transaction.secretHash),
    "primary transaction cookie did not match",
  );
});

Deno.test("fallback transaction is short-lived and script-settable", async () => {
  const transaction = await createUpstreamTransaction();
  const cookie = upstreamFallbackTransactionCookie(transaction.secret, 900);
  assert(
    cookie.startsWith(`${UPSTREAM_FALLBACK_TRANSACTION_COOKIE}=`),
    "wrong fallback name",
  );
  assert(cookie.includes("Max-Age=300"), "fallback age was not bounded");
  assert(cookie.includes("Path=/functions/"), "fallback path is too broad");
  assert(cookie.includes("Secure"), "fallback cookie lost Secure");
  assert(cookie.includes("SameSite=None"), "fallback is not cross-site");
  assert(
    !cookie.includes("HttpOnly"),
    "JavaScript cannot set an HttpOnly cookie",
  );
  assert(
    await upstreamFallbackTransactionMatches(cookie, transaction.secretHash),
    "fallback transaction cookie did not match",
  );
});

Deno.test("primary and fallback channels are isolated", async () => {
  const primary = await createUpstreamTransaction();
  const fallback = await createUpstreamTransaction();
  const cookieHeader = [
    upstreamTransactionCookie(primary.secret, 300),
    upstreamFallbackTransactionCookie(fallback.secret, 300),
  ].join("; ");

  assert(
    await upstreamTransactionMatches(cookieHeader, primary.secretHash),
    "primary channel did not match its secret",
  );
  assert(
    !await upstreamTransactionMatches(cookieHeader, fallback.secretHash),
    "primary channel accepted fallback secret",
  );
  assert(
    await upstreamFallbackTransactionMatches(cookieHeader, fallback.secretHash),
    "fallback channel did not match its secret",
  );
  assert(
    !await upstreamFallbackTransactionMatches(cookieHeader, primary.secretHash),
    "fallback channel accepted primary secret",
  );
});

Deno.test("missing or substituted browser transaction is rejected", async () => {
  const expected = await createUpstreamTransaction();
  const substituted = await createUpstreamTransaction();
  assert(
    !await upstreamTransactionMatches(null, expected.secretHash),
    "missing cookie matched",
  );
  assert(
    !await upstreamTransactionMatches(
      upstreamTransactionCookie(substituted.secret, 300),
      expected.secretHash,
    ),
    "substituted cookie matched",
  );
  assert(
    !await upstreamFallbackTransactionMatches(
      upstreamFallbackTransactionCookie(substituted.secret, 300),
      expected.secretHash,
    ),
    "substituted fallback cookie matched",
  );
});

Deno.test("transaction clear cookie retains required attributes", () => {
  const cookie = clearUpstreamTransactionCookie();
  assert(cookie.includes("Max-Age=0"), "clear cookie is not expired");
  assert(cookie.includes("Path=/"), "clear cookie has wrong path");
  assert(cookie.includes("HttpOnly"), "clear cookie lost HttpOnly");
  assert(cookie.includes("Secure"), "clear cookie lost Secure");
  assert(cookie.includes("SameSite=None"), "clear cookie lost SameSite=None");
});

Deno.test("fallback transaction clear retains the exact scoped path", () => {
  const cookie = clearUpstreamFallbackTransactionCookie();
  assert(cookie.includes("Max-Age=0"), "fallback clear is not expired");
  assert(cookie.includes("Path=/functions/"), "fallback clear path changed");
  assert(cookie.includes("SameSite=None"), "fallback clear is not cross-site");
});
